{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE OverloadedStrings #-}

import Control.Monad.Catch
import Control.Monad (when, unless, forever, replicateM_)
import Control.Monad.IO.Class
import Control.Error hiding (err)
import Data.Foldable
import qualified Data.Map.Strict as M
import Data.Time.Clock
import Data.Time.Format.Human
import System.Exit
import System.IO (stderr, stdout)

import qualified Text.PrettyPrint.ANSI.Leijen as T.PP
import Text.PrettyPrint.ANSI.Leijen (Doc, (<+>), (<$$>))
import qualified Network.Transport.TCP as TCP
import Network.Socket (ServiceName, HostName)
import Network.BSD (getHostName)
import Options.Applicative
import Control.Concurrent (threadDelay)
import Control.Distributed.Process
import Control.Distributed.Process.Internal.Types (NodeId(..))
import Control.Distributed.Process.Node
import qualified Text.Trifecta as TT

import Pipes
import qualified Pipes.Concurrent as P.C
import qualified Pipes.Prelude as P.P

import TPar.Rpc
import TPar.ProcessPipe hiding (runProcess)
import TPar.Server
import TPar.SubPubStream as SubPub
import TPar.Server.Types
import TPar.JobMatch
import TPar.Types

portOption :: Mod OptionFields ServiceName -> Parser ServiceName
portOption m =
    option str
           ( short 'p' <> long "port"
          <> value "5757" <> m
           )

hostOption :: Parser HostName
hostOption =
    strOption ( short 'H' <> long "host" <> value "localhost" <> help "server host name" )

jobMatchArg :: Parser JobMatch
jobMatchArg = argument (liftTrifecta parseJobMatch) (help "job match expression")

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
     <> command "rerun"   ( info modeRerun
                          $ fullDesc <> progDesc "Restart a failed job")
     <> command "watch"   ( info modeWatch
                          $ fullDesc <> progDesc "Watch the output of a set of jobs")

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
    hostname <- getHostName
    Right transport <- TCP.createTransport hostname "0" TCP.defaultTCPParameters
    node <- newLocalNode transport initRemoteTable
    runProcess node $ withServer' host port action

modeWorker :: Parser Mode
modeWorker =
    run <$> option (auto >>= checkNWorkers)
                        ( short 'N' <> long "workers" <> value 1
                       <> help "number of local workers to start"
                        )
        <*> hostOption
        <*> portOption (help "server port number")
        <*> option (Just <$> (auto <|> pure 10))
                   ( short 'r' <> long "reconnect" <> metavar "SECONDS" <> value Nothing
                     <> help "attempt to reconnect when server vanishes (with optional retry period); otherwise terminates on server vanishing"
                   )
        <*  helper
  where
    checkNWorkers n
      | n >= 1 = return n
      | otherwise = fail "Worker count (-N) should be at least one"

    run nWorkers serverHost serverPort reconnect =
        perhapsRepeat $ withServer serverHost serverPort $ \serverIface -> do
            replicateM_ nWorkers $ spawnLocal $ runRemoteWorker serverIface
            liftIO $ forever threadDelay maxBound
      where
        perhapsRepeat action
          | Just period <- reconnect = forever $ do
                handleAll (liftIO . print) action
                liftIO (threadDelay $ 1000*1000*period)
          | otherwise                = action

modeServer :: Parser Mode
modeServer =
    run <$> option str (short 'H' <> long "host" <> value "localhost"
                        <> help "interface address to listen on" )
        <*> portOption (help "port to listen on")
        <*> option auto ( short 'N' <> long "workers" <> value 0
                       <> help "number of local workers to start"
                        )
        <*  helper
  where
    run serverHost serverPort nLocalWorkers = do
        Right transport <- TCP.createTransport serverHost serverPort TCP.defaultTCPParameters
        node <- newLocalNode transport initRemoteTable
        runProcess node $ do
            iface <- runServer
            replicateM_ nLocalWorkers $ spawnLocal $ runRemoteWorker iface
            liftIO $ forever $ threadDelay maxBound

modeEnqueue :: Parser Mode
modeEnqueue =
    run <$> hostOption
        <*> portOption (help "server port number")
        <*> sinkType
        <*> switch (short 'w' <> long "watch" <> help "Watch output of task")
        <*> option (JobName <$> str)
                   (short 'n' <> long "name" <> value (JobName "unnamed-job")
                    <> help "Set the job's name")
        <*> option str
                   (short 'd' <> long "directory" <> value "."
                    <> help "Set the directory the job will be launched from (relative to the working directory of the worker who runs it)")
        <*> option (Priority <$> auto)
                   (short 'P' <> long "priority" <> value (Priority 0)
                    <> help "Set the job's priority")
        <*> some (argument str idm)
        <*  helper
  where
    run :: HostName -> ServiceName
        -> OutputStreams (Maybe FilePath) -> Bool
        -> JobName -> FilePath -> Priority -> [String]
        -> IO ()
    run serverHost serverPort sink watch name dir priority (cmd:args) =
        withServer serverHost serverPort $ \iface -> do
            let jobReq = JobRequest { jobName     = name
                                    , jobPriority = priority
                                    , jobCommand  = cmd
                                    , jobArgs     = args
                                    , jobSinks    = sink
                                    , jobCwd      = dir
                                    , jobEnv      = Nothing
                                    }
            if watch
              then do
                prod <- enqueueAndFollow iface jobReq
                code <- runEffect $ prod >-> P.P.mapM_ (processOutputToHandles $ OutputStreams stdout stderr)
                case code of
                    ExitSuccess   -> return ()
                    ExitFailure n ->
                        liftIO $ putStrLn $ "exited with code "++show n
              else do
                Right _ <- callRpc (enqueueJob iface) (jobReq, Nothing)
                return ()

    run _ _ _ _ _ _ _ _ = fail "Expected command line"

    sinkType :: Parser (OutputStreams (Maybe FilePath))
    sinkType =
        OutputStreams
          <$> option (Just <$> str)
                     (short 'o' <> long "output" <> metavar "FILE"
                     <> help "remote file to log standard output to"
                     <> value Nothing)
          <*> option (Just <$> str)
                     (short 'e' <> long "error" <> metavar "FILE"
                     <> help "remote file to log standard error to"
                     <> value Nothing)

liftTrifecta :: TT.Parser a -> ReadM a
liftTrifecta parser = do
    s <- str
    case TT.parseString parser mempty s of
        TT.Success a   -> return a
        TT.Failure err -> fail $ show $ TT._errDoc err

modeWatch :: Parser Mode
modeWatch =
    run <$> hostOption
        <*> portOption (help "server port number")
        <*> jobMatchArg
        <*  helper
  where
    run serverHost serverPort match =
        withServer serverHost serverPort $ \iface -> do
            inputs <- subscribeToJobs iface match
            let input = foldMap fold inputs
                failed = M.keys $ M.filter isNothing inputs
            unless (null failed) $ liftIO $ print
                  $  T.PP.red "warning: failed to attach to"
                 <+> prettyShow (length failed) <+> "jobs"
                <$$> T.PP.nest 4 (T.PP.vcat $ map prettyShow failed)
            runEffect $ P.C.fromInput input
                     >-> P.P.mapM_ (processOutputToHandles $ OutputStreams stdout stderr)

subscribeToJobs :: ServerIface -> JobMatch
                -> Process (M.Map JobId (Maybe (P.C.Input ProcessOutput)))
subscribeToJobs iface match = do
    Right jobs <- callRpc (getQueueStatus iface) match
    prods <- traverse SubPub.subscribe
        $ M.unions
        [ M.singleton jobId jobMonitor
        | Job {..} <- jobs
        , Running {..} <- pure jobState
        ]
    traverse (traverse producerToInput) prods
  where
    producerToInput :: Producer ProcessOutput Process ExitCode
                    -> Process (P.C.Input ProcessOutput)
    producerToInput prod = do
        (output, input) <- liftIO $ P.C.spawn (P.C.bounded 1)
        void $ spawnLocal $ runEffect $ void prod >-> P.C.toOutput output
        return input

modeStatus :: Parser Mode
modeStatus =
    run <$> hostOption
        <*> portOption (help "server port number")
        <*> switch (short 'v' <> long "verbose" <> help "verbose queue status")
        <*> (jobMatchArg <|> pure (NegMatch NoMatch))
        <*  helper
  where
    run serverHost serverPort verbose match =
        withServer serverHost serverPort $ \iface -> do
            Right jobs <- callRpc (getQueueStatus iface) match
            time <- liftIO getCurrentTime
            let prettyTime = T.PP.text . humanReadableTime' time
            liftIO $ T.PP.putDoc $ T.PP.vcat $ map (prettyJob verbose prettyTime) jobs ++ [mempty]

prettyJob :: Bool -> (UTCTime -> Doc) -> Job -> Doc
prettyJob verbose prettyTime (Job {..}) =
    T.PP.vcat $ [header] ++ (if verbose then [details] else [])
  where
    JobRequest {..} = jobRequest

    twoCols :: Int -> [(Doc, Doc)] -> Doc
    twoCols width =
        T.PP.vcat . map (\(a,b) -> T.PP.fillBreak width a <+> T.PP.align b)

    header =
        T.PP.fillBreak 5 (prettyJobId jobId)
        <+> T.PP.fillBreak 50 (prettyJobName jobName)
        <+> prettyJobState jobState

    details =
        T.PP.indent 4 $ twoCols 15
        [ ("priority:",  prettyPriority jobPriority)
        , ("queued:",    prettyTime (jobQueueTime jobState))
        , ("command:",   T.PP.text jobCommand)
        , ("arguments:", T.PP.hsep $ map T.PP.text jobArgs)
        , ("logging:",   T.PP.vcat $ toList $ (\x y -> x<>":"<+>y)
                         <$> OutputStreams "stdout" "stderr"
                         <*> fmap (maybe "none" T.PP.text) jobSinks)
        , ("status:",    prettyDetailedState jobState)
        ]
        <$$> mempty

    prettyDetailedState Queued{..}    =
        "waiting to run" <+> T.PP.parens ("since" <+> prettyTime jobQueueTime)
    prettyDetailedState Starting{..}  =
        "starting on" <+> prettyShow jobProcessId
        <+> T.PP.parens ("since" <+> prettyTime jobStartingTime)
    prettyDetailedState Running{..}   =
        "running on" <+> prettyShow jobProcessId
        <+> T.PP.parens ("since" <+> prettyTime jobStartTime)
    prettyDetailedState Finished{..}  =
        "finished with" <+> prettyShow (getExitCode jobExitCode)
        <+> T.PP.parens ("at" <+> prettyTime jobFinishTime)
        <$$> "started at" <+> prettyTime jobStartTime
        <$$> "ran on" <+> prettyShow jobWorkerNode
    prettyDetailedState Failed{..}    =
        "failed with error" <+> T.PP.parens (prettyTime jobFailedTime)
        <$$> "started at" <+> prettyTime jobStartTime
        <$$> T.PP.indent 4 (T.PP.text jobErrorMsg)
    prettyDetailedState Killed{..}    =
        "killed at user request" <+> T.PP.parens (prettyTime jobKilledTime)
        <$$> maybe "never started" (\t -> "started at" <+> prettyTime t) jobKilledStartTime

    prettyJobState Queued{}           = T.PP.blue "queued"
    prettyJobState Starting{}         = T.PP.blue "starting"
    prettyJobState Running{}          = T.PP.green "running"
    prettyJobState Finished{..}
      | ExitFailure _ <- jobExitCode  = T.PP.yellow $ "finished"
      | otherwise                     = T.PP.cyan "finished"
    prettyJobState Failed{}           = T.PP.red "failed"
    prettyJobState Killed{}           = T.PP.yellow "killed"

    prettyJobId (JobId n)        = T.PP.int n
    prettyJobName (JobName name) = T.PP.bold $ T.PP.text name
    prettyPriority (Priority p)  = T.PP.int p

    getExitCode ExitSuccess     = 0
    getExitCode (ExitFailure c) = c

prettyShow :: Show a => a -> Doc
prettyShow = T.PP.text . show

modeKill :: Parser Mode
modeKill =
    run <$> hostOption
        <*> portOption (help "server port number")
        <*> jobMatchArg
        <*  helper
  where
    run serverHost serverPort match =
        withServer serverHost serverPort $ \iface -> do
            Right jobs <- callRpc (killJobs iface) match
            liftIO $ T.PP.putDoc $ T.PP.vcat $ map (prettyJob False prettyShow) jobs ++ [mempty]
            liftIO $ when (null jobs) $ exitWith $ ExitFailure 1

modeRerun :: Parser Mode
modeRerun =
    run <$> hostOption
        <*> portOption (help "server port number")
        <*> jobMatchArg
        <*  helper
  where
    run serverHost serverPort match =
        withServer serverHost serverPort $ \iface -> do
            Right jobs <- callRpc (rerunJobs iface) match
            liftIO $ T.PP.putDoc $ T.PP.vcat $ map (prettyJob False prettyShow) jobs ++ [mempty]
            liftIO $ when (null jobs) $ exitWith $ ExitFailure 1

main :: IO ()
main = do
    run <- execParser tpar
    res <- runExceptT $ tryIO run
    case res of
      Left err -> putStrLn $ "error: "++show err
      Right () -> return ()
