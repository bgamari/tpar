import Control.Error
import Network
import System.Environment

import Types
import Util

main = do
    args <- getArgs
    let (myArgs,childCmd) = if "--" `elem` args
                              then break (=="--") args
                              else ([], args)
        port = 2228
        host = "localhost"
        
    res <- runEitherT $ submitJob host port childCmd
    return ()
    
    
submitJob :: HostName -> PortNumber -> [String] -> EitherT String IO JobResult
submitJob hostname port cmd = do
    h <- connectTo hostname port
    hPutBinary h $ JobRequest cmd
    hGetBinary h
    
