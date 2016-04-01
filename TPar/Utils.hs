module TPar.Utils where

import Control.Monad.IO.Class
import Debug.Trace

debugEnabled :: Bool
debugEnabled = False

tparDebug :: MonadIO m => String -> m ()
tparDebug _ | not debugEnabled = return ()
tparDebug s = liftIO $ do
    putStrLn s'
    traceEventIO s'
  where
     s' = "tpar: "++s
