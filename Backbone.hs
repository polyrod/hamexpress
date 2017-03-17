module Backbone where
import           Control.Concurrent
import           Control.Concurrent.STM
import           Control.Exception
import           Control.Monad
import           Data.Hash.MD5
import           Data.Map
import           Helpers
import           HETypes
import           Logo
import           Network.Socket
import           System.IO

addBB :: TVar Env -> Node -> STM ()
addBB e n =  do
  e' <- readTVar e
  let m = insert (_nodeId n) n (_bbm e')
  writeTVar e $ e' { _bbm = m }

delBB :: TVar Env -> Node -> STM ()
delBB e n =  do
  e' <- readTVar e
  let m = delete (_nodeId n) (_bbm e')
  writeTVar e $ e' { _bbm = m }

numBB :: TVar Env -> STM Int
numBB e = do
  e' <- readTVar e
  return $ size $ _bbm e'

constructBBNode :: TVar Env -> (Socket , SockAddr) -> IO (Maybe Node)
constructBBNode e (s,sa@(SockAddrInet port host)) = do
  let nodeid = md5s $ Str $ show sa --host

  hdl <- socketToHandle s ReadWriteMode
  hSetBuffering hdl NoBuffering


  (bbc,bbq,bbm) <- atomically $ do
    e' <- readTVar e
    return $ (_bbChan e',_bbQueue e',_bbm e')

  case Data.Map.lookup nodeid bbm of
    Just n -> do
      hPutStrLn hdl "Already connected ... bye"
      hClose hdl
      return Nothing
    _ -> do
      tochan <- atomically $ dupTChan bbc
      hPutStrLn hdl nodeid
      -- connect to Kademlia
      return $ Just $ BackboneNode nodeid tochan bbq hdl



handleBBConnections :: TVar Env -> Socket -> IO ()
handleBBConnections e sock = forever $ do
  conn <- accept sock
  bbNode <- constructBBNode e conn
  case bbNode of
    Just cn -> do
      atomically $ addBB e cn
      forkIO $ bbHandler e cn
      return ()
    _       -> return ()


bbHandler :: TVar Env -> Node -> IO ()
bbHandler e n = do

  nbb <- atomically $ numBB e
  log2stdout $ "New Backbone server connected as " ++ (show $ _nodeId n)
  log2stdout $ "Currently there are " ++ (show nbb ) ++ " backbone nodes connected"

  node2bb <- forkIO $ forever $ do
    outpub <- atomically $ readTChan (_toChan n)
    hPutStrLn (_handle n) $ show outpub

  handle (\(SomeException _) -> return ()) $ forever $ do
    inp <- hGetLine $ _handle n
    log2stdout $ "bbHandler: got '" ++ inp ++ "'"
    atomically $ writeTQueue (_fromQueue n) (read inp)

  killThread node2bb

  atomically $ delBB e n

  nbb' <- atomically $ numBB e
  log2stdout $ "Backbone Node " ++ (show $ _nodeId n) ++ " disconnected"
  log2stdout $ "Currently there are " ++ (show nbb' ) ++ " backbone nodes connected"

  hClose $ _handle n


bbUpstreamNodeHandler :: TVar Env -> String -> String -> IO ()
bbUpstreamNodeHandler e strhost strport = do
  addrinfos <- getAddrInfo Nothing (Just strhost ) (Just strport)
  s <- socket (addrFamily $ head addrinfos) Stream 0
  setSocketOption s KeepAlive 1
  connect s $ addrAddress $ head addrinfos
  sn <- getPeerName s
  log2stdout $ "bbUpstreamNodeHandler: connected to " ++ (show sn)
  hdl <- socketToHandle s ReadWriteMode
  hSetBuffering hdl NoBuffering
  (usuq,usdq) <- atomically $ do
      e' <- readTVar e
      return $ ((_usUpQueue e'),( _usDownQueue e'))

  nodeid <- liftM init (hGetLine hdl) -- read upstr nodeId

  let usn = UpstreamNode nodeid usuq usdq hdl

  atomically $ modifyTVar e (\env -> env { _usn = Just (nodeid,usn) } )

  usnUp <- forkIO $ forever $ do
     msg <- atomically $ readTQueue usuq
     hPutStrLn hdl $ show msg


  handle (\(SomeException _) -> return ()) $ forever $ do
    l <- hGetLine hdl
    --log2stdout $ "DXCluster: << : " ++ l
    atomically $ writeTQueue usdq (read l)

  atomically $ modifyTVar e (\env -> env { _usn = Nothing } )

  killThread usnUp

  hClose hdl



