module Util ( hGetBinary, hPutBinary
            , toHandleBinary, fromHandleBinary
            , tryIO'
            ) where

import Data.Word
import Control.Error
import Control.Monad (when, forever)
import Control.Monad.IO.Class
import Data.Binary
import Data.Binary.Get
import Data.Binary.Put
import qualified Data.ByteString.Lazy as LBS
import System.IO (Handle)
import Pipes

magicNumber :: Word32
magicNumber = 0xdeadbeef

runGetError :: Monad m => Get a -> LBS.ByteString -> ExceptT String m a
runGetError get bs = fmapRT third $ fmapLT third $ hoistEither $ runGetOrFail get bs
  where third (_,_,a) = a

describe :: Monad m => String -> ExceptT String m a -> ExceptT String m a
describe e = fmapLT ((e++": ")++)

tryIO' :: IO a -> ExceptT String IO a
tryIO' = fmapLT show . tryIO

hGetBinary :: Binary a => Handle -> ExceptT String IO a
hGetBinary h = do
    n <- describe "getting header" $ tryIO' $ LBS.hGet h 8
    len <- describe "parsing header" $ flip runGetError n $ do
        magic <- getWord32le
        when (magic /= magicNumber) $ fail "Invalid magic number"
        getWord32le
    body <- describe "getting body" $ tryIO' $ LBS.hGet h (fromIntegral len)
    describe "parsing body" $ runGetError get body

hPutBinary :: Binary a => Handle -> a -> IO ()
hPutBinary h a = do
    let bs = runPut (put a)
    LBS.hPut h $ runPut $ do
        putWord32le magicNumber
        putWord32le $ fromIntegral $ LBS.length bs
    LBS.hPut h bs

toHandleBinary :: Binary a => Handle -> Consumer a IO ()
toHandleBinary h =
    forever $ await >>= liftIO . hPutBinary h

fromHandleBinary :: Binary a => Handle -> Producer (Either String a) IO ()
fromHandleBinary h =
    forever $ liftIO (runExceptT $ hGetBinary h) >>= yield
