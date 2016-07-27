{-# LANGUAGE ScopedTypeVariables #-}

module TPar.SubPubStream
    ( SubPubSource
    , fromProducer
    , subscribe
      -- * Internal
    , produceTChan
    ) where

import Control.Monad.Catch
import Control.Monad (void)
import qualified Data.Set as S

import TPar.RemoteStream as RStream
import Control.Distributed.Process
import Control.Distributed.Process.Serializable
import Control.Concurrent.STM
import Pipes

data SubPubSource a r = SubPubSource (SendPort (RStream.SinkPort a r, SendPort ()))

-- | A process pushing data from the broadcast channel to a sink.
type PusherProcess = ProcessId

-- | Create a new 'SubPubSource' being asynchronously fed by the given
-- 'Producer'. Exceptions thrown by the 'Producer' will be thrown to
-- subscribers.
fromProducer :: forall a r. (Serializable a, Serializable r)
             => Producer a Process r -> Process (SubPubSource a r)
fromProducer prod0 = do
    chan <- liftIO $ atomically newBroadcastTChan
    (subReqSP, subReqRP) <- newChan
    feeder <- spawnLocal $ feedChan chan prod0
    void $ spawnLocal $ do
        feederRef <- monitor feeder
        subscriptionHandler feederRef subReqRP chan S.empty

    return $ SubPubSource subReqSP
  where
    -- Feed data from Producer into TChan
    feedChan :: TChan (Either r a)
             -> Producer a Process r
             -> Process ()
    feedChan chan = go
      where
        go prod = do
            mx <- handleAll (pure . Left) (fmap Right $ next prod)
            case mx of
              Left exc ->
                  throwM exc

              Right (Left r) -> do
                  say "feedChan:finishing"
                  liftIO $ atomically $ writeTChan chan (Left r)
                  say "feedChan:finished"

              Right (Right (x, prod')) -> do
                  say "feedChan:fed"
                  liftIO $ atomically $ writeTChan chan (Right x)
                  go prod'

    -- Accept requests for subscriptions
    subscriptionHandler :: MonitorRef  -- ^ on the feeder
                        -> ReceivePort (SinkPort a r, SendPort ())
                        -> TChan (Either r a)
                        -> S.Set PusherProcess
                        -> Process ()
                           -- ^ returns the set of 'PusherProcess's that we need
                           -- to ensure get cleaned up
    subscriptionHandler feederRef subReqRP chan pushers = do
        say "subscriptionFrom:preMatch"
        receiveWait
            [ matchIf (\(ProcessMonitorNotification mref _ _) -> mref == feederRef)
              $ \(ProcessMonitorNotification _ pid reason) -> do
                  case reason of
                    DiedNormal -> do
                        -- Source Producer has returned peacefully: stop
                        -- accepting subscriptions and wait for pushers since
                        -- they are linked to us
                        say ("pushers:"++show pushers)
                        waitForProcesses pushers
                        say "subHandler:dying"
                    _ -> throwM $ SubPubProducerFailed pid reason

            , matchChan subReqRP $ \(sink, confirmSP) -> do
                  say "subscriptionFrom:postMatch"
                  -- A subscription request
                  pid <- getSelfPid
                  say $ "subscriptionFrom:"++show sink
                  pusher <- spawnLocal $ do
                      link pid
                      say $ "pusher:serving:"++show sink
                      myChan <- liftIO $ atomically $ dupTChan chan
                      sendChan confirmSP ()
                      void $ connectSink sink (produceTChan myChan)
                      say "pusher:done"
                  subscriptionHandler feederRef subReqRP chan (S.insert pusher pushers)
            ]

-- | An exception indicating that the upstream 'Producer' feeding a
-- 'SubPubSource' failed.
data SubPubProducerFailed = SubPubProducerFailed ProcessId DiedReason
                          deriving (Show)
instance Exception SubPubProducerFailed

waitForProcesses :: S.Set ProcessId -> Process ()
waitForProcesses procs0 = mapM_ monitor procs0 >> go procs0
  where
    go procs
      | S.null procs = return ()
      | otherwise = do
        say $ "waitForProcesses:"++show procs
        ProcessMonitorNotification _ pid _ <- expect
        say $ "waitForProcesses:died:"++show pid
        go (S.delete pid procs)

produceTChan :: TChan (Either r a) -> Producer a Process r
produceTChan chan = go
  where
    go = do
        lift $ say "produceTChan:waiting"
        mx <- liftIO $ atomically $ readTChan chan
        case mx of
          Right x -> lift (say "produceTChan:fed") >> yield x >> go
          Left r  -> lift (say "produceTChan:done") >> return r

-- | Subscribe to a 'SubPubSource'. Exceptions thrown by the 'Producer' feeding
-- the 'SubPubSource' will be thrown by the returned 'Producer'. Will return
-- 'Nothing' if the 'SubPubSource' terminated before we were able to subscribe.
subscribe :: forall a r. (Serializable a, Serializable r)
          => SubPubSource a r -> Process (Maybe (Producer a Process r))
subscribe (SubPubSource reqSP) = do
    say "subscribing"
    (sink, src) <- RStream.newStream

    -- We provide a channel to confirm that we have actually been subscribed
    -- so that we can safely link during negotiation.
    mref <- monitorPort reqSP
    (confirmSp, confirmRp) <- newChan
    sendChan reqSP (sink, confirmSp)
    say "subscribe: waiting for confirmation"
    receiveWait
        [ matchChan confirmRp $ \() -> return $ Just $ RStream.toProducer src
        , matchIf (\(PortMonitorNotification mref' _ _) -> mref == mref') (pure $ pure Nothing)
        ]
