{- |
Module     : Agora.Proposal.Scripts
Maintainer : emi@haskell.fyi
Description: Plutus Scripts for Proposals.

Plutus Scripts for Proposals.
-}
module Agora.Proposal.Scripts (
  proposalValidator,
  proposalPolicy,
) where

import Agora.Proposal (
  PProposalDatum (PProposalDatum),
  PProposalRedeemer (PAdvanceProposal, PCosign, PUnlock, PVote),
  PProposalStatus (PDraft, PFinished, PLocked, PVotingReady),
  PProposalVotes (PProposalVotes),
  ProposalStatus (Draft, Finished, Locked, VotingReady),
  pretractVotes,
  pwinner',
 )
import Agora.Proposal.Time (
  currentProposalTime,
  isDraftPeriod,
  isExecutionPeriod,
  isLockingPeriod,
  isVotingPeriod,
 )
import Agora.Stake (
  PStakeDatum,
  pextractVoteOption,
  pgetStakeRoles,
  pisIrrelevant,
  pisVoter,
 )
import Agora.Utils (
  pfromSingleton,
  pinsertUniqueBy,
  plistEqualsBy,
  pmapMaybe,
 )
import Plutarch.Api.V1 (PCredential, PCurrencySymbol)
import Plutarch.Api.V1.AssocMap (plookup)
import Plutarch.Api.V2 (
  PMintingPolicy,
  PScriptContext (PScriptContext),
  PScriptPurpose (PMinting, PSpending),
  PTxInInfo,
  PTxInfo (PTxInfo),
  PTxOut,
  PValidator,
 )
import Plutarch.Extra.AssetClass (PAssetClassData, passetClass, ptoScottEncoding)
import Plutarch.Extra.Category (PCategory (pidentity))
import Plutarch.Extra.Field (pletAll, pletAllC)
import "liqwid-plutarch-extra" Plutarch.Extra.List (pfindJust)
import "plutarch-extra" Plutarch.Extra.Map (pupdate)
import Plutarch.Extra.Maybe (
  passertPJust,
  pisJust,
  pjust,
  pmaybe,
  pnothing,
 )
import Plutarch.Extra.Ord (pfromOrdBy, psort)
import Plutarch.Extra.Record (mkRecordConstr, (.&), (.=))
import Plutarch.Extra.ScriptContext (
  pfindTxInByTxOutRef,
  pfromOutputDatum,
  pisTokenSpent,
  ptryFromOutputDatum,
 )
import Plutarch.Extra.Sum (PSum (PSum))
import "liqwid-plutarch-extra" Plutarch.Extra.TermCont (
  pguardC,
  pletC,
  pletFieldsC,
  pmatchC,
  ptryFromC,
 )
import Plutarch.Extra.Traversable (pfoldMap)
import Plutarch.Extra.Value (passetClassValueOf, psymbolValueOf)
import Plutarch.Unsafe (punsafeCoerce)

{- | Policy for Proposals.

     == What this policy does

     === For minting:

     - Governor is happy with mint.

       * The governor must do most of the checking for the validity of the
         transaction. For example, the governor must check that the datum
         is correct, and that the ST is correctly paid to the right validator.

     - Exactly 1 token is minted.

     === For burning:

     - This policy cannot be burned.

     == Arguments

     Following arguments should be provided(in this order):
     1. The assetclass of GST, see 'Agora.Governor.Scripts.governorPolicy'.

     @since 1.0.0
-}
proposalPolicy :: ClosedTerm (PAssetClassData :--> PMintingPolicy)
proposalPolicy =
  plam $ \gtAssetClass _redeemer ctx' -> unTermCont $ do
    PScriptContext ctx' <- pmatchC ctx'
    ctx <- pletAllC ctx'
    PTxInfo txInfo' <- pmatchC $ pfromData ctx.txInfo
    txInfo <- pletFieldsC @'["inputs", "mint"] txInfo'

    PMinting ownSymbol' <- pmatchC $ pfromData ctx.purpose
    let mintedProposalST =
          passetClassValueOf
            # (passetClass # (pfield @"_0" # ownSymbol') # pconstant "")
            # txInfo.mint

    pguardC "Governance state-thread token must move" $
      pisTokenSpent
        # (ptoScottEncoding # gtAssetClass)
        # txInfo.inputs

    pguardC "Minted exactly one proposal ST" $
      mintedProposalST #== 1

    pure $ popaque (pconstant ())

{- | Validation context for redeemers which witness multiple stake in the reference
      inputs.

     @since 1.0.0
-}
data PWitnessMultipleStakeContext (s :: S) = PWitnessMultipleStakeContext
  { totalAmount :: Term s PInteger
  , orderedOwners :: Term s (PList PCredential)
  }
  deriving stock
    ( -- | @since 1.0.0
      Generic
    )
  deriving anyclass
    ( -- | @since 1.0.0
      PlutusType
    )

-- | @since 1.0.0
instance DerivePlutusType PWitnessMultipleStakeContext where
  type DPTStrat _ = PlutusTypeScott

-- | @since 1.0.0
newtype PStakeInputsContext (s :: S) = PStakeInputsContext
  { inputStakes :: Term s (PList PStakeDatum)
  }
  deriving stock
    ( -- | @since 1.0.0
      Generic
    )
  deriving anyclass
    ( -- | @since 1.0.0
      PlutusType
    )

-- | @since 1.0.0
instance DerivePlutusType PStakeInputsContext where
  type DPTStrat _ = PlutusTypeNewtype

{- | The validator for Proposals.

     The documentation for various of the redeemers lives at 'Agora.Proposal.ProposalRedeemer'.

     == What this validator does

     === Voting/unlocking

     When voting and unlocking, the proposal must witness a state transition
     occuring in the relevant Stake. This transition must place a lock on
     the stake that is tagged with the right 'Agora.Proposal.ResultTag', and 'Agora.Proposal.ProposalId'.
     Note that only one proposal per transaction is supported.

     === Periods

     Most redeemers are time-sensitive.

     A list of all time-sensitive redeemers and their requirements:

     - 'Agora.Proposal.Vote' can only be used when both the status is in 'Agora.Proposal.VotingReady',
       and 'Agora.Proposal.Time.isVotingPeriod' is true.
     - 'Agora.Proposal.Cosign' can only be used when both the status is in 'Agora.Proposal.Draft',
       and 'Agora.Proposal.Time.isDraftPeriod' is true.
     - 'Agora.Proposal.AdvanceProposal' can only be used when the status can be advanced
       (see 'Agora.Proposal.AdvanceProposal' docs).
     - 'Agora.Proposal.Unlock' is always valid.

     == Arguments

     Following arguments should be provided(in this order):
     1. stake ST assetclass
     2. governor ST symbol
     3. proposal ST symbol
     4. maximum number of cosigners

     @since 1.0.0
-}
proposalValidator ::
  ClosedTerm
    ( PAssetClassData
        :--> PCurrencySymbol
        :--> PCurrencySymbol
        :--> PInteger
        :--> PValidator
    )
proposalValidator =
  plam $ \sstClass gstSymbol pstSymbol maximumCosigners datum redeemer ctx -> unTermCont $ do
    ctxF <- pletAllC ctx

    txInfo <- pletC $ pfromData ctxF.txInfo
    txInfoF <-
      pletFieldsC
        @'[ "referenceInputs"
          , "inputs"
          , "outputs"
          , "mint"
          , "datums"
          , "signatories"
          , "validRange"
          ]
        txInfo

    currentTime <- pletC $ currentProposalTime # txInfoF.validRange

    ----------------------------------------------------------------------------

    PSpending ((pfield @"_0" #) -> propsalInputRef) <-
      pmatchC $ pfromData ctxF.purpose

    let proposalInput =
          pfield @"resolved"
            #$ passertPJust
            # "Own input should present"
              #$ pfindTxInByTxOutRef
            # propsalInputRef
            # txInfoF.inputs

    proposalInputF <- pletFieldsC @'["address", "value"] proposalInput

    proposalInputDatum <- pfromData . fst <$> ptryFromC @(PAsData PProposalDatum) datum
    proposalInputDatumF <- pletAllC $ pto proposalInputDatum

    thresholdsF <- pletAllC proposalInputDatumF.thresholds
    currentStatus <- pletC $ pfromData $ proposalInputDatumF.status

    -- Own output is an output that
    --  * is sent to the address of the proposal validator
    --  * has an PST
    --  * has the same proposal id as the proposal input
    --
    -- We can handle only one proposal under current design.
    proposalOutputDatum <-
      pletC $
        passertPJust # "proposal input should present"
          #$ pfindJust
            # plam
              ( flip pletAll $ \outputF ->
                  let isProposalUTxO =
                        foldl1
                          (#&&)
                          [ ptraceIfFalse "Own by proposal validator" $
                              outputF.address #== proposalInputF.address
                          , ptraceIfFalse "Has proposal ST" $
                              psymbolValueOf # pstSymbol # outputF.value #== 1
                          ]

                      handleProposalUTxO =
                        -- Using inline datum to avoid O(n^2) lookup.
                        pfromData $
                          ptrace "Resolve proposal datum" $
                            pfromOutputDatum @(PAsData PProposalDatum)
                              # outputF.datum
                              # txInfoF.datums
                   in pif
                        isProposalUTxO
                        (pjust # handleProposalUTxO)
                        pnothing
              )
            # pfromData txInfoF.outputs

    --------------------------------------------------------------------------

    -- Handle stake inputs/outputs.

    -- Reslove stake datum if the given UTxO is a stake UTxO.
    getStakeDatum :: Term _ (PTxOut :--> PMaybe PStakeDatum) <-
      pletC $
        plam $
          flip (pletFields @'["value", "datum"]) $ \txOutF ->
            let isStakeUTxO =
                  -- A stake UTxO is a UTxO that carries SST.
                  passetClassValueOf
                    # (ptoScottEncoding # sstClass)
                    # txOutF.value
                    #== 1

                stake =
                  pfromData $
                    -- If we can't resolve the stake datum, error out.
                    passertPJust # "Stake datum should present"
                      -- Use inline datum to avoid extra map lookup.
                      #$ ptryFromOutputDatum @(PAsData PStakeDatum)
                      # txOutF.datum
                      # txInfoF.datums
             in pif isStakeUTxO (pjust # stake) pnothing

    spendStakes' :: Term _ ((PStakeInputsContext :--> PUnit) :--> PUnit) <-
      pletC $
        plam $
          let stakeInputs =
                pmapMaybe
                  # plam ((getStakeDatum #) . (pfield @"resolved" #))
                  # pfromData txInfoF.inputs

              ctx = pcon $ PStakeInputsContext stakeInputs
           in (# ctx)

    let spendStakes ::
          ( PStakeInputsContext _ ->
            TermCont _ ()
          ) ->
          Term _ POpaque
        spendStakes c = popaque $
          spendStakes' #$ plam $ \sctx ->
            unTermCont $ pmatchC sctx >>= c >> pure (pconstant ())

    -- Witness stakes in reference inputs.
    witnessStakes' ::
      Term
        s
        ( (PWitnessMultipleStakeContext :--> PUnit) :--> PUnit
        ) <-
      pletC $
        let updateCtx = plam $ \ctx' stake -> unTermCont $ do
              ctxF <- pmatchC ctx'

              stakeF <-
                pletFieldsC @'["stakedAmount", "owner"] $
                  pto stake

              pure $
                pcon $
                  PWitnessMultipleStakeContext
                    { totalAmount =
                        ctxF.totalAmount
                          + punsafeCoerce
                            (pfromData stakeF.stakedAmount)
                    , orderedOwners =
                        pcons # stakeF.owner
                          # ctxF.orderedOwners
                    }

            f :: Term _ (_ :--> PTxInInfo :--> _)
            f = plam $ \ctx' ((pfield @"resolved" #) -> txOut) ->
              let stakeDatum = getStakeDatum # txOut
                  updateCtx' = updateCtx # ctx'
               in pmaybe # ctx' # updateCtx' # stakeDatum

            sortOwners =
              plam $
                flip pmatch $
                  \ctxF ->
                    pcon $
                      ctxF
                        { orderedOwners = psort # ctxF.orderedOwners
                        }

            initialCtx = pcon $ PWitnessMultipleStakeContext 0 pnil

            ctx =
              sortOwners
                #$ pfoldl
                # f
                # initialCtx
                # txInfoF.referenceInputs
         in plam (# ctx)

    let witnessStakes ::
          ( PWitnessMultipleStakeContext _ ->
            TermCont _ ()
          ) ->
          Term _ POpaque
        witnessStakes c = popaque $
          witnessStakes' #$ plam $ \sctxF ->
            unTermCont $ pmatchC sctxF >>= c >> pure (pconstant ())

    ----------------------------------------------------------------------------

    proposalRedeemer <- fst <$> ptryFromC @PProposalRedeemer redeemer

    pure $
      popaque $
        pmatch proposalRedeemer $ \case
          PCosign _ -> spendStakes $ \sctxF -> do
            pguardC "Should be in draft state" $
              currentStatus #== pconstant Draft

            stakeF <-
              pletFieldsC @'["owner", "stakedAmount"] $
                ptrace "Exactly one stake input" $
                  pfromSingleton # sctxF.inputStakes

            let newCosigner = stakeF.owner

            updatedSigs <-
              pletC $
                ptrace "Update signature set" $
                  pinsertUniqueBy
                    # (pfromOrdBy # plam pfromData)
                    # newCosigner
                    # proposalInputDatumF.cosigners

            pguardC "Less cosigners than maximum limit" $
              plength # updatedSigs #< maximumCosigners

            pguardC "Meet minimum GT requirement" $
              pfromData thresholdsF.cosign #<= stakeF.stakedAmount

            let expectedDatum =
                  mkRecordConstr
                    PProposalDatum
                    ( #proposalId .= proposalInputDatumF.proposalId
                        .& #effects .= proposalInputDatumF.effects
                        .& #status .= proposalInputDatumF.status
                        .& #cosigners .= pdata updatedSigs
                        .& #thresholds .= proposalInputDatumF.thresholds
                        .& #votes .= proposalInputDatumF.votes
                        .& #timingConfig .= proposalInputDatumF.timingConfig
                        .& #startingTime .= proposalInputDatumF.startingTime
                    )

            pguardC "Signatures are correctly added to cosignature list" $
              proposalOutputDatum #== expectedDatum

          ----------------------------------------------------------------------

          PVote r -> spendStakes $ \sctxF -> do
            totalStakeAmount <-
              pletC $
                pto $
                  pfoldMap
                    # plam
                      ( \stake -> unTermCont $ do
                          stakeF <- pletFieldsC @'["stakedAmount", "lockedBy"] stake

                          pguardC "Same stake shouldn't vote on the same proposal twice" $
                            pnot
                              #$ pisVoter
                              #$ pgetStakeRoles
                                # proposalInputDatumF.proposalId
                                # stakeF.lockedBy

                          pure $ pcon $ PSum $ pfromData stakeF.stakedAmount
                      )
                    # sctxF.inputStakes

            pguardC "Exceed minimum amount" $
              thresholdsF.vote #< totalStakeAmount

            pguardC "Input proposal must be in VotingReady state" $
              currentStatus #== pconstant VotingReady

            pguardC "Proposal time should be wthin the voting period" $
              isVotingPeriod # proposalInputDatumF.timingConfig
                # proposalInputDatumF.startingTime
                #$ passertPJust
                # "Should be able to get current time"
                # currentTime

            -- Ensure the transaction is voting to a valid 'ResultTag'(outcome).
            PProposalVotes voteMap <- pmatchC proposalInputDatumF.votes
            voteFor <- pletC $ pfromData $ pfield @"resultTag" # r

            pguardC "Vote option should be valid" $
              pisJust #$ plookup # voteFor # voteMap

            let -- The amount of new votes should be the 'stakedAmount'.
                -- Update the vote counter of the proposal, and leave other stuff as is.
                expectedNewVotes =
                  pcon $
                    PProposalVotes $
                      pupdate
                        # plam
                          ( \votes ->
                              pcon $ PJust $ votes + pto totalStakeAmount
                          )
                        # voteFor
                        # pto (pfromData proposalInputDatumF.votes)

                expectedProposalOut =
                  mkRecordConstr
                    PProposalDatum
                    ( #proposalId .= proposalInputDatumF.proposalId
                        .& #effects .= proposalInputDatumF.effects
                        .& #status .= proposalInputDatumF.status
                        .& #cosigners .= proposalInputDatumF.cosigners
                        .& #thresholds .= proposalInputDatumF.thresholds
                        .& #votes .= pdata expectedNewVotes
                        .& #timingConfig .= proposalInputDatumF.timingConfig
                        .& #startingTime .= proposalInputDatumF.startingTime
                    )

            pguardC "Output proposal should be valid" $
              proposalOutputDatum #== expectedProposalOut

          -- Note that the output stake locks validation now happens in the
          -- stake validator.

          ----------------------------------------------------------------------

          PUnlock _ -> spendStakes $ \sctxF -> do
            let expectedVotes =
                  pfoldl
                    # plam
                      ( \votes stake -> unTermCont $ do
                          stakeF <-
                            pletFieldsC
                              @'["stakedAmount", "lockedBy"]
                              stake

                          stakeRoles <-
                            pletC $
                              pgetStakeRoles
                                # proposalInputDatumF.proposalId
                                # stakeF.lockedBy

                          pguardC "Stake input should be relevant" $
                            pnot #$ pisIrrelevant # stakeRoles

                          let canRetractVotes =
                                pisVoter # stakeRoles

                              voteCount =
                                pto $
                                  pfromData stakeF.stakedAmount

                              newVotes =
                                pretractVotes
                                  # (pextractVoteOption # stakeRoles)
                                  # voteCount
                                  # votes

                          pure $ pif canRetractVotes newVotes votes
                      )
                    # proposalInputDatumF.votes
                    # sctxF.inputStakes

                currentTime' =
                  passertPJust
                    # "Should be able to get current time"
                    # currentTime

                inVotingPeriod =
                  isVotingPeriod # proposalInputDatumF.timingConfig
                    # proposalInputDatumF.startingTime
                    # currentTime'

                -- The votes can only change when the proposal still allows voting.
                shouldUpdateVotes =
                  currentStatus #== pconstant VotingReady
                    #&& inVotingPeriod

            pguardC "Proposal output correct" $
              pif
                shouldUpdateVotes
                ( let -- Remove votes and leave other parts of the proposal as it.
                      expectedProposalOut =
                        mkRecordConstr
                          PProposalDatum
                          ( #proposalId .= proposalInputDatumF.proposalId
                              .& #effects .= proposalInputDatumF.effects
                              .& #status .= proposalInputDatumF.status
                              .& #cosigners .= proposalInputDatumF.cosigners
                              .& #thresholds .= proposalInputDatumF.thresholds
                              .& #votes .= pdata expectedVotes
                              .& #timingConfig .= proposalInputDatumF.timingConfig
                              .& #startingTime .= proposalInputDatumF.startingTime
                          )
                   in ptraceIfFalse "Update votes" $
                        expectedProposalOut #== proposalOutputDatum
                )
                -- No change to the proposal is allowed.
                ( ptraceIfFalse "Proposal unchanged" $
                    proposalOutputDatum #== proposalInputDatum
                )

          ----------------------------------------------------------------------

          PAdvanceProposal _ -> unTermCont $ do
            currentTime' <-
              pletC $
                passertPJust
                  # "Should be able to get current time"
                  # currentTime

            applyIs <- pletC $
              plam $ \f ->
                f
                  # proposalInputDatumF.timingConfig
                  # proposalInputDatumF.startingTime
                  # currentTime'
            let inDraftPeriod = applyIs # isDraftPeriod
                inVotingPeriod = applyIs # isVotingPeriod
                inExecutionPeriod = applyIs # isExecutionPeriod

            inLockedPeriod <- pletC $ applyIs # isLockingPeriod

            proposalOutputStatus <-
              pletC $
                pfromData $
                  pfield @"status" # pto proposalOutputDatum

            pguardC "Only status changes in the output proposal" $
              let expectedProposalOutputDatum =
                    mkRecordConstr
                      PProposalDatum
                      ( #proposalId .= proposalInputDatumF.proposalId
                          .& #effects .= proposalInputDatumF.effects
                          .& #status .= pdata proposalOutputStatus
                          .& #cosigners .= proposalInputDatumF.cosigners
                          .& #thresholds .= proposalInputDatumF.thresholds
                          .& #votes .= proposalInputDatumF.votes
                          .& #timingConfig .= proposalInputDatumF.timingConfig
                          .& #startingTime .= proposalInputDatumF.startingTime
                      )
               in proposalOutputDatum #== expectedProposalOutputDatum

            pure $
              pmatch currentStatus $ \case
                PDraft ->
                  witnessStakes $ \sctxF -> do
                    let notTooLate = inDraftPeriod

                    pmatchC notTooLate >>= \case
                      PTrue -> do
                        pguardC "More cosigns than minimum amount" $
                          punsafeCoerce (pfromData thresholdsF.toVoting) #< sctxF.totalAmount

                        pguardC "All new cosigners are witnessed by their Stake datums" $
                          plistEqualsBy
                            # plam (\x (pfromData -> y) -> x #== y)
                            # sctxF.orderedOwners
                            # proposalInputDatumF.cosigners

                        -- 'Draft' -> 'VotingReady'
                        pguardC "Proposal status set to VotingReady" $
                          proposalOutputStatus #== pconstant VotingReady
                      -- Too late: failed proposal, status set to 'Finished'.
                      PFalse ->
                        pguardC "Proposal should fail: not on time" $
                          proposalOutputStatus #== pconstant Finished

                ----------------------------------------------------------------

                PVotingReady -> unTermCont $ do
                  let notTooLate = inLockedPeriod
                      notTooEarly = pnot # inVotingPeriod

                  pguardC "Cannot advance ahead of time" notTooEarly

                  pmatchC notTooLate >>= \case
                    PTrue -> do
                      -- 'VotingReady' -> 'Locked'
                      pguardC "Proposal status set to Locked" $
                        proposalOutputStatus #== pconstant Locked

                      pguardC "Winner outcome not found" $
                        pisJust #$ pwinner' # proposalInputDatumF.votes
                          #$ punsafeCoerce
                          $ pfromData thresholdsF.execute
                    -- Too late: failed proposal, status set to 'Finished'.
                    PFalse ->
                      pguardC "Proposal should fail: not on time" $
                        proposalOutputStatus #== pconstant Finished

                  pure $ popaque $ pconstant ()

                ----------------------------------------------------------------

                PLocked -> unTermCont $ do
                  let notTooLate = inExecutionPeriod
                      notTooEarly = pnot # inLockedPeriod

                  pguardC "Not too early" notTooEarly

                  pguardC "Proposal status set to Finished" $
                    proposalOutputStatus #== pconstant Finished

                  let gstMoved =
                        pany
                          # plam
                            ( \( (pfield @"value" #)
                                  . (pfield @"resolved" #) ->
                                  value
                                ) ->
                                  psymbolValueOf # gstSymbol # value #== 1
                            )
                          # pfromData txInfoF.inputs

                  pguardC "GST not moved if too late, moved otherwise" $
                    pif
                      notTooLate
                      -- Not too late: GST should moved
                      pidentity
                      -- Not too late: GST should not moved
                      pnot
                      # gstMoved

                  pure $ popaque $ pconstant ()

                ----------------------------------------------------------------

                PFinished -> ptraceError "Finished proposals cannot be advanced"
