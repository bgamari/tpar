import Control.Monad (when, forever)
import Control.Monad.IO.Class
import Control.Error
import Network
import Options.Applicative
import Control.Concurrent (threadDelay)

import JobClient
import JobServer
import Util
import Types

portOption :: Mod OptionFields PortID -> Parser PortID
portOption m =
    option (PortNumber . fromIntegral <$> auto)
           ( short 'p' <> long "port"
          <> value (PortNumber 5757) <> m
           )

hostOption :: Mod OptionFields String -> Parser String
hostOption m =
    strOption ( short 'H' <> long "host" <> value "localhost" <> help "server host name" )

type Mode = ExceptT String IO ()

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

modeWorker :: Parser Mode
modeWorker =
    run <$> hostOption idm
        <*> portOption (help "server port number")
        <*> option (Just <$> (auto <|> pure 10))
                   ( short 'r' <> long "reconnect" <> metavar "SECONDS"
                     <> help "attempt to reconnect when server vanishes (with optional retry period); otherwise terminates on server vanishing"
                   )
  where
    run serverHost serverPort reconnect = do
        perhapsRepeat $ remoteWorker serverHost serverPort
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
  where
    run serverPort nLocalWorkers = do
        let workers = replicate nLocalWorkers localWorker
        liftIO $ start serverPort workers

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
  where
    run serverHost serverPort watch name priority (cmd:args) = do
        let jobReq = JobRequest { jobName     = name
                                , jobPriority = priority
                                , jobCommand  = cmd
                                , jobArgs     = args
                                , jobCwd      = "."
                                , jobEnv      = Nothing
                                }
        prod <- tryIO' $ enqueueJob serverHost serverPort jobReq
        when watch $ do
          code <- watchStatus prod
          liftIO $ putStrLn $ "exited with code "++show code
    run _ _ _ _ _ _ = fail "Expected command line"

main :: IO ()
main = do
    run <- execParser tpar
    res <- runExceptT run
    case res of
      Left err -> putStrLn $ "error: "++err
      Right () -> return ()
