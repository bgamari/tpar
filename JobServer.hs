import Control.Error
import Control.Concurrent.Async
import Control.Concurrent.STM
import Control.Applicative
import Data.Binary
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import Network
import Control.Monad (forever, filterM)
import System.IO (Handle, hClose, hSetBuffering, BufferMode(NoBuffering))
import System.Process (runInteractiveProcess, ProcessHandle, waitForProcess)

import Pipes
import qualified Pipes.Prelude as PP
import qualified Pipes.ByteString as PBS

import Types
import Util

port :: PortID
port = PortNumber 2228       

workers :: [Worker]
workers = [localWorker, localWorker, sshWorker "ben-server"]

type Worker = JobRequest -> Producer Status IO ()

processPipes :: FilePath                -- ^ Executable name
             -> [String]                -- ^ Arguments
             -> Maybe FilePath          -- ^ Current working directory
             -> Maybe [(String,String)] -- ^ Optional environment
             -> IO ( Consumer ByteString IO ()
                   , Producer ByteString IO ()
                   , Producer ByteString IO ()
                   , ProcessHandle)
processPipes cmd args cwd env = do
    (stdin, stdout, stderr, phandle) <- runInteractiveProcess cmd args cwd env
    return (PBS.toHandle stdin, PBS.fromHandle stdout, PBS.fromHandle stderr, phandle)

interleave :: [Producer a IO ()] -> Producer a IO ()
interleave producers = do
    queue <- liftIO newTQueueIO
    active <- liftIO $ atomically $ newTVar (length producers)
    mapM_ (liftIO . listen active queue) producers
    watch active queue
  where
    listen :: TVar Int -> TQueue (Maybe a) -> Producer a IO () -> IO (Async ())
    listen active queue producer = async $ go producer
      where go prod = do
              n <- next prod
              case n of
                Right (x, prod')  -> do liftIO $ atomically $ writeTQueue queue (Just x)
                                        go prod'
                Left _            -> do liftIO $ atomically $ do
                                          modifyTVar active (subtract 1)
                                          writeTQueue queue Nothing

    watch :: TVar Int -> TQueue (Maybe a) -> Producer a IO ()
    watch active queue = do
      res <- liftIO $ atomically $ do
        e <- tryReadTQueue queue
        case e of
          Just e'  -> return (Just e')
          Nothing  -> do n <- readTVar active
                         if n > 0
                           then Just <$> readTQueue queue
                           else return Nothing
      case res of
        Just (Just x)  -> yield x >> watch active queue
        Just Nothing   -> watch active queue
        Nothing        -> return ()

runProcess :: FilePath -> [String] -> Maybe FilePath
           -> Producer Status IO ()
runProcess cmd args cwd = do
    (stdin, stdout, stderr, phandle) <- liftIO $ processPipes cmd args cwd Nothing
    interleave [ stderr >-> PP.map PutStderr
               , stdout >-> PP.map PutStdout
               ]
    liftIO (waitForProcess phandle) >>= yield . JobDone

localWorker :: Worker
localWorker req = runProcess (jobCommand req) (jobArgs req) Nothing

sshWorker :: HostName -> Worker
sshWorker host req = do
    runProcess "ssh" ([host, "--", jobCommand req]++jobArgs req) Nothing

data Job = Job { jobConn    :: Handle
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
