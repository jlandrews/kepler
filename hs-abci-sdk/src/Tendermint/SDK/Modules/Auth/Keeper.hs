{-# LANGUAGE TemplateHaskell #-}

module Tendermint.SDK.Modules.Auth.Keeper where

import           Polysemy
import           Polysemy.Error                    (Error, mapError, throw)
import           Tendermint.SDK.BaseApp            (AppError, ReadStore,
                                                    StoreKey (..), WriteStore,
                                                    get, makeAppError, put)
import           Tendermint.SDK.Modules.Auth.Types
import           Tendermint.SDK.Types.Address      (Address)

data Accounts m a where
  PutAccount :: Address -> Account -> Accounts m ()
  GetAccount :: Address -> Accounts m (Maybe Account)

makeSem ''Accounts

type AuthEffs = '[Accounts, Error AuthError]

storeKey :: StoreKey AuthNamespace
storeKey = StoreKey "auth"

eval
  :: Members [ReadStore, WriteStore, Error AppError] r
  => Sem (Accounts : Error AuthError : r) a
  -> Sem r a
eval = mapError makeAppError . evalAuth
  where
    evalAuth :: Members [ReadStore, WriteStore, Error AppError] r
             => Sem (Accounts : r) a
             -> Sem r a
    evalAuth =
      interpret (\case
          GetAccount addr ->
            get storeKey addr
          PutAccount addr acnt ->
            put storeKey addr acnt
        )

--------------------------------------------------------------------------------

createAccount
  :: Members [Accounts, Error AuthError] r
  => Address
  -> Sem r Account
createAccount addr = do
  mAcct <- getAccount addr
  case mAcct of
    Just _ -> throw $ AccountAlreadyExists addr
    Nothing -> do
      let emptyAccount = Account
            { accountCoins = []
            , accountNonce = 0
            }
      putAccount addr emptyAccount
      pure emptyAccount