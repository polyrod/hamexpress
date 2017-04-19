{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE ScopedTypeVariables #-}
module Main where
import           Backbone
import           Client
import           Control.Concurrent
import           Control.Concurrent.STM
import           Control.Concurrent.Supervisor
import           Control.Exception
import           Control.Monad
import           Data.Hash.MD5
import           Data.Map                      (empty)
import           Helpers
import           HETypes
import           Network.Socket                hiding (recv, recvFrom, send,
                                                sendTo)
import           Network.Socket.ByteString     (recv, send)
import           System.IO
import           System.Random

import           Logo

import           Data.Maybe                    (fromJust, isJust)
import           Safe
import           System.Console.GetOpt
import           System.Environment

import           Network.Info

import           DHT
data Flag = Verbose  | Version | Debugging | Root
          | Upstream String | UpstreamPort String | LocalPort String | IFace String

            deriving (Show,Eq)

options :: [OptDescr Flag]
options =
  [ Option ['v']     ["verbose"]            (NoArg Verbose)               "chatty output"
  , Option ['d']     ["debug"]              (NoArg Debugging)             "debugging"
  , Option ['R']     ["Root"]               (NoArg Root)                  "this node will be the RootNode"
  , Option ['V','?'] ["version"]            (NoArg Version)               "show version number"
  , Option ['U']     ["UpstreamServer"]     (ReqArg Upstream "SERVER")    "upstream SERVER"
  , Option ['P']     ["UPort"]              (ReqArg UpstreamPort  "PORT") "upstream PORT"
  , Option ['L']     ["LPort"]              (ReqArg LocalPort  "PORT")    "local PORT"
  , Option ['i']     ["iface"]              (ReqArg IFace "INTERFACE")  "interface to use"
  ]

compilerOpts :: [String] -> IO ([Flag], [String])
compilerOpts argv =
  case getOpt Permute options argv of
      (o,n,[]  ) -> return (o,n)
      (_,_,errs) -> ioError (userError (concat errs ++ usageInfo header options))
  where header = "Usage: hamexpress [OPTION...] files..."

main :: IO ()
main = do



  -- parse cmdline args
  argv <- getArgs
  (flags,str) <- compilerOpts argv
  log2stdout $ "Flags  : " ++ (show flags)
  log2stdout $ "String : " ++ (show str)


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
    forkSupervised sup fibonacciRetryPolicy $ bbUpstreamNodeHandler e s p
    return ()



  -- start msg router thread
  forkSupervised sup fibonacciRetryPolicy $ router e (isJust root)

  -- start backbone handler
  forkSupervised sup fibonacciRetryPolicy $ handleBBConnections e backboneSocket

  -- start backbone handler
  forkSupervised sup fibonacciRetryPolicy $ self_announcer e

  -- handle telnet clients
  forkSupervised sup fibonacciRetryPolicy $ handleClientConnections e listenSocket

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
    let msg = Trace $ "This is : " ++ sid
    writeTChan (_ngChan e) msg
    writeTChan (_bbChan e) msg


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

{-
bb2sys_router :: TVar Env -> IO ()
bb2sys_router e = forever $ do
  e <- atomically $ readTVar e
  msg <- atomically $ readTQueue (_bbQueue e)
  atomically $ writeTQueue (_ngChan e) msg

sys2_bb_ng_router :: TVar Env -> IO ()
sys2_bb_ng_router e = forever $ do
  e <- atomically $ readTVar e
  msg <- atomically $ readTQueue (_ngQueue e)
  atomically $ writeTChan (_bbChan e) msg
  atomically $ writeTChan (_ngChan e) msg

-}
