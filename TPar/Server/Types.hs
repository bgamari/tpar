{-# LANGUAGE DeriveGeneric #-}

module TPar.Server.Types where

import Control.Distributed.Process
import Data.Binary
import System.Exit
import GHC.Generics

import TPar.Rpc
import TPar.JobMatch
import TPar.Types

data ServerIface =
    ServerIface { serverPid      :: ProcessId
                , enqueueJob     :: RpcSendPort (JobRequest, OutputSink) JobId
                , requestJob     :: RpcSendPort () (Job, SendPort ExitCode)
                , killJobs       :: RpcSendPort JobMatch [Job]
                , getQueueStatus :: RpcSendPort JobMatch [Job]
                }
    deriving (Generic)

instance Binary ServerIface
