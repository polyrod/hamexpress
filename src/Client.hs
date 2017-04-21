module Client where
import           Control.Concurrent
import           Control.Concurrent.STM
import           Control.Exception
import           Control.Monad
import           Data.Hash.MD5
import           Data.Map
import           Helpers
import           HETypes
import           Logo
import           Network.Socket            hiding (recv, recvFrom, send, sendTo)
import           Network.Socket.ByteString (recv, send)
import           System.IO


addClient :: TVar Env -> Node -> STM ()
addClient e cn =  do
  e' <- readTVar e
  let m = insert (_nodeId cn) cn (_cm e')
  writeTVar e $ e' { _cm = m }

delClient :: TVar Env -> Node -> STM ()
delClient e cn =  do
  e' <- readTVar e
  let m = delete (_nodeId cn) (_cm e')
  writeTVar e $ e' { _cm = m }

numClient :: TVar Env -> STM Int
numClient e = do
  e' <- readTVar e
  return $ size $ _cm e'

handleClientConnections :: TVar Env -> Socket -> IO ()
handleClientConnections e sock = forever $ do
  conn <- accept sock
  clientNode <- constructClientNode e conn
  case clientNode of
    Just cn -> do
      atomically $ addClient e cn
      forkIO $ clientHandler e cn
      return ()
    _       -> return ()

constructClientNode :: TVar Env -> (Socket , SockAddr) -> IO (Maybe Node)
constructClientNode e (s,sa@(SockAddrInet port host)) = do
  let nodeid = md5s $ Str $ show sa

  hdl <- socketToHandle s ReadWriteMode
  hSetBuffering hdl NoBuffering
  privchan <- newTChanIO

  (gc,mq) <- atomically $ do
    e' <- readTVar e
    return $ ((_ngChan e'),( _ngQueue e'))

  gc' <- atomically $ dupTChan gc


  hPutStr hdl $ "login: "
  inp <- liftM init (hGetLine hdl)
  mbcs <- checkCallsign inp
  return $ case mbcs of
    Just cs -> Just $ ClientNode nodeid cs privchan gc' mq hdl
    _       -> Nothing


clientHandler :: TVar Env -> Node -> IO ()
clientHandler e n = do

  nc <- atomically $ numClient e
  log2stdout $ "New Client " ++ (_callSign n) ++  " connected as " ++ (show $ _nodeId n)
  log2stdout $ "Currently there are " ++ (show nc ) ++ " clients connected to this Node"

  hPutStrLn (_handle n) $ "\n\n\n" ++ logo
  hPutStrLn (_handle n) $ "+------------------------------------------------------------------------------+"
  hPutStrLn (_handle n) $ enclose '+' 80 $ "Hi " ++ _callSign n ++ " you are connected to the hamExpress Network."
  hPutStrLn (_handle n) $ enclose '+' 80 $ "Currently there are " ++ show nc ++ " clients connected to this Node."
  hPutStrLn (_handle n) $ "+------------------------------------------------------------------------------+"

  sys2client <- forkIO $ forever $ do
    outpub <- atomically $ readTChan (_pubChan n)
    hPutStrLn (_handle n) $ displayUsrMsg outpub

  priv2client <- forkIO $ forever $ do
    outpriv <- atomically $ readTChan (_privChan n)
    hPutStrLn (_handle n) $ displayUsrMsg outpriv

  hPutStr (_handle n) $ "\nConnecting you as '" ++ _callSign n ++ "' to dxClusterNode '" ++ dxhostname  ++ ":" ++ dxport ++  "' .... "
  sleep 2

  dxcChan <- newTChanIO
  dxc <- forkIO $ dxCluster e n dxcChan
  hPutStrLn (_handle n) $ "done\n"
  hPutStrLn (_handle n) $ take 6 $ cycle "\n"
  sleep 5

  handle (\(SomeException _) -> return ()) $ forever $ do
    inp <- liftM init (hGetLine $ _handle n)
    atomically $ writeTChan dxcChan inp
    atomically $ writeTQueue (_msgQueue n) (Trace inp)

  atomically $ writeTChan dxcChan "bye"
  killThread dxc
  killThread priv2client
  killThread sys2client

  atomically $ delClient e n

  nc <- atomically $ numClient e
  log2stdout $ "Client " ++ (_callSign n) ++ " " ++ (show $ _nodeId n) ++ " disconnected"
  log2stdout $ "Currently there are " ++ (show nc ) ++ " clients connected to this Node"

  hClose $ _handle n


