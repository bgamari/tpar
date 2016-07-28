{-# LANGUAGE DeriveGeneric #-}

module TPar.Server.Types where

import Control.Distributed.Process
import Data.Binary
import Data.Time.Clock
import System.Exit
import GHC.Generics

import TPar.Rpc
import TPar.JobMatch
import TPar.Types
import TPar.SubPubStream
import TPar.ProcessPipe

-- | A channel which should be used by a 'Worker' to indicate that a job has
-- been started.
type JobStartedChan = SendPort (SubPubSource ProcessOutput ExitCode)

type JobFinishedChan = SendPort (UTCTime, ExitCode)

data ServerIface =
    ServerIface { serverPid      :: ProcessId
                , enqueueJob     :: RpcSendPort (JobRequest, OutputSink) JobId
                , requestJob     :: RpcSendPort () (Job, JobStartedChan, JobFinishedChan)
                , killJobs       :: RpcSendPort JobMatch [Job]
                , getQueueStatus :: RpcSendPort JobMatch [Job]
                , rerunJobs      :: RpcSendPort JobMatch [Job]
                }
    deriving (Generic)

instance Binary ServerIface
