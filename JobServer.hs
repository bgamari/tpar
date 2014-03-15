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

printEitherT :: EitherT String IO () -> IO ()
printEitherT action = runEitherT action >>= either errLn return

listener :: PortID -> TQueue Job -> IO ()
listener port jobQueue = do
    listenSock <- listenOn port 
    void $ forever $ printEitherT $ do
        (h,_,_) <- liftIO $ accept listenSock
        liftIO $ hSetBuffering h NoBuffering
        res <- liftIO $ runEitherT $ hGetBinary h
        case res of
          Right (QueueJob jobReq) ->
            liftIO $ atomically $ writeTQueue jobQueue (Job (toHandleBinary h) jobReq)
          Right WorkerReady       ->
            liftIO $ void $ async $ runEitherT $ handleRemoteWorker jobQueue h
          Left err                -> do
            liftIO $ errLn $ "Error in request: "++err
            tryIO' $ hPutBinary h $ Error err
            tryIO' $ hClose h

runWorker :: TQueue Job -> Worker -> IO ()
runWorker jobQueue worker = forever $ runEitherT $ do
    job <- liftIO $ atomically (readTQueue jobQueue)
    tryIO' $ runEffect $ worker (jobRequest job) >-> jobConn job
    
start :: PortID -> [Worker] -> IO ()
start port workers = do
    jobQueue <- newTQueueIO
    mapM_ (async . runWorker jobQueue) workers 
    listener port jobQueue

handleRemoteWorker :: TQueue Job -> Handle -> EitherT String IO ()
handleRemoteWorker jobQueue h = do
    job <- liftIO $ atomically (readTQueue jobQueue)
    tryIO' $ hPutBinary h (jobRequest job)
    tryIO' $ runEffect $ fromHandleBinary h >-> handleError >-> jobConn job
  where
    handleError = do
      res <- await
      case res of
        Left err -> yield $ Error err
        Right a  -> yield a
    
remoteWorker :: HostName -> PortID -> EitherT String IO ()
remoteWorker host port = forever $ do
    h <- tryIO' $ connectTo host port
    liftIO $ hSetBuffering h NoBuffering
    jobReq <- hGetBinary h
    liftIO $ runEffect $ localWorker jobReq >-> toHandleBinary h
