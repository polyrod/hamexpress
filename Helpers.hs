module Helpers where
import           Control.Concurrent
import           Control.Concurrent.STM
import           Control.Exception
import           Control.Monad
import qualified Data.ByteString        as B
import qualified Data.ByteString.Char8  as C
import           Data.Hash.MD5
import           Data.Map
import           Data.Maybe
import           HETypes
import qualified Network.Kademlia       as K
import           Network.Socket
import           System.IO


kadAddPeer ::TVar Env -> String -> IO ()
kadAddPeer env p = do
  e <- atomically $ readTVar env
  let key = KademliaID $ C.pack $ md5s $ Str $ "peers"

  if (isJust $ _kademlia e)
     then do
        ml <- K.lookup (fromJust $ _kademlia e) key
        if isJust ml
           then do
             let ((List l),_) = fromJust ml

             K.store (fromJust $ _kademlia e) key (List $ l ++ [p])
             return ()

           else do
             K.store (fromJust $ _kademlia e) key (List [p])
             return ()
     else log2stdout "kadAddPeer: not connected"

kadDelPeer ::TVar Env -> String -> IO ()
kadDelPeer env p = do
  e <- atomically $ readTVar env
  let key = KademliaID $ C.pack $ md5s $ Str $ "peers"

  if (isJust $ _kademlia e)
     then do
        ml <- K.lookup (fromJust $ _kademlia e) key
        if isJust ml
           then do
             let ((List l),_) = fromJust ml

             K.store (fromJust $ _kademlia e) key (List $ Prelude.filter (/= p) l )

           else return ()

     else log2stdout "kadAddPeer: not connected"



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

  dxcUp <- forkIO $ forever $ do
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
