{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE ScopedTypeVariables #-}

module TPar.ProcessPipe ( ProcessOutput(..)
                        , runProcess
                          -- * Killing the process
                        , ProcessKilled(..)
                        ) where

import Control.Applicative
import qualified Pipes.Prelude as PP
import qualified Pipes.ByteString as PBS
import Data.ByteString (ByteString)
import Data.Traversable
import Control.Monad (msum)
import Control.Exception (Exception)

import Pipes
import Pipes.Safe () -- for MonadCatch instance
import qualified Pipes.Concurrent as PC
import System.Process (runInteractiveProcess, ProcessHandle, waitForProcess, terminateProcess)
import System.Exit
import Control.Concurrent.Async
import Control.Concurrent.STM
import Control.Distributed.Process
import Control.Monad.Catch (handle, throwM)

import Data.Binary
import Data.Binary.Put
import Data.Binary.Get
import GHC.Generics
import Debug.Trace

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

interleave :: forall a. [Producer a Process ()] -> Producer a Process ()
interleave producers = do
    inputs <- lift $ forM producers $ \prod -> do
        (output, input, seal) <- liftIO $ PC.spawn' (PC.bounded 10)
        spawnLocal $ runEffect $ do
            prod >-> PC.toOutput output
            liftIO $ atomically seal
        return input
    PC.fromInput $ msum inputs

data ProcessOutput
    = PutStdout !ByteString
    | PutStderr !ByteString
    deriving (Show, Generic)

instance Binary ProcessOutput

-- Unfortunate orphan
instance Binary ExitCode where
    get = do
        code <- getWord32le
        return $ case code of
          0  -> ExitSuccess
          _  -> ExitFailure (fromIntegral code)
    put ExitSuccess        = putWord32le 0
    put (ExitFailure code) = putWord32le (fromIntegral code)

data ProcessKilled = ProcessKilled
                   deriving (Show, Generic)

instance Binary ProcessKilled
instance Exception ProcessKilled

runProcess :: FilePath -> [String] -> Maybe FilePath
           -> Producer ProcessOutput Process ExitCode
runProcess cmd args cwd = do
    liftIO $ traceEventIO "Ben: starting process"
    (stdin, stdout, stderr, phandle) <- liftIO $ processPipes cmd args cwd Nothing
    let processKilled ProcessKilled = liftIO $ do
            terminateProcess phandle
            throwM ProcessKilled
    handle processKilled $ do
        interleave [ stderr >-> PP.map PutStderr
                   , stdout >-> PP.map PutStdout
                   ]
        liftIO $ waitForProcess phandle

traceIt msg = PP.mapM $ \x -> liftIO (traceEventIO msg) >> pure x
