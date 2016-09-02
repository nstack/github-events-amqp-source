{-# LANGUAGE OverloadedStrings #-}
module Settings where
import Control.Applicative ((<|>))
import Control.Lens                   -- from: lens
import Data.Text (Text)               -- from: text
import Data.Text.Strict.Lens (utf8)   -- from: lens
import qualified Network.Wreq as Wreq -- from: wreq

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

settingsToOpts :: Settings -> Wreq.Options
settingsToOpts s = Wreq.defaults & Wreq.auth .~ (Wreq.basicAuth <$> s ^? authUser . _Just . re utf8
                                                                <*> s ^? authToken . _Just . re utf8)
                                 & Wreq.header "User-Agent" .~ ((s ^.. authUser . _Just . re utf8)
                                                            <|> ["nstack:github-events-amqp-source"])