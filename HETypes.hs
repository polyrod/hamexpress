module HETypes where
import           Control.Concurrent
import           Control.Concurrent.STM
import           Control.Exception
import           Control.Monad
import           Data.Hash.MD5
import           Data.Map
import           Network.Socket
import           System.IO


import           Control.Arrow          (first)
import qualified Data.ByteString        as B
import qualified Data.ByteString.Char8  as C
import qualified Network.Kademlia       as K

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
               , _kademlia    :: Maybe (K.KademliaInstance KademliaID Ham)
               , _selfKadNode :: Maybe (K.Node KademliaID)
               , _selfKadPort :: Int
               }
               deriving Show

instance Show (K.KademliaInstance a i) where
  show _ = "KademliaInstance"

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



-- The type this example will use as value
data Ham = Ham { _callsign :: String
               , _qth      :: String
               , _loc      :: String
              }

         | List [String]
              deriving (Show,Read,Eq)

instance K.Serialize Ham where
   toBS = C.pack . show
   fromBS bs =
       case (reads :: ReadS Ham) . C.unpack $ bs of
           []               -> Left "Failed to parse Ham."
           (result, rest):_ -> Right (result, C.pack rest)

-- The type this example will use as key for the lookups
newtype KademliaID = KademliaID B.ByteString
                    deriving (Ord,Show,Read,Eq)

instance K.Serialize KademliaID where
   toBS (KademliaID bs)
       | B.length bs >= 32 = B.take 32 bs
       | otherwise         = error "KademliaID to short!"

   fromBS bs
       | B.length bs >= 32 = Right . first KademliaID . B.splitAt 32 $ bs
       | otherwise         = Left "ByteString too short!"

toKadID :: String -> KademliaID
toKadID = KademliaID . C.pack
