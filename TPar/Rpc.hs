{-# LANGUAGE GeneralizedNewtypeDeriving #-}

module TPar.Rpc where

import Control.Distributed.Process
import Control.Distributed.Process.Serializable
import Data.Binary

newtype RpcSendPort a b = RpcSendPort (SendPort (a, SendPort b))
                        deriving (Show, Binary, Serializable)
newtype RpcRecvPort a b = RpcRecvPort (ReceivePort (a, SendPort b) )

newRpc :: (Serializable a, Serializable b)
       => Process (RpcSendPort a b, RpcRecvPort a b)
newRpc = do
    (sp, rp) <- newChan
    return (RpcSendPort sp, RpcRecvPort rp)

-- | Call a remote procedure or return 'Left' if the handling process is no
-- longer alive.
callRpc :: (Serializable a, Serializable b)
        => RpcSendPort a b -> a -> Process (Either DiedReason b)
callRpc (RpcSendPort sp) x = do
    (reply_sp, reply_rp) <- newChan
    mref <- monitorPort sp
    sendChan sp (x, reply_sp)
    receiveWait [ matchIf (\(PortMonitorNotification mref' _ _) -> mref == mref')
                          (\(PortMonitorNotification _ _ reason) -> pure $ Left reason)
                , matchChan reply_rp (pure . Right)
                ]

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
