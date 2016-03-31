module JobServer ( -- * Workers
                   Worker
                 , localWorker
                 , sshWorker
                 , remoteWorker
                   -- * Running
                 , start
                   -- * Convenient re-exports
                 , PortID(..)
                 , PortNumber
                 ) where

import Control.Error
import Control.Applicative
import Control.Monad (void)
import Data.Binary
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import Network
import Control.Monad (forever, filterM)
import qualified Data.Heap as H

import System.IO (Handle, hClose, hSetBuffering, BufferMode(NoBuffering))
import Control.Concurrent.Async
import Control.Concurrent.STM

import Pipes
import qualified Pipes.Prelude as PP

import ProcessPipe
import Types
import Util

type Worker = JobRequest -> Producer Status IO ()

localWorker :: Worker
localWorker req = runProcess (jobCommand req) (jobArgs req) Nothing >-> PP.map PStatus

sshWorker :: HostName -> FilePath -> Worker
sshWorker host rootPath req = do
    runProcess "ssh" ([host, "--", "cd", cwd, ";", jobCommand req]++jobArgs req) Nothing >-> PP.map PStatus
  where
    cwd = rootPath ++ "/" ++ jobCwd req  -- HACK

data Job = Job { jobConn    :: Consumer Status IO ()
               , jobRequest :: JobRequest
               }

printExcept :: ExceptT String IO () -> IO ()
printExcept action = runExceptT action >>= either errLn return

listener :: PortID -> JobQueue -> IO ()
listener port jobQueue = do
    listenSock <- listenOn port
    void $ forever $ printExcept $ do
        (h,_,_) <- liftIO $ accept listenSock
        liftIO $ hSetBuffering h NoBuffering
        res <- liftIO $ runExceptT $ hGetBinary h
        case res of
          Right (QueueJob jobReq) ->
            liftIO $ pushJob jobQueue (Job (toHandleBinary h) jobReq)
          Right WorkerReady       ->
            liftIO $ void $ async $ runExceptT $ handleRemoteWorker jobQueue h
          Left err                -> do
            liftIO $ errLn $ "Error in request: "++err
            tryIO' $ hPutBinary h $ Error err
            tryIO' $ hClose h

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

runWorker :: JobQueue -> Worker -> IO ()
runWorker jobQueue worker = forever $ runExceptT $ do
    job <- liftIO $ takeJob jobQueue
    tryIO' $ runEffect $ worker (jobRequest job) >-> jobConn job

start :: PortID -> [Worker] -> IO ()
start port workers = do
    jobQueue <- newJobQueue
    mapM_ (async . runWorker jobQueue) workers
    listener port jobQueue

handleRemoteWorker :: JobQueue -> Handle -> ExceptT String IO ()
handleRemoteWorker jobQueue h = do
    job <- liftIO $ takeJob jobQueue
    tryIO' $ hPutBinary h (jobRequest job)
    tryIO' $ runEffect $ fromHandleBinary h >-> handleError >-> jobConn job
  where
    handleError = forever $ do
      res <- await
      case res of
        Left err -> yield $ Error err
        Right a  -> yield a

remoteWorker :: HostName -> PortID -> ExceptT String IO ()
remoteWorker host port = forever $ do
    h <- tryIO' $ connectTo host port
    liftIO $ hSetBuffering h NoBuffering
    tryIO' $ hPutBinary h WorkerReady
    jobReq <- hGetBinary h
    liftIO $ runEffect $ localWorker jobReq >-> toHandleBinary h
