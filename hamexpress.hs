{-# LANGUAGE BangPatterns        #-}
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
import           Network.Socket
import           System.IO
import           System.Random

import           Logo

import           Data.Maybe                    (fromJust, isJust)
import           Safe
import           System.Console.GetOpt
import           System.Environment

import qualified Data.ByteString               as B
import qualified Data.ByteString.Char8         as C
import qualified Network.Kademlia              as K

import           Network.Info

data Flag = Verbose  | Version | Debugging | Root
          | Upstream String | UpstreamPort String | LocalPort String | LocalKPort String | Tracker | IFace String

            deriving Show

options :: [OptDescr Flag]
options =
  [ Option ['v']     ["verbose"]            (NoArg Verbose)               "chatty output"
  , Option ['d']     ["debug"]              (NoArg Debugging)             "debugging"
  , Option ['R']     ["Root"]               (NoArg Root)                  "this node will be the RootNode"
  , Option ['V','?'] ["version"]            (NoArg Version)               "show version number"
  , Option ['U']     ["UpstreamServer"]     (ReqArg Upstream "SERVER")    "upstream SERVER"
  , Option ['P']     ["UPort"]              (ReqArg UpstreamPort  "PORT") "upstream PORT"
  , Option ['L']     ["LPort"]              (ReqArg LocalPort  "PORT")    "local PORT"
  , Option ['K']     ["KPort"]              (ReqArg LocalKPort  "PORT")   "local Kademlia PORT"
  , Option ['T']     ["Tracker"]            (NoArg Tracker)               "node should start Tracker service"
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
  let root = headMay $ filter (\case
                                   (Root)         -> True
                                   _              -> False) flags

  -- is trackerflag given
  let tracker = headMay $ filter (\case
                                   (Tracker)         -> True
                                   _                 -> False) flags


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

  -- local Kademlia P2P Port
  let kport = headMay $ filter (\case
                                   (LocalKPort x) -> True
                                   _              -> False) flags

  -- Update Env with givien local Kademlia Port
  when(isJust kport) $ do
    let (LocalKPort p) = fromJust kport
    atomically $ modifyTVar e (\env-> env { _selfKadPort = read p })



  -- if this is the Network Rootnode bootstrap Kademlia P2P Network
  when(isJust root) $ do
    myaddr <- getSocketName backboneSocket
    (hn,_) <- getNameInfo [NI_NUMERICHOST] True False myaddr
    e' <- atomically $ readTVar e
    if isJust hn && isJust (_selfid e')
    then do
      let firstNode = K.Node (K.Peer (fromJust hn) ( toEnum $ _selfKadPort e')) . toKadID . fromJust $ _selfid e'
      firstInstance <- K.create ( _selfKadPort e') . toKadID . fromJust $ _selfid e'
      atomically $ modifyTVar e (\env -> env { _kademlia = Just firstInstance , _selfKadNode = Just firstNode })
      kadAddPeer e (fromJust $ _selfid e')
    else log2stdout $ "Kademlia: couldnt resolve local address :( not connecting"

  -- if this is a tracker start tracker service
  -- Kademlia inverse HAsh index generation
  when(isJust tracker) $ do
    forkIO $ kademliaIndexer e 20
    return ()

  -- start msg router thread
  forkIO $ router e (isJust root)

  -- start backbone handler
  forkIO $ handleBBConnections e backboneSocket

  -- start backbone handler
  forkIO $ self_announcer e

  -- handle telnet clients
  forkIO $ handleClientConnections e listenSocket

  forkSupervised sup fibonacciRetryPolicy $ peer_dumper e

  go (eventStream sup)

  where
    go eS = do
      newE <- atomically $ readTQueue eS
      log2stdout $ show newE
      go eS


-- TODO:
kademliaIndexer :: TVar Env -> Int ->IO ()
kademliaIndexer e i = do
    e' <- atomically $ readTVar e
    let (kad,sid) = (_selfKadNode e', _selfid e')
    let l = [1..i]

    log2stdout $ "Indexer started " ++ show kad ++  "  " ++ show sid

    !idxs <- if isJust kad && isJust sid
       then do
         log2stdout $ "Bää"
         mapM (\i -> do
                    threadDelay $ 5 * 1000 * 1000
                    forkIO $ do
                              launchTracker (fromJust sid) (fromJust kad) i
                              return ()
              ) l
       else do
         log2stdout $ "Bii"
         return []

    log2stdout $ show idxs

    if null idxs
       then do
         log2stdout $ "Bee"
         threadDelay $ 2 * 1000 * 1000
         kademliaIndexer e i

       else forever $ do
         log2stdout $ "Boo"
         threadDelay $ 2 * 1000 * 1000
 where
   launchTracker sid !kad n = do
     let p = 10000+(10*n)
     let myid = md5s $ Str $ sid ++ show p


     (inst :: K.KademliaInstance KademliaID Ham) <- K.create p $  toKadID  myid
     log2stdout $ show kad
     jr <- K.joinNetwork inst kad
     case jr of
       K.JoinSucces -> log2stdout $ "Created Tracker instance : " ++ myid ++ " @ " ++ show p ++ " " ++  show jr
       _ -> log2stdout $ "Creating Tracker instance failed for : " ++ (show $ toKadID myid) ++ " @ " ++ show p ++ " " ++ show jr

     log2stdout $ "Buuu"
     return inst



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

  return $ Env ngq ngc bbq bbc cm bbm Nothing usuq usdq nodeid Nothing Nothing 5555

peer_dumper :: TVar Env -> IO ()
peer_dumper env = forever $ do
  threadDelay $ 10 * 1000 * 1000
  e <- atomically $ readTVar env
  let key = KademliaID $ C.pack $  md5s $ Str $ "peers"
  if isJust (_kademlia e)
  then do
    mres <- K.lookup (fromJust $ _kademlia e) key
    case mres of
      Nothing    -> return ()
      Just (h,_) -> log2stdout $ show h
  else
    log2stdout "KademliaDumper: not connected"


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
