module TPar.JobClient ( watchJob
                      , watchStatus
                      ) where

import Control.Monad.IO.Class
import Control.Error
import qualified Data.ByteString as BS
import System.IO
import System.Exit
import Pipes

import Control.Distributed.Process

import TPar.RemoteStream as RemoteStream
import TPar.Rpc
import TPar.ProcessPipe
import TPar.Server.Types
import TPar.Types
import Debug.Trace

watchJob :: ServerIface -> JobRequest
         -> Process (Producer ProcessOutput Process ExitCode)
watchJob iface req = do
    (sink, src) <- RemoteStream.newStream
    callRpc (enqueueJob iface) (req, Just sink)
    return $ RemoteStream.toProducer src

watchStatus :: MonadIO m => Producer ProcessOutput m a -> m a
watchStatus = go
  where
    go prod = do
      status <- next prod
      liftIO $ traceEventIO "Ben: watch message"
      case status of
        Right (x, prod') -> do
          liftIO $ case x of
                     PutStdout a  -> BS.hPut stdout a
                     PutStderr a  -> BS.hPut stderr a
          go prod'
        Left code -> return code
