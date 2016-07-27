{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | A (potentially distributed) stream of data from a source to a sink.
-- This has similar semantics to 'Pipe',
--
-- * The sink accepts multiple values followed by a terminal return value.
-- * The source emits each of these values downstream, returning the terminal
--   return value.
-- * If either side dies before the terminal return value has been yielded
--   the other side will be killed.
-- * Neither side will return until both sides have the return value.
-- * Each stream has at most one source process and one sink process
--
module TPar.RemoteStream where

import Pipes
import Control.Distributed.Process
import Control.Distributed.Process.Serializable
import Data.Binary

-- | A port which serves as a sink of data.
newtype SinkPort a r = SinkPort (SendPort (RequestConnection r a))
                     deriving (Binary, Show)

-- | A port which can source data.
newtype SourcePort a r = SourcePort (ReceivePort (RequestConnection r a))

-- handshake protocol:
-- | Source to sink
newtype RequestConnection r a = RequestConnection (SendPort (StartSending r a))
                              deriving (Binary)
-- | Sink to source
newtype StartSending r a = StartSending (SendPort (Either (r, SendPort a))
                         deriving (Binary)

data DataMesg r a = Next a
                  | Done r
                  | Failed DiedReason
                  deriving (Show, Generic)
instance (Binary a, Binary r) => Binary (DataMesg r a)
-- ... then send data ...

-- and then clean up:
newtype EverythingSent     = EverythingSent ()            -- source to sink
                           deriving (Binary)
newtype Done               = Done ()                      -- sink to source
                           deriving (Binary)

-- | Feed data from a 'Producer' into a 'SinkPort'.
connectSink :: forall a r. (Serializable a, Serializable r)
            => SinkPort a r -> Producer a Process r -> Process r
connectSink (SinkPort sp) prod0 = do
    linkPort sp
    (startSendSp, startSendRp) <- newChan
    sendChan sp (RequestConnection startSendSp)
    StartSending dataSp <- receiveChan startSendRp
    say "RStream.connectSink:haveConnection"
    r <- go dataSp prod0
    say "RStream.connectSink:expectEverythingSent"
    EverythingSent () <- expect    -- wait until completion confirmation
    say "RStream.connectSink:everythingSent"
    unlinkPort sp
    send srcPid (Done ())
    return r
  where
    go :: SendPort (Either r a) -> Producer a Process r -> Process r
    go dataSp prod = do
        r <- next prod
        case r of
            Left done -> do
                sendChan dataSp (Left done)
                return done
            Right (x, prod') -> do
                sendChan dataSp (Right x)
                go dataSp prod'

-- | Convert a 'SourcePort' into a 'Producer'.
toProducer :: (Serializable a, Serializable r)
           => SourcePort a r -> Producer a Process r
toProducer (SourcePort rp) = do
    lift $ say "RStream.toProducer:waitingForConnection"
    RequestConnection srcPid <- lift expect
    lift $ link srcPid
    lift $ send srcPid (ConnectionAccepted ())
    r <- go
    lift $ send srcPid (EverythingSent ())
    lift $ unlink srcPid
    lift $ say "RStream.toProducer:expectDone"
    Done () <- lift expect
    lift $ say "RStream.toProducer:done"
    return r
  where
    go = do
        lift $ say "RStream.toProducer:receive"
        r <- lift $ receiveChan rp
        lift $ say "RStream.toProducer:received"
        case r of
            Left done -> return done
            Right x   -> yield x >> go

newStream :: (Serializable a, Serializable r)
          => Process (SinkPort a r, SourcePort a r)
newStream = do
    (sp, rp) <- newChan
    return (SinkPort sp, SourcePort rp)
