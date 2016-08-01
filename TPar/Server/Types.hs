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
-- been started. It provides a 'SendPort' which will be called by the server to indicate that any atomic watches have been established and that the job can proceed.
type JobStartedNotify = RpcSendPort (SubPubSource ProcessOutput ExitCode) ()

-- | A channel which should be used by a 'Worker' to indicate that a job has
-- finished.
type JobFinishedChan = SendPort (UTCTime, ExitCode)

data ServerIface =
    ServerIface { protocolVersion :: ProtocolVersion
                , serverPid       :: ProcessId
                , enqueueJob      :: RpcSendPort (JobRequest, Maybe JobStartingNotify) JobId
                , requestJob      :: RpcSendPort () (Job, JobStartedNotify, JobFinishedChan)
                , killJobs        :: RpcSendPort JobMatch [Job]
                , getQueueStatus  :: RpcSendPort JobMatch [Job]
                , rerunJobs       :: RpcSendPort JobMatch [Job]
                }
    deriving (Generic)

instance Binary ServerIface

type ProtocolVersion = Int

currentProtocolVersion :: ProtocolVersion
currentProtocolVersion = 5

{- $ the-story

Starting a job (in the general case with an atomic monitor) happens as follows,

1. An 'enqueueJob' request is sent to the server. This request carries a
'JobStartingNotify' which will be used to guarantee that the job doesn't start
before the monitor is established.

2. The server places the job on the queue in the 'Queued' state.

3. A worker sends a 'requestJob' request to the server, the job is de-queued,
moved to 'Starting' state, and sent to the worker.

4. The worker creates a (paused) 'SubPubSource' for the job and notifies the
server with the 'JobStartedNotify'. The worker then waits on the result of the
'SubPubSource'.

5. The server notifies the job originator of the 'SubPubSource' with the
'JobStartingNotify' included in the 'enqueueJob' request.

6. The originator subscribes to the 'SubPubSource' and returns a confirmation to
the server.

7. The server starts the 'SubPubSource', moves the job to the 'Running' state,
and waits for notification on the 'JobFinishedChan'.

8. Optional: The server may kill the job due to a 'killJobs' request. In this
case the worker process running the job is asked to exit and the job is moved to
the 'Killed' state.

9. The worker eventually finishes the job and notifies the server on the
'JobFinishedChan'.

10. The server moves the job to either 'Failed' or 'Finished' state.

-}
