{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE ScopedTypeVariables #-}

module TPar.ProcessPipe ( ProcessOutput(..)
                        , runProcess
                          -- * Killing the process
                        , ProcessKilled(..)
                          -- * Deinterleaving output
                        , processOutputToHandles
                        ) where

import Control.Applicative
import qualified Pipes.Prelude as PP
import qualified Pipes.ByteString as PBS
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import Data.Traversable
import Control.Monad (msum)
import Control.Exception (Exception)
import System.IO (Handle)
import System.Exit

import Pipes
import Pipes.Safe () -- for MonadCatch instance
import qualified Pipes.Concurrent as PC
import System.Process (runInteractiveProcess, ProcessHandle, waitForProcess, terminateProcess)
import Control.Concurrent.STM
import Control.Distributed.Process
import Control.Monad.Catch (handle, throwM)

import Data.Binary
import Data.Binary.Put
import Data.Binary.Get
import GHC.Generics
import TPar.Utils

processPipes :: MonadIO m
             => FilePath                -- ^ Executable name
             -> [String]                -- ^ Arguments
             -> Maybe FilePath          -- ^ Current working directory
             -> Maybe [(String,String)] -- ^ Optional environment
             -> IO ( Consumer ByteString m ()
                   , Producer ByteString m ()
                   , Producer ByteString m ()
                   , ProcessHandle)
processPipes cmd args cwd env = do
    (stdin, stdout, stderr, phandle) <- runInteractiveProcess cmd args cwd env
    return (PBS.toHandle stdin, PBS.fromHandle stdout, PBS.fromHandle stderr, phandle)

data InterleaverCanTerminate = InterleaverCanTerminate deriving (Generic)
instance Binary InterleaverCanTerminate

data InterleaveException = InterleaveException String
                         deriving (Show)
instance Exception InterleaveException

interleave :: forall a. [Producer a Process ()] -> Producer a Process ()
interleave producers = do
    inputs <- lift $ forM producers $ \prod -> do
        (output, input, seal) <- liftIO $ PC.spawn' (PC.bounded 10)
        pid <- spawnLocal $ runEffect $ do
            prod >-> PC.toOutput output
            liftIO $ atomically seal

        _ <- monitor pid
        return input

    let matchTermination = match $ \(ProcessMonitorNotification _ pid reason) ->
                                     case reason of
                                       DiedNormal -> return Nothing
                                       _          -> throwM $ InterleaveException $ show reason
        matchData = matchSTM (PC.recv $ msum inputs) pure
        go :: Producer a Process ()
        go = do
            mx <- lift $ receiveWait [ matchTermination, matchData ]
            case mx of
              Nothing -> return ()
              Just x -> yield x >> go
    go

data ProcessOutput
    = PutStdout !ByteString
    | PutStderr !ByteString
    deriving (Show, Generic)

instance Binary ProcessOutput

-- Unfortunate orphan
instance Binary ExitCode where
    get = do
        code <- getInt32le
        return $ case code of
          0  -> ExitSuccess
          _  -> ExitFailure (fromIntegral code)
    put ExitSuccess        = putInt32le 0
    put (ExitFailure code) = putInt32le (fromIntegral code)

data ProcessKilled = ProcessKilled
                   deriving (Show, Generic)

instance Binary ProcessKilled
instance Exception ProcessKilled

runProcess :: FilePath -> [String] -> Maybe FilePath
           -> Producer ProcessOutput Process ExitCode
runProcess cmd args cwd = do
    lift $ tparDebug "starting process"
    (stdin, stdout, stderr, phandle) <- liftIO $ processPipes cmd args cwd Nothing
    let processKilled ProcessKilled = liftIO $ do
            terminateProcess phandle
            throwM ProcessKilled
    handle processKilled $ do
        interleave [ stderr >-> PP.map PutStderr
                   , stdout >-> PP.map PutStdout
                   ]
        liftIO $ waitForProcess phandle

processOutputToHandles :: MonadIO m
                       => Handle -> Handle -> Producer ProcessOutput m a -> m a
processOutputToHandles stdout stderr = go
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
