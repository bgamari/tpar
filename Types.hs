module Types where
                
import System.Exit
import Data.Binary
import Data.ByteString (ByteString)
import Control.Applicative
import Data.Binary.Put
import Data.Binary.Get

data JobRequest = JobRequest { jobCommand :: String }
                deriving (Show)

instance Binary JobRequest where
    get = JobRequest <$> get
    put (JobRequest cmd) = put cmd

data JobResult = JobResult { resultStdout :: ByteString
                           , resultStderr :: ByteString
                           , resultExitCode :: ExitCode
                           }
               deriving (Show)

instance Binary JobResult where
    get = JobResult <$> get <*> get <*> get
    put (JobResult out err code) = put out >> put err >> put code

instance Binary ExitCode where
    get = do
        code <- getWord32le
        return $ case code of
          0  -> ExitSuccess
          _  -> ExitFailure (fromIntegral code)
    put ExitSuccess        = putWord32le 0
    put (ExitFailure code) = putWord32le (fromIntegral code)
