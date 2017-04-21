module Helpers where
import           Control.Concurrent
import           Control.Concurrent.STM
import           Control.Exception
import           Control.Monad
import qualified Data.ByteString           as B
import qualified Data.ByteString.Char8     as C
import           Data.Hash.MD5
import           Data.Map
import           Data.Maybe
import           HETypes
import           Network.Socket            hiding (recv, recvFrom, send, sendTo)
import           Network.Socket.ByteString (recv, send)
import           System.IO
import           Control.Concurrent.Supervisor
import           Control.Concurrent.Supervisor.Types
import           Control.Retry


displayUsrMsg :: UsrMsg -> String
displayUsrMsg (DXCluster x) = "DXC> " ++ x
displayUsrMsg (Trace x) = "HEC>" ++ x
displayUsrMsg x = "HEC>" ++ show x

cappedFibonacciRetryPolicy :: RetryPolicyM IO
cappedFibonacciRetryPolicy = capDelay (10*1000*1000) fibonacciRetryPolicy

heFork :: QueueLike q => Supervisor0 q -> IO () -> IO ThreadId
heFork sup = forkSupervised sup cappedFibonacciRetryPolicy

checkCallsign :: String -> IO (Maybe CallSign)
checkCallsign s = return $ Just s

log2stdout :: String -> IO ()
log2stdout m = putStrLn m

padto :: Int -> String -> String
padto n l = let p = n - (length l)
             in l ++ (take p $ cycle " ")

enclose :: Char -> Int -> String -> String
enclose b w l  = (padto (w-1) $ [b,' '] ++ l) ++ [b]

dxCluster :: TVar Env -> Node -> TChan String -> IO ()
dxCluster e n c = do
  addrinfos <- getAddrInfo Nothing (Just dxhostname) (Just dxport)
  s <- socket (addrFamily $ head addrinfos) Stream 0
  setSocketOption s KeepAlive 1
  connect s $ addrAddress $ head addrinfos
  sn <- getPeerName s
  log2stdout $ "DXCluster: connected to " ++ (show sn)
  hdl <- socketToHandle s ReadWriteMode
  hSetBuffering hdl NoBuffering
  (gc,mq) <- atomically $ do
      e' <- readTVar e
      return $ ((_ngChan e'),( _ngQueue e'))

  hPutStrLn hdl (_callSign n)

  dxcUp <- forkIO $ handle (\(SomeException _) -> return ()) $ forever $ do
     dxmsg <- atomically $ readTChan c
     hPutStrLn hdl dxmsg


  handle (\(SomeException _) -> return ()) $ forever $ do
    l <- hGetLine hdl
    --log2stdout $ "DXCluster: << : " ++ l
    atomically $ writeTChan (_privChan n) (DXCluster  l)

  killThread dxcUp

  hClose hdl


sleep :: Int -> IO ()
sleep n = threadDelay $ 1000 * 1000 * n
