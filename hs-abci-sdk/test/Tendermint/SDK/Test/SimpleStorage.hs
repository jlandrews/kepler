{-# LANGUAGE QuasiQuotes     #-}
{-# LANGUAGE TemplateHaskell #-}
{-# OPTIONS_GHC -fno-warn-unused-top-binds #-}

module Tendermint.SDK.Test.SimpleStorage
  ( SimpleStorage
  , UpdateCountTx(..)
  , UpdatePaidCountTx(..)
  , simpleStorageModule
  , simpleStorageCoinId
  , evalToIO
  , Count(..)
  ) where

import           Control.Lens                          ((^.))
import           Data.Bifunctor                        (first)
import qualified Data.ByteArray.Base64String           as Base64
import           Data.Int                              (Int32)
import           Data.Proxy
import qualified Data.Serialize                        as Serialize
import           Data.Serialize.Text                   ()
import           Data.String.Conversions               (cs)
import           Data.Validation                       (Validation (..))
import           Data.Word                             (Word64)
import           GHC.Generics                          (Generic)
import           GHC.TypeLits                          (symbolVal)
import           Polysemy
import           Polysemy.Error                        (Error, catch, throw)
import           Servant.API
import           Tendermint.SDK.Application            (Module (..), ModuleEffs)
import qualified Tendermint.SDK.BaseApp                as BA
import qualified Tendermint.SDK.BaseApp.Store.Array    as A
import qualified Tendermint.SDK.BaseApp.Store.Map      as M
import           Tendermint.SDK.BaseApp.Store.TH       (makeSubStore)
import qualified Tendermint.SDK.BaseApp.Store.Var      as V
import           Tendermint.SDK.Codec                  (HasCodec (..))
import qualified Tendermint.SDK.Modules.Bank           as B
import qualified Tendermint.SDK.Test.SimpleStorageKeys as Keys
import           Tendermint.SDK.Types.Address          (Address)
import           Tendermint.SDK.Types.Message          (HasMessageType (..),
                                                        Msg (..),
                                                        ValidateMessage (..))
import           Tendermint.SDK.Types.Transaction      (Tx (..))


--------------------------------------------------------------------------------
-- Types
--------------------------------------------------------------------------------
type SimpleStorageName = "simple_storage"

simpleStorageCoinId :: B.CoinId
simpleStorageCoinId = B.CoinId . cs . symbolVal $ Proxy @SimpleStorageName

newtype Count = Count Int32 deriving (Eq, Show, Ord, Num, Serialize.Serialize)

instance HasCodec Count where
    encode = Serialize.encode
    decode = first cs . Serialize.decode

-- Count

newtype AmountPaid = AmountPaid B.Amount deriving (Eq, Show, Num, Ord, HasCodec)

--------------------------------------------------------------------------------
-- Message Types
--------------------------------------------------------------------------------

data UpdateCountTx = UpdateCountTx
  { updateCountTxCount    :: Int32
  } deriving (Show, Eq, Generic)

instance Serialize.Serialize UpdateCountTx

instance HasMessageType UpdateCountTx where
  messageType _ = "update_count"

instance HasCodec UpdateCountTx where
  encode = Serialize.encode
  decode = first cs . Serialize.decode

instance ValidateMessage UpdateCountTx where
  validateMessage _ = Success ()

data UpdatePaidCountTx = UpdatePaidCountTx
  { updatePaidCountTxCount  :: Int32
  , updatePaidCountTxAmount :: Word64
  } deriving (Show, Eq, Generic)

instance Serialize.Serialize UpdatePaidCountTx

instance HasMessageType UpdatePaidCountTx where
  messageType _ = "update_paid_count"

instance HasCodec UpdatePaidCountTx where
  encode = Serialize.encode
  decode = first cs . Serialize.decode

instance ValidateMessage UpdatePaidCountTx where
  validateMessage _ = Success ()

--------------------------------------------------------------------------------
-- Keeper
--------------------------------------------------------------------------------


data SimpleStorageKeeper m a where
    UpdateCount :: Count -> SimpleStorageKeeper m ()
    UpdatePaidCount :: Address -> Count -> B.Amount -> SimpleStorageKeeper m ()
    GetCount :: SimpleStorageKeeper m (Maybe Count)
    GetAllCounts :: SimpleStorageKeeper m [Count]

makeSem ''SimpleStorageKeeper

--------------------------------------------------------------------------------

data SimpleStorageNamespace

store :: BA.Store SimpleStorageNamespace
store = BA.makeStore $ BA.KeyRoot (cs . symbolVal $ Proxy @SimpleStorageName)

$(makeSubStore 'store "countVar" [t| V.Var Count |] Keys.countKey)

instance BA.QueryData CountVarKey

$(makeSubStore 'store "paidMap" [t| M.Map Address AmountPaid |] Keys.paidKey)

$(makeSubStore 'store "countsList" [t| A.Array Count|] Keys.countsKey)
--------------------------------------------------------------------------------

type SimpleStorageEffs = '[SimpleStorageKeeper]

eval
  :: forall r.
     Members BA.TxEffs r
  => Members B.BankEffs r
  => forall a. (Sem (SimpleStorageKeeper ': r) a -> Sem r a)
eval = interpret (\case
  UpdateCount count -> updateCountF count
  UpdatePaidCount addr count amt -> updatePaidCountF addr count amt
  GetCount -> V.takeVar countVar
  GetAllCounts -> A.toList countsList
  )


updateCountF
  :: Members [Error BA.AppError, BA.ReadStore, BA.WriteStore] r
  => Count
  -> Sem r ()
updateCountF count = do
  V.putVar count countVar
  A.append count countsList


updatePaidCountF
  :: forall r .
     Members B.BankEffs r
  => Members [BA.ReadStore, BA.WriteStore, Error BA.AppError] r
  => Address
  -> Count
  -> B.Amount
  -> Sem r ()
updatePaidCountF from count amount =
  catch @_ @r
    ( do
        B.burn from (B.Coin simpleStorageCoinId amount)
        updateCountF count
        M.update (Just . \a -> a + AmountPaid amount) from paidMap
    )
    (\(B.InsufficientFunds _) -> do
      let mintAmount = B.Coin simpleStorageCoinId (amount + 1)
      B.mint from mintAmount
      updatePaidCountF from count amount
    )

--------------------------------------------------------------------------------
-- Router
--------------------------------------------------------------------------------

type MessageApi =
  BA.TypedMessage UpdateCountTx BA.:~> BA.Return () :<|>
  BA.TypedMessage UpdatePaidCountTx BA.:~> BA.Return ()

messageHandlers
  :: Member SimpleStorageKeeper r
  => BA.RouteTx MessageApi r
messageHandlers = updateCountH :<|> updatePaidCountH

updateCountH
  :: Member SimpleStorageKeeper r
  => BA.RoutingTx UpdateCountTx
  -> Sem r ()
updateCountH (BA.RoutingTx Tx{txMsg}) =
  let Msg{msgData} = txMsg
      UpdateCountTx{updateCountTxCount} = msgData
  in updateCount (Count updateCountTxCount)

updatePaidCountH
  :: Member SimpleStorageKeeper r
  => BA.RoutingTx UpdatePaidCountTx
  -> Sem r ()
updatePaidCountH (BA.RoutingTx Tx{txMsg}) =
  let Msg{msgData, msgAuthor} = txMsg
      UpdatePaidCountTx{..} = msgData
  in updatePaidCount msgAuthor (Count updatePaidCountTxCount)
       (B.Amount updatePaidCountTxAmount)

--------------------------------------------------------------------------------
-- Server
--------------------------------------------------------------------------------

type CountStoreApi =
  "count" :> BA.StoreLeaf (V.Var Count) :<|>
  "counts" :> BA.StoreLeaf (A.Array Count) :<|>
  "amount_paid" :> BA.StoreLeaf (M.Map Address AmountPaid)

type GetMultipliedCount =
     "manipulated"
  :> Capture "subtract" Integer
  :> QueryParam' '[Required, Strict] "factor" Integer
  :> BA.Leaf Count

getMultipliedCount
  :: Members [Error BA.AppError, SimpleStorageKeeper] r
  => Integer
  -> Integer
  -> Sem r (BA.QueryResult Count)
getMultipliedCount subtractor multiplier = do
  let m = fromInteger multiplier
      s = fromInteger subtractor
  mc <- getCount
  case mc of
    Nothing -> throw . BA.makeAppError $ BA.ResourceNotFound
    Just c -> pure $ BA.QueryResult
      { queryResultData = m * c - s
      , queryResultIndex = 0
      , queryResultKey = Base64.fromBytes $ CountVarKey ^. BA.rawKey
      , queryResultProof  = Nothing
      , queryResultHeight = 0
      }

type QueryApi = GetMultipliedCount :<|> CountStoreApi

querier
  :: forall r.
     Members BA.QueryEffs r
  => Member SimpleStorageKeeper r
  => BA.RouteQ QueryApi r
querier =
  getMultipliedCount :<|>
    ( BA.storeQueryHandler countVar :<|>
      BA.storeQueryHandler countsList :<|>
      BA.storeQueryHandler paidMap
    )

--------------------------------------------------------------------------------
-- Module Definition
--------------------------------------------------------------------------------

type SimpleStorage =
  Module SimpleStorageName MessageApi MessageApi QueryApi BA.EmptyBeginBlockServer BA.EmptyEndBlockServer SimpleStorageEffs '[B.Bank]

simpleStorageModule
  :: Members (ModuleEffs SimpleStorage) r
  => SimpleStorage r
simpleStorageModule = Module
  { moduleTxDeliverer = messageHandlers
  , moduleTxChecker = BA.defaultCheckTx (Proxy :: Proxy MessageApi) (Proxy :: Proxy r)
  , moduleQuerier = querier
  , moduleBeginBlocker = BA.EmptyBeginBlockServer
  , moduleEndBlocker = BA.EmptyEndBlockServer
  , moduleEval = eval
  }

evalToIO
  :: BA.PureContext
  -> Sem (BA.BaseAppEffs BA.PureCoreEffs) a
  -> IO a
evalToIO context action = do
  eRes <- BA.runPureCoreEffs context .  BA.defaultCompileToPureCore $ action
  either (error . show) pure eRes
