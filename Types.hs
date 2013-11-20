{-# LANGUAGE DeriveGeneric #-}                

module Types where
                
import System.Exit
import Data.Binary
import Data.ByteString (ByteString)
import Control.Applicative
import Data.Binary.Put
import Data.Binary.Get
import GHC.Generics

data JobRequest = JobRequest { jobCommand :: String
                             , jobArgs    :: [String]
                             , jobEnv     :: [(String, String)]
                             }
                deriving (Show, Generic)

instance Binary JobRequest where
    get = JobRequest <$> get <*> get <*> get
    put (JobRequest cmd args env) =
        put cmd >> put args >> put env

data Status = PutStdout !ByteString
            | PutStderr !ByteString
            | JobDone   !ExitCode
            | Error      String
            deriving (Show, Generic)

instance Binary Status

instance Binary ExitCode where
    get = do
        code <- getWord32le
        return $ case code of
          0  -> ExitSuccess
          _  -> ExitFailure (fromIntegral code)
    put ExitSuccess        = putWord32le 0
    put (ExitFailure code) = putWord32le (fromIntegral code)
