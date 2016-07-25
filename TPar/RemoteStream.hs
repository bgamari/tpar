{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | A (potentially distributed) stream of data from a source to a sink.
-- This has similar semantics to 'Pipe',
--
-- * The sink accepts multiple values followed by a terminal return value.
-- * The source emits each of these values downstream, returning the terminal
--   return value.
-- * If either side dies before yielding the terminal return value
--   the other side will be killed.
-- * Neither side will return until both sides have the return value.
-- * Each stream has at most one source process and one sink process
--
module TPar.RemoteStream where

import Pipes
import Control.Distributed.Process
import Control.Distributed.Process.Serializable
import Data.Binary
import TPar.Utils

newtype SinkPort a r = SinkPort (SendPort (Either r a))
                     deriving (Binary)

newtype SourcePort a r = SourcePort (ReceivePort (Either r a))

-- handshake protocol:
newtype RequestConnection  = RequestConnection ProcessId  -- source to sink
                           deriving (Binary)
newtype ConnectionAccepted = ConnectionAccepted ()        -- sink to source
                           deriving (Binary)
-- ... send data
newtype EverythingSent     = EverythingSent ()            -- source to sink
                           deriving (Binary)
newtype Done               = Done ()                      -- sink to source
                           deriving (Binary)

-- | Connect a 'SinkPort' to a 'Producer'.
connectSink :: forall a r. (Serializable a, Serializable r)
            => SinkPort a r -> Producer a Process r -> Process r
connectSink (SinkPort sp) prod0 = do
    linkPort sp
    myPid <- getSelfPid
    let srcPid = sendPortProcessId $ sendPortId sp
    send srcPid (RequestConnection myPid)
    tparDebug "Sent RequestConnection"
    ConnectionAccepted () <- expect
    tparDebug "Have connection accepted"
    r <- go prod0
    tparDebug "Sending EverythingSent"
    EverythingSent () <- expect    -- wait until completion confirmation
    unlinkPort sp
    tparDebug "Sending Done"
    send srcPid (Done ())
    return r
  where
    go :: Producer a Process r -> Process r
    go prod = do
        r <- next prod
        case r of
            Left done -> do
                sendChan sp (Left done)
                return done
            Right (x, prod') -> do
                sendChan sp (Right x)
                go prod'

-- | Convert a 'SourcePort' into a 'Producer'.
toProducer :: (Serializable a, Serializable r)
           => SourcePort a r -> Producer a Process r
toProducer (SourcePort rp) = do
    lift $ tparDebug "Waiting for RequestConnection"
    RequestConnection srcPid <- lift expect
    lift $ link srcPid
    lift $ tparDebug "Sending ConnectionAccepted"
    lift $ send srcPid (ConnectionAccepted ())
    lift $ tparDebug "In read loop"
    r <- go
    lift $ tparDebug "Sending EverythingSent"
    lift $ send srcPid (EverythingSent ())
    lift $ unlink srcPid
    lift $ tparDebug "Waitin for all done"
    Done () <- lift expect
    lift $ tparDebug "All done"
    return r
  where
    go = do
        r <- lift $ receiveChan rp
        case r of
            Left done -> return done
            Right x   -> yield x >> go

newStream :: (Serializable a, Serializable r)
          => Process (SinkPort a r, SourcePort a r)
newStream = do
    (sp, rp) <- newChan
    return (SinkPort sp, SourcePort rp)
