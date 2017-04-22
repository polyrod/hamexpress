{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE ScopedTypeVariables #-}
module Main where
import           Control.Concurrent
import           Control.Concurrent.STM
import           Control.Concurrent.Supervisor
import           Control.Exception
import           Control.Monad
import           Data.Hash.MD5
import           Data.Map                      (empty)
import           Data.Maybe                    (fromJust, isJust)
import           Network.Info
import           Network.Socket                hiding (recv, recvFrom, send,
                                                sendTo)
import           Network.Socket.ByteString     (recv, send)
import           Safe

import           System.IO
import           System.Random
import           System.Posix.IO
import           System.Posix.Process
import           System.Console.GetOpt
import           System.Environment


import           Backbone
import           Client
import           DHT
import           Helpers
import           HETypes
import           Logo


data Flag = Verbose  | Foreground | Debugging | Root | Help
          | Upstream String | UpstreamPort String | LocalPort String | DhtPort String | IFace String

            deriving (Show,Eq)

options :: [OptDescr Flag]
options =
  [ Option ['h']     ["help"]               (NoArg Help)                      "this help"
  , Option ['i']     ["interface"]          (ReqArg IFace "<interface>")      "interface to use"
  , Option ['u']     ["upstream-server"]    (ReqArg Upstream "<server-ip>")   "upstream server (ip-only)"
  , Option ['p']     ["upstream-port"]      (ReqArg UpstreamPort  "<port>")   "upstream port"
  , Option ['l']     ["local-port-base"]    (ReqArg LocalPort  "<port>")      "local portbase"
  , Option ['d']     ["local-dht-port"]     (ReqArg DhtPort  "<port>")        "local dht port"
  , Option ['f']     ["forground"]          (NoArg Foreground)                "Dont deamonize; Stay in forground"
  , Option ['v']     ["verbose"]            (NoArg Verbose)                   "be verbose"
  , Option ['d']     ["debug"]              (NoArg Debugging)                 "debugging"
  , Option ['r']     ["root"]               (NoArg Root)                      "this node will be the RootNode (use only to spawn new network) "
  ]



header = "Usage: hamexpress [OPTION...]"

heOpts :: [String] -> IO ([Flag], [String])
heOpts argv =
  case getOpt Permute options argv of
      (o,n,[]  ) -> return (o,n)
      (_,_,errs) -> ioError (userError (concat errs ++ usageInfo header options))


spawnFn :: (t -> IO ()) -> t -> IO ()
spawnFn fn arg = do 
  forkProcess $ do
    mapM_ closeFd [stdInput, stdOutput, stdError]
    nullFd <- openFd "/dev/null" ReadWrite Nothing defaultFileFlags
    mapM_ (dupTo nullFd) [stdInput, stdOutput, stdError]
    closeFd nullFd
    fn arg
  return ()

main :: IO ()
main = do
  
  -- parse cmdline args
  argv <- getArgs
  (flags,str) <- heOpts argv
  let debug = isJust $ headMay $ filter (== Root) flags
  let foreground = isJust $ headMay $ filter (== Foreground) flags

  if not foreground
    then do
      putStrLn "daemonizing now ... bye"
      spawnFn server flags 
    else server flags

  when debug $ log2stdout $ "Flags  : " ++ (show flags)
  when debug $ log2stdout $ "String : " ++ (show str)

  when( isJust $ headMay $ filter (== Help) flags) $ ioError (userError (usageInfo header options))


server :: [Flag] -> IO ()
server flags = do

  supSpec <- newSupervisorSpec OneForOne
  sup <- newSupervisor supSpec

  -- is rootflag given
  let root = headMay $ filter (== Root) flags

  -- iface
  let iface = headMay $ filter (\case
                                   (IFace x)      -> True
                                   _              -> False) flags
  -- localport
  let lport = headMay $ filter (\case
                                   (LocalPort x) -> True
                                   _              -> False) flags



  lip <- if isJust iface
            then do
              ifl <- getNetworkInterfaces
              let (IFace ifname) = fromJust iface
              let ni = headMay $ filter (\ife ->  name ife == ifname) ifl

              if isJust ni
                 then do
                    let (IPv4 x) = ipv4 $ fromJust ni

                    return x

                 else return iNADDR_ANY
            else return iNADDR_ANY


  -- construct SockAddr for listen sockets
  (ca,sa) <- if isJust lport
             then do
              let (LocalPort lp) = fromJust lport
              let d = 73-55
              return ((SockAddrInet ((read lp) - d) lip)
                     ,(SockAddrInet (read lp) lip))
             else return ((SockAddrInet 7355 lip)
                         ,(SockAddrInet 7373 lip))



  -- listen socket for telnet clients
  listenSocket <- socket AF_INET Stream 0
  setSocketOption listenSocket ReuseAddr 1
  bind listenSocket ca
  listen listenSocket 10

  -- listen socket for backbone servers
  backboneSocket <- socket AF_INET Stream 0
  setSocketOption backboneSocket ReuseAddr 1
  bind backboneSocket sa
  listen backboneSocket 10

  -- construct initial Environment
  env <- if (isJust root)
         then createEnv True
         else createEnv False


{- TODO
  let dht = if isroot
               then DHT.new (Peer (_n
               else Nothing
-}
  e <- newTVarIO env

  -- Check if to connect to UpStrem Server/Port
  let usserv = headMay $ filter (\case
                                    (Upstream x) -> True
                                    _            -> False) flags

  let usport = headMay $ filter (\case
                                    (UpstreamPort x) -> True
                                    _                -> False) flags

  when (isJust usserv  &&  isJust usport && (not $ isJust root)) $  do
    log2stdout "Connecting UpStremServer ...."
    let (Upstream s) = fromJust usserv
    let (UpstreamPort p) = fromJust usport
    heFork sup $ bbUpstreamNodeHandler e s p
    return ()



  -- start msg router thread
  heFork sup $ router e (isJust root)

  -- start backbone handler
  heFork sup $ handleBBConnections e backboneSocket

  -- start backbone handler
  heFork sup $ self_announcer e

  -- handle telnet clients
  heFork sup $ handleClientConnections e listenSocket

  go (eventStream sup)

  where
    go eS = do
      newE <- atomically $ readTQueue eS
      log2stdout $ show newE
      go eS


-- Construct Environment with this nodes shared data
createEnv :: Bool -> IO Env
createEnv isroot = do


  let cm = empty
  let bbm = empty

  ngq <- newTQueueIO
  ngc <- newTChanIO
  bbq <- newTQueueIO
  bbc <- newTChanIO
  usuq <- newTQueueIO
  usdq <- newTQueueIO

  (r:: Integer) <- randomIO

  let nodeid = if isroot
               then Just $ md5s $ Str $ "aLLyOURbASEaREbELONGtOuS" ++ show r
               else Nothing


  return $ Env ngq ngc bbq bbc cm bbm Nothing usuq usdq nodeid Nothing

self_announcer :: TVar Env -> IO ()
self_announcer env = forever $ do
  threadDelay $ 60 * 1000 * 1000
  e <- atomically $ readTVar env
  atomically $ do
    let sid = fromJust (_selfid e)
    let msg = Trace $ "node " ++ sid ++ " active"
    writeTChan (_bbChan e) msg
    when (not $ isJust $ _usn e) $ writeTChan (_ngChan e) msg
    when (isJust $ _usn e) $ writeTQueue (_usUpQueue e) msg


-- Message Router thread dispatches msgs
router :: TVar Env -> Bool -> IO ()
router env isroot = do
  e <- atomically $ readTVar env
  if isroot
  then do
    -- sys2bb_and_ng
    forkIO $ forever $ do
      msg <- atomically $ readTQueue (_ngQueue e)
      log2stdout $ "router(sys2bb_and_ng)(root): reading '" ++ show msg ++  "' from ngQueue writing to bbChan,ngChan"
      atomically $ writeTChan (_bbChan e) msg
      atomically $ writeTChan (_ngChan e) msg

    -- bb2bb_and_ng
    forkIO $ forever $ do
      msg <- atomically $ readTQueue (_bbQueue e)
      log2stdout $ "router(bb2bb_and_ng)(root): reading '" ++ show msg ++  "' from bbQueue writing to bbChan,ngChan"
      atomically $ writeTChan (_bbChan e) msg
      atomically $ writeTChan (_ngChan e) msg

  else do
    -- bb2us
    forkIO $ forever $ do
      msg <- atomically $ readTQueue (_bbQueue e)
      log2stdout $ "router(bb2us)(!root): reading '" ++ show msg ++  "' from bbQueue writing to usUpQueue"
      atomically $ writeTQueue (_usUpQueue e) msg

    -- sys2us
    forkIO $ forever $ do
      msg <- atomically $ readTQueue (_ngQueue e)
      log2stdout $ "router(sys2us)(!root): reading '" ++ show msg ++  "' from ngQueue writing to usUpQueue"
      atomically $ writeTQueue (_usUpQueue e) msg

    -- us2sys_and_bb
    forkIO $ forever $ do
      msg <- atomically $ readTQueue (_usDownQueue e)
      log2stdout $ "router(us2sys_and_bb)(!root): reading '" ++ show msg ++  "' from usDownQueue writing to ngChan,bbChan"
      atomically $ writeTChan  (_ngChan e) msg
      atomically $ writeTChan  (_bbChan e) msg

  return ()

