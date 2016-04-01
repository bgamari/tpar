import Control.Monad (replicateM_)
import qualified Network.Transport.TCP as TCP
import Control.Distributed.Process
import Control.Distributed.Process.Internal.Types (NodeId(..))
import Control.Distributed.Process.Node
import Control.Concurrent (newEmptyMVar, takeMVar, putMVar)
import Control.Concurrent.Async
import Pipes
import qualified Pipes.Prelude as PP

import TPar.Server
import TPar.Server.Types
import TPar.Types

singleNode :: IO ()
singleNode = do
    Right transport <- TCP.createTransport "localhost" "0" TCP.defaultTCPParameters
    node <- newLocalNode transport initRemoteTable
    runProcess node $ do
        iface <- runServer
        replicateM_ 1 $ spawnLocal $ runRemoteWorker iface
        replicateM_ 100 $ do
            prod <- enqueueAndFollow iface jobReq
            runEffect $ prod >-> PP.drain

jobReq = JobRequest { jobName     = JobName "hello"
                    , jobPriority = Priority 0
                    , jobCommand  = "echo"
                    , jobArgs     = ["hello", "world"]
                    , jobCwd      = "."
                    , jobEnv      = Nothing
                    }

multiNode :: IO ()
multiNode = do
    Right transport1 <- TCP.createTransport "localhost" "9000" TCP.defaultTCPParameters
    node1 <- newLocalNode transport1 initRemoteTable
    ifaceVar <- newEmptyMVar
    doneVar <- newEmptyMVar
    async $ runProcess node1 $ do
        iface <- runServer
        liftIO $ putMVar ifaceVar iface
        liftIO $ takeMVar doneVar
    iface <- takeMVar ifaceVar

    let nid = NodeId (TCP.encodeEndPointAddress "localhost" "9000" 0)

    Right transport2 <- TCP.createTransport "localhost" "0" TCP.defaultTCPParameters
    node2 <- newLocalNode transport2 initRemoteTable
    async $ runProcess node2 $ do
        (sq, rq) <- newChan :: Process (SendPort ServerIface, ReceivePort ServerIface)
        nsendRemote nid "tpar" sq
        iface <- receiveChan rq
        replicateM_ 1 $ spawnLocal $ runRemoteWorker iface

    Right transport3 <- TCP.createTransport "localhost" "0" TCP.defaultTCPParameters
    node3 <- newLocalNode transport3 initRemoteTable
    runProcess node3 $ do
        replicateM_ 100 $ do
            prod <- enqueueAndFollow iface jobReq
            runEffect $ prod >-> PP.print

    putMVar doneVar ()

main :: IO ()
main = multiNode
