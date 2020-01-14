module SimpleStorage.Test.E2ESpec (spec) where

import           Control.Lens                         ((^.))
import qualified Data.ByteArray.Base64String          as Base64
import           Data.Default.Class                   (def)
import           Data.Proxy
import qualified Network.ABCI.Types.Messages.Response as Resp
import qualified Network.Tendermint.Client            as RPC
import           Servant.API                          ((:>))
import qualified SimpleStorage.Modules.SimpleStorage  as SS
import           Tendermint.SDK.BaseApp.Query         (QueryArgs (..))
import           Tendermint.SDK.Codec                 (HasCodec (..))
import           Tendermint.Utils.Client              (ClientResponse (..),
                                                       HasClient (..))
import           Tendermint.Utils.Request             (runRPC)
import           Tendermint.Utils.User                (User (..), makeUser, mkSignedRawTransactionWithRoute)
import           Test.Hspec

spec :: Spec
spec = do
  describe "SimpleStorage E2E - via hs-tendermint-client" $ do

    it "Can query /health to make sure the node is alive" $ do
      resp <- runRPC RPC.health
      resp `shouldBe` RPC.ResultHealth

    --it "Can query the count and make sure its initialized to 0" $ do
    --  let queryReq = QueryArgs
    --        { queryArgsData = SS.CountKey
    --        , queryArgsHeight = 0
    --        , queryArgsProve = False
    --        }
    --  ClientResponse{clientResponseData = Just foundCount} <- runQueryRunner $ getCount queryReq
    --  foundCount `shouldBe` SS.Count 0

    it "Can submit a tx synchronously and make sure that the response code is 0 (success)" $ do
      let txMsg = SS.UpdateCount $ SS.UpdateCountTx "irakli" 4
      tx <- mkSignedRawTransactionWithRoute "simple_storage" user1 txMsg
      let txReq = RPC.RequestBroadcastTxCommit
                    { RPC.requestBroadcastTxCommitTx = Base64.fromBytes . encode $ tx
                    }
      deliverResp <- fmap RPC.resultBroadcastTxCommitDeliverTx . runRPC $ RPC.broadcastTxCommit txReq
      let deliverRespCode = deliverResp ^. Resp._deliverTxCode
      deliverRespCode `shouldBe` 0

    it "can make sure the synchronous tx transaction worked and the count is now 4" $ do
      let queryReq = QueryArgs
            { queryArgsData = SS.CountKey
            , queryArgsHeight = 0
            , queryArgsProve = False
            }
      ClientResponse{clientResponseData = Just foundCount} <- runRPC $ getCount queryReq
      foundCount `shouldBe` SS.Count 4

--------------------------------------------------------------------------------

getCount :: QueryArgs SS.CountKey -> RPC.TendermintM (ClientResponse SS.Count)
getCount =
  let apiP = Proxy :: Proxy ("simple_storage" :> SS.Api)
  in genClient (Proxy :: Proxy RPC.TendermintM) apiP def

user1 :: User
user1 = makeUser "f65255094d7773ed8dd417badc9fc045c1f80fdc5b2d25172b031ce6933e039a"
