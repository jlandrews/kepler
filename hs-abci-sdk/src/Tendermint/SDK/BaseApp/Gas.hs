{-# LANGUAGE TemplateHaskell #-}
module Tendermint.SDK.BaseApp.Gas
  (
  -- * Effect
    GasMeter(..)
  , GasAmount(..)
  , withGas
  -- * Eval
  , eval
  , doNothing
  ) where

import           Data.Int                      (Int64)
import           Polysemy                      (Members, Sem, interpretH,
                                                makeSem, raise, runT)
import           Polysemy.Error                (Error)
import           Polysemy.State                (State, get, put)
import           Tendermint.SDK.BaseApp.Errors (AppError,
                                                SDKError (OutOfGasException),
                                                throwSDKError)

newtype GasAmount = GasAmount { unGasAmount :: Int64 } deriving (Eq, Show, Num, Ord)

data GasMeter m a where
    WithGas :: forall m a. GasAmount -> m a -> GasMeter m a

makeSem ''GasMeter


eval
  :: Members [Error AppError, State GasAmount] r
  => Sem (GasMeter ': r) a
  -> Sem r a
eval = interpretH (\case
  WithGas gasCost action -> do
    remainingGas <- get
    let balanceAfterAction = remainingGas - gasCost
    if balanceAfterAction < 0
      then throwSDKError OutOfGasException
      else do
        put balanceAfterAction
        a <- runT action
        raise $ eval a
  )

doNothing
  :: forall r.
     forall a.
     Sem (GasMeter ': r) a
  -> Sem r a
doNothing = interpretH (\case
  WithGas _ action -> do
    a <- runT action
    raise $ doNothing a
  )
