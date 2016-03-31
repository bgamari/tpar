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

data Job = Job { jobSink    :: Maybe (SinkPort ProcessOutput ExitCode)
               , jobRequest :: JobRequest
               }
         deriving (Generic)

instance Binary Job

data ServerIface =
    ServerIface { enqueueJob  :: RpcSendPort (JobRequest, Maybe (SinkPort ProcessOutput ExitCode)) ()
                , requestJob  :: RpcSendPort () Job
                , getQueueStatus :: RpcSendPort () [JobRequest]
                }
    deriving (Generic)

instance Binary ServerIface

newtype JobName = JobName String
                deriving (Show, Eq, Ord, Binary)

data JobRequest = JobRequest { jobName     :: JobName
                             , jobPriority :: Priority
                             , jobCommand  :: FilePath
                             , jobArgs     :: [String]
                             , jobCwd      :: FilePath
                             , jobEnv      :: Maybe [(String, String)]
                             }
                deriving (Show, Generic)

instance Binary JobRequest

newtype Priority = Priority Int
                 deriving (Eq, Ord, Show, Binary)
