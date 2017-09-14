{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE OverloadedStrings #-}

module Network.WireGuard.RPC
  ( runRPC,
    serveConduit,
    bytesToPair,
    showDevice,
    showPeer
  ) where

import           Control.Concurrent.STM                    (STM, atomically,
                                                            modifyTVar', readTVar,
                                                            writeTVar)
import           Control.Monad                             (when)
import           Control.Monad.IO.Class                    (liftIO)
import qualified Crypto.Noise.DH                     as DH (dhPubToBytes, dhSecToBytes,
                                                            dhBytesToPair, dhBytesToPair,
                                                            dhBytesToPub)
import           Crypto.Noise.DH.Curve25519 (Curve25519)
import qualified Data.ByteArray                      as BA (convert)
import qualified Data.ByteString                     as BS (ByteString, concat,
                                                            replicate, empty)
import           Data.ByteString.Lazy                      (fromStrict)
import           Data.ByteString.Conversion                (toByteString')
import qualified Data.ByteString.Char8               as BC (pack, singleton, map)
import           Data.Char                                 (toLower)
import           Data.Conduit.Attoparsec                   (sinkParserEither) 
import           Data.Conduit.Network.Unix                 (appSink, appSource,
                                                            runUnixServer,
                                                            serverSettings)
import qualified Data.HashMap.Strict                 as HM (delete, lookup, insert,
                                                            empty, elems, member)
import           Data.Hex                                  (hex)
import           Data.Int                                  (Int32)
import           Data.List                                 (foldl')
import           Data.Bits                                 (Bits(..))
import           Data.Conduit                              (ConduitM, (.|),
                                                            yield, runConduit)
import           Data.IP                                   (IPRange(..), addrRangePair,
                                                            toHostAddress, toHostAddress6,
                                                            fromHostAddress, makeAddrRange,
                                                            fromHostAddress6)
import           Data.Maybe                                (fromJust, isJust,
                                                            fromMaybe)

import           Network.WireGuard.Foreign.UAPI            (WgPeer(..), WgDevice(..),
                                                            WgIpmask(..),
                                                            peerFlagRemoveMe, peerFlagReplaceIpmasks,
                                                            deviceFlagRemoveFwmark, deviceFlagReplacePeers,
                                                            deviceFlagRemovePrivateKey, deviceFlagRemovePresharedKey)
import           Network.WireGuard.Internal.Constant       (keyLength)
import           Network.WireGuard.Internal.RpcParsers     (requestParser)
import           Network.WireGuard.Internal.State          (Device(..), Peer(..),
                                                            createPeer,
                                                            invalidateSessions)
import           Network.WireGuard.Internal.Data.Types     (PrivateKey, PublicKey,
                                                            PresharedKey, KeyPair)
import           Network.WireGuard.Internal.Data.RpcTypes  (RpcRequest(..), RpcSetPayload(..),
                                                            OpType(..), RpcDevicePayload(..),
                                                            RpcPeerPayload(..))
import           Network.WireGuard.Internal.Util           (catchIOExceptionAnd)

-- | Run RPC service over a unix socket
runRPC :: FilePath -> Device -> IO ()
runRPC sockPath device = runUnixServer (serverSettings sockPath) $ \app ->
    catchIOExceptionAnd (return ()) $ 
      runConduit (appSource app .| serveConduit device .| appSink app)
    
-- TODO: ensure that all bytestring over sockets will be erased
serveConduit :: Device -> ConduitM BS.ByteString BS.ByteString IO ()
serveConduit device = do
  request <- sinkParserEither requestParser
  routeRequest request
  where
    --returnError = yield $ writeConfig (-invalidValueError)
    routeRequest (Left _) = yield mempty
    routeRequest (Right req) = 
      case opType req of
        Set -> do 
          err <- liftIO . atomically $ setDevice req device
          let errno = fromMaybe "0" err
          yield $ BS.concat [BC.pack "errno=", errno, BC.pack "\n\n"]
        Get -> do
          deviceBstr <- liftIO . atomically $ showDevice device
          yield $ BS.concat [deviceBstr, BC.pack "errno=0\n\n"]

setDevice :: RpcRequest -> Device -> STM (Maybe BS.ByteString)
setDevice req dev = do
  let devReq = devicePayload . fromJust $ payload req
  when (isJust $ pk devReq) . writeTVar (localKey dev) $ pk devReq
  writeTVar (port dev) $ listenPort devReq
  when (isJust $ fwMark devReq) . writeTVar (fwmark dev) . fromJust $ fwMark devReq
  when (replacePeers devReq) $ delDevPeers dev
  let peersList = peersPayload . fromJust $ payload req
  when (not $ null peersList) $ setPeers peersList dev
  return Nothing
  -- TODO: Handle errors using errno.h

setPeers :: [RpcPeerPayload] -> Device -> STM ()
setPeers peerList dev = mapM_ inFunc peerList
  where
    inFunc peer = do
      statePeers <- readTVar $ peers dev
      let peerPubK = pubToString $ pubK peer
      let peerExists = HM.member peerPubK statePeers
      if remove peer
        then removePeer peer dev
        else if peerExists
               then do
                stmPeer <- modifyPeer peer (fromJust $ HM.lookup peerPubK statePeers)
                let nPeers = HM.insert peerPubK stmPeer statePeers
                writeTVar (peers dev) nPeers
               else do
                stmPeer <- createSTMPeer peer 
                let nPeers = HM.insert peerPubK stmPeer statePeers
                writeTVar (peers dev) nPeers

modifyPeer :: RpcPeerPayload -> Peer -> STM Peer
modifyPeer peer stmPeer = undefined

createSTMPeer :: RpcPeerPayload -> STM Peer
createSTMPeer peer = do
  stmPeer <- createPeer $ pubK peer
  writeTVar (endPoint stmPeer) . Just $ endpoint peer
  writeTVar (keepaliveInterval stmPeer) $ persistantKeepaliveInterval peer
  writeTVar (ipmasks stmPeer) $ allowedIp peer
  return stmPeer
  

delDevPeers :: Device -> STM ()
delDevPeers dev = writeTVar (peers dev) HM.empty

removePeer :: RpcPeerPayload -> Device -> STM ()
removePeer peer dev = do
  currentPeers <- readTVar $ peers dev
  let nPeers = HM.delete (pubToString $ pubK peer) currentPeers
  writeTVar (peers dev) nPeers

showDevice :: Device -> STM BS.ByteString
showDevice device@Device{..} = do
  listen_port   <- BC.pack . show <$> readTVar port
  fwm           <- BC.pack . show <$> readTVar fwmark
  private_key   <- fmap (toLowerBs . hex . privToBytes . fst) <$> readTVar localKey
  let devHm     = [("private_key", private_key),
                   ("listen_port", Just listen_port),
                   ("fwmark", Just fwm)]
  let devBs     = serializeRpcKeyValue devHm
  prs           <- readTVar peers 
  peersBstrList <-  mapM showPeer $ HM.elems prs
  return . BS.concat $ (devBs : peersBstrList)

showPeer :: Peer -> STM BS.ByteString
showPeer Peer{..} = do
  let hm                        =  HM.empty
  let public_key                =  pubToString remotePub
  endpoint                      <- readTVar endPoint
  persistant_keepalive_interval <- readTVar keepaliveInterval
  allowed_ip                    <- readTVar ipmasks
  rx_bytes                      <- readTVar receivedBytes
  tx_bytes                      <- readTVar transferredBytes
  last_handshake_time           <- readTVar lastHandshakeTime
  let peer = [("public_key", Just public_key),
              ("endpoint", BC.pack . show <$> endpoint),
              ("persistent_keepalive_interval", Just . BC.pack . show $ persistant_keepalive_interval),
              ("tx_bytes", Just . BC.pack . show $ tx_bytes),
              ("rx_bytes", Just . BC.pack . show $ rx_bytes),
              ("last_handshake_time", BC.pack . show <$> last_handshake_time)
              ] ++ expandAllowedIps (Just . BC.pack . show <$> allowed_ip)
  return $ serializeRpcKeyValue peer
  where
    expandAllowedIps = foldr (\val acc -> ("allowed_ip", val):acc) []

serializeRpcKeyValue :: [(String, Maybe BS.ByteString)] -> BS.ByteString
serializeRpcKeyValue = foldl' showKeyValueLine BS.empty
  where
    showKeyValueLine acc (key, Just val) 
      | val == BC.pack "0" = acc
      | otherwise          = BS.concat [acc, BC.pack key, BC.singleton '=', val, BC.singleton '\n']
    showKeyValueLine acc (_, Nothing) = acc



ipRangeToWgIpmask :: IPRange -> WgIpmask
ipRangeToWgIpmask (IPv4Range ipv4range) = case addrRangePair ipv4range of
    (ipv4, prefix) -> WgIpmask (Left (toHostAddress ipv4)) (fromIntegral prefix)
ipRangeToWgIpmask (IPv6Range ipv6range) = case addrRangePair ipv6range of
    (ipv6, prefix) -> WgIpmask (Right (toHostAddress6 ipv6)) (fromIntegral prefix)

wgIpmaskToIpRange :: WgIpmask -> IPRange
wgIpmaskToIpRange (WgIpmask ip cidr) = case ip of
    Left ipv4  -> IPv4Range $ makeAddrRange (fromHostAddress ipv4) (fromIntegral cidr)
    Right ipv6 -> IPv6Range $ makeAddrRange (fromHostAddress6 ipv6) (fromIntegral cidr)

invalidValueError :: Int32
invalidValueError = 22  -- TODO: report back actual error

emptyKey :: BS.ByteString
emptyKey = BS.replicate keyLength 0

pubToBytes :: PublicKey -> BS.ByteString
pubToBytes = BA.convert . DH.dhPubToBytes

pubToString :: PublicKey -> BS.ByteString
pubToString = toLowerBs . hex . pubToBytes

privToBytes :: PrivateKey -> BS.ByteString
privToBytes = BA.convert . DH.dhSecToBytes

pskToBytes :: PresharedKey -> BS.ByteString
pskToBytes = BA.convert

bytesToPair :: BS.ByteString -> Maybe KeyPair
bytesToPair = DH.dhBytesToPair . BA.convert

bytesToPub :: BS.ByteString -> Maybe PublicKey
bytesToPub = DH.dhBytesToPub . BA.convert

bytesToPSK :: BS.ByteString -> PresharedKey
bytesToPSK = BA.convert

toLowerBs :: BS.ByteString -> BS.ByteString
toLowerBs = BC.map toLower 

testFlag :: Bits a => a -> a -> Bool
testFlag a flag = (a .&. flag) /= zeroBits
