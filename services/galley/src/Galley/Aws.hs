{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE GADTs                      #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE StandaloneDeriving         #-}
{-# LANGUAGE TemplateHaskell            #-}
{-# LANGUAGE TypeFamilies               #-}
{-# LANGUAGE UndecidableInstances       #-}

module Galley.Aws
    ( -- * Monad
      Env
    , mkEnv
    , awsEnv
    , region
    , eventQueue
    , Amazon
    , execute
    , enqueue

      -- * Errors
    , Error (..)
    ) where

import Blaze.ByteString.Builder (toLazyByteString)
import Galley.Options
import Galley.Types.Teams.Queues
import Control.Lens hiding ((.=))
import Control.Monad.Base
import Control.Monad.Catch
import Control.Monad.IO.Class
import Control.Monad.Reader
import Control.Monad.Trans.Control
import Control.Monad.Trans.Resource
import Data.Typeable
import Data.Text (Text)
import Network.HTTP.Client
       (Manager, HttpException(..), HttpExceptionContent(..))
import System.Logger.Class

import qualified Network.TLS             as TLS
import qualified Network.AWS.SQS         as SQS
import qualified System.Logger           as Logger
import qualified Control.Monad.Trans.AWS as AWST
import qualified Network.AWS             as AWS
import qualified Network.AWS.Env         as AWS




import Control.Retry (retrying, limitRetries)
import Data.Id
import Data.UUID.V4 (nextRandom)
import Data.Time.Clock
import Control.Concurrent.Lifted (threadDelay)
import Control.Error hiding (err)
--import Control.Exception.Enclosed (handleAny)
import Control.Lens hiding ((.=))
import Control.Monad
import Control.Monad.Trans.Resource
import Control.Monad.Base
import Control.Monad.Catch
import Control.Monad.Reader
import Control.Monad.Trans.Control
--import Control.Monad.Trans.Resource
import Control.Retry (retrying, limitRetries)
import Data.Misc
import Galley.Types.Teams.Queues
import Control.Monad           (forM_, unless, void, when)
import Control.Monad.IO.Class
import Data.Aeson              ((.:), encode)
import Data.ByteString         (ByteString)
import Data.Monoid
import Data.Text               (Text)
import System.IO
import System.Logger.Class
import Network.HTTP.Types
import Network.HTTP.Client (Manager, HttpException (..), HttpExceptionContent (..))
import qualified Network.TLS             as TLS
import qualified Data.Aeson.Types        as JSON (parseEither)
import qualified Data.Text               as Text
import qualified Data.Text.Encoding      as Text
import qualified Data.Text.IO            as Text
import qualified Data.ByteString.Lazy    as BL
import qualified Network.AWS.SQS         as SQS
import qualified Data.UUID               as UUID
import qualified System.Logger           as Logger
import qualified Control.Monad.Trans.AWS as AWST
import qualified Network.AWS             as AWS
import qualified Network.AWS.Env         as AWS
import qualified Network.AWS.Data        as AWS
import Blaze.ByteString.Builder (toLazyByteString)
import Control.Concurrent.Lifted (threadDelay)
import Control.Error hiding (err)
import Data.Id
import Data.Time.Clock
import Data.UUID.V4 (nextRandom)
import Galley.Options
import Control.Lens hiding ((.=))
import Control.Monad (forM_, unless, void, when)
import Control.Monad.Base
import Control.Monad.Catch
import Control.Monad.IO.Class
import Control.Monad.Reader
import Control.Monad.Trans.Control
import Control.Monad.Trans.Resource
import Control.Retry (retrying, limitRetries)
import Data.Aeson ((.:), encode)
import Data.ByteString (ByteString)
import Data.Misc
import Data.Monoid
import Data.ProtoLens.Encoding
import Data.Typeable
import Data.Text (Text)
import Galley.Types.Teams.Queues
import Network.HTTP.Client
       (Manager, HttpException(..), HttpExceptionContent(..))
import Network.HTTP.Types
import System.IO
import System.Logger.Class
import qualified Network.TLS             as TLS
import qualified Data.Aeson.Types        as JSON (parseEither)
import qualified Data.Text               as Text
import qualified Data.Text.Encoding      as Text
import qualified Data.Text.IO            as Text
import qualified Data.ByteString.Lazy    as BL
import qualified Network.AWS.SQS         as SQS
import qualified Data.UUID               as UUID
import qualified System.Logger           as Logger
import qualified Control.Monad.Trans.AWS as AWST
import qualified Network.AWS             as AWS
import qualified Network.AWS.Env         as AWS
import qualified Network.AWS.Data        as AWS
import qualified Data.Text               as Text
import qualified Data.Text.Encoding      as Text
import qualified Data.Text.IO            as Text
import qualified Data.ByteString.Base64  as B64
import qualified Proto.Galley.Types.TeamEvents as E

newtype QueueUrl = QueueUrl Text deriving Show

data Error where
    GeneralError     :: (Show e, AWS.AsError e) => e -> Error

deriving instance Show     Error
deriving instance Typeable Error

instance Exception Error

data Env = Env
    { _awsEnv     :: !AWS.Env
    , _logger     :: !Logger
    , _eventQueue :: !QueueUrl
    , _region     :: !AWS.Region
    }

makeLenses ''Env

newtype Amazon a = Amazon
    { unAmazon :: ReaderT Env (ResourceT IO) a
    } deriving ( Functor
               , Applicative
               , Monad
               , MonadIO
               , MonadBase IO
               , MonadThrow
               , MonadCatch
               , MonadMask
               , MonadReader Env
               , MonadResource
               )

instance MonadLogger Amazon where
    log l m = view logger >>= \g -> Logger.log g l m

instance MonadBaseControl IO Amazon where
    type StM Amazon a = StM (ReaderT Env (ResourceT IO)) a
    liftBaseWith    f = Amazon $ liftBaseWith $ \run -> f (run . unAmazon)
    restoreM          = Amazon . restoreM

instance AWS.MonadAWS Amazon where
    liftAWS aws = view awsEnv >>= \e -> AWS.runAWS e aws

mkEnv :: Logger -> Opts -> Manager -> IO Env
mkEnv lgr opts mgr = do
    let g = Logger.clone (Just "aws.galley") lgr
    e <- configure <$> mkAwsEnv g
    q <- getQueueUrl e (opts^.queueName)
    return (Env e g q (opts^.awsRegion))
  where
    mkAwsEnv g =  set AWS.envLogger (awsLogger g)
               .  set AWS.envRegion (opts^.awsRegion)
              <$> AWS.newEnvWith AWS.Discover Nothing mgr

    awsLogger g l = Logger.log g (mapLevel l) . Logger.msg . toLazyByteString

    mapLevel AWS.Info  = Logger.Info
    -- Debug output from amazonka can be very useful for tracing requests
    -- but is very verbose (and multiline which we don't handle well)
    -- distracting from our own debug logs, so we map amazonka's 'Debug'
    -- level to our 'Trace' level.
    mapLevel AWS.Debug = Logger.Trace
    mapLevel AWS.Trace = Logger.Trace
    -- n.b. Errors are either returned or thrown. In both cases they will
    -- already be logged if left unhandled. We don't want errors to be
    -- logged inside amazonka already, before we even had a chance to handle
    -- them, which results in distracting noise. For debugging purposes,
    -- they are still revealed on debug level.
    mapLevel AWS.Error = Logger.Debug

    configure = set AWS.envRetryCheck retryCheck

    -- TODO: Remove custom retryCheck? Should be fixed since tls 1.3.9?
    -- account occasional TLS handshake failures.
    -- See: https://github.com/vincenthz/hs-tls/issues/124
    -- See: https://github.com/brendanhay/amazonka/issues/269
    retryCheck _ InvalidUrlException{} = False
    retryCheck n (HttpExceptionRequest _ ex) = case ex of
        _ | n >= 3                    -> False
        NoResponseDataReceived        -> True
        ConnectionTimeout             -> True
        ConnectionClosed              -> True
        ConnectionFailure _           -> True
        InternalException x           -> case fromException x of
            Just TLS.HandshakeFailed {} -> True
            _                           -> False
        _                             -> False

    getQueueUrl :: AWS.Env -> Text -> IO QueueUrl
    getQueueUrl e q = do
        x <- runResourceT . AWST.runAWST e $
            AWST.trying AWS._Error $
                AWST.send (SQS.getQueueURL q)
        either (throwM . GeneralError)
               (return . QueueUrl . view SQS.gqursQueueURL) x

execute :: MonadIO m => Env -> Amazon a -> m a
execute e m = liftIO $ runResourceT (runReaderT (unAmazon m) e)

enqueue :: E.TeamEvent -> Amazon ()
enqueue e = do
    QueueUrl url <- view eventQueue
    res <- retrying (limitRetries 1) (const isTimeout) $ const (sendCatch (req url))
    either (throwM . GeneralError) (const (return ())) res
  where
    event = Text.decodeLatin1 $ B64.encode $ encodeMessage e
    req url = SQS.sendMessage url event & SQS.smMessageGroupId .~ Just "team.events"

--------------------------------------------------------------------------------
-- Utilities

sendCatch :: AWS.AWSRequest r => r -> Amazon (Either AWS.Error (AWS.Rs r))
sendCatch = AWST.trying AWS._Error . AWS.send

isTimeout :: MonadIO m => Either AWS.Error a -> m Bool
isTimeout (Right _) = pure False
isTimeout (Left  e) = case e of
    AWS.TransportError (HttpExceptionRequest _ ResponseTimeout) -> pure True
    _                                                           -> pure False
