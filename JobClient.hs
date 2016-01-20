module JobClient ( enqueueJob
                 , watchStatus
                 ) where

import Network
import Control.Monad.IO.Class
import Control.Error
import qualified Data.ByteString as BS
import System.IO
import System.Exit
import Pipes

import ProcessPipe
import Types
import Util

enqueueJob :: HostName
           -> PortID
           -> String                  -- ^ Command name
           -> [String]                -- ^ Arguments
           -> FilePath                -- ^ Current working directory
           -> Maybe [(String,String)] -- ^ Environment
           -> IO (Producer (Either String Status) IO ())
enqueueJob hostname port cmd args cwd env = do
    h <- connectTo hostname port
    hSetBuffering h NoBuffering
    hPutBinary h $ QueueJob $ JobRequest cmd args cwd env
    return $ fromHandleBinary h

watchStatus :: Producer (Either String Status) IO () -> EitherT String IO ExitCode
watchStatus = go
  where
    go prod = do
      status <- liftIO $ next prod
      case status of
        Right (Left err, _) -> left $ "handleResult: Stream error: "++err
        Right (Right x, prod') ->
          case x of
            PStatus (PutStdout a)  -> liftIO (BS.hPut stdout a) >> go prod'
            PStatus (PutStderr a)  -> liftIO (BS.hPut stderr a) >> go prod'
            PStatus (JobDone code) -> return code
            Error err              -> left err
        Left _ -> left "handleResult: Failed to return exit code before end of stream"
