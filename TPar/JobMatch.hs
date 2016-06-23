{-# LANGUAGE DeriveGeneric #-}

module TPar.JobMatch where

import Data.Foldable (traverse_)
import Control.Monad (void)
import Control.Applicative ((<|>))
import System.Exit
import GHC.Generics

import Data.Binary
import Text.Trifecta

import TPar.Types

data GlobAtom = WildCard
              | Literal String
          deriving (Generic, Show)

instance Binary GlobAtom

type Glob = [GlobAtom]

globAtomToParser :: GlobAtom -> Parser ()
globAtomToParser WildCard    = void anyChar
globAtomToParser (Literal a) = void $ string a

globToParser :: Glob -> Parser ()
globToParser atoms = traverse_ globAtomToParser atoms >> eof

globMatches :: Glob -> String -> Bool
globMatches glob str =
    case parseString (globToParser glob) mempty str of
        Success () -> True
        Failure _  -> False

parseGlob :: Parser Glob
parseGlob = many $ wildCard <|> literal
  where
    wildCard = char '*' >> pure WildCard
    literal  = Literal <$> some (noneOf reserved)

    reserved = "*\""

data JobMatch = NoMatch
              | AllMatch
              | NegMatch JobMatch
              | NameMatch Glob
              | JobIdMatch JobId
              | AltMatch [JobMatch]
              | StateMatch StateMatch
              deriving (Generic, Show)

instance Binary JobMatch

data StateMatch = IsQueued
                | IsRunning
                | IsFinished (Maybe ExitCode)
                | IsFailed
                | IsKilled
                deriving (Generic, Show)

instance Binary StateMatch

jobMatches :: JobMatch -> Job -> Bool
jobMatches NoMatch            _   = False
jobMatches AllMatch           _   = True
jobMatches (NegMatch m)       job = not $ jobMatches m job
jobMatches (NameMatch glob)   job = globMatches glob name
  where JobName name = jobName $ jobRequest job
jobMatches (JobIdMatch jobid) job = jobId job == jobid
jobMatches (AltMatch alts)    job = any (`jobMatches` job) alts
jobMatches (StateMatch s)     job = stateMatches s (jobState job)

stateMatches :: StateMatch -> JobState -> Bool
stateMatches IsQueued                 Queued           = True
stateMatches IsRunning                (Running _)      = True
stateMatches (IsFinished Nothing)     (Finished _)     = True
stateMatches (IsFinished (Just code)) (Finished code') = code == code'
stateMatches IsFailed                 (Failed _)       = True
stateMatches IsKilled                 Killed           = True
stateMatches _                        _                = False

parseJobMatch :: Parser JobMatch
parseJobMatch =
    AltMatch <$> (negMatch <|> nameMatch <|> jobIdMatch <|> stateMatch) `sepBy1` char ','
  where
    allMatch :: Parser JobMatch
    allMatch = char '*' >> pure AllMatch

    nameMatch :: Parser JobMatch
    nameMatch = do
        string "name="
        NameMatch <$> between (char '"') (char '"') parseGlob

    stateMatch :: Parser JobMatch
    stateMatch = do
        string "state="
        StateMatch <$> parseJobState

    jobIdMatch :: Parser JobMatch
    jobIdMatch = do
        string "id="
        JobIdMatch . JobId . fromIntegral <$> integer

    negMatch = do
        char '!'
        NegMatch <$> between (char '(') (char ')') parseJobMatch

parseJobState :: Parser StateMatch
parseJobState =
        (string "queued"    *> pure IsQueued)
    <|> (string "running"   *> pure IsRunning)
    <|> (string "finished"  *> pure (IsFinished Nothing))
    <|> (string "done"      *> pure (IsFinished Nothing))
    <|> (string "succeeded" *> pure (IsFinished (Just ExitSuccess)))
    <|> (string "code="     *> (IsFinished . Just <$> exitCode))
    <|> (string "failed"    *> pure IsFailed)
    <|> (string "killed"    *> pure IsKilled)
  where
    exitCode = (<?> "exit code") $ do
      n <- integer
      pure $ case n of
               0 -> ExitSuccess
               _ -> ExitFailure (fromIntegral n)
