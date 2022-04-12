{-# LANGUAGE TemplateHaskell #-}

{- |
Module     : Agora.Effects.GovernorMutation
Maintainer : chfanghr@gmail.com
Description: An effect that mutates governor settings

An effect for mutating governor settings
-}
module Agora.Effects.GovernorMutation (mutateGovernorValidator, PMutateGovernorDatum (..), MutateGovernorDatum (..)) where

--------------------------------------------------------------------------------

import GHC.Generics qualified as GHC
import Generics.SOP (Generic, I (I))
import Prelude

--------------------------------------------------------------------------------

import Plutarch (popaque)
import Plutarch.Api.V1 (
  PMaybeData (PDJust),
  PTxOutRef,
  PValidator,
  PValue,
 )
import Plutarch.Builtin (pforgetData)
import Plutarch.DataRepr (
  DerivePConstantViaData (..),
  PDataFields,
  PIsDataReprInstances (PIsDataReprInstances),
 )
import Plutarch.Lift (PLifted, PUnsafeLiftDecl)
import Plutarch.Monadic qualified as P

--------------------------------------------------------------------------------

import Plutus.V1.Ledger.Api (TxOutRef)
import PlutusTx qualified

--------------------------------------------------------------------------------

import Agora.Effect (makeEffect)
import Agora.Governor (
  Governor,
  GovernorDatum,
  PGovernorDatum,
  authorityTokenSymbolFromGovernor,
  governorStateTokenAssetClass,
 )
import Agora.Utils (
  containsSingleCurrencySymbol,
  findOutputsToAddress,
  passert,
  passetClassValueOf',
  pfindDatum,
 )

--------------------------------------------------------------------------------

data MutateGovernorDatum = MutateGovernorDatum
  { governorRef :: TxOutRef
  , newDatum :: GovernorDatum
  }
  deriving stock (Show, GHC.Generic)
  deriving anyclass (Generic)

PlutusTx.makeIsDataIndexed ''MutateGovernorDatum [('MutateGovernorDatum, 0)]

--------------------------------------------------------------------------------

newtype PMutateGovernorDatum (s :: S)
  = PMutateGovernorDatum
      ( Term
          s
          ( PDataRecord
              '[ "governorRef" ':= PTxOutRef
               , "newDatum" ':= PGovernorDatum
               ]
          )
      )
  deriving stock (GHC.Generic)
  deriving anyclass (Generic)
  deriving anyclass (PIsDataRepr)
  deriving
    (PlutusType, PIsData, PDataFields)
    via (PIsDataReprInstances PMutateGovernorDatum)

instance PUnsafeLiftDecl PMutateGovernorDatum where type PLifted PMutateGovernorDatum = MutateGovernorDatum
deriving via (DerivePConstantViaData MutateGovernorDatum PMutateGovernorDatum) instance (PConstant MutateGovernorDatum)

--------------------------------------------------------------------------------

mutateGovernorValidator :: Governor -> ClosedTerm PValidator
mutateGovernorValidator gov = makeEffect gatSymbol $
  \_gatCs (datum :: Term _ PMutateGovernorDatum) _txOutRef txInfo' -> P.do
    let newDatum = pforgetData $ pfield @"newDatum" # datum
        pinnedGovernor = pfield @"governorRef" # datum

    txInfo <- pletFields @'["mint", "inputs", "outputs"] txInfo'

    passert "Nothing should be minted/burnt other than GAT" $
      containsSingleCurrencySymbol # txInfo.mint

    filteredInputs <-
      plet $
        pfilter
          # ( plam $ \inInfo ->
                let value = pfield @"value" #$ pfield @"resolved" # inInfo
                 in gstValueOf # value #== 1
            )
          # pfromData txInfo.inputs

    passert "Governor's state token must be moved" $
      plength # filteredInputs #== 1

    input <- plet $ phead # filteredInputs

    passert "Can only modify the pinned governor" $
      pfield @"outRef" # input #== pinnedGovernor

    let govAddress =
          pfield @"address"
            #$ pfield @"resolved"
            #$ pfromData input

    filteredOutputs <- plet $ findOutputsToAddress # pfromData txInfo' # govAddress

    passert "Exactly one output to the governor" $
      plength # filteredOutputs #== 1

    outputToGovernor <- plet $ phead # filteredOutputs

    passert "Governor's state token must stay at governor's address" $
      (gstValueOf #$ pfield @"value" # outputToGovernor) #== 1

    outputDatumHash' <- pmatch $ pfromData $ pfield @"datumHash" # outputToGovernor

    case outputDatumHash' of
      PDJust ((pfromData . (pfield @"_0" #)) -> outputDatumHash) -> P.do
        datum' <- pmatch $ pfindDatum # outputDatumHash # pfromData txInfo'
        case datum' of
          PJust datum -> P.do
            passert "Unexpected output datum" $
              pto datum #== newDatum

            popaque $ pconstant ()
          _ -> ptraceError "Output datum not found"
      _ -> ptraceError "Ouput to governor should have datum"
  where
    gatSymbol = authorityTokenSymbolFromGovernor gov
    gstAssetClass = governorStateTokenAssetClass gov

    gstValueOf :: Term s (PValue :--> PInteger)
    gstValueOf = passetClassValueOf' gstAssetClass
