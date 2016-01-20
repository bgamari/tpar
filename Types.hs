{-# LANGUAGE DeriveGeneric #-}

module Types where

import Control.Applicative
import Data.Binary
import GHC.Generics
import ProcessPipe

-- | This is the first thing that will be sent over a new
-- request socket
data Request = QueueJob JobRequest
             | WorkerReady
             deriving (Show, Generic)

instance Binary Request

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
