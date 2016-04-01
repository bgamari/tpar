{-# LANGUAGE DeriveGeneric #-}

module JobMatch where

import Data.Foldable (traverse_)
import Control.Monad (void)
import Control.Applicative ((<|>))
import Data.Binary
import GHC.Generics
import Text.Trifecta

import Types

data GlobAtom = WildCard
              | Literal String
          deriving (Generic, Show)

instance Binary GlobAtom

type Glob = [GlobAtom]

globToParser :: GlobAtom -> Parser ()
globToParser WildCard    = void anyChar
globToParser (Literal a) = void $ string a

globMatches :: Glob -> String -> Bool
globMatches glob str =
    case parseString (traverse_ globToParser glob) mempty str of
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
              | NameMatch (Glob Char)
              | JobIdMatch JobId
              | AltMatch JobMatch JobMatch
              deriving (Generic)

instance Binary JobMatch

jobMatches :: JobMatch -> Job -> Bool
jobMatches NoMatch            _   = False
jobMatches AllMatch           _   = True
jobMatches (NameMatch glob)   job = globMatches glob (jobName $ jobRequest job)
jobMatches (JobIdMatch jobid) job = jobId job == jobid
jobMatches (AltMatch x y)     job = jobMatches x job || jobMatches y job

parseJobMatch :: Parser JobMatch
parseJobMatch =
    allMatch <|> nameMatch <|> jobIdMatch <|> altMatch
  where
    allMatch = char '*' >> pure AllMatch
    nameMatch = do
        "name="
        NameMatch <$> betwen "\"" "\"" parseGlob
