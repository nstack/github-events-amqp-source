{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE TypeApplications #-}
module RateLimit (Reset, Remaining, Microseconds,
                  LimitMonad(..), runRateLimitT, applyRateLimit) where
import Control.Monad.State      -- from: mtl
import Data.AffineSpace ((.-.)) -- from: vector-space
import Data.Ratio ((%))
import Data.Thyme               -- from: thyme
import Data.VectorSpace ((^/))  -- from: vector-space

type Reset = UTCTime
type Remaining = Integer
type Microseconds = Integer

class LimitMonad m where
  limitFor :: NominalDiffTime -> m ()

newtype RateLimitT m a = RateLimitT { runRateLimitT' :: StateT NominalDiffTime m a }
  deriving (Functor, Applicative, Monad, MonadTrans, MonadIO)

runRateLimitT :: Monad m => RateLimitT m a -> (Microseconds -> a -> m r) -> m r
runRateLimitT m f = do (a, s) <- runStateT (runRateLimitT' m) $ fromSeconds @Integer 0
                       f (truncate @Double . (* 1000000) . toSeconds $ s) a

instance Monad m => LimitMonad (RateLimitT m) where
  limitFor a = RateLimitT $ put a

applyRateLimit :: (MonadIO m, LimitMonad m) => Reset -> Remaining -> m ()
applyRateLimit reset remain = do cur <- liftIO getCurrentTime
                                 limitFor $ (reset .-. cur) ^/ (remain % 1)