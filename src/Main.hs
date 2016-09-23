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
import Data.Text (pack)                     -- from: text
import Data.Text.Lazy (fromStrict)          -- from: text
import Data.Text.Lazy.Encoding (encodeUtf8) -- from: text
import Data.Text.Strict.Lens (unpacked)     -- from: lens
import Network.AMQP                         -- from: amqp
import Network.Wreq (responseBody,
                     responseStatus,
                     statusCode)            -- from: wreq
import qualified Network.Wreq as Wreq       -- from: wreq
import Options.Applicative                  -- from: optparse-applicative

import RateLimit
import SeenEvents
import Settings
import Skippable
import Types

-- https://developer.github.com/v3/#rate-limiting
-- TODO: etag

cmdParser :: Parser Settings
cmdParser = Settings <$> optional (textOption (long "auth-user" <> metavar "USERNAME"))
                     <*> optional (textOption (long "auth-token" <> metavar "AUTH_TOKEN"))
                     <*> option auto (long "minimum-sleep"
                                   <> metavar "MILLISECONDS"
                                   <> value (defaultSettings ^. minSleep))
                     <*> (textOption (long "amqp-user"
                                   <> metavar "USERNAME") <|> pure (defaultSettings ^. amqpUser))
                     <*> (textOption (long "amqp-password"
                                   <> metavar "PASSWORD") <|> pure (defaultSettings ^. amqpPassword))
                     <*> (textOption (long "amqp-host"
                                   <> metavar "HOST") <|> pure (defaultSettings ^. amqpHost))
                     <*> (textOption (long "amqp-virtualhost"
                                   <> metavar "VIRTUALHOST") <|> pure (defaultSettings ^. amqpVirtualHost))
                     <*> (textOption (long "amqp-exchange"
                                   <> metavar "EXCHANGE") <|> pure (defaultSettings ^. amqpExchange))
                     <*> option auto (long "events-per-page"
                                   <> metavar "NUM_PAGES"
                                   <> value (defaultSettings ^. eventsPerPage))
  where textOption = fmap pack . strOption

opts :: ParserInfo Settings
opts = info (helper <*> cmdParser) fullDesc

main :: IO ()
main = execParser opts >>= \s -> do (_, chan) <- bindAMQPChan s
                                    let handler = runReaderT $ (ReaderT . fmap liftIO $ publishEvent s chan)
                                                             >> ReaderT printEvents
                                    runReaderT (run handler) s

run :: (MonadReader Settings m, MonadIO m) => (Event -> m a) -> m ()
run f = runEvents $ getData >>= \r -> (getEvents r handlers) >> inspectRateLimit r
  where handlers = trackEvents >>@ lift . lift . lift . f
        runEvents = runSeenEventsT . runRL . logErrors
        runRL m = view minSleep >>= \s -> foreverRateLimitT m $ s * 1000

logErrors :: (Show r, MonadIO m) => ExceptT r m a -> m ()
logErrors m = runExceptT m >>= either (liftIO . print) (void . return)

getData :: (MonadReader Settings m, MonadError PollError m, MonadIO m) => m (Wreq.Response ByteString)
getData = do settings <- ask
             let url = "https://api.github.com/events?per_page=" <> show (settings ^. eventsPerPage)
             r <- liftIO $ Wreq.getWith (settingsToOpts settings) url
             case r ^. responseStatus . statusCode of
               200 -> return r
               x   -> throwError $ StatusError x

getEvents :: (AsValue body, Applicative m) => Wreq.Response body -> (Event -> m ()) -> m ()
getEvents r k = traverse_ k . sortBy sortf $ r ^.. responseBody . values . toMaster . isOrg . event
  where sortf = curry $ uncurry compare . (view $ eventId `alongside` eventId)

printEvents :: MonadIO m => Event -> m ()
printEvents = liftIO . print

repo' :: AsValue s => ReifiedFold s Repo
repo' = Repo <$> Fold (key "repo" . key "name" . _String)

eventType' :: AsValue s => ReifiedFold s EventType
eventType' = Fold $ key "type" . _String . et

event :: AsValue s => Fold s Event
event = runFold $ Event <$> (Fold $ key "id" . _String . _Integer) <*> eventType' <*> repo'

toMaster :: (AsValue s, Choice p, Applicative f) => Optic' p f s s
toMaster = filtered . has $ key "payload" . key "ref" . filtered (== "refs/heads/master")

isOrg :: (AsValue s, Choice p, Applicative f) => Optic' p f s s
isOrg = filtered . has $ key "org"

bindAMQPChan :: Settings -> IO (Connection, Channel)
bindAMQPChan s = do conn <- openConnection (s ^. amqpHost . unpacked)
                                           (s ^. amqpVirtualHost)
                                           (s ^. amqpUser)
                                           (s ^. amqpPassword)
                    chan <- openChannel conn
                    declareExchange chan newExchange { exchangeName = s ^. amqpExchange,
                                                       exchangeType = "topic" }
                    return (conn, chan)

publishEvent :: Settings -> Channel -> Event -> IO ()
publishEvent s chan evt = void $ publishMsg chan (s ^. amqpExchange) (evt ^. eventType . re et)
  newMsg { msgBody = "https://github.com/" <> encodeUtf8 (fromStrict $ evt ^. repo . coerced) }
