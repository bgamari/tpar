import Control.Error
import Control.Concurrent (forkIO)
import Control.Concurrent.STM
import Data.Binary
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import Network
import Control.Monad (forever)
import System.IO (Handle)

import Types
import Util

port :: PortID
port = PortNumber 2228       
     
workers :: [Worker]
workers = [localWorker, remoteWorker "localhost"]

type Worker = JobRequest -> IO JobResult

localWorker :: Worker
localWorker = undefined

remoteWorker :: HostName -> Worker
remoteWorker host req = do
    undefined

data Job = Job { jobConn    :: Handle
               , jobRequest :: JobRequest
               }

orFail :: EitherT String IO a -> IO a
orFail m = undefined

listener :: PortID -> TQueue Job -> IO ()
listener port jobQueue = do
    listenSock <- listenOn port 
    forever $ do
        (h,_,_) <- accept listenSock
        jobReq <- orFail $ hGetBinary h
        atomically $ writeTQueue jobQueue (Job h jobReq)

runWorker :: TQueue Job -> Worker -> IO ()
runWorker jobQueue worker = forever $ do
    job <- atomically (readTQueue jobQueue)
    result <- worker (jobRequest job)
    let h = jobConn job
    hPutBinary h result

main = start port workers
     
start :: PortID -> [Worker] -> IO ()
start _ [] = putStrLn "Error: No workers provided"
start port workers = do
    jobQueue <- newTQueueIO
    mapM_ (forkIO . runWorker jobQueue) workers 
    listener port jobQueue
