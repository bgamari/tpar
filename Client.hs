import Control.Error hiding (err)
import Network
import System.Environment
import System.Exit
import qualified Data.ByteString as BS
import System.IO (stderr, stdout, hPutStrLn, hSetBuffering, BufferMode(NoBuffering))
import Pipes

import Types
import Util

main :: IO ()
main = do
    args <- liftIO getArgs
    let (myArgs,childArgs) = if "--" `elem` args
                              then break (=="--") args
                              else ([], args)
        port = PortNumber 2228
        host = "localhost"
    res <- runEitherT (main' host port childArgs)
    case res of
      Right code  -> liftIO $ exitWith code
      Left err    -> do liftIO $ hPutStrLn stderr $ "error: "++err
                        liftIO $ exitWith (ExitFailure 250)

main' :: HostName -> PortID -> [String] -> EitherT String IO ExitCode
main' host port childArgs = do
    (cmd,args) <- case childArgs of
        cmd:args  -> right (cmd, args)
        _         -> left "No command given"
    runJob host port cmd args
    
runJob :: HostName -> PortID -> String -> [String] -> EitherT String IO ExitCode
runJob hostname port cmd args = do
    h <- fmapLT show $ tryIO $ connectTo hostname port
    liftIO $ hSetBuffering h NoBuffering
    liftIO $ hPutBinary h $ JobRequest cmd args
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
