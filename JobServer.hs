{-# LANGUAGE RecordWildCards #-}

module JobServer ( -- * Workers
                   Worker
                 , localWorker
                 , sshWorker
                 , runRemoteWorker
                   -- * Running
                 , server
                 , runServer
                 ) where

import Control.Error
import Control.Applicative
import Control.Monad (void)
import Data.Binary
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import Data.Foldable
import Control.Monad (forever, filterM)
import qualified Data.Heap as H
import qualified Data.Map as M
import Control.Distributed.Process

import System.IO (Handle, hClose, hSetBuffering, BufferMode(NoBuffering))
import System.Exit
import Control.Concurrent.STM

import Pipes
import qualified Pipes.Prelude as PP

import Rpc
import RemoteStream
import ProcessPipe
import Types
import Debug.Trace

type Worker = JobRequest -> Producer ProcessOutput Process ExitCode

localWorker :: Worker
localWorker req = runProcess (jobCommand req) (jobArgs req) Nothing

sshWorker :: String -> FilePath -> Worker
sshWorker host rootPath req = do
    runProcess "ssh" ([host, "--", "cd", cwd, ";", jobCommand req]++jobArgs req) Nothing
  where
    cwd = rootPath ++ "/" ++ jobCwd req  -- HACK

runRemoteWorker :: ServerIface -> Process ()
runRemoteWorker (ServerIface {..}) = forever $ do
    (job, finishedSp) <- callRpc requestJob ()
    code <- runJobWithWorker job localWorker
    sendChan finishedSp code

runJobWithWorker :: Job -> Worker -> Process ExitCode
runJobWithWorker (Job {..}) worker =
    let intoSink = case jobSink of
                     Just sink -> connectSink sink
                     Nothing   -> \src -> runEffect $ src >-> PP.drain
    in intoSink $ worker jobRequest

-- | Spawn a process running a server
runServer :: Process ServerIface
runServer = do
    q <- liftIO newJobQueue
    iface <- server q
    announce <- spawnLocal $ forever $ do
        x <- expect :: Process (SendPort ServerIface)
        sendChan x iface
    register "tpar" announce
    return iface

-- | The heart of the server
server :: JobQueue -> Process ServerIface
server jobQueue = do
    (enqueueJob, enqueueJobRp) <- newRpc
    (requestJob, requestJobRp) <- newRpc
    (getQueueStatus, getQueueStatusRp) <- newRpc

    serverPid <- spawnLocal $ void $ forever $ do
        serverPid <- getSelfPid
        receiveWait
            [ matchRpc enqueueJobRp $ \(jobReq, dataStream) -> do
                  liftIO $ traceEventIO "Ben: enqueue"
                  liftIO $ atomically $ do
                      jobId <- getFreshJobId jobQueue
                      queueJob jobQueue jobId dataStream jobReq
                      return (jobId, ())

            , matchRpc' requestJobRp $ \ workerPid () reply -> do
                  liftIO $ traceEventIO "Ben: request job"
                  spawnLocal $ handleJobRequest serverPid jobQueue workerPid reply
                  return ()

            , matchRpc getQueueStatusRp $ \() -> do
                  q <- liftIO $ atomically $ getJobs jobQueue
                  return (q, ())
            ]
    return $ ServerIface {..}

handleJobRequest :: ProcessId
                 -> JobQueue
                 -> ProcessId
                 -> ((Job, SendPort ExitCode) -> Process ())
                 -> Process ()
handleJobRequest serverPid jobQueue workerPid reply = do
    -- get a job
    link serverPid
    monRef <- monitor workerPid
    job <- liftIO $ atomically $ takeQueuedJob jobQueue

    -- send the job to worker
    (finishedSp, finishedRp) <- newChan
    reply (job, finishedSp)
    let jobid = jobId job
    liftIO $ atomically $ setJobState jobQueue jobid (Running workerPid)
    liftIO $ traceEventIO "Ben: job sent"

    -- wait for result
    receiveWait
        [ matchChan finishedRp $ \code -> do
              liftIO $ atomically $ setJobState jobQueue jobid (Finished code)
        , matchIf (\(PortMonitorNotification ref _ _) -> ref == monRef) $
          \(PortMonitorNotification _ _ reason) -> do
              liftIO $ atomically $ setJobState jobQueue jobid (Failed $ show reason)
        ]
    unmonitor monRef


-----------------------------------------------------
-- primitives

-- | Our job queue state
data JobQueue = JobQueue { freshJobIds :: TVar [JobId]
                         , jobQueue    :: TVar (H.Heap (H.Entry Priority JobId))
                         , jobs        :: TVar (M.Map JobId Job)
                         }

getFreshJobId :: JobQueue -> STM JobId
getFreshJobId (JobQueue {..}) = do
    x:xs <- readTVar freshJobIds
    writeTVar freshJobIds xs
    return x

newJobQueue :: IO JobQueue
newJobQueue = JobQueue <$> newTVarIO [ JobId i | i <- [0..] ]
                       <*> newTVarIO H.empty
                       <*> newTVarIO mempty

takeQueuedJob :: JobQueue -> STM Job
takeQueuedJob jq@(JobQueue {..}) = do
    q <- readTVar jobQueue
    case H.viewMin q of
        Nothing -> retry
        Just (H.Entry _ jobid, q') -> do
            writeTVar jobQueue q'
            getJob jq jobid

getJob :: JobQueue -> JobId -> STM Job
getJob (JobQueue {..}) jobId = (M.! jobId) <$> readTVar jobs

setJobState :: JobQueue -> JobId -> JobState -> STM ()
setJobState (JobQueue {..}) jobId newState =
    modifyTVar jobs $ M.alter setState jobId
  where
    setState (Just s) = Just $ s { jobState = newState }
    setState _        = error "setJobState: unknown JobId"

queueJob :: JobQueue -> JobId -> Maybe (SinkPort ProcessOutput ExitCode) -> JobRequest -> STM ()
queueJob (JobQueue {..}) jobId jobSink jobRequest = do
    modifyTVar jobQueue $ H.insert (H.Entry prio jobId)
    modifyTVar jobs $ M.insert jobId (Job {jobState = Queued, ..})
  where
    prio = jobPriority jobRequest

getJobs :: JobQueue -> STM [Job]
getJobs (JobQueue {..}) =
    M.elems <$> readTVar jobs
