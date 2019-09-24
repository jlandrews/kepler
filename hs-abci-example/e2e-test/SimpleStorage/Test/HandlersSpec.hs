module SimpleStorage.Test.HandlersSpec where

import           Control.Lens                         (to, (&), (.~), (^.))
import           Control.Lens.Wrapped                 (_Unwrapped', _Wrapped')
import           Data.Binary                          (decode, encode)
import           Data.ByteArray.Base64String          (Base64String)
import qualified Data.ByteArray.Base64String          as Base64
import qualified Data.ByteString.Lazy                 as LBS
import           Data.Int                             (Int32)
import           Data.ProtoLens                       (defMessage)
import           Data.ProtoLens.Encoding              (encodeMessage)
import           Data.Text                            (pack)
import           Network.ABCI.Server.App              (Request (..),
                                                       Response (..))
import qualified Network.ABCI.Types.Messages.Request  as Req
import qualified Network.ABCI.Types.Messages.Response as Resp
import           SimpleStorage.Application            (makeAppConfig,
                                                       transformHandler)
import           SimpleStorage.Handlers               (deliverTxH, queryH)
import           SimpleStorage.Logging
import           SimpleStorage.Types                  (UpdateCountTx (..))
import           Test.Hspec
import           Test.QuickCheck


spec :: Spec
spec = beforeAll (mkLogConfig "handler-spec" >>= makeAppConfig) $ do
  describe "SimpleStorage E2E - via handlers" $ do
    it "Can query the initial count and make sure it's 0" $ \cfg -> do
      let handle = transformHandler cfg . queryH
      (ResponseQuery queryResp) <- handle
        (RequestQuery $ defMessage ^. _Unwrapped' & Req._queryPath .~ "count")
      let foundCount = queryResp ^. Resp._queryValue . to decodeCount
      foundCount `shouldBe` 0
    it "Can update count and make sure it's increments" $ \cfg -> do
      genUsername <- pack . getPrintableString <$> generate arbitrary
      genCount    <- abs <$> generate arbitrary
      let
        handleDeliver = transformHandler cfg . deliverTxH
        handleQuery = transformHandler cfg . queryH
        updateTx = (defMessage ^. _Unwrapped') { updateCountTxUsername = genUsername
                                               , updateCountTxCount = genCount
                                               }
        encodedUpdateTx = Base64.fromBytes $ encodeMessage (updateTx ^. _Wrapped')
      (ResponseDeliverTx deliverResp) <- handleDeliver
        (  RequestDeliverTx
        $  defMessage
        ^. _Unwrapped'
        &  Req._deliverTxTx
        .~ encodedUpdateTx
        )
      (deliverResp ^. Resp._deliverTxCode) `shouldBe` 0
      (ResponseQuery queryResp) <- handleQuery
        (RequestQuery $ defMessage ^. _Unwrapped' & Req._queryPath .~ "count")
      let foundCount = queryResp ^. Resp._queryValue . to decodeCount
      foundCount `shouldBe` genCount

encodeCount :: Int32 -> Base64String
encodeCount = Base64.fromBytes . LBS.toStrict . encode

decodeCount :: Base64String -> Int32
decodeCount = decode . LBS.fromStrict . Base64.toBytes