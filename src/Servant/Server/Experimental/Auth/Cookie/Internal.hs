{-# LANGUAGE DataKinds                  #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE GADTs                      #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE TypeFamilies               #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE PartialTypeSignatures      #-}
{-# LANGUAGE Rank2Types                 #-}
{-# LANGUAGE RecordWildCards  #-}


module Servant.Server.Experimental.Auth.Cookie.Internal where

import Control.Monad.IO.Class
import Control.Monad             (when)
import Control.Concurrent
import Data.Either (isLeft)
import Data.Maybe                (fromMaybe, fromJust, isNothing)
import Data.IORef

import GHC.TypeLits (Symbol)

import Data.ByteString              (ByteString)
import Data.ByteString.Lazy         (toStrict, fromStrict)
import Data.ByteString.Lazy.Builder (toLazyByteString)

import qualified Data.ByteArray as BA
import qualified Data.ByteString as BS            (length, splitAt, concat, pack)
import qualified Data.ByteString.Base64 as Base64 (encode, decode)
import qualified Data.ByteString.Char8 as BS8


import Data.Serialize            (Serialize, put, get)
import Data.Serialize.Put        (runPut)
import Data.Serialize.Get        (runGet)

import Data.Time.Clock           (UTCTime, getCurrentTime, addUTCTime)
import Data.Time.Format          (defaultTimeLocale, formatTime, parseTimeM)

import Network.HTTP.Types.Header        (hCookie)
import Network.Wai                      (Request, requestHeaders)
import Servant                          (throwError)
import Servant                          (addHeader, Proxy(..))
import Servant.API.Experimental.Auth    (AuthProtect)
import Servant.API.ResponseHeaders      (AddHeader)
import Servant.Server                   (err403, errBody, Handler)
import Servant.Server.Experimental.Auth (AuthHandler, AuthServerData, mkAuthHandler)

import Web.Cookie                (parseCookies, renderCookies)

import Crypto.Cipher.AES              (AES256, AES192, AES128)
import Crypto.Cipher.Types            (ctrCombine, IV, makeIV, Cipher(..), BlockCipher(..), KeySizeSpecifier(..))

import Crypto.Error                   (maybeCryptoError)
import Crypto.Hash                    (HashAlgorithm(..))
import Crypto.Hash.Algorithms         (SHA256)
import Crypto.MAC.HMAC                (HMAC)
import qualified Crypto.MAC.HMAC as H (hmac)
import Crypto.Random                  (drgNew, DRG(..), ChaChaDRG, getSystemDRG)


errBadIV :: String
errBadIV = "bad IV"

errBadKey :: String
errBadKey = "bad key"

errShortKey :: Int -> Int -> String
errShortKey x y = "key size must be at least " ++ (show x) ++ " bytes (given " ++ (show y) ++ ")"

errBadMAC :: String
errBadMAC = "bad MAC"

errBadTimeFormat :: String
errBadTimeFormat = "bad time format"

errExpired :: String
errExpired = "expired cookie"




type GenericCipherAlgorithm c ba = (BlockCipher c, BA.ByteArray ba) =>
  c -> IV c -> ba -> ba

type CipherAlgorithm c = GenericCipherAlgorithm c ByteString

data RandomSource d where
  RandomSource :: (DRG d) => IO d -> Int -> IORef (d, Int) -> RandomSource d


refreshRef :: IO a -> IORef a -> IO ()
refreshRef mkState ref = void $ forkIO refresh where
  void f = f >> return ()
  refresh = mkState >>= atomicWriteIORef ref


mkRandomSourceState :: (DRG d) => IO d -> IO (d, Int)
mkRandomSourceState mkDRG = do
  drg <- mkDRG
  return (drg, 0)


mkRandomSource :: forall d. (DRG d) => IO d -> Int -> IO (RandomSource d)
mkRandomSource mkDRG threshold = (RandomSource mkDRG threshold)
                             <$> (mkRandomSourceState mkDRG >>= newIORef)


refreshSource :: forall d. RandomSource d -> IO ()
refreshSource (RandomSource mkDRG _ ref) = refreshRef (mkRandomSourceState mkDRG) ref


getRandomBytes :: forall d. (DRG d) => RandomSource d -> Int -> IO ByteString
getRandomBytes rs@(RandomSource _ threshold ref) n = do
    (result, bytes) <- atomicModifyIORef ref $ \(drg, bytes) -> let
      (result, drg') = randomBytesGenerate n drg
      bytes'         = bytes + n
      in ((drg', bytes'), (result, bytes'))

    when (bytes >= threshold) $ refreshSource rs
    return $! result


data ServerKey where
  ServerKey :: Int -> Maybe Int -> IORef (ByteString, UTCTime) -> ServerKey

mkServerKeyState :: Int -> Maybe Int -> IO (ByteString, UTCTime)
mkServerKeyState size maxAge = do
  key <- fst . randomBytesGenerate size <$> drgNew
  time <- addUTCTime (fromIntegral (fromMaybe 0 maxAge)) <$> getCurrentTime
  return (key, time)

mkServerKey :: Int -> Maybe Int -> IO ServerKey
mkServerKey size maxAge = (ServerKey size maxAge) <$> (mkServerKeyState size maxAge >>= newIORef)

refreshServerKey :: ServerKey -> IO ()
refreshServerKey (ServerKey size maxAge ref) = refreshRef (mkServerKeyState size maxAge) ref


getServerKey :: ServerKey -> IO ByteString
getServerKey sk@(ServerKey size maxAge ref) = do
  (key, time) <- readIORef ref
  currentTime <- getCurrentTime

  let expired = ($ maxAge) $ maybe
                  False
                  (\dt -> currentTime > addUTCTime (fromIntegral dt) time)

  when (expired) $ refreshServerKey sk
  return $! key


data Cookie = Cookie {
    iv         :: ByteString
  , expiration :: UTCTime
  , payload    :: ByteString
  }


type family MkHMAC h
  where MkHMAC (Proxy h) = HMAC h


sign :: forall h. (HashAlgorithm h) => Proxy h -> ByteString -> ByteString -> ByteString
sign _ key msg = (BS.pack . BA.unpack) ((H.hmac key msg) :: HMAC h)


applyCipherAlgorithm :: forall c. (BlockCipher c) =>
  CipherAlgorithm c -> ByteString -> ByteString -> ByteString -> ByteString

applyCipherAlgorithm f iv key msg = (BS.pack . BA.unpack) (f key' iv' msg) where
  iv' = (fromMaybe (error errBadIV) (makeIV iv)) :: IV c
  key' = (fromMaybe (error errBadKey) (maybeCryptoError $ cipherInit key)) :: c


mkProperKey :: KeySizeSpecifier -> ByteString -> ByteString
mkProperKey kss s = BS8.take (getProperLength (BS8.length s) kss) s where
  getProperLength :: Int -> KeySizeSpecifier -> Int

  getProperLength x (KeySizeRange l r) = case x < l of
    False -> min x r
    True -> error $ errShortKey l x

  getProperLength x (KeySizeEnum ls) = let
    ls' = filter (<= x) ls
    in case (null ls') of
         False -> foldl1 max ls'
         True -> error $ errShortKey (foldl1 min ls) x

  getProperLength x (KeySizeFixed l) = case x < l of
    False -> l
    True -> error $ errShortKey l x


splitMany :: (Int -> a -> (a, a)) -> [Int] -> a -> [a]
splitMany _ [] s = [s]
splitMany f (x:xs) s = let (chunk, rest) = f x s in chunk:(splitMany f xs rest)


-- | Encrypt given cookie with server key
encryptCookie :: forall h c. (HashAlgorithm h, BlockCipher c) =>
  CipherAlgorithm c -> Proxy h -> ByteString -> Cookie -> String -> ByteString

encryptCookie f h serverKey cookie expFormat = BS.concat [
    iv'
  , expiration'
  , payload'
  , mac
  ] where
      iv'         = iv cookie
      expiration' = BS8.pack . formatTime defaultTimeLocale expFormat $ expiration cookie
      key         = mkProperKey
                      (cipherKeySize (undefined :: c))
                      (sign h serverKey $ BS.concat [iv', expiration'])
      payload'    = applyCipherAlgorithm f iv' key (payload cookie)
      mac         = sign h serverKey $ BS.concat [iv', expiration', payload']


-- | Decrypt cookie from bytestring
decryptCookie :: forall h c. (HashAlgorithm h, BlockCipher c) =>
  CipherAlgorithm c -> Proxy h -> ByteString -> UTCTime -> (String, Int) -> ByteString
  -> Either String Cookie

decryptCookie f h serverKey currentTime (expFormat, expSize) s = do
  let ivSize = blockSize (undefined::c)
  let [iv', expiration', payload', mac'] = splitMany BS.splitAt [
          ivSize
        , expSize
        , (BS.length s) - ivSize - expSize - hashDigestSize (undefined::h)
        ] s

  when (mac' /= (sign h serverKey $ BS.concat [iv', expiration', payload'])) $ Left errBadMAC

  let parsedTime = parseTimeM True defaultTimeLocale expFormat $ BS8.unpack expiration'
  when (isNothing parsedTime) $ Left errBadTimeFormat

  let expiration'' = fromJust parsedTime
  when (currentTime >= expiration'') $ Left errExpired

  let key = mkProperKey
              (cipherKeySize (undefined :: c))
              (sign h serverKey $ BS.concat [iv', expiration'])

  Right Cookie {
      iv         = iv'
    , expiration = expiration''
    , payload    = applyCipherAlgorithm f iv' key payload'
    }

unProxy :: forall a. Proxy a -> a
unProxy _ = undefined

-- | Pack session object into a cookie
encryptSession :: forall a. (Serialize a) => Settings -> a -> IO ByteString
encryptSession (Settings {..}) session = do
  iv'         <- getRandomBytes randomSource (blockSize $ unProxy cipher)
  expiration' <- addUTCTime (fromIntegral maxAge) <$> getCurrentTime
  sk          <- getServerKey serverKey

  let payload' = runPut $ put session
  padding <- let
        bs = blockSize $ unProxy cipher
        n = (BS8.length payload')
        l = (bs - (n `mod` bs)) `mod` bs
        in getRandomBytes randomSource l

  let cookie = Cookie  {
      iv         = iv'
    , expiration = expiration'
    , payload    = BS8.concat [payload', padding]
    }

  return $ Base64.encode $ encryptCookie
    encryptAlgorithm
    hashAlgorithm
    sk
    cookie
    (fst $ expirationFormat)


-- | Unpack session object from a cookie
decryptSession :: (Serialize a) => Settings -> ByteString -> IO (Either String a)
decryptSession (Settings {..}) s = do
  currentTime <- getCurrentTime
  serverKey'  <- getServerKey serverKey
  return $ (Base64.decode s)
       >>= (decryptCookie
             decryptAlgorithm
             hashAlgorithm
             serverKey'
             currentTime
             expirationFormat)
       >>= (runGet get . payload)


data Settings where
  Settings :: ( DRG d
              , HashAlgorithm h
              , BlockCipher c
              ) => {
      sessionField :: ByteString
      -- ^ Name of a cookie which stores session object

    , cookieFlags  :: [ByteString]
      -- ^ Session cookie's flags

    , maxAge       :: Int
      -- ^ How much time (in seconds) the cookie will be valid
      -- (corresponds to Max-Age attribute)

    , expirationFormat :: (String, Int)
      -- ^ TODO

    , path         :: ByteString
      -- ^ Scope of the cookie (corresponds to Path attribute)

    , errorMessage :: String
      -- ^ Message to show in request when the cookie is invalid

    , hideReason   :: Bool
      -- ^ Whether to print reason why the cookie was rejected
      -- (if False, errorMessage will be used instead)

    , randomSource :: RandomSource d
      -- ^ Random source for IV

    , serverKey :: ServerKey
      -- ^ Server key to encrypt cookies

    , hashAlgorithm :: Proxy h
      -- ^ TODO

    , cipher :: Proxy c
      -- ^ TODO

    , encryptAlgorithm :: CipherAlgorithm c
    , decryptAlgorithm :: CipherAlgorithm c
      -- ^ TODO
    } -> Settings


defaultSettings :: Settings
defaultSettings = Settings {
   sessionField = "Session"
 , cookieFlags = ["HttpOnly", "Secure"]
 , maxAge = 300
 , expirationFormat = ("%0Y%m%d%H%M%S", 14)
 , path = "/"
 , hideReason = True
 , errorMessage = "Not authorized"
 , hashAlgorithm = (Proxy :: Proxy SHA256)
 , cipher = (Proxy :: Proxy AES256)
 , encryptAlgorithm = ctrCombine
 , decryptAlgorithm = ctrCombine
 , serverKey = undefined
 , randomSource = (undefined :: RandomSource ChaChaDRG)
 }


type family AuthCookieData
type instance AuthServerData (AuthProtect "cookie-auth") = AuthCookieData


getSession :: forall a. (Serialize a) => Settings -> Request -> IO (Either String a)
getSession settings req = formatError <$>
                            either (return . Left) (decryptSession settings) getSessionString where

  getSessionString :: Either String ByteString
  getSessionString = do
    let cookies = parseCookies <$> lookup hCookie (requestHeaders req)
    when (isNothing cookies) $ Left "No cookie header"

    let sessionStr = lookup (sessionField settings) (fromJust cookies)
    when (isNothing sessionStr) $ Left "No session cookie"
    Right $ fromJust sessionStr

  formatError :: Either String a -> Either String a
  formatError result = do
    when ((isLeft result) && (hideReason settings)) $ Left (errorMessage settings)
    result


addSession :: ( MonadIO m
              , Serialize a
              , AddHeader (e::Symbol) ByteString s r
              ) => Settings -> a -> s -> m r

addSession settings@(Settings {..}) a response = do
  sessionString <- liftIO $ encryptSession settings a
  return $ addHeader (toStrict $ toLazyByteString $ renderCookies $ [
                         (sessionField, sessionString)
                       , ("Path"                 , path)
                       , ("Max-Age"              , BS8.pack $ show maxAge)
                       ] ++ (map (\f -> (f, "")) cookieFlags)) response

defaultAuthHandler :: forall a. (Serialize a) => Settings -> AuthHandler Request a
defaultAuthHandler settings = mkAuthHandler handler where

  handler :: Request -> Handler a
  handler req = (liftIO $ (getSession settings req)) >>= either
    (\err -> throwError (err403 { errBody = fromStrict $ BS8.pack err }))
    return


