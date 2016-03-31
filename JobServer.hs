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
    job <- callRpc requestJob ()
    runJobWithWorker job localWorker

printExcept :: MonadIO m => ExceptT String m () -> m ()
printExcept action = runExceptT action >>= either (liftIO . errLn) return

runServer :: Process ServerIface
runServer = do
    q <- liftIO $ newJobQueue
    (serverPid, iface) <- server q
    announce <- spawnLocal $ forever $ do
        x <- expect :: Process (SendPort ServerIface)
        sendChan x iface
    register "tpar" announce
    return iface

server :: JobQueue -> Process (ProcessId, ServerIface)
server jobQueue = do
    (enqueueJob, enqueueJobRp) <- newRpc
    (requestJob, requestJobRp) <- newRpc
    (getQueueStatus, getQueueStatusRp) <- newRpc

    pid <- spawnLocal $ forever $ do
        serverPid <- getSelfPid
        receiveWait
            [ matchRpc enqueueJobRp $ \(jobReq, dataStream) -> do
                  liftIO $ pushJob jobQueue (Job dataStream jobReq)
                  return ((), ())
            , matchRpc' requestJobRp $ \() reply -> do
                  spawnLocal $ do
                      link serverPid
                      job <- liftIO $ takeJob jobQueue
                      reply job
                  return ()
            , matchRpc getQueueStatusRp $ \() -> do
                  q <- liftIO $ getQueuedJobs jobQueue
                  return (map jobRequest q, ())
            ]
    return (pid, ServerIface {..})

newtype JobQueue = JobQueue (TVar (H.Heap (H.Entry Priority Job)))

newJobQueue :: IO JobQueue
newJobQueue = JobQueue <$> atomically (newTVar H.empty)

takeJob :: JobQueue -> IO Job
takeJob (JobQueue qVar) = atomically $ do
    q <- readTVar qVar
    case H.viewMin q of
        Just (job, q') -> writeTVar qVar q' >> return (H.payload job)
        Nothing        -> retry

pushJob :: JobQueue -> Job -> IO ()
pushJob (JobQueue qVar) job =
    atomically $ modifyTVar qVar $ H.insert (H.Entry prio job)
  where
    prio = jobPriority $ jobRequest job

getQueuedJobs :: JobQueue -> IO [Job]
getQueuedJobs (JobQueue qVar) =
    map (\(H.Entry _ x) -> x). toList <$> atomically (readTVar qVar)

runJobWithWorker :: Job -> Worker -> Process ExitCode
runJobWithWorker (Job {..}) worker =
    let intoSink = case jobSink of
                     Just sink -> connectSink sink
                     Nothing   -> \src -> runEffect $ src >-> PP.drain
    in intoSink $ worker jobRequest
