module Network.ABCI.Server.Middleware.MetricsLogger
    ( -- * Custom Loggers
      mkMetricsLogger
    , mkMetricsLoggerM
    , OrderedMessageType(..)
    ) where
import           Control.Concurrent.MVar (MVar, modifyMVar)
import           Control.Monad.IO.Class  (MonadIO, liftIO)
import qualified Data.Aeson              as A
import           Data.Map.Strict         (Map)
import qualified Data.Map.Strict         as Map
import           Data.Time               (NominalDiffTime, diffUTCTime,
                                          getCurrentTime)
import           Katip
import           Network.ABCI.Server.App (App (..), MessageType (..),
                                          Middleware, Request (..), msgTypeKey)

---------------------------------------------------------------------------
-- mkMetricsLogger
---------------------------------------------------------------------------
-- | Request logger middleware for ABCI metrics with custom 'Katip.LogEnv'
-- and 'Katip.Namespace'.
mkMetricsLogger :: (MonadIO m) => MVar (Map OrderedMessageType Integer) -> LogEnv -> Namespace -> Middleware m
mkMetricsLogger mvarMap le ns (App app) = App $ \ req -> do
  startTime <- liftIO getCurrentTime
  res <- app req
  endTime <- liftIO getCurrentTime
  metrics <- liftIO $ modifyMVar mvarMap $ \metMap ->
    let mt        = requestToMessageType req
        count     = maybe 1 (+1) (metMap Map.!? mt)
        metrics   = Metrics mt count (diffUTCTime endTime startTime)
        newMetMap = Map.insert mt count metMap
    in  pure (newMetMap, metrics)
  runKatipContextT le () ns $ logMetrics metrics
  pure res

---------------------------------------------------------------------------
-- mkMetricsLoggerM
---------------------------------------------------------------------------
-- | Metrics logger middleware for ABCI server already within the KatipContext.
-- Great for `App m` with a `KatipContext` instance.
mkMetricsLoggerM :: (KatipContext m) => MVar (Map OrderedMessageType Integer) -> Middleware m
mkMetricsLoggerM mvarMap (App app) = App $ \ req -> do
  startTime <- liftIO getCurrentTime
  res <- app req
  endTime <- liftIO getCurrentTime
  metrics <- liftIO $ modifyMVar mvarMap $ \metMap ->
    let mt        = requestToMessageType req
        count     = maybe 1 (+1) (metMap Map.!? mt)
        metrics   = Metrics mt count (diffUTCTime endTime startTime)
        newMetMap = Map.insert mt count metMap
    in  pure (newMetMap, metrics)
  localKatipNamespace (<> "server") $
    logMetrics metrics
  pure res

---------------------------------------------------------------------------
-- Common
---------------------------------------------------------------------------
-- | Metrics logger function.
logMetrics :: (KatipContext m) => Metrics -> m ()
logMetrics metrics = katipAddContext metrics $ logFM InfoS ""


data Metrics = Metrics
  { metricsMessageType  :: OrderedMessageType
  , metricsMessageCount :: Integer
  , metricsResponseTime :: NominalDiffTime
  }
instance A.ToJSON Metrics where
  toJSON Metrics{..} = A.object
    [ "message_type"  A..= A.toJSON ((msgTypeKey $ unOrderedMessageType metricsMessageType) :: String)
    , "message_count" A..= A.toJSON metricsMessageCount
    , "response_time" A..= A.toJSON metricsResponseTime
    ]

instance ToObject Metrics
instance LogItem Metrics where
  payloadKeys _ _  = AllKeys

newtype OrderedMessageType = OrderedMessageType {unOrderedMessageType :: MessageType}

instance Eq OrderedMessageType where
  (==) (OrderedMessageType a) (OrderedMessageType b) = msgTypeKey a == msgTypeKey b

instance Ord OrderedMessageType where
  (<=) (OrderedMessageType a) (OrderedMessageType b) = msgTypeKey a <= msgTypeKey b

requestToMessageType :: Request (t :: MessageType) -> OrderedMessageType
requestToMessageType  (RequestEcho _)       = OrderedMessageType MTEcho
requestToMessageType  (RequestInfo _)       = OrderedMessageType MTInfo
requestToMessageType  (RequestSetOption _)  = OrderedMessageType MTSetOption
requestToMessageType  (RequestQuery _)      = OrderedMessageType MTQuery
requestToMessageType  (RequestCheckTx _)    = OrderedMessageType MTCheckTx
requestToMessageType  (RequestFlush _)      = OrderedMessageType MTFlush
requestToMessageType  (RequestInitChain _)  = OrderedMessageType MTInitChain
requestToMessageType  (RequestBeginBlock _) = OrderedMessageType MTBeginBlock
requestToMessageType  (RequestDeliverTx _)  = OrderedMessageType MTDeliverTx
requestToMessageType  (RequestEndBlock _)   = OrderedMessageType MTEndBlock
requestToMessageType  (RequestCommit _)     = OrderedMessageType MTCommit