{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}

module TPar.Types where

import Control.Applicative
import System.Exit

import Data.Binary
import GHC.Generics
import Control.Distributed.Process

import TPar.ProcessPipe
import TPar.RemoteStream

newtype JobId = JobId Int
              deriving (Eq, Ord, Show, Binary)

data Job = Job { jobId      :: !JobId
               , jobSink    :: OutputSink
               , jobRequest :: JobRequest
               , jobState   :: !JobState
               }
         deriving (Generic)

instance Binary Job

data OutputSink = NoOutput
                | ToRemoteSink (SinkPort ProcessOutput ExitCode)
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

data JobState = Queued
                -- ^ the job is waiting to be run
              | Running ProcessId
                -- ^ the job currently running on the worker with the given
                -- 'ProcessId'
              | Finished ExitCode
                -- ^ the job has finished with the given 'ExitCode'
              | Failed String
                -- ^ something happened to the worker which was running the job
              | Killed
                -- ^ the job was manually killed
              deriving (Show, Generic)

instance Binary JobState
