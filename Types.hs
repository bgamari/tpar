{-# LANGUAGE DeriveGeneric #-}                

module Types where
                
import Control.Applicative
import Data.Binary
import GHC.Generics
import ProcessPipe

data JobRequest = JobRequest { jobCommand :: FilePath
                             , jobArgs    :: [String]
                             , jobCwd     :: FilePath
                             , jobEnv     :: Maybe [(String, String)]
                             }
                deriving (Show, Generic)

instance Binary JobRequest where
    get = JobRequest <$> get <*> get <*> get <*> get
    put (JobRequest cmd args cwd env) =
        put cmd >> put args >> put cwd >> put env

data Status = PStatus ProcessStatus
            | Error   String
            deriving (Show, Generic)

instance Binary Status
