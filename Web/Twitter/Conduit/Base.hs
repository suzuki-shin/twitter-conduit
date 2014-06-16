{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE CPP #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE ConstraintKinds #-}

module Web.Twitter.Conduit.Base
       ( api
       , apiRequest
       , call
       , call'
       , sourceWithMaxId
       , sourceWithCursor
       , TwitterBaseM
       , endpoint
       , makeRequest
       , sinkJSON
       , sinkFromJSON
       , showBS
       ) where

import Prelude as P
import Web.Twitter.Conduit.Monad
import Web.Twitter.Conduit.Types
import Web.Twitter.Conduit.Parameters
import Web.Twitter.Conduit.Request
import Web.Twitter.Conduit.Cursor
import Web.Twitter.Types.Lens

import qualified Network.HTTP.Conduit as HTTP
import Network.HTTP.Client.MultipartFormData
import qualified Network.HTTP.Types as HT
import qualified Data.Conduit as C
import qualified Data.Conduit.List as CL

import Data.Aeson
import Data.Aeson.Lens
import qualified Data.Conduit.Attoparsec as CA
import qualified Data.Text.Encoding as T
import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as S8
import Control.Monad.IO.Class
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.Resource (MonadResource, MonadThrow, monadThrow)
import Text.Shakespeare.Text
import Control.Monad.Logger
import Control.Lens
import Unsafe.Coerce

type TwitterBaseM m = ( MonadResource m
                      , MonadLogger m
                      )

makeRequest :: MonadIO m
            => HT.Method -- ^ HTTP request method (GET or POST)
            -> String -- ^ API Resource URL
            -> HT.SimpleQuery -- ^ Query
            -> TW m HTTP.Request
makeRequest m url query = do
    p <- getProxy
    req <- liftIO $ HTTP.parseUrl url
    return $ req { HTTP.method = m
                 , HTTP.queryString = HT.renderSimpleQuery False query
                 , HTTP.proxy = p }

api :: TwitterBaseM m
    => HT.Method -- ^ HTTP request method (GET or POST)
    -> String -- ^ API Resource URL
    -> HT.SimpleQuery -- ^ Query
    -> TW m (C.ResumableSource (TW m) ByteString)
api m url query =
    apiRequest =<< makeRequest m url query

apiRequest :: TwitterBaseM m
           => HTTP.Request
           -> TW m (C.ResumableSource (TW m) ByteString)
apiRequest req = do
    signedReq <- signOAuthTW req
    $(logDebug) [st|Signed Request: #{show signedReq}|]
    mgr <- getManager
    res <- HTTP.http signedReq mgr
    $(logDebug) [st|Response Status: #{show $ HTTP.responseStatus res}|]
    $(logDebug) [st|Response Header: #{show $ HTTP.responseHeaders res}|]
    return $ HTTP.responseBody res

endpoint :: String
endpoint = "https://api.twitter.com/1.1/"

apiValue :: (TwitterBaseM m, FromJSON a)
         => HT.Method -- ^ HTTP request method (GET or POST)
         -> String -- ^ API Resource URL
         -> HT.SimpleQuery -- ^ Query
         -> TW m a
apiValue m url query = do
    src <- api m url query
    src C.$$+- sinkFromJSON

call :: (TwitterBaseM m, FromJSON responseType)
     => APIRequest apiName responseType
     -> TW m responseType
call = call'

call' :: (TwitterBaseM m, FromJSON value)
      => APIRequest apiName responseType
      -> TW m value
call' (APIRequestGet u pa) = apiValue "GET" u pa
call' (APIRequestPost u pa) = apiValue "POST" u pa
call' (APIRequestPostMultipart u param prt) = do
    req <- formDataBody body =<< makeRequest "POST" u []
    src <- apiRequest req
    src C.$$+- sinkFromJSON
  where
    body = prt ++ partParam
    partParam = P.map (uncurry partBS . over _1 T.decodeUtf8) param

sourceWithMaxId :: ( TwitterBaseM m
                   , FromJSON responseType
                   , AsStatus responseType
                   , HasMaxIdParam (APIRequest apiName [responseType])
                   )
                => APIRequest apiName [responseType]
                -> C.Source (TW m) responseType
sourceWithMaxId = loop
  where
    loop req = do
        res <- lift $ call req
        case getMinId res of
            Just mid -> do
                CL.sourceList res
                loop $ req & maxId ?~ mid - 1
            Nothing -> CL.sourceList res
    getMinId = minimumOf (traverse . status_id)

sourceWithMaxId' :: ( TwitterBaseM m
                    , HasMaxIdParam (APIRequest apiName [responseType])
                    )
                 => APIRequest apiName [responseType]
                 -> C.Source (TW m) Value
sourceWithMaxId' = loop
  where
    loop req = do
        res <- lift $ call' req
        case getMinId res of
            Just mid -> do
                CL.sourceList res
                loop $ req & maxId ?~ mid - 1
            Nothing -> CL.sourceList res
    getMinId = minimumOf (traverse . key "id" . _Integer)

sourceWithCursor :: ( TwitterBaseM m
                    , FromJSON responseType
                    , CursorKey ck
                    , HasCursorParam (APIRequest apiName (WithCursor ck responseType))
                    )
                 => APIRequest apiName (WithCursor ck responseType)
                 -> C.Source (TW m) responseType
sourceWithCursor req = loop (-1)
  where
    loop 0 = CL.sourceNull
    loop cur = do
        res <- lift $ call $ req & cursor ?~ cur
        CL.sourceList $ contents res
        loop $ nextCursor res

sourceWithCursor' :: ( TwitterBaseM m
                     , FromJSON responseType
                     , CursorKey ck
                     , HasCursorParam (APIRequest apiName (WithCursor ck responseType))
                     )
                  => APIRequest apiName (WithCursor ck responseType)
                  -> C.Source (TW m) Value
sourceWithCursor' req = loop (-1)
  where
    relax :: FromJSON value
          => APIRequest apiName (WithCursor ck responseType)
          -> APIRequest apiName (WithCursor ck value)
    relax = unsafeCoerce
    loop 0 = CL.sourceNull
    loop cur = do
        res <- lift $ call $ relax $ req & cursor ?~ cur
        CL.sourceList $ contents res
        loop $ nextCursor res

sinkJSON :: ( MonadThrow m
            , MonadLogger m
            ) => C.Consumer ByteString m Value
sinkJSON = do
    js <- CA.sinkParser json
    $(logDebug) [st|Response JSON: #{show js}|]
    return js

sinkFromJSON :: ( FromJSON a
                , MonadThrow m
                , MonadLogger m
                ) => C.Consumer ByteString m a
sinkFromJSON = do
    v <- sinkJSON
    case fromJSON v of
        Error err -> lift $ monadThrow $ ParseError err
        Success r -> return r

showBS :: Show a => a -> ByteString
showBS = S8.pack . show
