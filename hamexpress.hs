{-# LANGUAGE LambdaCase #-}
module Main where
import           Backbone
import           Client
import           Control.Concurrent
import           Control.Concurrent.STM
import           Control.Exception
import           Control.Monad
import           Data.Hash.MD5
import           Data.Map               (empty)
import           Helpers
import           HETypes
import           Network.Socket
import           System.IO

import           Logo

import           Data.Maybe             (fromJust, isJust)
import           Safe
import           System.Console.GetOpt
import           System.Environment

data Flag = Verbose  | Version | Debugging | Root
          | Upstream String | UpstreamPort String | LocalPort String
            deriving Show

options :: [OptDescr Flag]
options =
  [ Option ['v']     ["verbose"]            (NoArg Verbose)               "chatty output"
  , Option ['d']     ["debug"]              (NoArg Debugging)             "debugging"
  , Option ['R']     ["Root"]               (NoArg Root)                  "this node will be the RootNode"
  , Option ['V','?'] ["version"]            (NoArg Version)               "show version number"
  , Option ['U']     ["UpstreamServer"]     (ReqArg Upstream "SERVER")    "upstream SERVER"
  , Option ['P']     ["Port"]               (ReqArg UpstreamPort  "PORT") "upstream PORT"
  , Option ['L']     ["Port"]               (ReqArg LocalPort  "PORT")    "local PORT"
  ]

compilerOpts :: [String] -> IO ([Flag], [String])
compilerOpts argv =
  case getOpt Permute options argv of
      (o,n,[]  ) -> return (o,n)
      (_,_,errs) -> ioError (userError (concat errs ++ usageInfo header options))
  where header = "Usage: hamexpress [OPTION...] files..."

main :: IO ()
main = do

  argv <- getArgs
  (flags,str) <- compilerOpts argv
  log2stdout $ "Flags  : " ++ (show flags)
  log2stdout $ "String : " ++ (show str)


  let root = headMay $ filter (\case
                                   (Root)         -> True
                                   _              -> False) flags

  let lport = headMay $ filter (\case
                                   (LocalPort x) -> True
                                   _              -> False) flags
  (ca,sa) <- if isJust lport
             then do
              let (LocalPort lp) = fromJust lport
              let d = 73-55
              return ((SockAddrInet ((read lp) - d) iNADDR_ANY)
                     ,(SockAddrInet (read lp) iNADDR_ANY))
             else return ((SockAddrInet 7355 iNADDR_ANY)
                         ,(SockAddrInet 7373 iNADDR_ANY))


  listenSocket <- socket AF_INET Stream 0
  setSocketOption listenSocket ReuseAddr 1
  bind listenSocket ca
  listen listenSocket 10

  backboneSocket <- socket AF_INET Stream 0
  setSocketOption backboneSocket ReuseAddr 1
  bind backboneSocket sa
  listen backboneSocket 10

  env <- if (isJust root)
         then createEnv True
         else createEnv False

  e <- newTVarIO env

  let usserv = headMay $ filter (\case
                                    (Upstream x) -> True
                                    _            -> False) flags

  let usport = headMay $ filter (\case
                                    (UpstreamPort x) -> True
                                    _                -> False) flags

  when (isJust usserv  &&  isJust usport) $  do
    log2stdout "Connecting UpStremServer ...."
    let (Upstream s) = fromJust usserv
    let (UpstreamPort p) = fromJust usport
    forkIO $ bbUpstreamNodeHandler e s p
    return ()

  forkIO $ router e (isJust root)
  forkIO $ handleBBConnections e backboneSocket
  handleClientConnections e listenSocket


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


  let nodeid = if isroot
               then Just $ md5s $ Str $ "aLLyOURbASEaREbELONGtOuS"
               else Nothing

  return $ Env ngq ngc bbq bbc cm bbm Nothing usuq usdq nodeid


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
