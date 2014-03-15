import Control.Monad.IO.Class
import Control.Error
import Network
import Options.Applicative
import qualified Options.Applicative.Help as Help
import System.IO
import Util
import JobServer
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
                               }

data TPar = Worker WorkerOpts
          | Server ServerOpts
          | Enqueue EnqueueOpts
          | Help
          
portOption :: Mod OptionFields PortID -> Parser PortID
portOption m =
    nullOption ( short 'p' <> long "port"
              <> value (PortNumber 5757)
              <> reader (fmap (PortNumber . fromIntegral) . auto) <> m
               )
           
hostOption :: Mod OptionFields String -> Parser String
hostOption m = 
    strOption ( short 'H' <> long "host" <> value "localhost" <> help "server host name" )
           
tpar :: ParserInfo TPar
tpar = info tparParser fullDesc

tparParser :: Parser TPar
tparParser =
    subparser
      $ command "server"  (info (Server <$> server)   $ progDesc "Start a server")
     <> command "worker"  (info (Worker <$> worker)   $ progDesc "Start a worker")
     <> command "enqueue" (info (Enqueue <$> enqueue) $ progDesc "Enqueue a job")
     <> command "help"    (info (pure Help)           $ progDesc "Display help message")
  where
    worker =
      WorkerOpts
        <$> hostOption idm
        <*> portOption (help "server port number")
    server =
      ServerOpts
        <$> portOption (help "server port number")
        <*> option ( short 'N' <> long "workers" <> value 0
                  <> help "number of local workers to start"
                   )
    enqueue = 
      EnqueueOpts
        <$> hostOption idm
        <*> portOption (help "server port number")
        <*> arguments1 Just idm

main :: IO ()
main = do
    opts <- execParser tpar
    res <- runEitherT $ case opts of
      Worker opts -> remoteWorker (workerHostName opts) (workerPort opts)
      Server opts -> do
        let workers = replicate (serverNLocalWorkers opts) localWorker
        liftIO $ start (serverPort opts) workers
      Enqueue opts -> do 
        h <- fmapLT show $ tryIO $ connectTo (enqueueHostName opts) (enqueuePort opts)
        liftIO $ hSetBuffering h NoBuffering
        let cmd:args = enqueueCommand opts
        liftIO $ hPutBinary h $ QueueJob $ JobRequest cmd args "." Nothing
      Help -> do
        liftIO $ putStrLn $ Help.parserHelpText (prefs idm) tpar

    case res of
      Left err -> putStrLn $ "error: "++err
      Right () -> return ()
