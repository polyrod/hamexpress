{-# LANGUAGE FlexibleInstances #-}
module HETypes where
import           Control.Concurrent
import           Control.Concurrent.STM
import           Control.Exception
import           Control.Monad
import           Data.Hash.MD5
import           Data.Map
import           Network.Socket            hiding (recv, recvFrom, send, sendTo)
import           Network.Socket.ByteString (recv, send)
import           System.IO

import           DHT



dxhostname = "dd5xx.incq.com"
dxport = "4000"

type NodeId = String
type CallSign = String

data UsrMsg = Msg CallSign CallSign String
            | Trace String   -- DEBUG
            | DXCluster String   -- DEBUG
            deriving (Show,Read)

data Env = Env { _ngQueue     :: TQueue UsrMsg
               , _ngChan      :: TChan UsrMsg
               , _bbQueue     :: TQueue UsrMsg
               , _bbChan      :: TChan UsrMsg
               , _cm          :: Map NodeId Node
               , _bbm         :: Map NodeId Node
               , _usn         :: Maybe (NodeId,Node)
               , _usUpQueue   :: TQueue UsrMsg
               , _usDownQueue :: TQueue UsrMsg
               , _selfid      :: Maybe NodeId
               , _dhtinst     :: Maybe (Instance NodeId (DHTdata String))
               }
               deriving Show

data DHTdata i = Counter Integer
               | Value i
               | List [DHTdata i]
               deriving (Show,Read)

instance Show (Instance NodeId (DHTdata a)) where
  show _ = "DHTinst"

instance Show (TChan a) where
  show _ = "TChan"

instance Show (TQueue a) where
  show _ = "TQueue"

data Node = BackboneNode  { _nodeId   :: NodeId
                         , _toChan    :: TChan UsrMsg
                         , _fromQueue :: TQueue UsrMsg
                         , _handle    :: Handle
                         }
          | UpstreamNode { _nodeId    :: NodeId
                         , _upQueue   :: TQueue UsrMsg
                         , _downQueue :: TQueue UsrMsg
                         , _handle    :: Handle
                         }
          | ClientNode   { _nodeId   :: NodeId
                         , _callSign :: CallSign
                         , _privChan :: TChan UsrMsg
                         , _pubChan  :: TChan UsrMsg
                         , _msgQueue :: TQueue UsrMsg
                         , _handle   :: Handle
                         }
                         deriving Show

