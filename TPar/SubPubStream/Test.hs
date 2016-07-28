{-# LANGUAGE ScopedTypeVariables #-}

module TPar.SubPubStream.Test where

import TPar.SubPubStream
import Control.Applicative
import Test.QuickCheck

import Control.Concurrent.STM
import Control.Monad.Trans.State
import Control.Distributed.Process
import Control.Distributed.Process.Node
import Control.Distributed.Process.Serializable
import Network.Transport.InMemory

import Pipes
import qualified Pipes.Prelude as P.P

data TestEvent a r
    = NewSubscriber (Maybe Int) (TestEvent a r) -- how long before terminating
    | Produce a (TestEvent a r)
    | Finish r
    | Throw
    deriving (Show)

instance (Arbitrary a, Arbitrary r) => Arbitrary (TestEvent a r) where
    arbitrary = oneof
        [ Produce <$> arbitrary <*> arbitrary
        , newSub
        , Finish <$> arbitrary
        -- , pure Throw
        ]
      where
        newSub = (\n -> NewSubscriber $ fmap getPositive n) <$> arbitrary <*> arbitrary

atomically' :: MonadIO m => STM a -> m a
atomically' = liftIO . atomically

test :: TestEvent Int () -> Property
test = ioProperty . runLocalProcess . test'

--test :: Property
--test = ioProperty $ runLocalProcess $ test' $ events'

runLocalProcess :: Process a -> IO a
runLocalProcess process = do
    tport <- createTransport
    node <- newLocalNode tport initRemoteTable
    resultVar <- atomically newEmptyTMVar
    runProcess node $ do
        r <- process
        say "runLocalProcess:done"
        atomically' $ putTMVar resultVar r

    atomically $ takeTMVar resultVar

test' :: forall a r. (Show a, Show r, Serializable a, Serializable r)
     => TestEvent a r -> Process Bool
test' events0 = do
    produceChan <- atomically' newTChan
    (pubSubSrc, readRet) <- fromProducer $ produceTChan produceChan >-> traceP
    goodVars <- execStateT (go produceChan pubSubSrc events0) []
    say $ "goodVars:"++show (length goodVars)
    and <$> mapM (atomically' . readTMVar) goodVars
  where
    go :: TChan (Either r a)
       -> SubPubSource a r
       -> TestEvent a r
       -> StateT [TMVar Bool] Process ()
    go produceChan pubSubSrc (NewSubscriber maybeN rest) = do
        goodVar <- atomically' newEmptyTMVar
        Just prod <- lift $ subscribe pubSubSrc
        void $ lift $ spawnLocal $ do
            say "testSubscriber:starting"
            result <- P.P.toListM'
                 $  fmap Right prod
                >-> fmap Left (maybe cat P.P.take maybeN)
            say $ "testSubscriber:got:"++show result
            say $ "testSubscriber:expected:"++show rest
            -- TODO: Actually check this result
            atomically' $ putTMVar goodVar True
        modify (goodVar:)
        go produceChan pubSubSrc rest

    go produceChan pubSubSrc (Produce x rest) = do
        lift $ say "test:produce"
        atomically' $ writeTChan produceChan (Right x)
        go produceChan pubSubSrc rest

    go produceChan pubSubSrc (Finish x) = do
        lift $ say "test:finish"
        atomically' $ writeTChan produceChan (Left x)

    go produceChan pubSubSrc Throw = do
        lift $ say "test:throw"
        atomically' $ writeTChan produceChan (Right undefined)

events' :: TestEvent Int ()
events' = NewSubscriber Nothing $ Finish ()

events :: TestEvent Int ()
events =
      Produce 1
    $ NewSubscriber Nothing
    $ Produce 2
    $ Produce 3
    $ Finish ()

dbg :: MonadIO m => Show a => a -> m ()
dbg = liftIO . print

traceP :: (MonadIO m, Show a) => Pipe a a m r
traceP = P.P.mapM (\x -> dbg x >> return x)
