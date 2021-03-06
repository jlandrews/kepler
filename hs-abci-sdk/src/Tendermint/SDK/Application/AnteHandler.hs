module Tendermint.SDK.Application.AnteHandler
  ( module Tendermint.SDK.Application.AnteHandler
  --  Re-Exports
  , AnteHandler
  ) where

import           Control.Monad                      (unless, void)
import           Data.Foldable                      (fold)
import           Data.Monoid                        (Endo (..))
import           Polysemy
import           Polysemy.Error                     (Error)
import           Tendermint.SDK.BaseApp.Errors      (AppError, SDKError (..),
                                                     throwSDKError)
import           Tendermint.SDK.BaseApp.Transaction (AnteHandler,
                                                     RoutingTx (..))
import qualified Tendermint.SDK.Modules.Auth        as A
import           Tendermint.SDK.Types.Message       (Msg (..))
import           Tendermint.SDK.Types.Transaction   (Tx (..))


createAccountAnteHandler
  :: Members A.AuthEffs r
  => AnteHandler r
createAccountAnteHandler = Endo $
  \txApplication tx@(RoutingTx Tx{..}) -> do
    let Msg{msgAuthor} = txMsg
    mAcnt <- A.getAccount msgAuthor
    case mAcnt of
      Nothing -> void $ A.createAccount msgAuthor
      _       -> pure ()
    txApplication tx >>= pure

nonceAnteHandler
  :: Members A.AuthEffs r
  => Member (Error AppError) r
  => AnteHandler r
nonceAnteHandler = Endo $
  \txApplication tx@(RoutingTx Tx{..}) -> do
    let Msg{msgAuthor} = txMsg
    preMAcnt <- A.getAccount msgAuthor
    case preMAcnt of
      Just A.Account{accountNonce} -> do
        let expectedNonce = accountNonce + 1
        unless (txNonce == expectedNonce) $
          throwSDKError (NonceException expectedNonce txNonce)
      Nothing -> throwSDKError (UnknownAccountError msgAuthor)
    result <- txApplication tx
    postMAcnt <- A.getAccount msgAuthor
    case postMAcnt of
      Just A.Account{accountNonce} -> do
        A.updateAccount msgAuthor $ \a ->
          a { A.accountNonce = accountNonce + 1}
      -- @NOTE: no-op when no nonce is availble to update
      Nothing -> pure ()
    pure result

baseAppAnteHandler
  :: Members A.AuthEffs r
  => Member (Error AppError) r
  => AnteHandler r
baseAppAnteHandler = fold $
  -- @NOTE: antehandlers in this list are applied top to bottom
  [ createAccountAnteHandler
  , nonceAnteHandler
  ]
