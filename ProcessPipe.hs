{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE ScopedTypeVariables #-}

module ProcessPipe ( ProcessOutput(..)
                   , runProcess
                   ) where

import Control.Applicative
import qualified Pipes.Prelude as PP
import qualified Pipes.ByteString as PBS
import Data.ByteString (ByteString)
import Data.Traversable
import Control.Monad (msum)

import Pipes
import qualified Pipes.Concurrent as PC
import System.Process (runInteractiveProcess, ProcessHandle, waitForProcess)
import System.Exit
import Control.Concurrent.Async
import Control.Concurrent.STM
import Control.Distributed.Process

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
        (output, input) <- liftIO $ PC.spawn (PC.bounded 100)
        spawnLocal $ runEffect $ prod >-> PC.toOutput output
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

runProcess :: FilePath -> [String] -> Maybe FilePath
           -> Producer ProcessOutput Process ExitCode
runProcess cmd args cwd = do
    liftIO $ traceEventIO "Ben: starting process"
    (stdin, stdout, stderr, phandle) <- liftIO $ processPipes cmd args cwd Nothing
    liftIO $ traceEventIO "Ben: process running"
    interleave [ stderr >-> PP.map PutStderr >-> traceIt "Ben: stderr"
               , stdout >-> PP.map PutStdout >-> traceIt "Ben: stdout"
               ] >-> traceIt "Ben: output"
    liftIO $ traceEventIO "Ben: interleave done"
    r <- liftIO (waitForProcess phandle)
    liftIO $ traceEventIO "Ben: process done"
    pure r

traceIt msg = PP.mapM $ \x -> liftIO (traceEventIO msg) >> pure x
