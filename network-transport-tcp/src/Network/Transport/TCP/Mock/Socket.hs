{-# LANGUAGE EmptyDataDecls #-}
module Network.Transport.TCP.Mock.Socket
  ( -- * Types
    HostName
  , ServiceName
  , Socket
  , SocketType(..)
  , SocketOption(..)
  , AddrInfo(..)
  , Family
  , SockAddr
  , ProtocolNumber
  , ShutdownCmd(..)
    -- * Functions
  , getAddrInfo
  , socket
  , bindSocket
  , listen
  , setSocketOption
  , accept
  , sClose
  , connect
  , shutdown
    -- * Constants
  , defaultHints
  , defaultProtocol
  , sOMAXCONN
    -- * Internal API
  , writeSocket
  , readSocket
  , Message(..)
  ) where

import Data.Word (Word8)
import Data.Map (Map)
import qualified Data.Map as Map
import Control.Exception (throwIO)
import Control.Category ((>>>))
import Control.Concurrent.MVar 
import Control.Concurrent.Chan
import System.IO.Unsafe (unsafePerformIO)
import Data.Accessor (Accessor, accessor, (^=), (^.))
import qualified Data.Accessor.Container as DAC (mapMaybe)
import System.Timeout (timeout)

--------------------------------------------------------------------------------
-- Mock state                                                                 --
--------------------------------------------------------------------------------

data MockState = MockState {
    _boundSockets   :: !(Map SockAddr Socket)
  , _nextSocketId   :: !Int
  , _validHostnames ::  [HostName]
  }

initialMockState :: MockState
initialMockState = MockState {
    _boundSockets   = Map.empty
  , _nextSocketId   = 0
  , _validHostnames = ["localhost", "127.0.0.1"]
  }

mockState :: MVar MockState
{-# NOINLINE mockState #-}
mockState = unsafePerformIO $ newMVar initialMockState

get :: Accessor MockState a -> IO a
get acc = timeoutThrow mvarThreshold $ withMVar mockState $ return . (^. acc)

set :: Accessor MockState a -> a -> IO ()
set acc val = timeoutThrow mvarThreshold $ modifyMVar_ mockState $ return . (acc ^= val) 

boundSockets :: Accessor MockState (Map SockAddr Socket)
boundSockets = accessor _boundSockets (\bs st -> st { _boundSockets = bs })

boundSocketAt :: SockAddr -> Accessor MockState (Maybe Socket)
boundSocketAt addr = boundSockets >>> DAC.mapMaybe addr

nextSocketId :: Accessor MockState Int
nextSocketId = accessor _nextSocketId (\sid st -> st { _nextSocketId = sid })

validHostnames :: Accessor MockState [HostName]
validHostnames = accessor _validHostnames (\ns st -> st { _validHostnames = ns })

--------------------------------------------------------------------------------
-- The public API (mirroring Network.Socket)                                  --
--------------------------------------------------------------------------------

type HostName    = String
type ServiceName = String
type PortNumber  = String 
type HostAddress = String 

data SocketType   = Stream 
data SocketOption = ReuseAddr
data ShutdownCmd  = ShutdownSend

data Family
data ProtocolNumber

data Socket = Socket { 
    socketState       :: MVar SocketState
  , socketDescription :: String
  }

data SocketState = 
    Uninit
  | BoundSocket { socketBacklog :: Chan (Socket, SockAddr, MVar Socket) }
  | Connected { socketPeer :: Maybe Socket, socketBuff :: Chan Message }
  | Closed

data Message = 
    Payload Word8
  | CloseSocket

data AddrInfo = AddrInfo {
    addrFamily  :: Family
  , addrAddress :: SockAddr
  }

data SockAddr = SockAddrInet PortNumber HostAddress
  deriving (Eq, Ord, Show)

instance Show AddrInfo where
  show = show . addrAddress

instance Show Socket where
  show sock = "<<socket " ++ socketDescription sock ++ ">>"

getAddrInfo :: Maybe AddrInfo -> Maybe HostName -> Maybe ServiceName -> IO [AddrInfo]
getAddrInfo _ (Just host) (Just port) = do
  validHosts <- get validHostnames
  if host `elem` validHosts
    then return . return $ AddrInfo { 
             addrFamily  = error "Family unused" 
           , addrAddress = SockAddrInet port host 
           }
    else throwSocketError $ "getAddrInfo: invalid hostname '" ++ host ++ "'"
getAddrInfo _ _ _ = error "getAddrInfo: unsupported arguments"

defaultHints :: AddrInfo
defaultHints = error "defaultHints not implemented" 

socket :: Family -> SocketType -> ProtocolNumber -> IO Socket
socket _ Stream _ = do
  state <- newMVar Uninit
  sid   <- get nextSocketId
  set nextSocketId (sid + 1)
  return Socket { 
      socketState       = state
    , socketDescription = show sid
    }
  
bindSocket :: Socket -> SockAddr -> IO ()
bindSocket sock addr = do
  timeoutThrow mvarThreshold $ modifyMVar_ (socketState sock) $ \st -> case st of
    Uninit -> do
      backlog <- newChan
      return BoundSocket { 
          socketBacklog = backlog 
        }
    _ ->
      throwSocketError "bind: socket already initialized"
  set (boundSocketAt addr) (Just sock)
  
listen :: Socket -> Int -> IO ()
listen _ _ = return () 

defaultProtocol :: ProtocolNumber
defaultProtocol = error "defaultProtocol not implemented" 

setSocketOption :: Socket -> SocketOption -> Int -> IO ()
setSocketOption _ ReuseAddr 1 = return ()
setSocketOption _ _ _ = error "setSocketOption: unsupported arguments"

accept :: Socket -> IO (Socket, SockAddr)
accept serverSock = do
  backlog <- timeoutThrow mvarThreshold $ withMVar (socketState serverSock) $ \st -> case st of
    BoundSocket {} -> 
      return (socketBacklog st)
    _ ->
      throwSocketError "accept: socket not bound"
  (theirSocket, theirAddress, reply) <- readChan backlog 
  ourBuff  <- newChan
  ourState <- newMVar Connected { 
      socketPeer = Just theirSocket
    , socketBuff = ourBuff
    }
  let ourSocket = Socket {
      socketState       = ourState
    , socketDescription = ""
    }
  timeoutThrow mvarThreshold $ putMVar reply ourSocket 
  return (ourSocket, theirAddress)

sClose :: Socket -> IO ()
sClose sock = do
  -- Close the peer socket
  writeSocket sock CloseSocket 

  -- Close our socket
  timeoutThrow mvarThreshold $ modifyMVar_ (socketState sock) $ \st ->
    case st of
      Connected {} -> do
        -- In case there is a parallel read stuck on a readChan
        writeChan (socketBuff st) CloseSocket
        return Closed
      _ -> 
        return Closed

connect :: Socket -> SockAddr -> IO ()
connect us serverAddr = do
  mServer <- get (boundSocketAt serverAddr)
  case mServer of
    Just server -> do
      serverBacklog <- timeoutThrow mvarThreshold $ withMVar (socketState server) $ \st -> case st of
        BoundSocket {} ->
          return (socketBacklog st)
        _ ->
          throwSocketError "connect: server socket not bound"
      reply <- newEmptyMVar
      writeChan serverBacklog (us, SockAddrInet "" "", reply)
      them <- timeoutThrow mvarThreshold $ readMVar reply 
      timeoutThrow mvarThreshold $ modifyMVar_ (socketState us) $ \st -> case st of
        Uninit -> do 
          buff <- newChan
          return Connected { 
              socketPeer = Just them 
            , socketBuff = buff
            }
        _ ->
          throwSocketError "connect: already connected"
    Nothing -> throwSocketError "connect: unknown address"

sOMAXCONN :: Int
sOMAXCONN = error "sOMAXCONN not implemented" 

shutdown :: Socket -> ShutdownCmd -> IO ()
shutdown sock ShutdownSend = do
  writeSocket sock CloseSocket
  timeoutThrow mvarThreshold $ modifyMVar_ (socketState sock) $ \st -> case st of
    Connected {} ->
      return (Connected Nothing (socketBuff st))
    _ ->
      return st

--------------------------------------------------------------------------------
-- Functions with no direct public counterpart                                --
--------------------------------------------------------------------------------

peerBuffer :: Socket -> IO (Either String (Chan Message))
peerBuffer sock = do
  mPeer <- timeoutThrow mvarThreshold $ withMVar (socketState sock) $ \st -> case st of
    Connected {} -> 
      return (socketPeer st)
    _ ->
      return Nothing
  case mPeer of
    Just peer -> timeoutThrow mvarThreshold $ withMVar (socketState peer) $ \st -> case st of
      Connected {} ->
        return (Right (socketBuff st))
      _ ->
        return (Left "Peer socket closed") 
    Nothing -> 
      return (Left "Socket closed") 

throwSocketError :: String -> IO a
throwSocketError = throwIO . userError

writeSocket :: Socket -> Message -> IO ()
writeSocket sock msg = do
  theirBuff <- peerBuffer sock
  case theirBuff of
    Right buff -> writeChan buff msg 
    Left err   -> case msg of Payload _   -> throwSocketError $ "writeSocket: " ++ err 
                              CloseSocket -> return ()

readSocket :: Socket -> IO (Maybe Word8)
readSocket sock = do
  mBuff <- timeoutThrow mvarThreshold $ withMVar (socketState sock) $ \st -> case st of
    Connected {} -> 
      return (Just $ socketBuff st)
    _ ->
      return Nothing
  case mBuff of
    Just buff -> do
      msg <- timeoutThrow readSocketThreshold $ readChan buff 
      case msg of
        Payload w -> return (Just w)
        CloseSocket -> timeoutThrow mvarThreshold $ modifyMVar (socketState sock) $ \st -> case st of
          Connected {} ->
            return (Closed, Nothing)
          _ ->
            throwSocketError "readSocket: socket in unexpected state"
    Nothing -> 
      return Nothing

--------------------------------------------------------------------------------
-- Util                                                                       --
--------------------------------------------------------------------------------

mvarThreshold :: Int
mvarThreshold = 1000000

readSocketThreshold :: Int
readSocketThreshold = 10000000

timeoutThrow :: Int -> IO a -> IO a
timeoutThrow n p = do
  ma <- timeout n p
  case ma of
    Just a  -> return a
    Nothing -> throwIO (userError "timeout")