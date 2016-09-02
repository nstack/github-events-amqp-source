{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
module SeenEvents (MonadSeenEvents(..), runSeenEventsT, trackEvents) where
import Control.Monad.State -- from: mtl
import Data.Monoid ((<>))

import Max
import Skippable
import Types

type LastSeenEvent = Max EventId

data Age = OlderThanLatestSeen | NewerThanLatestSeen
  deriving (Eq, Show)

class MonadSeenEvents m where
  updateMaxId :: EventId -> m Age

newtype SeenEventsT m a = SeenEventsT { runSeenEventsT' :: StateT LastSeenEvent m a }
  deriving (Functor, Applicative, Monad, MonadTrans, MonadIO)

runSeenEventsT :: Monad m => SeenEventsT m a -> m a
runSeenEventsT = flip evalStateT mempty . runSeenEventsT'

instance {-# OVERLAPPING  #-} Monad m => MonadSeenEvents (SeenEventsT m) where
  updateMaxId i = SeenEventsT . state $ \s -> (if pure i > s then NewerThanLatestSeen
                                                             else OlderThanLatestSeen,
                                                s <> pure i)

instance {-# OVERLAPPABLE #-} (MonadSeenEvents m, Monad m, MonadTrans t)
    => MonadSeenEvents (t m) where
  updateMaxId = lift . updateMaxId

trackEvents :: (MonadSeenEvents m, Monad m, Skippable m) => Event -> m ()
trackEvents (Event i _ _) = do age <- updateMaxId i
                               case age of
                                 OlderThanLatestSeen -> skip
                                 NewerThanLatestSeen -> return ()
