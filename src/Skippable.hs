{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE FlexibleInstances #-}
module Skippable (SkipT, Skippable(..), (>>@), resetSkipT) where
import Control.Monad (void)
import Control.Monad.Trans (lift) -- from: mtl
import Control.Monad.Trans.Free   -- from: free

data SkipF f = Skip | Continue f deriving Functor
type SkipT = FreeT SkipF

class Skippable m where
  skip :: m ()

instance Monad m => Skippable (FreeT SkipF m) where
  skip = liftF Skip

resetSkipT :: Monad m => SkipT m () -> m ()
resetSkipT = iterT go
  where go Skip         = return ()
        go (Continue a) = a

(>>@) :: Monad m => (r -> SkipT m a) -> (r -> m b) -> r -> m ()
a >>@ b = \r -> resetSkipT . void $ a r >> lift (b r)
