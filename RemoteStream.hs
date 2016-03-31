{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE ScopedTypeVariables #-}

module RemoteStream where

import Pipes
import Control.Distributed.Process
import Control.Distributed.Process.Serializable
import Data.Binary

newtype SinkPort a r = SinkPort (SendPort (Either r a))
                     deriving (Binary)

newtype SourcePort a r = SourcePort (ReceivePort (Either r a))

connectSink :: forall a r. (Serializable a, Serializable r)
            => SinkPort a r -> Producer a Process r -> Process r
connectSink (SinkPort sp) = go
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

toProducer :: (Serializable a, Serializable r)
           => SourcePort a r -> Producer a Process r
toProducer (SourcePort rp) = go
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
