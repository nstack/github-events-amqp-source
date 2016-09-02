{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}
module RateLimit (Reset, Remaining, Microseconds, MinimumSleep,
                  LimitMonad(..), runRateLimitT,
                  applyRateLimit, foreverRateLimitT, inspectRateLimit) where
import Control.Concurrent (threadDelay)
import Control.Lens ((^?), lens, iso) -- from: lens
import Control.Monad.State            -- from: mtl
import Data.Aeson.Lens (_Integer)     -- from: lens-aeson
import Data.AffineSpace ((.-.))       -- from: vector-space
import Data.Ratio ((%))
import Data.Thyme                     -- from: thyme
import Data.Thyme.Time                -- from: thyme
import Data.VectorSpace ((^/))        -- from: vector-space
import Network.Wreq (Response,
                     responseHeader)  -- from: wreq

type Reset = UTCTime
type Remaining = Integer
type Microseconds = Int
type MinimumSleep = Microseconds

class LimitMonad m where
  limitFor :: NominalDiffTime -> m ()

newtype RateLimitT m a = RateLimitT { runRateLimitT' :: StateT NominalDiffTime m a }
  deriving (Functor, Applicative, Monad, MonadTrans, MonadIO)

runRateLimitT :: Monad m => RateLimitT m a -> MinimumSleep -> (Microseconds -> a -> m r) -> m r
runRateLimitT m minsleep f = do (a, s) <- runStateT (runRateLimitT' m) $ fromSeconds minsleep
                                f (truncate @Double . (* 1000000) . toSeconds $ s) a

instance {-# OVERLAPPING  #-} Monad m => LimitMonad (RateLimitT m) where
  limitFor a = RateLimitT $ put a

instance {-# OVERLAPPABLE #-} (LimitMonad m, Monad m, MonadTrans t) => LimitMonad (t m) where
  limitFor a = lift $ limitFor a

applyRateLimit :: (MonadIO m, LimitMonad m) => Reset -> Remaining -> m ()
applyRateLimit reset remain = do cur <- liftIO getCurrentTime
                                 limitFor $ (reset .-. cur) ^/ (remain % 1)

foreverRateLimitT :: MonadIO m => RateLimitT m a -> MinimumSleep -> m r
foreverRateLimitT m ms = forever $ runRateLimitT m ms delay
  where delay sleep _ = liftIO $ threadDelay sleep

inspectRateLimit :: (MonadIO m, LimitMonad m) => Response body -> m ()
inspectRateLimit r = let foo = r ^? responseHeader "X-RateLimit-Reset" . _Integer . nomd . posx
                         bar = r ^? responseHeader "X-RateLimit-Remaining" . _Integer
                         lim = sequence $ applyRateLimit <$> foo <*> bar
                     in maybe () (const ()) <$> lim
  where nomd = lens fromSeconds $ \_ -> truncate @Double . toSeconds
        posx = iso posixSecondsToUTCTime utcTimeToPOSIXSeconds
