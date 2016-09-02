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
import Data.Text (Text)                     -- from: text
import Data.Text.Lazy (fromStrict)          -- from: text
import Data.Text.Lazy.Encoding (encodeUtf8) -- from: text
import Data.Text.Strict.Lens (utf8,
                              unpacked)     -- from: lens
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
-- TODO: etag

data Settings = Settings { _authUser        :: Maybe Text,
                           _authToken       :: Maybe Text,
                           _minSleep        :: Int,
                           _amqpUser        :: Text,
                           _amqpPassword    :: Text,
                           _amqpHost        :: Text,
                           _amqpVirtualHost :: Text,
                           _amqpExchange    :: Text}
  deriving (Eq, Show)

defaultSettings :: Settings
defaultSettings = Settings Nothing Nothing 1000 "guest" "guest" "127.0.0.1" "/" "github-events"

authUser :: Lens' Settings (Maybe Text)
authUser f s = (\t -> s { _authUser = t }) <$> f (_authUser s)

authToken :: Lens' Settings (Maybe Text)
authToken f s = (\t -> s { _authToken = t }) <$> f (_authToken s)

minSleep :: Lens' Settings Int
minSleep f s = (\t -> s { _minSleep = t }) <$> f (_minSleep s)

amqpUser :: Lens' Settings Text
amqpUser f s = (\t -> s { _amqpUser = t }) <$> f (_amqpUser s)

amqpPassword :: Lens' Settings Text
amqpPassword f s = (\t -> s { _amqpPassword = t }) <$> f (_amqpPassword s)

amqpHost :: Lens' Settings Text
amqpHost f s = (\t -> s { _amqpHost = t }) <$> f (_amqpHost s)

amqpVirtualHost :: Lens' Settings Text
amqpVirtualHost f s = (\t -> s { _amqpVirtualHost = t }) <$> f (_amqpVirtualHost s)

amqpExchange :: Lens' Settings Text
amqpExchange f s = (\t -> s { _amqpExchange = t }) <$> f (_amqpExchange s)

foo :: Parser Settings
foo = Settings <$> option auto (long "auth-user" <> metavar "USERNAME")
               <*> option auto (long "auth-token" <> metavar "AUTH_TOKEN")
               <*> option auto (long "minimum-sleep"
                             <> metavar "MILLISECONDS"
                             <> value (defaultSettings ^. minSleep))
               <*> option auto (long "amqp-user"
                             <> metavar "USERNAME"
                             <> value (defaultSettings ^. amqpUser))
               <*> option auto (long "amqp-password"
                             <> metavar "PASSWORD"
                             <> value (defaultSettings ^. amqpPassword))
               <*> option auto (long "amqp-host"
                             <> metavar "HOST"
                             <> value (defaultSettings ^. amqpHost))
               <*> option auto (long "amqp-virtualhost"
                             <> metavar "VIRTUALHOST"
                             <> value (defaultSettings ^. amqpVirtualHost))
               <*> option auto (long "amqp-exchange"
                             <> metavar "EXCHANGE"
                             <> value (defaultSettings ^. amqpExchange))

bar :: ParserInfo Settings
bar = info (helper <*> foo) fullDesc

settingsToOpts :: Settings -> Wreq.Options
settingsToOpts s = Wreq.defaults & Wreq.auth .~ (Wreq.basicAuth <$> s ^? authUser . _Just . re utf8
                                                                <*> s ^? authToken . _Just . re utf8)
                                 & Wreq.header "User-Agent" .~ ((s ^.. authUser . _Just . re utf8)
                                                            <|> ["nstack:github-events-amqp-source"])

main :: IO ()
main = execParser bar >>= \s -> runReaderT (run printEvents) s

run :: (MonadReader Settings m, MonadIO m) => (Event -> m a) -> m ()
run f = runEvents $ getData >>= \r -> (getEvents r handlers) >> inspectRateLimit r
  where handlers = trackEvents >>@ lift . lift . lift . f
        runEvents = runSeenEventsT . runRL . logErrors
        runRL m = view minSleep >>= \s -> foreverRateLimitT m $ s * 1000

logErrors :: (Show r, MonadIO m) => ExceptT r m a -> m ()
logErrors m = runExceptT m >>= either (liftIO . print) (void . return)

getData :: (MonadReader Settings m, MonadError PollError m, MonadIO m) => m (Wreq.Response ByteString)
getData = do opts <- settingsToOpts <$> ask
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

bindAMQPChan :: Settings -> IO (Connection, Channel)
bindAMQPChan s = do conn <- openConnection (s ^. amqpHost . unpacked)
                                           (s ^. amqpPassword)
                                           (s ^. amqpUser)
                                           (s ^. amqpPassword)
                    chan <- openChannel conn
                    declareExchange chan newExchange { exchangeName = s ^. amqpExchange,
                                                       exchangeType = "topic" }
                    return (conn, chan)

publishEvent :: Channel -> Event -> IO ()
publishEvent chan evt = void $ publishMsg chan "github-events" (evt ^. eventType . re et)
  newMsg { msgBody = encodeUtf8 (fromStrict $ evt ^. repo . coerced) }
