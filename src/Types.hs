module Types where
import Data.Text (Text) -- from: text

import Max

type EventId = Integer
type SleepTime = Int
type LastSeenEvent = Max EventId

data PollError = StatusError Int
  deriving (Eq, Show)

data EventType = PushEvent
  deriving (Eq, Show)

newtype Repo = Repo Text
  deriving (Eq, Show)

data Event = Event EventId EventType Repo
  deriving (Eq, Show)