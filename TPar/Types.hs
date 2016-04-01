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
               , jobSink    :: Maybe (SinkPort ProcessOutput ExitCode)
               , jobRequest :: JobRequest
               , jobState   :: !JobState
               }
         deriving (Generic)

instance Binary Job

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
              | Running ProcessId
              | Finished ExitCode
              | Failed String
              | Killed
              deriving (Show, Generic)

instance Binary JobState
