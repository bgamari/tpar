{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE NamedFieldPuns #-}

module TPar.Server
    ( -- * Workers
      Worker
    , localWorker
    , sshWorker
    , runRemoteWorker
      -- * Running the server
    , server
    , runServer
      -- * Convenience wrappers
    , enqueueAndFollow
    ) where

import Control.Error
import Control.Applicative
import Control.Monad (void, forever, filterM)
import Control.Monad.Catch
import Data.Foldable
import Data.Traversable
import qualified Data.Heap as H
import qualified Data.Map as M
import qualified Data.Set as S
import Control.Monad.Catch (finally, bracket)
import Control.Distributed.Process hiding (finally, bracket)
import Data.Time.Clock

import System.IO ( openFile, hClose, IOMode(..))
import System.Exit
import Control.Concurrent.STM

import Pipes

import TPar.Rpc
import TPar.SubPubStream as SubPub
import TPar.ProcessPipe
import TPar.Server.Types
import TPar.Types
import TPar.JobMatch
import TPar.Utils

-----------------------------------------------
-- Convenience wrappers

enqueueAndFollow :: ServerIface -> JobRequest
                 -> Process (Producer ProcessOutput Process ExitCode)
enqueueAndFollow iface jobReq = do
    (rpcSp, rpcRp) <- newRpc
    jobId <- callRpc (enqueueJob iface) (jobReq, Just rpcSp)
    receiveWait
        [ matchRpc rpcRp $ \subPub -> do
              mprod <- subscribe subPub
              case mprod of
                Just prod -> return ((), prod)
                Nothing   -> fail "enqueueAndFollow: Initial subscription failed"
        ]

-----------------------------------------------
-- Workers

type Worker = JobRequest -> Producer ProcessOutput Process ExitCode

localWorker :: Worker
localWorker req = runProcess (jobCommand req) (jobArgs req) Nothing

sshWorker :: String -> FilePath -> Worker
sshWorker host rootPath req = do
    runProcess "ssh" ([host, "--", "cd", cwd, ";", jobCommand req]++jobArgs req) Nothing
  where
    cwd = rootPath ++ "/" ++ jobCwd req  -- HACK

runRemoteWorker :: ServerIface -> Process ()
runRemoteWorker (ServerIface {..}) = forever runOneJob
  where
    runOneJob = do
        doneVar <- liftIO newEmptyTMVarIO
        -- We run each process in a separate thread to ensure that ProcessKilled
        -- exceptions go to the Process that is actually running the job being
        -- killed
        let finished = liftIO $ atomically $ putTMVar doneVar ()
        _pid <- spawnLocal $ flip finally finished $ do
            Right (job, notifyJobStarted, jobFinishedSp) <- callRpc requestJob ()
            tparDebug $ "have job "++show (jobId job)
            result <- runJobWithWorker job notifyJobStarted localWorker
            finishedTime <- liftIO getCurrentTime
            sendChan jobFinishedSp (finishedTime, result)

        liftIO $ atomically $ takeTMVar doneVar

runJobWithWorker :: Job
                 -> JobStartedNotify
                 -> Worker
                 -> Process ExitCode
runJobWithWorker (Job {..}) notifyJobStarted worker = do
    --let intoSink = case jobSink of
    --                 NoOutput          -> \src -> cat
    --                 ToFiles so se     -> \src ->
    --                     withOutFiles so se $ \hStdout hStderr -> do
    --                     src >-> processOutputToHandles hStdout hStderr
    (start, subPub, readRet) <- SubPub.fromProducer' $ worker jobRequest
    -- wait for confirmation from server before starting
    Right () <- callRpc notifyJobStarted subPub
    start
    either throwM pure =<< liftIO (atomically readRet)
  where
    withOutFiles outPath errPath action
      | outPath == errPath = withOutFile outPath $ \h -> action h h
      | otherwise          = withOutFile outPath $ \out ->
                             withOutFile errPath $ \err -> action out err
    withOutFile path = bracket (liftIO $ openFile path WriteMode) (liftIO . hClose)

------------------------------------------------
-- the server

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
    (killJobs, killJobsRp) <- newRpc
    (rerunJobs, rerunJobsRp) <- newRpc

    serverPid <- spawnLocal $ void $ forever $ do
        serverPid <- getSelfPid
        receiveWait
            [ matchRpc enqueueJobRp $ \(jobReq, notifyOriginator) -> do
                  tparDebug "enqueue"
                  jobQueueTime <- liftIO getCurrentTime
                  liftIO $ atomically $ do
                      jobId <- getFreshJobId jobQueue
                      queueJob jobQueue jobId jobQueueTime jobReq notifyOriginator
                      return (jobId, ())

            , matchRpc' requestJobRp $ \ workerPid () reply -> do
                  tparDebug "request job"
                  spawnLocal $ do
                      link serverPid
                      handleJobRequest jobQueue workerPid reply
                  return ()

            , matchRpc getQueueStatusRp $ \match -> do
                  q <- liftIO $ atomically $ getJobs jobQueue
                  let filtered = filter (jobMatches match) q
                  return (filtered, ())

            , matchRpc killJobsRp $ \match -> do
                  killedJobs <- handleKillJobs jobQueue match
                  return (killedJobs, ())

            , matchRpc rerunJobsRp $ \match -> do
                  reran <- handleRerunJobs jobQueue match
                  return (reran, ())
            ]
    return $ ServerIface {..}

handleJobRequest :: JobQueue
                 -> ProcessId
                 -> ((Job, JobStartedNotify, JobFinishedChan) -> Process ())
                 -> Process ()
handleJobRequest jobQueue workerPid reply = do
    -- get a job
    monRef <- monitor workerPid
    job <- liftIO $ atomically $ takeQueuedJob jobQueue

    -- send the job to worker
    (startedSp, startedRp) <- newRpc
    (finishedSp, finishedRp) <- newChan
    reply (job, startedSp, finishedSp)
    let jobid = jobId job
        jobProcessId = workerPid
        Queued {jobQueueTime} = jobState job
    jobStartingTime <- liftIO getCurrentTime
    liftIO $ atomically $ setJobState jobQueue jobid (Starting {..})
    tparDebug $ "job "++show jobid++" starting"

    -- wait for started notification
    jobMonitor <- receiveWait
        [matchRpc startedRp $ \jobMonitor -> do
            flip traverse (jobStartingNotify job) $ \notifyOriginator -> do
                res <- callRpc notifyOriginator jobMonitor
                case res of
                  Right () -> return ()
                  Left reason ->
                      say $ "Job starting notification to "++show notifyOriginator++" failed. Starting anyways."
            return ((), jobMonitor)
        ]
    jobStartTime <- liftIO getCurrentTime
    liftIO $ atomically $ setJobState jobQueue jobid (Running {..})
    tparDebug $ "job "++show jobid++" running"

    -- wait for result
    receiveWait
        [ matchChan finishedRp $ \(jobFinishTime, jobExitCode) ->
              liftIO $ atomically $ setJobState jobQueue jobid (Finished {..})

        , matchIf (\(ProcessMonitorNotification ref _ _) -> ref == monRef) $
          \(ProcessMonitorNotification _ _ reason) -> do
              tparDebug $ "job "++show jobid++" failed"
              jobFailedTime <- liftIO getCurrentTime
              let jobErrorMsg = show reason
              liftIO $ atomically $ setJobState jobQueue jobid (Failed {..})
        ]
    unmonitor monRef

handleKillJobs :: JobQueue -> JobMatch -> Process [Job]
handleKillJobs jq@(JobQueue {..}) match = do
    let shouldBeKilled :: Job -> Maybe (Maybe ProcessId, JobId)
        shouldBeKilled job@(Job {..})
          | Running {..} <- jobState
          , jobMatches match job    = Just (Just jobProcessId, jobId)
          | Queued {..}  <- jobState
          , jobMatches match job    = Just (Nothing, jobId)
          | otherwise               = Nothing
    jobsToKill <- liftIO $ atomically $ mapMaybe shouldBeKilled <$> getJobs jq
    say $ "killing "++show jobsToKill
    jobKilledTime <- liftIO getCurrentTime
    killed <- forM jobsToKill $ \(pid, jobid) -> do
        maybe (return ()) (flip exit ProcessKilled) pid
        liftIO $ atomically $ do
            oldState <- updateJob jq jobid $ \job ->
              let state' = case jobState job of
                             Queued {..}     -> Killed { jobKilledStartTime = Nothing, ..}
                             Running {..}    -> Killed { jobKilledStartTime = Just jobStartTime, .. }
                             s               -> s
              in (job {jobState=state'}, jobState job)
            case oldState of
                Queued {}  -> do
                    modifyTVar jobQueue $ H.fromList . filter (\(_, job') -> job' /= jobid) . toList
                    return $ Just jobid
                Running {} -> return $ Just jobid
                _          -> return Nothing
    let killedSet = S.fromList $ catMaybes killed
    liftIO $ atomically $ filter (\job -> jobId job `S.member` killedSet) <$> getJobs jq

handleRerunJobs :: JobQueue -> JobMatch -> Process [Job]
handleRerunJobs jq@(JobQueue {..}) match = do
    jobQueueTime <- liftIO getCurrentTime
    liftIO $ atomically $ do
        jobs <- getJobs jq
        filterM (\job -> reEnqueueJob jq job jobQueueTime)
            $ filter (jobMatches match) jobs

-----------------------------------------------------
-- primitives

-- | Our job queue state
data JobQueue = JobQueue { freshJobIds :: TVar [JobId]
                         , jobQueue    :: TVar (H.Heap (Priority, JobId))
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
        Just ((_, jobid), q') -> do
            writeTVar jobQueue q'
            getJob jq jobid

getJob :: JobQueue -> JobId -> STM Job
getJob (JobQueue {..}) jobId = (M.! jobId) <$> readTVar jobs

updateJob :: JobQueue -> JobId -> (Job -> (Job, a)) -> STM a
updateJob (JobQueue {..}) jobId f = do
    jobsMap <- readTVar jobs
    Just x <- pure $ M.lookup jobId jobsMap
    let (x', r) = f x
    writeTVar jobs $ M.insert jobId x' jobsMap
    return r

setJobState :: JobQueue -> JobId -> JobState -> STM ()
setJobState jobQueue jobId newState =
    updateJob jobQueue jobId (\s -> (s {jobState = newState}, ()))

-- | Place a finished, failed, or killed job back on the run queue.
-- Returns 'True' if re-queued.
reEnqueueJob :: JobQueue -> Job -> UTCTime -> STM Bool
reEnqueueJob jq Job{..} reEnqueueTime
  | reQueuable = do
      setJobState jq jobId (Queued reEnqueueTime)
      modifyTVar (jobQueue jq) $ H.insert (jobPriority jobRequest, jobId)
      return True
  | otherwise = return False
  where
    reQueuable =
      case jobState of
        Queued {}   -> False
        Starting {} -> False
        Running {}  -> False
        Failed {}   -> True
        Finished {} -> True
        Killed {}   -> True

queueJob :: JobQueue -> JobId -> UTCTime -> JobRequest
         -> Maybe JobStartingNotify
         -> STM ()
queueJob (JobQueue {..}) jobId jobQueueTime jobRequest jobStartingNotify = do
    modifyTVar jobQueue $ H.insert (prio, jobId)
    modifyTVar jobs $ M.insert jobId (Job {jobState = Queued {..}, ..})
  where
    prio = jobPriority jobRequest

getJobs :: JobQueue -> STM [Job]
getJobs (JobQueue {..}) =
    M.elems <$> readTVar jobs
