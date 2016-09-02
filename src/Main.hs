{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}
module Main where
import Control.Lens                         -- from: lens
import Control.Monad.Except                 -- from: mtl
import Control.Monad.Reader                 -- from: mtl
import Control.Monad.Trans (MonadIO(..))    -- from: mtl
import Data.Aeson.Lens                      -- from: lens-aeson
import Data.ByteString.Lazy (ByteString)    -- from: bytestring
import Data.Foldable
import Data.List (sortBy)
import Data.Text (Text, pack)               -- from: text
import Data.Text.Lazy (fromStrict)          -- from: text
import Data.Text.Lazy.Encoding (encodeUtf8) -- from: text
import Data.Text.Strict.Lens (utf8)         -- from: lens
import Network.AMQP                         -- from: amqp
import Network.Wreq (responseBody,
                     responseStatus,
                     statusCode)            -- from: wreq
import qualified Network.Wreq as Wreq       -- from: wreq
import Options.Applicative                  -- from: optparse-applicative

import RateLimit
import SeenEvents
import Skippable
import Types

-- https://developer.github.com/v3/#rate-limiting
-- TODO: User-agent
-- TODO: etag

data Settings = Settings { _authUser :: Maybe Text,
                           _authToken :: Maybe Text }
  deriving (Eq, Show)

defaultSettings :: Settings
defaultSettings = Settings Nothing Nothing

authUser :: Lens' Settings (Maybe Text)
authUser f s = (\t -> s { _authUser = t }) <$> f (_authUser s)

authToken :: Lens' Settings (Maybe Text)
authToken f s = (\t -> s { _authToken = t }) <$> f (_authToken s)

foo :: Parser Settings
foo = Settings <$> optional (textOption (long "auth-user" <> metavar "USERNAME"))
               <*> optional (textOption (long "auth-token" <> metavar "AUTH_TOKEN"))
  where textOption = fmap pack . strOption

bar :: ParserInfo Settings
bar = info (helper <*> foo) fullDesc

settingsToOpts :: Settings -> Wreq.Options
settingsToOpts s = Wreq.defaults & Wreq.auth .~ (Wreq.basicAuth <$> s ^? authUser . _Just. re utf8
                                                                <*> s ^? authToken . _Just . re utf8)

main :: IO ()
main = execParser bar >>= flip run printEvents . settingsToOpts

run :: MonadIO m => Wreq.Options -> (Event -> m a) -> m ()
run opts f = runEvents $ getData >>= \r -> (getEvents r handlers) >> inspectRateLimit r
  where handlers = trackEvents >>@ lift . lift . lift . lift . f
        runEvents = runSeenEventsT . flip foreverRateLimitT 1000000 . logErrors . flip runReaderT opts

logErrors :: (Show r, MonadIO m) => ExceptT r m a -> m ()
logErrors m = runExceptT m >>= either (liftIO . print) (void . return)

getData :: (MonadReader Wreq.Options m, MonadError PollError m, MonadIO m) => m (Wreq.Response ByteString)
getData = do opts <- ask
             r <- liftIO $ Wreq.getWith opts "https://api.github.com/events?per_page=200"
             case r ^. responseStatus . statusCode of
               200 -> return r
               x   -> throwError $ StatusError x

getEvents :: (AsValue body, Applicative m) => Wreq.Response body -> (Event -> m ()) -> m ()
getEvents r k = traverse_ k . sortBy sortf $ r ^.. responseBody . values . toMaster . isOrg . test
  where sortf = curry $ uncurry compare . (view $ eventId `alongside` eventId)

printEvents :: MonadIO m => Event -> m ()
printEvents = liftIO . print

repo' :: AsValue s => ReifiedFold s Repo
repo' = Repo <$> Fold (key "repo" . key "name" . _String)

blah :: AsValue s => ReifiedFold s EventType
blah = Fold $ key "type" . _String . et

test :: AsValue s => Fold s Event
test = runFold $ Event <$> (Fold $ key "id" . _String . _Integer) <*> blah <*> repo'

toMaster :: (AsValue s, Choice p, Applicative f) => Optic' p f s s
toMaster = filtered . has $ key "payload" . key "ref" . filtered (== "refs/heads/master")

isOrg :: (AsValue s, Choice p, Applicative f) => Optic' p f s s
isOrg = filtered . has $ key "org"

bindAMQPChan :: IO (Connection, Channel)
bindAMQPChan = do conn <- openConnection "127.0.0.1" "/" "guest" "guest"
                  chan <- openChannel conn
                  declareExchange chan newExchange { exchangeName = "github-events",
                                                     exchangeType = "topic" }
                  return (conn, chan)

publishEvent :: Channel -> Event -> IO ()
publishEvent chan evt = void $ publishMsg chan "github-events" (evt ^. eventType . re et)
  newMsg { msgBody = encodeUtf8 (fromStrict $ evt ^. repo . coerced) }
