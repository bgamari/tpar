import Control.Monad (when)
import Control.Monad.IO.Class
import Control.Error
import Network
import Options.Applicative
import System.IO

import JobClient
import JobServer
import Util
import Types

data WorkerOpts = WorkerOpts { workerHostName      :: String
                             , workerPort          :: PortID
                             }

data ServerOpts = ServerOpts { serverPort          :: PortID
                             , serverNLocalWorkers :: Int
                             }

data EnqueueOpts = EnqueueOpts { enqueueHostName      :: String
                               , enqueuePort          :: PortID
                               , enqueueCommand       :: [String]
                               , enqueueWatch         :: Bool
                               }

data TPar = Worker WorkerOpts
          | Server ServerOpts
          | Enqueue EnqueueOpts

portOption :: Mod OptionFields PortID -> Parser PortID
portOption m =
    option (PortNumber . fromIntegral <$> auto)
           ( short 'p' <> long "port"
          <> value (PortNumber 5757) <> m
           )

hostOption :: Mod OptionFields String -> Parser String
hostOption m =
    strOption ( short 'H' <> long "host" <> value "localhost" <> help "server host name" )

tpar :: ParserInfo TPar
tpar = info (helper <*> tparParser)
     $ fullDesc
    <> progDesc "Start queues, add workers, and enqueue tasks"
    <> header "tpar - simple distributed task queuing"

tparParser :: Parser TPar
tparParser =
    subparser
      $ command "server"  ( info (Server <$> server)
                          $ fullDesc <> progDesc "Start a server")
     <> command "worker"  ( info (Worker <$> worker)
                          $ fullDesc <> progDesc "Start a worker")
     <> command "enqueue" ( info (Enqueue <$> enqueue)
                          $ fullDesc <> progDesc "Enqueue a job")
  where
    worker =
      WorkerOpts
        <$> hostOption idm
        <*> portOption (help "server port number")
    server =
      ServerOpts
        <$> portOption (help "server port number")
        <*> option auto ( short 'N' <> long "workers" <> value 0
                       <> help "number of local workers to start"
                        )
    enqueue =
      EnqueueOpts
        <$> hostOption idm
        <*> portOption (help "server port number")
        <*> some (argument str idm)
        <*> switch (short 'w' <> long "watch" <> help "Watch output of task")

main :: IO ()
main = do
    opts <- execParser tpar
    res <- runEitherT $ case opts of
      Worker opts -> remoteWorker (workerHostName opts) (workerPort opts)
      Server opts -> do
        let workers = replicate (serverNLocalWorkers opts) localWorker
        liftIO $ start (serverPort opts) workers
      Enqueue opts -> do
        let cmd:args = enqueueCommand opts
        prod <- tryIO' $ enqueueJob (enqueueHostName opts) (enqueuePort opts) cmd args "." Nothing
        when (enqueueWatch opts) $ do
          code <- watchStatus prod
          liftIO $ putStrLn $ "exited with code "++show code

    case res of
      Left err -> putStrLn $ "error: "++err
      Right () -> return ()
