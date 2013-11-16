import Control.Error
import Control.Concurrent.Async
import Control.Concurrent.STM
import Control.Applicative
import Data.Binary
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import Network
import Control.Monad (forever, filterM)
import System.IO (Handle, hClose)
import System.Process (runInteractiveProcess, ProcessHandle, waitForProcess)

import Pipes
import qualified Pipes.Prelude as PP
import qualified Pipes.ByteString as PBS

import Types
import Util

port :: PortID
port = PortNumber 2228       
     
workers :: [Worker]
workers = [localWorker, localWorker]

type Worker = JobRequest -> Producer Status IO ()

processPipes :: FilePath -> [String]
             -> IO ( Consumer ByteString IO ()
                   , Producer ByteString IO ()
                   , Producer ByteString IO ()
                   , ProcessHandle)
processPipes cmd args = do
    (stdin, stdout, stderr, phandle) <- runInteractiveProcess cmd args Nothing Nothing
    return (PBS.toHandle stdin, PBS.fromHandle stdout, PBS.fromHandle stderr, phandle)

interleave :: [Producer a IO ()] -> Producer a IO ()
interleave producers = do
    queue <- liftIO newTQueueIO
    mapM (liftIO . go queue) producers >>= watch queue
  where
    go :: TQueue a -> Producer a IO () -> IO (Async ())
    go queue producer = async $ runEffect $ producer >-> put
      where put = forever $ await >>= liftIO . atomically . writeTQueue queue

    watch :: TQueue a -> [Async ()] -> Producer a IO ()
    watch queue [] = return ()
    watch queue tasks = do
      liftIO (atomically $ readTQueue queue) >>= yield
      filterM (\t->liftIO $ isNothing `fmap` poll t) tasks >>= watch queue

runProcess :: FilePath -> [String] -> Producer Status IO ()
runProcess cmd args = do
    (stdin, stdout, stderr, phandle) <- liftIO $ processPipes cmd args
    interleave [ stderr >-> PP.map PutStderr
               , stdout >-> PP.map PutStdout
               ]
    liftIO (waitForProcess phandle) >>= yield . JobDone

localWorker :: Worker
localWorker req = runProcess (jobCommand req) (jobArgs req)

remoteWorker :: HostName -> Worker
remoteWorker host req = do undefined

data Job = Job { jobConn    :: Handle
               , jobRequest :: JobRequest
               }

listener :: PortID -> TQueue Job -> IO ()
listener port jobQueue = do
    listenSock <- listenOn port 
    forever $ do
        (h,_,_) <- accept listenSock
        res <- runEitherT $ hGetBinary h
        case res of
          Right jobReq -> atomically $ writeTQueue jobQueue (Job h jobReq)
          Left  err    -> do hPutBinary h $ Error err
                             hClose h
                             putStr $ "Error in request: "++err

runWorker :: TQueue Job -> Worker -> IO ()
runWorker jobQueue worker = forever $ do
    job <- atomically (readTQueue jobQueue)
    runEffect $ worker (jobRequest job) >-> toHandleBinary (jobConn job)

main :: IO ()    
main = start port workers
     
start :: PortID -> [Worker] -> IO ()
start _ [] = putStrLn "Error: No workers provided"
start port workers = do
    jobQueue <- newTQueueIO
    mapM_ (async . runWorker jobQueue) workers 
    listener port jobQueue
