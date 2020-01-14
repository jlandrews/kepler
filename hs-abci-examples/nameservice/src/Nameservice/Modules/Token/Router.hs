module Nameservice.Modules.Token.Router where

import           Nameservice.Modules.Token.Keeper   (TokenEffs, burn,
                                                     faucetAccount, transfer)
import           Nameservice.Modules.Token.Messages (Burn (..),
                                                     TokenMessage (..),
                                                     Transfer (..))
import           Polysemy                           (Members, Sem)
import           Tendermint.SDK.BaseApp             (BaseAppEffs, TxEffs)
import           Tendermint.SDK.Types.Message       (Msg (..))
import           Tendermint.SDK.Types.Transaction   (PreRoutedTx (..), Tx (..))

router
  :: Members TokenEffs r
  => Members BaseAppEffs r
  => Members TxEffs r
  => PreRoutedTx TokenMessage
  -> Sem r ()
router (PreRoutedTx Tx{txMsg}) =
  let Msg{msgData} = txMsg
  in case msgData of
       TFaucetAccount faucet ->
         faucetAccount faucet
       TTransfer Transfer{..} ->
         transfer transferFrom transferAmount transferTo
       TBurn Burn{..} ->
         burn burnAddress burnAmount
