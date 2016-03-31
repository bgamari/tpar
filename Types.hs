{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}

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

newtype JobName = JobName String
                deriving (Show, Eq, Ord, Binary)

data JobRequest = JobRequest { jobName     :: JobName
                             , jobPriority :: Priority
                             , jobCommand  :: FilePath
                             , jobArgs     :: [String]
                             , jobCwd      :: FilePath
                             , jobEnv      :: Maybe [(String, String)]
                             }
                deriving (Show, Generic)

instance Binary JobRequest

newtype Priority = Priority Int
                 deriving (Eq, Ord, Show, Binary)

data Status = PStatus ProcessStatus
            | Error   String
            deriving (Show, Generic)

instance Binary Status
