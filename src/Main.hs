{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}
module Main where
import Control.Lens                         -- from: lens
import Control.Monad.Except                 -- from: mtl
import Control.Monad.State                  -- from: mtl
import Control.Monad.Trans (MonadIO(..))    -- from: mtl
import Data.Aeson.Lens                      -- from: lens-aeson
import Data.AffineSpace ((.-.))             -- from: vector-space
import Data.ByteString.Lazy (ByteString)    -- from: bytestring
import Data.Foldable
import Data.List (sortBy)
import Data.Monoid ((<>))
import Data.Ratio ((%))
import Data.Text (Text, pack, unpack)       -- from: text
import Data.Text.Lazy (fromStrict)          -- from: text
import Data.Text.Lazy.Encoding (encodeUtf8) -- from: text
import Data.Thyme.Time                      -- from: thyme
import Data.VectorSpace ((^/))              -- from: vector-space
import Text.Read (readMaybe)
import Network.AMQP                         -- from: amqp
import Network.Wreq (responseBody,
                     responseHeader,
                     responseStatus,
                     statusCode)            -- from: wreq
import qualified Network.Wreq as Wreq       -- from: wreq

import Max
import Skippable
import Types

-- https://developer.github.com/v3/#rate-limiting
-- TODO: Auth
-- TODO: Rate-Limiting awareness
-- TODO: sleep
-- TODO: User-agent
-- TODO: etag


main :: IO ()
main = putStrLn "Hello, Haskell!"

run :: MonadIO m => (Event -> m ()) -> m ()
run f = void . flip runStateT mempty . forever . logErrors $ getData >>= flip getRepos (lift . (trackEvents >>@ liftTracking f))
  where liftTracking :: Monad m => (r -> m a) -> r -> StateT LastSeenEvent m a
        liftTracking f r = lift $ f r

logErrors :: (Show r, MonadIO m) => ExceptT r m a -> m ()
logErrors m = runExceptT m >>= either (liftIO . print) (void . return)

getData :: (MonadError PollError m, MonadIO m) => m (Wreq.Response ByteString)
getData = do r <- liftIO $ Wreq.get "https://api.github.com/events?per_page=200"
             case r ^. responseStatus . statusCode of
               200 -> return r
               x   -> throwError $ StatusError x

inspectRateLimit :: Wreq.Response body -> IO (Maybe NominalDiffTime)
inspectRateLimit r = let foo = r ^? responseHeader "X-RateLimit-Reset" . _Integer . nomd . posx
                         bar = r ^? responseHeader "X-RateLimit-Remaining" . _Integer
                     in sequence $ do foo >>= \a -> bar >>= \b -> return $ do
                                        cur <- getCurrentTime
                                        return $ (a .-. cur) ^/ (b % 1)
  where nomd = lens fromSeconds $ \_ -> truncate @Double . toSeconds
        posx = iso posixSecondsToUTCTime utcTimeToPOSIXSeconds

getRepos :: (AsValue body, Applicative m) => Wreq.Response body -> (Event -> m ()) -> m ()
getRepos r k = traverse_ k . sortBy sortf $ r ^.. responseBody . values . test
  where sortf = curry $ uncurry compare . (view $ eventId `alongside` eventId)

trackEvents :: (MonadState LastSeenEvent m, Skippable m) => Event -> m ()
trackEvents (Event i _ _) = do let cur = Max $ Just i
                               last <- state $ \s -> (s, s <> Max (Just i))
                               if last < cur then return ()
                                             else skip

printEvents :: MonadIO m => Event -> m ()
printEvents = liftIO . print

eventId :: Lens' Event EventId
eventId f (Event i et r) = (\j -> Event j et r) <$> f i

eventType :: Lens' Event EventType
eventType f (Event i et r) = (\s -> Event i s r) <$> f et

repo :: Lens' Event Repo
repo f (Event i et r) = Event i et <$> f r

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

bindAMQPChan :: IO (Connection, Channel)
bindAMQPChan = do conn <- openConnection "127.0.0.1" "/" "guest" "guest"
                  chan <- openChannel conn
                  declareExchange chan newExchange { exchangeName = "github-events",
                                                     exchangeType = "topic" }
                  return (conn, chan)

publishEvent :: Channel -> Event -> IO ()
publishEvent chan evt = void $ publishMsg chan "github-events" (evt ^. eventType . re et)
  newMsg { msgBody = encodeUtf8 (fromStrict $ evt ^. repo . coerced) }
