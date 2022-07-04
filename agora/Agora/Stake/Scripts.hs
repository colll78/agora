{- |
Module     : Agora.Stake.Scripts
Maintainer : emi@haskell.fyi
Description: Plutus Scripts for Stakes.

Plutus Scripts for Stakes.
-}
module Agora.Stake.Scripts (stakePolicy, stakeValidator) where

import Agora.SafeMoney (GTTag)
import Agora.Stake (
  PStakeDatum (PStakeDatum),
  PStakeRedeemer (
    PDepositWithdraw,
    PDestroy,
    PPermitVote,
    PRetractVotes
  ),
  Stake (gtClassRef, proposalSTClass),
  StakeRedeemer (WitnessStake),
  stakeLocked,
 )
import Agora.Utils (
  mustBePJust,
  mustFindDatum',
  pvalidatorHashToTokenName,
 )
import Data.Tagged (Tagged (..), untag)
import Plutarch.Api.V1 (
  AmountGuarantees (Positive),
  PCredential (PPubKeyCredential, PScriptCredential),
  PDatumHash,
  PMintingPolicy,
  PScriptPurpose (PMinting, PSpending),
  PTokenName,
  PTxInfo,
  PTxOut,
  PValidator,
  PValue,
  mintingPolicySymbol,
  mkMintingPolicy,
 )
import Plutarch.Api.V1.AssetClass (passetClass, passetClassValueOf, pvalueOf)
import Plutarch.Api.V1.ScriptContext (pfindTxInByTxOutRef, ptxSignedBy, pvalueSpent)
import "liqwid-plutarch-extra" Plutarch.Api.V1.Value (pgeqByClass', pgeqBySymbol, psymbolValueOf)
import Plutarch.Extra.List (pmapMaybe, pmsortBy)
import Plutarch.Extra.Maybe (pfromDJust)
import Plutarch.Extra.Record (mkRecordConstr, (.&), (.=))
import Plutarch.Extra.TermCont (pguardC, pletC, pletFieldsC, pmatchC, ptryFromC)
import Plutarch.Internal (punsafeCoerce)
import Plutarch.Numeric.Additive (AdditiveMonoid (zero), AdditiveSemigroup ((+)))
import Plutarch.SafeMoney (
  pdiscreteValue',
  pvalueDiscrete',
 )
import PlutusLedgerApi.V1.Value (AssetClass (AssetClass))
import Prelude hiding (Num (..))

{- | Policy for Stake state threads.

   == What this Policy does

   === For minting:

   - Check that exactly one state thread is minted.
   - Check that an output exists with a state thread and a valid datum.
   - Check that no state thread is an input.
   - assert @'PlutusLedgerApi.V1.TokenName' == 'PlutusLedgerApi.V1.ValidatorHash'@
     of the script that we pay to.

   === For burning:

   - Check that exactly one state thread is burned.
   - Check that datum at state thread is valid and not locked.

   @since 0.1.0
-}
stakePolicy ::
  -- | The (governance) token that a Stake can store.
  Tagged GTTag AssetClass ->
  ClosedTerm PMintingPolicy
stakePolicy gtClassRef =
  plam $ \_redeemer ctx' -> unTermCont $ do
    ctx <- pletFieldsC @'["txInfo", "purpose"] ctx'
    txInfo <- pletC $ ctx.txInfo
    let _a :: Term _ PTxInfo
        _a = txInfo
    txInfoF <- pletFieldsC @'["mint", "inputs", "outputs", "signatories", "datums"] txInfo

    PMinting ownSymbol' <- pmatchC $ pfromData ctx.purpose
    ownSymbol <- pletC $ pfield @"_0" # ownSymbol'
    spentST <- pletC $ psymbolValueOf # ownSymbol #$ pvalueSpent # txInfoF.inputs
    mintedST <- pletC $ psymbolValueOf # ownSymbol # txInfoF.mint

    let burning = unTermCont $ do
          pguardC "ST at inputs must be 1" $
            spentST #== 1

          pguardC "ST burned" $
            mintedST #== -1

          pguardC "An unlocked input existed containing an ST" $
            pany
              # plam
                ( \((pfield @"resolved" #) -> txOut) -> unTermCont $ do
                    txOutF <- pletFieldsC @'["value", "datumHash"] txOut
                    pure $
                      pif
                        (psymbolValueOf # ownSymbol # txOutF.value #== 1)
                        ( let datum = mustFindDatum' @PStakeDatum # txOutF.datumHash # txInfoF.datums
                           in pnot # (stakeLocked # datum)
                        )
                        (pconstant False)
                )
              # pfromData txInfoF.inputs

          pure $ popaque (pconstant ())

    let minting = unTermCont $ do
          pguardC "ST at inputs must be 0" $
            spentST #== 0

          pguardC "Minted ST must be exactly 1" $
            mintedST #== 1

          pguardC "A UTXO must exist with the correct output" $
            unTermCont $ do
              let scriptOutputWithStakeST =
                    mustBePJust
                      # "Output to script not found"
                        #$ pfind
                      # plam
                        ( \output -> unTermCont $ do
                            outputF <- pletFieldsC @'["value", "address"] output
                            pure $
                              pmatch (pfromData $ pfield @"credential" # outputF.address) $ \case
                                -- Should pay to a script address
                                PPubKeyCredential _ -> pcon PFalse
                                PScriptCredential ((pfield @"_0" #) -> validatorHash) ->
                                  let tn :: Term _ PTokenName
                                      tn = pvalidatorHashToTokenName validatorHash
                                   in pvalueOf # outputF.value # ownSymbol # tn #== 1
                        )
                      # pfromData txInfoF.outputs

              outputF <-
                pletFieldsC @'["value", "address", "datumHash"] scriptOutputWithStakeST
              datumF <-
                pletFieldsC @'["owner", "stakedAmount"] $
                  mustFindDatum' @PStakeDatum # outputF.datumHash # txInfoF.datums

              let hasExpectedStake =
                    ptraceIfFalse "Stake ouput has expected amount of stake token" $
                      pvalueDiscrete' gtClassRef # outputF.value #== datumF.stakedAmount
              let ownerSignsTransaction =
                    ptraceIfFalse "Stake Owner should sign the transaction" $
                      ptxSignedBy
                        # txInfoF.signatories
                        # datumF.owner

              pure $ hasExpectedStake #&& ownerSignsTransaction

          pure $ popaque (pconstant ())

    pure $ pif (0 #< mintedST) minting burning

--------------------------------------------------------------------------------

{- | Validator intended for Stake UTXOs to be locked by.

     == What this Validator does:

     === 'DepositWithdraw'

     Deposit or withdraw some GT to the stake.

     - Tx must be signed by the owner.
     - The 'stakedAmount' field must be updated.
     - The stake must not be locked.
     - The new UTXO must have the previous value plus the difference
       as stated by the redeemer.

     === 'PermitVote'

     Allow a 'ProposalLock' to be put on the stake in order to vote
     on a proposal.

     - A proposal token must be spent alongside the stake.

       * Its total votes must be correctly updated to include this stake's
         contribution.

     - Tx must be signed by the owner.

     === 'RetractVotes'

     Remove a 'ProposalLock' set when voting on a proposal.

     - A proposal token must be spent alongside the stake.
     - Tx must be signed by the owner.

     === 'Destroy'

     Destroy the stake in order to reclaim the min ADA.

     - The stake must not be locked.
     - Tx must be signed by the owner.

     === 'WitnessStake'

     Allow this Stake to be included in a transaction without making
     any changes to it. In the future,
     this could use [CIP-31](https://cips.cardano.org/cips/cip31/) instead.

     - Tx must be signed by the owner __or__ a proposal ST token must be spent
       alongside the stake.
     - The datum and value must remain unchanged.

     @since 0.1.0
-}
stakeValidator :: Stake -> ClosedTerm PValidator
stakeValidator stake =
  plam $ \datum redeemer ctx' -> unTermCont $ do
    ctx <- pletFieldsC @'["txInfo", "purpose"] ctx'
    txInfo <- pletC $ pfromData ctx.txInfo
    txInfoF <-
      pletFieldsC
        @'[ "mint"
          , "inputs"
          , "outputs"
          , "signatories"
          , "datums"
          ]
        txInfo

    (pfromData -> stakeRedeemer, _) <- ptryFromC redeemer

    -- TODO: Use PTryFrom
    let stakeDatum' :: Term _ PStakeDatum
        stakeDatum' = pfromData $ punsafeCoerce datum
    stakeDatum <- pletFieldsC @'["owner", "stakedAmount", "lockedBy"] stakeDatum'

    PSpending txOutRef <- pmatchC $ pfromData ctx.purpose

    PJust ((pfield @"resolved" #) -> resolved) <-
      pmatchC $
        pfindTxInByTxOutRef
          # (pfield @"_0" # txOutRef)
          # txInfoF.inputs
    resolvedF <- pletFieldsC @'["address", "value", "datumHash"] resolved

    -- Whether the owner signs this transaction or not.
    ownerSignsTransaction <- pletC $ ptxSignedBy # txInfoF.signatories # stakeDatum.owner

    stCurrencySymbol <-
      pletC $
        pconstant $
          mintingPolicySymbol $
            mkMintingPolicy (stakePolicy stake.gtClassRef)
    mintedST <- pletC $ psymbolValueOf # stCurrencySymbol # txInfoF.mint
    valueSpent <- pletC $ pvalueSpent # txInfoF.inputs
    spentST <- pletC $ psymbolValueOf # stCurrencySymbol #$ valueSpent

    -- Is the stake currently locked?
    stakeIsLocked <- pletC $ stakeLocked # stakeDatum'

    pure $
      pmatch stakeRedeemer $ \case
        PDestroy _ -> unTermCont $ do
          pguardC "ST at inputs must be 1" $
            spentST #== 1

          pguardC "Should burn ST" $
            mintedST #== -1

          pguardC "Stake unlocked" $ pnot # stakeIsLocked

          pguardC "Owner signs this transaction" ownerSignsTransaction

          pure $ popaque (pconstant ())
        ------------------------------------------------------------------------
        -- Handle redeemers that require own stake output.

        _ -> unTermCont $ do
          let AssetClass (propCs, propTn) = stake.proposalSTClass
              proposalSTClass = passetClass # pconstant propCs # pconstant propTn
              spentProposalST = passetClassValueOf # valueSpent # proposalSTClass

          proposalTokenMoved <- pletC $ spentProposalST #== 1

          -- Filter out own outputs using own address and ST.
          ownOutputs <-
            pletC $
              pfilter
                # plam
                  ( \output -> unTermCont $ do
                      outputF <- pletFieldsC @'["address", "value"] output

                      pure $
                        outputF.address #== resolvedF.address
                          #&& psymbolValueOf # stCurrencySymbol # outputF.value #== 1
                  )
                # pfromData txInfoF.outputs

          let witnessStake = unTermCont $ do
                pguardC "Either owner signs the transaction or propsoal token moved" $
                  ownerSignsTransaction #|| proposalTokenMoved

                -- FIXME: refactor this with reference input, once it's supported by plutarch.
                --
                -- Our goal here is to allow multiple input stakes, and also ensure that every the input stakes has a
                --   corresponding output stake, which carries the same value and the same datum as the input stake.
                --
                -- Validation strategy I have tried/considered so far:
                -- 1. Check that the number of input stakes equals to the number of output stakes, and verify
                --     that there's an output stake with the exact same value and datum hash as the stake being
                --     validated , However this approach has a fatal vulnerability: let's say we have two totally
                --     identical stakes, a malicious user can comsume these two stakes and remove GTs from one of them.
                -- 2. Perform the same checks as the last approch does, while also checking that every output stake is
                --     valid(stakedAmount == actual value). However this requires that all the output stake datum are
                --     included in the transaction, and we have to find and go through them one by one to access the
                --      'stakedAmount' fields, meaning that computationally this approach is *very* expensive.
                -- 3. The one implemented below. Find all the continuous input/output, sort them by 'datumHash', and
                --     ensure that the two sorted lists are equal.
                let ownInputs =
                      pmapMaybe
                        # plam
                          ( \input -> plet (pfield @"resolved" # input) $ \resolvedInput ->
                              let value = pfield @"value" # resolvedInput
                               in pif
                                    (psymbolValueOf # stCurrencySymbol # value #== 1)
                                    (pcon $ PJust resolvedInput)
                                    (pcon PNothing)
                          )
                        # pfromData txInfoF.inputs

                    sortTxOuts :: Term _ (PBuiltinList (PAsData PTxOut) :--> PBuiltinList (PAsData PTxOut))
                    sortTxOuts =
                      plam
                        ( pmsortBy
                            # plam
                              ( \((getDatumHash #) -> dhX)
                                 ((getDatumHash #) -> dhY) -> dhX #< dhY
                              )
                            #
                        )
                      where
                        getDatumHash :: Term _ (PAsData PTxOut :--> PDatumHash)
                        getDatumHash = phoistAcyclic $ plam ((pfromDJust #) . pfromData . (pfield @"datumHash" #))

                    sortedOwnInputs = sortTxOuts # ownInputs
                    sortedOwnOutputs = sortTxOuts # ownOutputs

                pguardC "Every stake inputs has a corresponding unchanged output" $
                  plistEquals # sortedOwnInputs # sortedOwnOutputs

                pure $ popaque $ pconstant ()

          ----------------------------------------------------------------------

          let onlyAcceptOneStake = unTermCont $ do
                pguardC "ST at inputs must be 1" $
                  spentST #== 1

                ownOutput <- pletC $ pfromData $ phead # ownOutputs

                stakeOut <-
                  pletC $
                    mustFindDatum' @PStakeDatum
                      # (pfield @"datumHash" # ownOutput)
                      # txInfoF.datums

                ownOutputValue <-
                  pletC $
                    pfield @"value" # ownOutput

                ownOutputValueUnchanged <-
                  pletC $
                    pdata resolvedF.value #== pdata ownOutputValue

                pure $
                  pmatch stakeRedeemer $ \case
                    PRetractVotes l -> unTermCont $ do
                      pguardC
                        "Owner signs this transaction"
                        ownerSignsTransaction

                      -- This puts trust into the Proposal. The Proposal must necessarily check
                      -- that this is not abused.
                      pguardC "Proposal ST spent" proposalTokenMoved

                      pguardC "A UTXO must exist with the correct output" $
                        let expectedLocks = pfield @"locks" # l

                            expectedDatum =
                              mkRecordConstr
                                PStakeDatum
                                ( #stakedAmount .= stakeDatum.stakedAmount
                                    .& #owner .= stakeDatum.owner
                                    .& #lockedBy .= expectedLocks
                                )

                            valueCorrect = ownOutputValueUnchanged
                            outputDatumCorrect = stakeOut #== expectedDatum
                         in foldl1
                              (#&&)
                              [ ptraceIfFalse "valueCorrect" valueCorrect
                              , ptraceIfFalse "datumCorrect" outputDatumCorrect
                              ]

                      pure $ popaque (pconstant ())

                    ------------------------------------------------------------

                    PPermitVote l -> unTermCont $ do
                      pguardC
                        "Owner signs this transaction"
                        ownerSignsTransaction

                      -- This puts trust into the Proposal. The Proposal must necessarily check
                      -- that this is not abused.
                      pguardC "Proposal ST spent" proposalTokenMoved

                      -- Update the stake datum, but only the 'lockedBy' field.

                      let -- We actually don't know whether the given lock is valid or not.
                          -- This is checked in the proposal validator.
                          newLock = pfield @"lock" # l
                          -- Prepend the new lock to the existing locks.
                          expectedLocks = pcons # newLock # stakeDatum.lockedBy

                      expectedDatum <-
                        pletC $
                          mkRecordConstr
                            PStakeDatum
                            ( #stakedAmount .= stakeDatum.stakedAmount
                                .& #owner .= stakeDatum.owner
                                .& #lockedBy .= pdata expectedLocks
                            )

                      pguardC "A UTXO must exist with the correct output" $
                        let correctOutputDatum = stakeOut #== expectedDatum
                            valueCorrect = ownOutputValueUnchanged
                         in foldl1
                              (#&&)
                              [ ptraceIfFalse "valueCorrect" valueCorrect
                              , ptraceIfFalse "datumCorrect" correctOutputDatum
                              ]

                      pure $ popaque (pconstant ())

                    ------------------------------------------------------------

                    PDepositWithdraw r -> unTermCont $ do
                      pguardC "Stake unlocked" $
                        pnot #$ stakeIsLocked
                      pguardC
                        "Owner signs this transaction"
                        ownerSignsTransaction
                      pguardC "A UTXO must exist with the correct output" $
                        unTermCont $ do
                          let oldStakedAmount = pfromData $ stakeDatum.stakedAmount
                              delta = pfromData $ pfield @"delta" # r

                          newStakedAmount <- pletC $ oldStakedAmount + delta

                          pguardC "New staked amount shoudl be greater than or equal to 0" $
                            zero #<= newStakedAmount

                          let expectedDatum =
                                mkRecordConstr
                                  PStakeDatum
                                  ( #stakedAmount .= pdata newStakedAmount
                                      .& #owner .= stakeDatum.owner
                                      .& #lockedBy .= stakeDatum.lockedBy
                                  )
                              datumCorrect = stakeOut #== expectedDatum

                          let valueDelta :: Term _ (PValue _ 'Positive)
                              valueDelta = pdiscreteValue' stake.gtClassRef # delta

                              expectedValue =
                                resolvedF.value <> valueDelta

                              valueCorrect =
                                foldr1
                                  (#&&)
                                  [ pgeqByClass' (AssetClass ("", ""))
                                      # ownOutputValue
                                      # expectedValue
                                  , pgeqByClass' (untag stake.gtClassRef)
                                      # ownOutputValue
                                      # expectedValue
                                  , pgeqBySymbol
                                      # stCurrencySymbol
                                      # ownOutputValue
                                      # expectedValue
                                  ]
                          --
                          pure $
                            foldl1
                              (#&&)
                              [ ptraceIfFalse "valueCorrect" valueCorrect
                              , ptraceIfFalse "datumCorrect" datumCorrect
                              ]
                      --
                      pure $ popaque (pconstant ())
                    _ -> popaque (pconstant ())

          pure $
            pif
              (pdata stakeRedeemer #== pconstantData WitnessStake)
              witnessStake
              onlyAcceptOneStake
