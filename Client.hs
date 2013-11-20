import Network
import System.Environment
import System.Exit
import System.Directory (getCurrentDirectory)
import System.IO (stderr, stdout, hPutStrLn, hSetBuffering, BufferMode(NoBuffering))
import Control.Error hiding (err)
import Data.List (stripPrefix)
import qualified Data.ByteString as BS
import Pipes
import Options.Applicative

import Types
import Util
       
data Opts = Opts { port      :: PortNumber
                 , host      :: String
                 -- , keepEnv   :: Bool
                 -- , hideEnv   :: [String]
                   -- * Strip this prefix path when determining current working directory
                 , stripPath :: FilePath
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
    -- <*> switch     ( short 'e' <> long "keep-env"
    --               <> help "keep environment variables"
    --                )
    -- <*> nullOption ( short 'h' <> long "hide"
    --               <> help "hide the given environment variables"
    --                )
    <*> strOption  ( short 's' <> long "strip"
                  <> value ""
                  <> help "strip this prefix path when determining current working directory"
                   )
    <*> arguments1 Just idm

parserInfo :: ParserInfo Opts
parserInfo = info opts fullDesc

main :: IO ()
main = do
    opts <- execParser parserInfo
    --env <- if keepEnv opts
    --         then Just . filter (\(k,_)->k `notElem` hideEnv opts) <$> getEnvironment
    --         else return Nothing
    let env = Nothing -- TODO
    let stripCwd cwd = maybe cwd id $ stripPrefix (stripPath opts) cwd
    cwd <- stripCwd <$> getCurrentDirectory
    res <- runEitherT $ main' (host opts) (PortNumber $ port opts) (childArgs opts) cwd env
    case res of
      Right code  -> exitWith code
      Left err    -> do hPutStrLn stderr $ "error: "++err
                        exitWith (ExitFailure 250)

main' :: HostName
      -> PortID
      -> [String]
      -> FilePath
      -> Maybe [(String,String)]
      -> EitherT String IO ExitCode
main' host port childArgs cwd env = do
    (cmd,args) <- case childArgs of
        cmd:args  -> right (cmd, args)
        _         -> left "No command given"
    runJob host port cmd args cwd env
    
runJob :: HostName
       -> PortID
       -> String                  -- ^ Command name
       -> [String]                -- ^ Arguments
       -> FilePath                -- ^ Current working directory
       -> Maybe [(String,String)] -- ^ Environment
       -> EitherT String IO ExitCode
runJob hostname port cmd args cwd env = do
    h <- fmapLT show $ tryIO $ connectTo hostname port
    liftIO $ hSetBuffering h NoBuffering
    liftIO $ hPutBinary h $ JobRequest cmd args cwd env
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
