{-# LANGUAGE GeneralizedNewtypeDeriving #-}

module TPar.Rpc where

import Control.Distributed.Process
import Control.Distributed.Process.Serializable
import Data.Binary

newtype RpcSendPort a b = RpcSendPort (SendPort (a, SendPort b))
                        deriving (Binary, Serializable)
newtype RpcRecvPort a b = RpcRecvPort (ReceivePort (a, SendPort b) )

newRpc :: (Serializable a, Serializable b)
       => Process (RpcSendPort a b, RpcRecvPort a b)
newRpc = do
    (sp, rp) <- newChan
    return (RpcSendPort sp, RpcRecvPort rp)

callRpc :: (Serializable a, Serializable b)
        => RpcSendPort a b -> a -> Process b
callRpc (RpcSendPort sp) x = do
    (reply_sp, reply_rp) <- newChan
    sendChan sp (x, reply_sp)
    receiveChan reply_rp

matchRpc :: (Serializable a, Serializable b)
         => RpcRecvPort a b -> (a -> Process (b, c)) -> Match c
matchRpc rp handler = matchRpc' rp $ \_ x reply -> do
    (y, z) <- handler x
    reply y
    return z

type RpcHandler a b c
    = ProcessId          -- ^ 'ProcessId' of the requestor
   -> a                  -- ^ arguments
   -> (b -> Process ())  -- ^ reply action
   -> Process c          -- ^ return

-- | Allow deferred replies
matchRpc' :: (Serializable a, Serializable b)
          => RpcRecvPort a b -> RpcHandler a b c -> Match c
matchRpc' (RpcRecvPort rp) handler = matchChan rp $ \(x, reply_sp) -> do
    let requestor_pid = sendPortProcessId $ sendPortId reply_sp
    handler requestor_pid x (sendChan reply_sp)
