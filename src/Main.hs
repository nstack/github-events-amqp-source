{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}
module Main where
import Control.Lens                   -- from: lens
import Control.Monad.Except           -- from: mtl
import Control.Monad.Reader           -- from: mtl
import Control.Monad.State            -- from: mtl
import Control.Monad.Trans            -- from: mtl
import Control.Monad.Trans.Maybe      -- from: transformers
import Data.Aeson                     -- from: aeson
import Data.Aeson.Lens                -- from: lens-aeson
import Data.Foldable
import Data.List
import Data.Monoid
import Data.Text (Text, pack, unpack) -- from: text
import qualified Data.Text as T       -- from: text
import Text.Read (readMaybe)
import Network.Wreq (responseBody,
                     responseStatus,
                     statusCode)      -- from: wreq
import qualified Network.Wreq as Wreq -- from: wreq

-- https://developer.github.com/v3/#rate-limiting
-- TODO: Auth
-- TODO: Rate-Limiting awareness
-- TODO: sleep
-- TODO: User-agent
-- TODO: etag

type EventId = Integer
type SleepTime = Int
type LastSeenEvent = Max EventId

data PollError = StatusError Int | BodyError String
  deriving (Eq, Show)

data EventType = PushEvent
  deriving (Eq, Show)

newtype Repo = Repo Text
  deriving (Eq, Show)
data Event = Event EventId EventType Repo
  deriving (Eq, Show)

newtype Max a = Max { getMax :: Maybe a } deriving (Eq, Ord, Show)

instance Ord a => Monoid (Max a) where
  mempty                = Max Nothing
  Max a `mappend` Max b = Max $ max a b

class Skippable m where
  skip :: m ()

instance Applicative m => Skippable (MaybeT m) where
  skip = MaybeT (pure Nothing)

main :: IO ()
main = putStrLn "Hello, Haskell!"

run :: MonadIO m => (Event -> m ()) -> m ()
run f = void . flip runStateT mempty . forever . logErrors $ getData >>= flip getRepos (lift . (trackEvents >>@?! liftTracking f))
  where liftTracking :: Monad m => (r -> m a) -> r -> StateT LastSeenEvent m a
        liftTracking f r = lift $ f r

logErrors :: (Show r, MonadIO m) => ExceptT r m a -> m ()
logErrors m = runExceptT m >>= either (liftIO . print) (void . return)

getData :: (MonadError PollError m, MonadIO m) => m Value
getData = do r <- liftIO $ Wreq.get "https://api.github.com/events?per_page=200"
             case r ^. responseStatus . statusCode of
               200 -> return ()
               x   -> throwError $ StatusError x
             case eitherDecode (r ^. responseBody) of
               Left e -> throwError $ BodyError e
               Right x -> return x

getRepos :: Applicative m => Value -> (Event -> m ()) -> m ()
getRepos v k = traverse_ k . sortBy sortf $ v ^.. values . test
  where sortf = curry $ uncurry compare . (view $ eventId `alongside` eventId)

trackEvents :: (MonadState LastSeenEvent m, Skippable m) => Event -> m ()
trackEvents (Event i _ _) = do let cur = Max $ Just i
                               last <- state $ \s -> (s, s <> Max (Just i))
                               if last < cur then return ()
                                             else skip

printEvents :: MonadIO m => Event -> m ()
printEvents = liftIO . print

resetSkip :: (Functor m) => MaybeT m () -> m ()
resetSkip = fmap (maybe () id) . runMaybeT

eventId :: Lens' Event EventId
eventId f (Event i et r) = (\j -> Event j et r) <$> f i

eventType :: Lens' Event EventType
eventType f (Event i et r) = (\s -> Event i s r) <$> f et

repo :: Lens' Event Repo
repo f (Event i et r) = Event i et <$> f r

parseEventType :: Text -> Maybe EventType
parseEventType "PushEvent" = Just PushEvent
parseEventType _           = Nothing

et :: Prism' Text EventType
et = prism' (pack . show) parseEventType

repo' :: AsValue s => ReifiedFold s Repo
repo' = Repo <$> Fold (key "repo" . key "name" . _String)

blah :: AsValue s => ReifiedFold s EventType
blah = Fold $ key "type" . _String . et

test :: AsValue s => Fold s Event
test = runFold $ Event <$> (Fold $ key "id" . _String . readInteger) <*> blah <*> repo'

readInteger :: Prism' Text Integer
readInteger = prism' (pack . show) (readMaybe . unpack)

(>>@) :: Monad m => (r -> m a) -> (r -> m b) -> r -> m b
a >>@ b = runReaderT $ ReaderT a >> ReaderT b

(>>@?) :: Monad m => (r -> MaybeT m a) -> (r -> m b) -> r -> MaybeT m ()
a >>@? b = \r -> MaybeT $ do x <- runMaybeT (a r)
                             case x of
                               Nothing -> return Nothing
                               Just  _ -> Just <$> void (b r)

(>>@?!) :: Monad m => (r -> MaybeT m a) -> (r -> m b) -> r -> m ()
a >>@?! b = \r -> do x <- runMaybeT (a r)
                     case x of
                       Nothing -> return ()
                       Just  _ -> void $ b r
