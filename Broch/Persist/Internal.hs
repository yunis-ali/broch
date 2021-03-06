{-# LANGUAGE QuasiQuotes, TypeFamilies, OverloadedStrings, GADTs,
             FlexibleContexts, MultiParamTypeClasses, TemplateHaskell,
             GeneralizedNewtypeDeriving #-}

module Broch.Persist.Internal
    ( migrateAll
    , createAuthorization
    , getAuthorizationByCode
    , createClient
    , getClientById
    , createApproval
    , deleteApproval
    , getApproval
    , createUser
    , getUserById
    , getUserByUsername
    )
where

import           Control.Exception (throwIO)
import           Control.Monad (void)
import           Control.Monad.IO.Class
import           Control.Monad.Trans.Reader (ReaderT)
import           Data.Aeson (encode, decodeStrict)
import           Data.ByteString.Lazy (toStrict)
import           Data.Maybe (fromJust)
import           Database.Persist.Sql (SqlBackend)
import           Database.Persist.Types (PersistException(..))
import           Database.Persist (insert, getBy, delete, deleteBy, Entity(..))
import           Database.Persist.TH (share, sqlSettings, mkMigrate, mkPersist, persistLowerCase)
import           Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import           Data.Time.Clock.POSIX
import           Data.Time.Clock
import           Jose.Jwt (IntDate (..))

import qualified Broch.Model as M
import           Broch.Scim
import           Broch.URI

share [mkPersist sqlSettings, mkMigrate "migrateAll"] [persistLowerCase|
AuthCode sql=authz_code
  code   Text
  uid    Text
  clientId Text
  issuedAt UTCTime
  scope  [Text]
  nonce  Text Maybe
  uri    Text Maybe
  authTime UTCTime
  UniqueCode code
  deriving Show

Approval sql=authz_approval
  uid      Text
  clientId Text
  scope    [Text]
  deniedScope [Text]
  expiresAt UTCTime
  UniqueApproval uid clientId
  deriving Show

Client sql=oauth2_client
  clientId       Text
  clientSecret   Text Maybe
  authorizedGrantTypes [Text]
  redirectURIs   [Text]
  accessTokenValidity Int
  refreshTokenValidity Int
  allowedScope   [Text]
  autoapprove    Bool
  tokenEndpointAuthMethod Text
  tokenEndpointAuthAlg Text Maybe
  keysUri        Text Maybe
  keys           Text Maybe
  idTokenAlgs    Text Maybe
  userInfoAlgs   Text Maybe
  requestObjAlgs Text Maybe
  sectorIdentifier Text
  UniqueClientId clientId
  deriving Show

User
  uid            Text
  username       Text
  password       Text
  scim           Text
  UniqueUserId   uid
  UniqueUserName username
  deriving Show
|]

createAuthorization :: (MonadIO m, Functor m, M.Subject s)
                    => Text
                    -> s
                    -> M.Client
                    -> POSIXTime
                    -> [M.Scope]
                    -> Maybe Text
                    -> Maybe URI
                    -> ReaderT SqlBackend m ()
createAuthorization code user client now scope nonce mURI =
    void $ insert $ AuthCode code (M.subjectId user) (M.clientId client) (posixSecondsToUTCTime now) (map M.scopeName scope) nonce ((TE.decodeUtf8 . renderURI) <$> mURI) (posixSecondsToUTCTime $ M.authTime user)

getAuthorizationByCode :: (MonadIO m)
                       => Text
                       -> ReaderT SqlBackend m (Maybe M.Authorization)
getAuthorizationByCode code = do
    record <- getBy $ UniqueCode code
    case record of
        Nothing -> return Nothing
        Just (Entity key (AuthCode _ uid client issuedAt scope nonce uri authTime)) -> do
            delete key
            uri' <- case uri of
                Nothing -> return Nothing
                Just u  -> either (liftIO . throwIO . PersistError) return (Just <$> parseURI u)
            return $ Just $ M.Authorization uid client (IntDate $ utcTimeToPOSIXSeconds issuedAt) (map M.scopeFromName scope) nonce uri' (utcTimeToPOSIXSeconds authTime)

createApproval :: (MonadIO m, Functor m)
               => M.Approval
               -> ReaderT SqlBackend m ()
createApproval (M.Approval uid clientId scope denied (IntDate expires)) =
    void $ insert $ Approval uid clientId (map M.scopeName scope) (map M.scopeName denied) (posixSecondsToUTCTime expires)

getApproval :: (MonadIO m)
            => Text
            -> Text
            -> POSIXTime
            -> ReaderT SqlBackend m (Maybe M.Approval)
getApproval uid cid now = do
    record <- getBy $ UniqueApproval uid cid
    case record of
        Nothing -> return Nothing
        Just (Entity key (Approval _ _ scope denied expiry)) -> do
            let posixExpiry = utcTimeToPOSIXSeconds expiry
            if now > posixExpiry
                then delete key >> return Nothing
                else return $ Just $ M.Approval uid cid (map M.scopeFromName scope) (map M.scopeFromName denied) (IntDate posixExpiry)

deleteApproval :: (MonadIO m)
               => Text
               -> Text
               -> ReaderT SqlBackend m ()
deleteApproval uid cid = deleteBy $ UniqueApproval uid cid

createClient :: (MonadIO m, Functor m)
             => M.Client
             -> ReaderT SqlBackend m ()
createClient (M.Client cid ms gs uris atv rtv scps appr authMethod authAlg kuri ks idtAlgs uiAlgs roAlgs sectorId) =
    let ec a = fmap (TE.decodeUtf8 . toStrict . encode) a
    in  void $ insert $ Client cid ms (map M.grantTypeName gs) (map (TE.decodeUtf8 . renderURI) uris) atv rtv (map M.scopeName scps) appr (toText authMethod) (fmap toText authAlg) kuri (ec ks) (ec idtAlgs) (ec uiAlgs) (ec roAlgs) sectorId

getClientById :: (MonadIO m)
              => Text
              -> ReaderT SqlBackend m (Maybe M.Client)
getClientById cid = do
    record <- getBy $ UniqueClientId cid
    case record of
        Nothing -> return Nothing
        Just (Entity _ (Client _ ms gs uris atv rtv scps appr am aalg kuri ks idtAlgs uiAlgs roAlgs sectorId)) -> do
            let grants     = Prelude.map (\g -> fromJust $ lookup g M.grantTypes) gs
                authMethod = fromText am
                authAlg    = fmap fromText aalg
                ks'        = TE.encodeUtf8 <$> ks >>= decodeStrict
                idtAlgs'   = TE.encodeUtf8 <$> idtAlgs >>= decodeStrict
                uiAlgs'    = TE.encodeUtf8 <$> uiAlgs >>= decodeStrict
                roAlgs'    = TE.encodeUtf8 <$> roAlgs >>= decodeStrict

            uris' <- case mapM parseURI uris of
                Left _  -> liftIO . throwIO $ PersistError "unable to parse stored redirect URIs"
                Right u -> return u
            return $ Just $ M.Client cid ms grants uris' atv rtv (map M.scopeFromName scps) appr authMethod authAlg kuri ks' idtAlgs' uiAlgs' roAlgs' sectorId

createUser :: (MonadIO m, Functor m)
           => Text
           -> Text
           -> ScimUser
           -> ReaderT SqlBackend m ()
createUser uid pass scimUser =
    void $ insert $ User uid (scimUserName scimUser) pass $ TE.decodeUtf8 $ toStrict $ encode scimUser

getUserById :: (MonadIO m)
            => M.SubjectId
            -> ReaderT SqlBackend m (Maybe ScimUser)
getUserById uid = do
    record <- getBy $ UniqueUserId uid
    case record of
        Nothing -> return Nothing
        Just (Entity _ (User _ _ _ scim)) -> return $ decodeStrict $ TE.encodeUtf8 scim

getUserByUsername :: (MonadIO m)
                  => Text
                  -> ReaderT SqlBackend m (Maybe (M.SubjectId, Text))
getUserByUsername name = do
    record <- getBy $ UniqueUserName name
    case record of
        Nothing -> return Nothing
        Just (Entity _ (User uid _ password _)) -> return $ Just (uid, password)

toText :: Show a => a -> Text
toText = T.pack . show

fromText :: Read a => Text -> a
fromText = read . T.unpack
