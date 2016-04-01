{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}

module Types where

import Control.Applicative
import System.Exit

import Data.Binary
import GHC.Generics
import Control.Distributed.Process

import ProcessPipe
import Rpc
import RemoteStream

newtype JobId = JobId Int
              deriving (Eq, Ord, Show, Binary)

data Job = Job { jobId      :: !JobId
               , jobSink    :: Maybe (SinkPort ProcessOutput ExitCode)
               , jobRequest :: JobRequest
               , jobState   :: !JobState
               }
         deriving (Generic)

instance Binary Job

data ServerIface =
    ServerIface { serverPid :: ProcessId
                , enqueueJob  :: RpcSendPort (JobRequest, Maybe (SinkPort ProcessOutput ExitCode)) JobId
                , requestJob  :: RpcSendPort () (Job, SendPort ExitCode)
                , getQueueStatus :: RpcSendPort () [Job]
                }
    deriving (Generic)

instance Binary ServerIface

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
              | Failed
              deriving (Show, Generic)

instance Binary JobState
