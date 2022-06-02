{- |
Module     : Property.Generator
Maintainer : seungheon.ooh@gmail.com
Description: Generic generators for property tests

Shared generators for all Agora property tests
-}
module Property.Generator (
  -- * Credentials
  genPubKeyHash,
  genUserCredential,
  genScriptCredential,
  genCredential,
  genAddress,

  -- * Values
  genValue,
  genAssetClass,
  genSingletonValue,
) where

import Control.Applicative (Applicative (liftA2))
import Data.ByteString.Char8 qualified as C (ByteString, pack)
import Data.ByteString.Hash (sha2)
import Plutus.V1.Ledger.Api (
  Address (Address),
  Credential (..),
  PubKeyHash (PubKeyHash),
  ValidatorHash (ValidatorHash),
  Value,
  toBuiltin,
 )
import Plutus.V1.Ledger.Value (
  AssetClass (AssetClass),
  assetClassValue,
  currencySymbol,
  tokenName,
 )
import Test.QuickCheck (
  Arbitrary (arbitrary),
  Gen,
  chooseAny,
  elements,
  listOf1,
  oneof,
 )

{- | Generate a random Hash
Hashs cannot be shrunken; functions utilizing this function,
therefore, cannot be shrunken as well.
-}
genHashByteString :: Gen C.ByteString
genHashByteString = sha2 . C.pack . show <$> (chooseAny :: Gen Integer)

-- TODO: How do I need to ensure uniqueness?

-- | Random PubKeyHash
genPubKeyHash :: Gen PubKeyHash
genPubKeyHash = PubKeyHash . toBuiltin <$> genHashByteString

-- | Random user credential.
genUserCredential :: Gen Credential
genUserCredential = PubKeyCredential . PubKeyHash . toBuiltin <$> genHashByteString

-- | Random script credential.
genScriptCredential :: Gen Credential
genScriptCredential = ScriptCredential . ValidatorHash . toBuiltin <$> genHashByteString

-- | Random credential: combination of user and script credential generators.
genCredential :: Gen Credential
genCredential = oneof [genUserCredential, genScriptCredential]

genAddress :: Gen Address
genAddress = flip Address Nothing <$> genCredential

{- | Random Value of given AssetClass
`genSingletonValue` will create a random value with a random assetclass.
-}
genValue :: AssetClass -> Gen Value
genValue ac = assetClassValue ac . abs <$> (arbitrary :: Gen Integer)

-- | Random bytestring but only with alphabets for better legibility.
genPrettyByteString :: Gen C.ByteString
genPrettyByteString = C.pack <$> listOf1 (elements ['a' .. 'z'])

-- | Random @AssetClass@ with pretty token name.
genAssetClass :: Gen AssetClass
genAssetClass =
  AssetClass
    <$> liftA2
      (,)
      (currencySymbol <$> genHashByteString)
      (tokenName <$> genPrettyByteString)

-- | Random *singleton* value with random @AssetClass@.
genSingletonValue :: Gen Value
genSingletonValue = genAssetClass >>= genValue