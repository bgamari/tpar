module JobClient ( watchJob
                 , watchStatus
                 ) where

import Control.Monad.IO.Class
import Control.Error
import qualified Data.ByteString as BS
import System.IO
import System.Exit
import Pipes

import Control.Distributed.Process

import RemoteStream
import Rpc
import ProcessPipe
import Types

watchJob :: ServerIface -> JobRequest
         -> Process (Producer ProcessOutput Process ExitCode)
watchJob iface req = do
    say "watch1"
    (sink, src) <- RemoteStream.newStream
    say "watch2"
    callRpc (enqueueJob iface) (req, Just sink)
    say "watch3"
    return $ RemoteStream.toProducer src

watchStatus :: MonadIO m => Producer ProcessOutput m a -> m a
watchStatus = go
  where
    go prod = do
      status <- next prod
      case status of
        Right (x, prod') -> do
          liftIO $ case x of
                     PutStdout a  -> BS.hPut stdout a
                     PutStderr a  -> BS.hPut stderr a
          go prod'
        Left code -> return code
