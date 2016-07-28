{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE RecordWildCards #-}

module TPar.Types where

import Control.Applicative
import System.Exit

import Data.Binary
import GHC.Generics
import Control.Distributed.Process
import Data.Time.Clock
import Data.Time.Calendar

import TPar.ProcessPipe
import TPar.SubPubStream

newtype JobId = JobId Int
              deriving (Eq, Ord, Show, Binary)

data Job = Job { jobId      :: !JobId
               , jobSink    :: !OutputSink
               , jobRequest :: JobRequest
               , jobState   :: !JobState
               }
         deriving (Generic)

instance Binary Job

data OutputSink = NoOutput
                | ToFiles FilePath FilePath
                deriving (Generic)

instance Binary OutputSink

newtype JobName = JobName String
                deriving (Show, Eq, Ord, Binary)

data JobRequest = JobRequest { jobName     :: !JobName
                             , jobPriority :: !Priority
                             , jobCommand  :: FilePath
                             , jobArgs     :: [String]
                             , jobCwd      :: FilePath
                             , jobEnv      :: Maybe [(String, String)]
                             }
                deriving (Show, Generic)

instance Binary JobRequest

newtype Priority = Priority Int
                 deriving (Eq, Ord, Show, Binary)

data JobState = Queued { jobQueueTime    :: !UTCTime }
                -- ^ the job is waiting to be run
              | Starting { jobProcessId  :: !ProcessId
                         , jobQueueTime  :: !UTCTime
                         , jobStartingTime :: !UTCTime
                         }
                -- ^ the job is currently starting on the given worker.
              | Running { jobProcessId   :: !ProcessId
                        , jobMonitor     :: !(SubPubSource ProcessOutput ExitCode)
                        , jobQueueTime   :: !UTCTime
                        , jobStartTime   :: !UTCTime }
                -- ^ the job currently running on the worker with the given
                -- 'ProcessId'
              | Finished { jobExitCode   :: !ExitCode
                         , jobQueueTime  :: !UTCTime
                         , jobStartTime  :: !UTCTime
                         , jobFinishTime :: !UTCTime }
                -- ^ the job has finished with the given 'ExitCode'
              | Failed { jobErrorMsg     :: !String
                       , jobQueueTime    :: !UTCTime
                       , jobStartTime    :: !UTCTime
                       , jobFailedTime   :: !UTCTime }
                -- ^ something happened to the worker which was running the job
              | Killed { jobQueueTime    :: !UTCTime
                       , jobKilledStartTime :: !(Maybe UTCTime)
                       , jobKilledTime   :: !UTCTime }
                -- ^ the job was manually killed
              deriving (Show, Generic)

jobMaybeStartTime :: JobState -> Maybe UTCTime
jobMaybeStartTime (Queued{})     = Nothing
jobMaybeStartTime (Starting{})   = Nothing
jobMaybeStartTime (Running{..})  = Just jobStartTime
jobMaybeStartTime (Finished{..}) = Just jobStartTime
jobMaybeStartTime (Failed{..})   = Just jobStartTime
jobMaybeStartTime (Killed{..})   = jobKilledStartTime

instance Binary JobState

instance Binary DiffTime where
    get = picosecondsToDiffTime <$> get
    put = put . diffTimeToPicoseconds

instance Binary Day where
    get = ModifiedJulianDay <$> get
    put = put . toModifiedJulianDay

instance Binary UTCTime where
    get = UTCTime <$> get <*> get
    put (UTCTime a b) = put a >> put b
