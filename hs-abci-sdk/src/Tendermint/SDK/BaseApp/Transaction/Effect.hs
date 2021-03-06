module Tendermint.SDK.BaseApp.Transaction.Effect
  ( TxEffs
  , runTx
  , eval
  , evalReadOnly
  ) where

import           Control.Lens                             ((&), (.~))
import           Control.Monad.IO.Class                   (liftIO)
import           Data.ByteArray.Base64String              (fromBytes)
import           Data.Default.Class                       (def)
import           Data.IORef                               (IORef, readIORef,
                                                           writeIORef)
import           Data.Proxy
import           Polysemy                                 (Embed, Member,
                                                           Members, Sem,
                                                           interpret,
                                                           raiseUnder, rewrite)
import           Polysemy.Error                           (Error, runError)
import           Polysemy.Internal                        (send)
import           Polysemy.Output                          (Output, ignoreOutput,
                                                           runOutputMonoidIORef)
import qualified Polysemy.State                           as State
import           Polysemy.Tagged                          (Tagged (..))
import           Tendermint.SDK.BaseApp.Errors            (AppError,
                                                           txResultAppError)
import qualified Tendermint.SDK.BaseApp.Events            as E
import qualified Tendermint.SDK.BaseApp.Gas               as G
import           Tendermint.SDK.BaseApp.Store.RawStore    (ReadStore (..),
                                                           WriteStore (..))
import qualified Tendermint.SDK.BaseApp.Transaction.Cache as Cache
import           Tendermint.SDK.BaseApp.Transaction.Types
import           Tendermint.SDK.Codec                     (HasCodec (..))
import           Tendermint.SDK.Types.Effects             ((:&))
import           Tendermint.SDK.Types.TxResult            (TxResult,
                                                           txResultData,
                                                           txResultEvents,
                                                           txResultGasUsed,
                                                           txResultGasWanted)

type TxEffs =
    [ Output E.Event
    , G.GasMeter
    , WriteStore
    , ReadStore
    , Error AppError
    ]

eval
  :: forall r scope a.
     Members [Embed IO, Tagged scope ReadStore] r
  => Proxy scope
  -> TransactionContext
  -> Sem (TxEffs :& r) a
  -> Sem r (Either AppError a)
eval ps TransactionContext{..} = do
  runError .
    evalCachedReadStore ps storeCache .
    rewrite (Tagged @Cache.Cache) .
    evalCachedWriteStore storeCache .
    rewrite (Tagged @Cache.Cache) .
    State.runStateIORef gasRemaining .
    G.eval .
    raiseUnder @(State.State G.GasAmount) .
    runOutputMonoidIORef events (pure @[])

evalReadOnly
  :: forall r.
     forall a.
     Sem (TxEffs :& r) a
  -> Sem (ReadStore ': Error AppError ': r) a
evalReadOnly =
    writeNothing .
      G.doNothing .
      ignoreOutput
  where
    writeNothing = interpret (\case
      StorePut _ _ -> pure ()
      StoreDelete _ -> pure ()
      )

runTx
  :: Members [Embed IO, Tagged scope ReadStore] r
  => HasCodec a
  => Proxy scope
  -> TransactionContext
  -> Sem (TxEffs :& r) a
  -> Sem r (TxResult, Maybe Cache.Cache)
runTx ps ctx@TransactionContext{..} tx = do
  initialGas <- liftIO $ readIORef gasRemaining
  eRes <- eval ps ctx tx
  finalGas <- liftIO $ readIORef gasRemaining
  let gasUsed = initialGas - finalGas
      baseResponse =
        def & txResultGasWanted .~ G.unGasAmount initialGas
            & txResultGasUsed .~ G.unGasAmount gasUsed
  case eRes of
    Left e -> return (baseResponse & txResultAppError .~ e, Nothing)
    Right a -> do
        es <- liftIO $ readIORef events
        c <- liftIO $ readIORef storeCache
        return ( baseResponse & txResultEvents .~ es
                              & txResultData .~ fromBytes (encode a)
               , Just c
               )

evalCachedReadStore
  :: Members [Embed IO, Tagged scope ReadStore] r
  => Proxy scope
  -> IORef Cache.Cache
  -> Sem (Tagged Cache.Cache ReadStore ': r) a
  -> Sem r a
evalCachedReadStore (_ :: Proxy scope) c m = do
  interpret
    (\(Tagged action) -> case action of
      StoreGet k -> do
        cache <- liftIO $ readIORef c
        case Cache.get k cache of
          Left Cache.Deleted -> pure Nothing
          Right (Just v)     -> pure (Just v)
          Right Nothing      -> send (Tagged @scope (StoreGet k))
      StoreProve _ -> pure Nothing
    ) m

evalCachedWriteStore
  :: Member (Embed IO) r
  => IORef Cache.Cache
  -> Sem (Tagged Cache.Cache WriteStore ': r) a
  -> Sem r a
evalCachedWriteStore c m = do
  interpret
    (liftIO . \(Tagged action) -> case action of
      StorePut k v  -> do
       cache <- liftIO $ readIORef c
       writeIORef c $ Cache.put k v cache
      StoreDelete k -> do
        cache <- liftIO $ readIORef c
        writeIORef c $ Cache.delete k cache
    ) m
