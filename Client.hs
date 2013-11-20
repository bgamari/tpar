import Control.Error hiding (err)
import Network
import System.Environment
import System.Exit
import qualified Data.ByteString as BS
import System.IO (stderr, stdout, hPutStrLn, hSetBuffering, BufferMode(NoBuffering))
import Pipes
import Options.Applicative

import Types
import Util
       
data Opts = Opts { port      :: PortNumber
                 , host      :: String
                 , keepEnv   :: Bool
                 , hideEnv   :: [String]
                 , childArgs :: [String]
                 }

opts :: Parser Opts
opts = Opts
    <$> nullOption ( short 'p' <> long "port"
                  <> value 2228
                  <> reader (fmap fromIntegral . auto)
                  <> help "job server port"
                   )
    <*> option     ( short 'h' <> long "host"
                  <> value "localhost"
                  <> help "job server hostname"
                   )
    <*> switch     ( short 'e' <> long "keep-env"
                  <> help "keep environment variables"
                   )
    <*> nullOption ( short 'h' <> long "hide"
                  <> help "hide the given environment variables"
                   )
    <*> arguments1 Just idm

parserInfo :: ParserInfo Opts
parserInfo = info opts fullDesc

main :: IO ()
main = do
    opts <- execParser parserInfo
    env <- if keepEnv opts
             then filter (\(k,_)->k `notElem` hideEnv opts) <$> getEnvironment
             else return []
    res <- runEitherT $ main' (host opts) (PortNumber $ port opts) env (childArgs opts)
    case res of
      Right code  -> liftIO $ exitWith code
      Left err    -> do liftIO $ hPutStrLn stderr $ "error: "++err
                        liftIO $ exitWith (ExitFailure 250)

main' :: HostName -> PortID -> [(String,String)] -> [String] -> EitherT String IO ExitCode
main' host port env childArgs = do
    (cmd,args) <- case childArgs of
        cmd:args  -> right (cmd, args)
        _         -> left "No command given"
    runJob host port env cmd args
    
runJob :: HostName -> PortID -> [(String,String)] -> String -> [String] -> EitherT String IO ExitCode
runJob hostname port env cmd args = do
    h <- fmapLT show $ tryIO $ connectTo hostname port
    liftIO $ hSetBuffering h NoBuffering
    liftIO $ hPutBinary h $ JobRequest cmd args env
    go $ fromHandleBinary h
  where
    go prod = do
      status <- liftIO $ next prod 
      case status of
        Right (Left err, _) -> left $ "handleResult: Stream error: "++err
        Right (Right x, prod') ->
          case x of
            PutStdout a  -> liftIO (BS.hPut stdout a) >> go prod'
            PutStderr a  -> liftIO (BS.hPut stderr a) >> go prod'
            Error err    -> left err
            JobDone code -> return code
        Left _ -> left "handleResult: Failed to return exit code before end of stream"
