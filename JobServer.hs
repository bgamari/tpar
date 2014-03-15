module JobServer ( -- * Workers
                   Worker
                 , localWorker
                 , sshWorker
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

listener :: PortID -> TQueue Job -> IO ()
listener port jobQueue = do
    listenSock <- listenOn port 
    forever $ do
        (h,_,_) <- accept listenSock
        hSetBuffering h NoBuffering
        res <- runEitherT $ hGetBinary h
        case res of
          Right (QueueJob jobReq) ->
            atomically $ writeTQueue jobQueue (Job (toHandleBinary h) jobReq)
          Right WorkerReady       ->
            void $ async $ handleRemoteWorker jobQueue h
          Left  err    -> do
            hPutBinary h $ Error err
            hClose h
            putStr $ "Error in request: "++err

runWorker :: TQueue Job -> Worker -> IO ()
runWorker jobQueue worker = forever $ do
    job <- atomically (readTQueue jobQueue)
    runEffect $ worker (jobRequest job) >-> jobConn job
    
start :: PortID -> [Worker] -> IO ()
start _ [] = putStrLn "Error: No workers provided"
start port workers = do
    jobQueue <- newTQueueIO
    mapM_ (async . runWorker jobQueue) workers 
    listener port jobQueue

handleRemoteWorker :: TQueue Job -> Handle -> IO ()
handleRemoteWorker jobQueue h = do
    job <- atomically (readTQueue jobQueue)
    hPutBinary h (jobRequest job)
    runEffect $ fromHandleBinary h >-> handleError >-> jobConn job
  where
    handleError = do
      res <- await
      case res of
        Left err -> yield $ Error err
        Right a  -> yield a
    
remoteWorker :: HostName -> PortID -> EitherT String IO ()
remoteWorker host port = forever $ do
    h <- fmapLT show $ tryIO $ connectTo host port
    liftIO $ hSetBuffering h NoBuffering
    jobReq <- hGetBinary h
    liftIO $ runEffect $ localWorker jobReq >-> toHandleBinary h
