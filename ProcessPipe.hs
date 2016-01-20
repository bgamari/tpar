{-# LANGUAGE DeriveGeneric #-}

module ProcessPipe ( ProcessStatus(..)
                   , runProcess
                   ) where

import Control.Applicative
import qualified Pipes.Prelude as PP
import qualified Pipes.ByteString as PBS
import Data.ByteString (ByteString)

import Pipes
import System.Process (runInteractiveProcess, ProcessHandle, waitForProcess)
import System.Exit
import Control.Concurrent.Async
import Control.Concurrent.STM

import Data.Binary
import Data.Binary.Put
import Data.Binary.Get
import GHC.Generics

processPipes :: FilePath                -- ^ Executable name
             -> [String]                -- ^ Arguments
             -> Maybe FilePath          -- ^ Current working directory
             -> Maybe [(String,String)] -- ^ Optional environment
             -> IO ( Consumer ByteString IO ()
                   , Producer ByteString IO ()
                   , Producer ByteString IO ()
                   , ProcessHandle)
processPipes cmd args cwd env = do
    (stdin, stdout, stderr, phandle) <- runInteractiveProcess cmd args cwd env
    return (PBS.toHandle stdin, PBS.fromHandle stdout, PBS.fromHandle stderr, phandle)

interleave :: [Producer a IO ()] -> Producer a IO ()
interleave producers = do
    queue <- liftIO newTQueueIO
    active <- liftIO $ atomically $ newTVar (length producers)
    mapM_ (liftIO . listen active queue) producers
    watch active queue
  where
    listen :: TVar Int -> TQueue (Maybe a) -> Producer a IO () -> IO (Async ())
    listen active queue producer = async $ go producer
      where go prod = do
              n <- next prod
              case n of
                Right (x, prod')  -> do liftIO $ atomically $ writeTQueue queue (Just x)
                                        go prod'
                Left _            -> do liftIO $ atomically $ do
                                          modifyTVar active (subtract 1)
                                          writeTQueue queue Nothing

    watch :: TVar Int -> TQueue (Maybe a) -> Producer a IO ()
    watch active queue = do
      res <- liftIO $ atomically $ do
        e <- tryReadTQueue queue
        case e of
          Just e'  -> return (Just e')
          Nothing  -> do n <- readTVar active
                         if n > 0
                           then Just <$> readTQueue queue
                           else return Nothing
      case res of
        Just (Just x)  -> yield x >> watch active queue
        Just Nothing   -> watch active queue
        Nothing        -> return ()

data ProcessStatus
    = PutStdout !ByteString
    | PutStderr !ByteString
    | JobDone   !ExitCode
    deriving (Show, Generic)

instance Binary ProcessStatus

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
           -> Producer ProcessStatus IO ()
runProcess cmd args cwd = do
    (stdin, stdout, stderr, phandle) <- liftIO $ processPipes cmd args cwd Nothing
    interleave [ stderr >-> PP.map PutStderr
               , stdout >-> PP.map PutStdout
               ]
    liftIO (waitForProcess phandle) >>= yield . JobDone
