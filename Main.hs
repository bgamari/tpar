{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE OverloadedStrings #-}

import Control.Monad (when, forever, replicateM_, void)
import Control.Monad.IO.Class
import Control.Error
import System.Exit
import System.IO (stderr, stdout)

import qualified Text.PrettyPrint.ANSI.Leijen as T.PP
import Text.PrettyPrint.ANSI.Leijen (Doc, (<+>))
import qualified Network.Transport.TCP as TCP
import Network.Socket (ServiceName, HostName)
import Options.Applicative
import Control.Concurrent (threadDelay)
import Control.Distributed.Process
import Control.Distributed.Process.Internal.Types (NodeId(..))
import Control.Distributed.Process.Node
import qualified Text.Trifecta as TT

import TPar.Rpc
import TPar.RemoteStream as RemoteStream
import TPar.ProcessPipe (processOutputToHandles)
import TPar.Server
import TPar.Server.Types
import TPar.JobMatch
import TPar.Types

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
     <> command "status"  ( info modeStatus
                          $ fullDesc <> progDesc "Show queue status")
     <> command "kill"    ( info modeKill
                          $ fullDesc <> progDesc "Kill or dequeue a job")

withServer' :: HostName -> ServiceName
           -> (ServerIface -> Process a) -> Process a
withServer' host port action = do
    let nid :: NodeId
        nid = NodeId (TCP.encodeEndPointAddress host port 0)
    -- request server interface
    mref <- monitorNode nid
    (sq, rq) <- newChan :: Process (SendPort ServerIface, ReceivePort ServerIface)
    nsendRemote nid "tpar" sq
    iface <- receiveWait
        [ matchIf (\(NodeMonitorNotification ref _ _) -> ref == mref) $
          \(NodeMonitorNotification _ _ reason) ->
          case reason of
              DiedDisconnect -> fail "Failed to connect. Are you sure there is a server running?"
              _              -> fail $ show reason
        , matchChan rq pure
        ]

    -- request server interface
    link (serverPid iface)
    unlinkNode nid
    r <- action iface
    unlink (serverPid iface)
    return r

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
                   ( short 'r' <> long "reconnect" <> metavar "SECONDS" <> value Nothing
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
        <*> sinkType
        <*> option (JobName <$> str)
                   (short 'n' <> long "name" <> value (JobName "unnamed-job")
                    <> help "Set the job's name")
        <*> option str
                   (short 'd' <> long "directory" <> value "."
                    <> help "Set the directory the job will be launched from (relative to the cwd of the worker who runs it)")
        <*> option (Priority <$> auto)
                   (short 'P' <> long "priority" <> value (Priority 0)
                    <> help "Set the job's priority")
        <*> some (argument str idm)
        <*  helper
  where
    run serverHost serverPort runSink name dir priority (cmd:args) =
        withServer serverHost serverPort $ \iface -> do
            let jobReq = JobRequest { jobName     = name
                                    , jobPriority = priority
                                    , jobCommand  = cmd
                                    , jobArgs     = args
                                    , jobCwd      = dir
                                    , jobEnv      = Nothing
                                    }
            runSink iface jobReq
    run _ _ _ _ _ _ _ = fail "Expected command line"

    sinkType :: Parser (ServerIface -> JobRequest -> Process ())
    sinkType = remoteSink <|> files <|> noOutput
      where
        noOutput =
            pure $ \iface jobReq -> void $ callRpc (enqueueJob iface) (jobReq, NoOutput)

        files =
            go <$> option str (metavar "FILE" <> help "file to place stdout in")
               <*> option str (metavar "FILE" <> help "file to place stderr in")
          where
            go stdout stderr iface jobReq =
                void $ callRpc (enqueueJob iface) (jobReq, ToFiles stdout stderr)

        remoteSink =
            switch (short 'w' <> long "watch" <> help "Watch output of task")
            *> pure go
          where
            go iface jobReq = do
                prod <- enqueueAndFollow iface jobReq
                code <- processOutputToHandles stdout stderr prod
                case code of
                    ExitSuccess   -> return ()
                    ExitFailure n ->
                        liftIO $ putStrLn $ "exited with code "++show n

liftTrifecta :: TT.Parser a -> ReadM a
liftTrifecta parser = do
    s <- str
    case TT.parseString parser mempty s of
        TT.Success a   -> return a
        TT.Failure err -> fail $ show err

modeStatus :: Parser Mode
modeStatus =
    run <$> hostOption idm
        <*> portOption (help "server port number")
        <*> switch (short 'v' <> long "verbose" <> help "verbose queue status")
        <*> (argument (liftTrifecta parseJobMatch) (help "filter jobs") <|> pure AllMatch)
        <*  helper
  where
    run serverHost serverPort verbose match =
        withServer serverHost serverPort $ \iface -> do
            jobs <- callRpc (getQueueStatus iface) match
            liftIO $ T.PP.putDoc $ T.PP.vcat $ map (prettyJob verbose) jobs ++ [mempty]

prettyJob :: Bool -> Job -> Doc
prettyJob verbose (Job {..}) =
    T.PP.vcat $ [header] ++ (if verbose then [details] else [])
  where
    JobRequest {..} = jobRequest

    twoCols :: Int -> [(Doc, Doc)] -> Doc
    twoCols width =
        T.PP.vcat . map (\(a,b) -> T.PP.fillBreak width a <+> b)

    header =
        T.PP.fillBreak 5 (prettyJobId jobId)
        <+> T.PP.fillBreak 50 (prettyJobName jobName)
        <+> prettyJobState jobState

    details =
        T.PP.indent 4 $ twoCols 15
        [ ("priority:",  prettyPriority jobPriority)
        , ("command:",   T.PP.text jobCommand)
        , ("arguments:", T.PP.hsep $ map T.PP.text jobArgs)
        , ("status:",    prettyDetailedState jobState)
        ]
        T.PP.<$$> mempty

    prettyDetailedState Queued                = "waiting to run"
    prettyDetailedState (Running node)        = "running on" <+> T.PP.text (show node)
    prettyDetailedState (Finished code)       = "finished with" <+> T.PP.text (show code)
    prettyDetailedState (Failed err)          = "failed with error:" <+> T.PP.text err
    prettyDetailedState Killed                = "killed at user request"

    prettyJobState Queued                     = T.PP.blue "queued"
    prettyJobState (Running _)                = T.PP.green "running"
    prettyJobState (Finished ExitSuccess)     = T.PP.cyan "finished"
    prettyJobState (Finished (ExitFailure c)) = T.PP.yellow $ "finished"<+>T.PP.parens (T.PP.int c)
    prettyJobState (Failed _)                 = T.PP.red "failed"
    prettyJobState Killed                     = T.PP.yellow "killed"

    prettyJobId (JobId n)        = T.PP.int n
    prettyJobName (JobName name) = T.PP.text name
    prettyPriority (Priority p)  = T.PP.int p

modeKill :: Parser Mode
modeKill =
    run <$> hostOption idm
        <*> portOption (help "server port number")
        <*> argument (liftTrifecta parseJobMatch) (help "jobs to kill")
        <*  helper
  where
    run serverHost serverPort match =
        withServer serverHost serverPort $ \iface -> do
            jobs <- callRpc (killJobs iface) match
            liftIO $ T.PP.putDoc $ T.PP.vcat $ map (prettyJob False) jobs ++ [mempty]
            liftIO $ when (null jobs) $ exitWith $ ExitFailure 1

main :: IO ()
main = do
    run <- execParser tpar
    res <- runExceptT $ tryIO run
    case res of
      Left err -> putStrLn $ "error: "++show err
      Right () -> return ()
