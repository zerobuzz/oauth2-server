{-# LANGUAGE DataKinds         #-}
{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes        #-}
{-# LANGUAGE RecordWildCards   #-}
{-# LANGUAGE TypeOperators     #-}

module Network.OAuth2.Server (
    module X,
    processTokenRequest,
    tokenEndpoint,
    TokenEndpoint,
) where

import Control.Applicative
import Control.Monad.Error.Class
import Control.Monad.IO.Class
import Control.Monad.Trans.Except
import Data.Aeson
import Data.ByteString (ByteString)
import Data.ByteString.Conversion
import Data.Time.Clock
import Servant.API
import Servant.Server

import Network.OAuth2.Server.Configuration as X
import Network.OAuth2.Server.Types as X

data NoStore = NoStore
instance ToByteString NoStore where
    builder _ = "no-store"

data NoCache = NoCache
instance ToByteString NoCache where
    builder _ = "no-cache"

type TokenEndpoint
    = "token"
    :> Header "Authorization" ByteString
    :> ReqBody '[FormUrlEncoded] (Either OAuth2Error AccessRequest)
    :> Post '[JSON] (Headers '[Header "Cache-Control" NoStore, Header "Pragma" NoCache] AccessResponse)

throwOAuth2Error :: (MonadError ServantErr m) => OAuth2Error -> m a
throwOAuth2Error e =
    throwError err400 { errBody = encode e
                      , errHeaders = [("Content-Type", "application/json")]
                      }

tokenEndpoint :: OAuth2Server (ExceptT OAuth2Error IO) -> Server TokenEndpoint
tokenEndpoint _ _ (Left e) = throwOAuth2Error e
tokenEndpoint conf auth (Right req) = do
    t <- liftIO getCurrentTime
    res <- liftIO $ runExceptT $ processTokenRequest conf t auth req
    case res of
        Left e -> throwOAuth2Error e
        Right response -> do
            return $ addHeader NoStore $ addHeader NoCache $ response

processTokenRequest
    :: (MonadError OAuth2Error m)
    => OAuth2Server m
    -> UTCTime
    -> Maybe ByteString
    -> AccessRequest
    -> m AccessResponse
processTokenRequest Configuration{..} t client_auth req = do
    (client_id, modified_req) <- oauth2CheckCredentials client_auth req
    (user, req_scope) <- case modified_req of
            RequestAuthorizationCode{..} ->
                return (Nothing, Nothing)
            RequestPassword{..} ->
                return
                ( Just requestUsername
                , requestScope
                )
            RequestClientCredentials{..} ->
                return
                ( Nothing
                , requestScope
                )
            RequestRefreshToken{..} -> do
                -- Decode previous token so we can copy details across.
                previous <- oauth2StoreLoad requestRefreshToken
                return
                    ( tokenDetailsUsername =<< previous
                    , requestScope <|> (tokenDetailsScope =<< previous)
                    )
    let expires = addUTCTime 1800 t
        access_grant = TokenGrant
            { grantTokenType = Bearer
            , grantExpires = expires
            , grantUsername = user
            , grantClientID = client_id
            , grantScope = req_scope
            }
        -- Create a refresh token with these details.
        refresh_expires = addUTCTime (3600 * 24 * 7) t
        refresh_grant = access_grant
            { grantTokenType = Refresh
            , grantExpires = refresh_expires
            }
    access_details <- oauth2StoreSave access_grant
    refresh_details <- oauth2StoreSave refresh_grant
    return $ grantResponse t access_details (Just $ tokenDetailsToken refresh_details)
