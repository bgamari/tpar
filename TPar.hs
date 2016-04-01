import Control.Monad (when, forever, replicateM_)
import Control.Monad.IO.Class
import Control.Error
import qualified Network.Transport.TCP as TCP
import Network.Socket (ServiceName, HostName)
import Options.Applicative
import Control.Concurrent (threadDelay)
import Control.Distributed.Process
import Control.Distributed.Process.Internal.Types (NodeId(..))
import Control.Distributed.Process.Node
import Debug.Trace

import JobClient
import JobServer
import Types

portOption :: Mod OptionFields ServiceName -> Parser ServiceName
portOption m =
    option str
           ( short 'p' <> long "port"
          <> value "5757" <> m
           )

hostOption :: Mod OptionFields String -> Parser HostName
hostOption m =
    strOption ( short 'H' <> long "host" <> value "localhost" <> help "server host name" )

type Mode = IO ()

tpar :: ParserInfo Mode
tpar = info (helper <*> tparParser)
     $ fullDesc
    <> progDesc "Start queues, add workers, and enqueue tasks"
    <> header "tpar - simple distributed task queuing"

tparParser :: Parser Mode
tparParser =
    subparser
      $ command "server"  ( info modeServer
                          $ fullDesc <> progDesc "Start a server")
     <> command "worker"  ( info modeWorker
                          $ fullDesc <> progDesc "Start a worker")
     <> command "enqueue" ( info modeEnqueue
                          $ fullDesc <> progDesc "Enqueue a job")

withServer' :: HostName -> ServiceName
           -> (ServerIface -> Process a) -> Process a
withServer' host port action = do
    let nid :: NodeId
        nid = NodeId (TCP.encodeEndPointAddress host port 0)
    (sq, rq) <- newChan :: Process (SendPort ServerIface, ReceivePort ServerIface)
    nsendRemote nid "tpar" sq
    iface <- receiveChan rq
    action iface

withServer :: HostName -> ServiceName
           -> (ServerIface -> Process ()) -> IO ()
withServer host port action = do
    Right transport <- TCP.createTransport "localhost" "0" TCP.defaultTCPParameters
    node <- newLocalNode transport initRemoteTable
    runProcess node $ withServer' host port action

modeWorker :: Parser Mode
modeWorker =
    run <$> hostOption idm
        <*> portOption (help "server port number")
        <*> option (Just <$> (auto <|> pure 10))
                   ( short 'r' <> long "reconnect" <> metavar "SECONDS"
                     <> help "attempt to reconnect when server vanishes (with optional retry period); otherwise terminates on server vanishing"
                   )
        <*  helper
  where
    run serverHost serverPort reconnect =
        perhapsRepeat $ withServer serverHost serverPort runRemoteWorker
      where
        perhapsRepeat action
          | Just period <- reconnect =
                forever $ action >> liftIO (threadDelay period)
          | otherwise                = action

modeServer :: Parser Mode
modeServer =
    run <$> portOption (help "server port number")
        <*> option auto ( short 'N' <> long "workers" <> value 0
                       <> help "number of local workers to start"
                        )
        <*  helper
  where
    run serverPort nLocalWorkers = do
        Right transport <- TCP.createTransport "localhost" serverPort TCP.defaultTCPParameters
        node <- newLocalNode transport initRemoteTable
        runProcess node $ do
            iface <- runServer
            replicateM_ nLocalWorkers $ spawnLocal $ runRemoteWorker iface
            liftIO $ forever $ threadDelay maxBound

modeEnqueue :: Parser Mode
modeEnqueue =
    run <$> hostOption idm
        <*> portOption (help "server port number")
        <*> switch (short 'w' <> long "watch" <> help "Watch output of task")
        <*> option (JobName <$> str)
                   (short 'n' <> long "name" <> value (JobName "unnamed-job")
                    <> help "Set the job's name")
        <*> option (Priority <$> auto)
                   (short 'p' <> long "priority" <> value (Priority 0)
                    <> help "Set the job's priority")
        <*> some (argument str idm)
        <*  helper
  where
    run serverHost serverPort watch name priority (cmd:args) =
        withServer serverHost serverPort $ \iface -> do
            let jobReq = JobRequest { jobName     = name
                                    , jobPriority = priority
                                    , jobCommand  = cmd
                                    , jobArgs     = args
                                    , jobCwd      = "."
                                    , jobEnv      = Nothing
                                    }
            liftIO $ traceEventIO "Ben: starting"
            prod <- watchJob iface jobReq
            liftIO $ traceEventIO "Ben: watching"
            when watch $ do
              code <- watchStatus prod
              liftIO $ traceEventIO "Ben: watched"
              liftIO $ putStrLn $ "exited with code "++show code
    run _ _ _ _ _ _ = fail "Expected command line"

main :: IO ()
main = do
    run <- execParser tpar
    res <- runExceptT $ tryIO run
    case res of
      Left err -> putStrLn $ "error: "++show err
      Right () -> return ()
