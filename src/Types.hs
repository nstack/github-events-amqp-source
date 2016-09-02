{-# LANGUAGE OverloadedStrings #-}
module Types where
import Control.Lens           -- from: lens
import Data.Text (Text, pack) -- from: text

type EventId = Integer
type SleepTime = Int

data PollError = StatusError Int
  deriving (Eq, Show)

data EventType = PushEvent
  deriving (Eq, Show)

newtype Repo = Repo Text
  deriving (Eq, Show)

data Event = Event EventId EventType Repo
  deriving (Eq, Show)

parseEventType :: Text -> Maybe EventType
parseEventType "PushEvent" = Just PushEvent
parseEventType _           = Nothing

eventId :: Lens' Event EventId
eventId f (Event i et r) = (\j -> Event j et r) <$> f i

eventType :: Lens' Event EventType
eventType f (Event i et r) = (\s -> Event i s r) <$> f et

repo :: Lens' Event Repo
repo f (Event i et r) = Event i et <$> f r

et :: Prism' Text EventType
et = prism' (pack . show) parseEventType
