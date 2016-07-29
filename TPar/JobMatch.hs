{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE NamedFieldPuns #-}

module TPar.JobMatch where

import Data.Foldable (traverse_)
import Control.Monad (void)
import Control.Applicative ((<|>))
import System.Exit
import GHC.Generics (Generic)

import Data.Binary
import Text.Trifecta
import Text.Parser.Expression
import Text.Parser.Token.Style (emptyOps)

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
              | NegMatch JobMatch
              | NameMatch Glob
              | JobIdMatch JobId
              | AltMatch [JobMatch]
              | AllMatch [JobMatch]
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
jobMatches (NegMatch m)       job = not $ jobMatches m job
jobMatches (NameMatch glob)   job = globMatches glob name
  where JobName name = jobName $ jobRequest job
jobMatches (JobIdMatch jobid) job = jobId job == jobid
jobMatches (AltMatch alts)    job = any (`jobMatches` job) alts
jobMatches (AllMatch alts)    job = all (`jobMatches` job) alts
jobMatches (StateMatch s)     job = stateMatches s (jobState job)

stateMatches :: StateMatch -> JobState -> Bool
stateMatches IsQueued                 Queued{}               = True
stateMatches IsRunning                Running{}              = True
stateMatches (IsFinished Nothing)     Finished{}             = True
stateMatches (IsFinished (Just code)) Finished {jobExitCode} = code == jobExitCode
stateMatches IsFailed                 Failed{}               = True
stateMatches IsKilled                 Killed{}               = True
stateMatches _                        _                      = False

opTable :: OperatorTable Parser JobMatch
opTable =
    [ [ prefix "!" NegMatch ]
    , [ binary "&" (\x y -> AllMatch [x,y]) AssocLeft
      , binary "and" (\x y -> AllMatch [x,y]) AssocLeft
      ]
    , [ binary "|" (\x y -> AltMatch [x,y]) AssocLeft
      , binary "or" (\x y -> AltMatch [x,y]) AssocLeft
      ]
    ]
  where
    binary  name fun assoc = Infix (fun <$ reservedOp name) assoc
    prefix  name fun       = Prefix (fun <$ reservedOp name)
    reservedOp name = reserve emptyOps name

parseJobMatch :: Parser JobMatch
parseJobMatch = expr
  where
    expr = buildExpressionParser opTable term <?> "job match expression"

    term = parens expr <|> simple

    simple = starMatch <|> jobIdMatch <|> stateMatch <|> nameMatch

    starMatch :: Parser JobMatch
    starMatch = char '*' >> pure (NegMatch NoMatch)

    nameMatch :: Parser JobMatch
    nameMatch = do
        void $ string "name="
        NameMatch <$> between (char '"') (char '"') parseGlob

    stateMatch :: Parser JobMatch
    stateMatch = do
        void $ string "state="
        StateMatch <$> parseJobState

    jobIdMatch :: Parser JobMatch
    jobIdMatch = do
        void $ string "id="
        JobIdMatch . JobId . fromIntegral <$> integer

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
