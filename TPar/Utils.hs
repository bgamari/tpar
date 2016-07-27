module TPar.Utils where

import Control.Distributed.Process

debugEnabled :: Bool
debugEnabled = True

tparDebug :: String -> Process ()
tparDebug _ | not debugEnabled = return ()
tparDebug s = say s'
  where
     s' = "tpar: "++s
