module Max (Max(..)) where

newtype Max a = Max { getMax :: Maybe a } deriving (Eq, Ord, Show)

instance Ord a => Monoid (Max a) where
  mempty                = Max Nothing
  Max a `mappend` Max b = Max $ max a b