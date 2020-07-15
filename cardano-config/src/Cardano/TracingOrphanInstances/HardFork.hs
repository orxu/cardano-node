{-# LANGUAGE DerivingStrategies    #-}
{-# LANGUAGE DeriveAnyClass        #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NamedFieldPuns        #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE TypeFamilies          #-}
{-# LANGUAGE UndecidableInstances  #-}
{-# LANGUAGE StandaloneDeriving    #-}
{-# LANGUAGE TypeOperators         #-}
{-# LANGUAGE TypeApplications      #-}

{-# OPTIONS_GHC -Wno-orphans  #-}

module Cardano.TracingOrphanInstances.HardFork () where

import           Cardano.Prelude hiding (All)

import           Data.Aeson
import           Data.SOP.Strict

import qualified Cardano.Crypto.Hash.Class as Crypto
import           Cardano.TracingOrphanInstances.Common
import           Cardano.TracingOrphanInstances.Consensus ()

import           Cardano.Slotting.Slot (EpochSize(..))
import           Ouroboros.Consensus.Block (BlockProtocol)
import           Ouroboros.Consensus.BlockchainTime (getSlotLength)
import           Ouroboros.Consensus.Protocol.Abstract
                   (ValidationErr, CannotLead, ChainIndepState)
import           Ouroboros.Consensus.Ledger.Abstract (LedgerError)
import           Ouroboros.Consensus.Ledger.Inspect (LedgerWarning)
import           Ouroboros.Consensus.Ledger.SupportsMempool
                   (GenTx, TxId, ApplyTxErr)
import           Ouroboros.Consensus.HeaderValidation
                   (OtherHeaderEnvelopeError)
import           Ouroboros.Consensus.HardFork.Combinator
import           Ouroboros.Consensus.HardFork.Combinator.AcrossEras
                   (OneEraValidationErr(..), OneEraLedgerError(..),
                   OneEraLedgerWarning(..),
                    OneEraEnvelopeErr(..), OneEraCannotLead(..),
                    EraMismatch(..), mkEraMismatch)
import           Ouroboros.Consensus.HardFork.History.EraParams
                   (EraParams(..), SafeZone, SafeBeforeEpoch)
import           Ouroboros.Consensus.TypeFamilyWrappers

import           Ouroboros.Consensus.Util.Condense (Condense(..))


--
-- instances for hashes
--

instance Condense (OneEraHash xs) where
    condense = condense . Crypto.UnsafeHash . getOneEraHash


--
-- instances for Header HardForkBlock
--

instance All (ToObject `Compose` Header) xs => ToObject (Header (HardForkBlock xs)) where
    toObject verb =
          hcollapse
        . hcmap (Proxy @ (ToObject `Compose` Header)) (K . toObject verb)
        . getOneEraHeader
        . getHardForkHeader


--
-- instances for GenTx HardForkBlock
--

instance All (Compose ToObject GenTx) xs => ToObject (GenTx (HardForkBlock xs)) where
    toObject verb =
          hcollapse
        . hcmap (Proxy @ (ToObject `Compose` GenTx)) (K . toObject verb)
        . getOneEraGenTx
        . getHardForkGenTx

instance  All (Compose ToJSON WrapGenTxId) xs => ToJSON (TxId (GenTx (HardForkBlock xs))) where
    toJSON =
          hcollapse
        . hcmap (Proxy @ (ToJSON `Compose` WrapGenTxId)) (K . toJSON)
        . getOneEraGenTxId
        . getHardForkGenTxId

instance ToJSON (TxId (GenTx blk)) => ToJSON (WrapGenTxId blk) where
    toJSON = toJSON . unwrapGenTxId


--
-- instances for GenTx HardForkBlock
--

{-
instance HasKESMetricsData (HardForkBlock xs) where
    getKESMetricsData :: ProtocolInfo m (HardForkBlock xs)
                      -> ForgeState (HardForkBlock xs)
                      -> KESMetricsData
    getKESMetricsData protoInfo forgeState =
-}

--
-- instances for HardForkApplyTxErr
--

instance All (ToObject `Compose` WrapApplyTxErr) xs => ToObject (HardForkApplyTxErr xs) where
    toObject verb (HardForkApplyTxErrFromEra err) = toObject verb err
    toObject _verb (HardForkApplyTxErrWrongEra mismatch) =
      mkObject
        [ "kind"       .= String "HardForkApplyTxErrWrongEra"
        , "currentEra" .= ledgerEraName
        , "txEra"      .= otherEraName
        ]
      where
        EraMismatch {ledgerEraName, otherEraName} = mkEraMismatch mismatch

instance All (ToObject `Compose` WrapApplyTxErr) xs => ToObject (OneEraApplyTxErr xs) where
    toObject verb =
        hcollapse
      . hcmap (Proxy @ (ToObject `Compose` WrapApplyTxErr)) (K . toObject verb)
      . getOneEraApplyTxErr

instance ToObject (ApplyTxErr blk) => ToObject (WrapApplyTxErr blk) where
    toObject verb = toObject verb . unwrapApplyTxErr


--
-- instances for HardForkLedgerError
--

instance All (ToObject `Compose` WrapLedgerErr) xs => ToObject (HardForkLedgerError xs) where
    toObject verb (HardForkLedgerErrorFromEra err) = toObject verb err

    toObject _verb (HardForkLedgerErrorWrongEra mismatch) =
      mkObject
        [ "kind"       .= String "HardForkLedgerErrorWrongEra"
        , "currentEra" .= ledgerEraName
        , "blockEra"   .= otherEraName
        ]
      where
        EraMismatch {ledgerEraName, otherEraName} = mkEraMismatch mismatch

instance All (ToObject `Compose` WrapLedgerErr) xs => ToObject (OneEraLedgerError xs) where
    toObject verb =
        hcollapse
      . hcmap (Proxy @ (ToObject `Compose` WrapLedgerErr)) (K . toObject verb)
      . getOneEraLedgerError

instance ToObject (LedgerError blk) => ToObject (WrapLedgerErr blk) where
    toObject verb = toObject verb . unwrapLedgerErr


--
-- instances for HardForkLedgerWarning
--

instance All (ToObject `Compose` WrapLedgerWarning) xs => ToObject (HardForkLedgerWarning xs) where
    toObject verb (HardForkLedgerWarningInEra err) = toObject verb err

    toObject verb (HardForkLedgerWarningUnexpectedTransition eraParams epoch) =
      mkObject
        [ "kind"            .= String "HardForkLedgerWarningUnexpectedTransition"
        , "eraParams"       .= toObject verb eraParams
        , "transitionEpoch" .= epoch
        ]

instance All (ToObject `Compose` WrapLedgerWarning) xs => ToObject (OneEraLedgerWarning xs) where
    toObject verb =
        hcollapse
      . hcmap (Proxy @ (ToObject `Compose` WrapLedgerWarning)) (K . toObject verb)
      . getOneEraLedgerWarning

instance ToObject (LedgerWarning blk) => ToObject (WrapLedgerWarning blk) where
    toObject verb = toObject verb . unwrapLedgerWarning

instance ToObject EraParams where
    toObject _verb EraParams{ eraEpochSize, eraSlotLength, eraSafeZone} =
      mkObject
        [ "epochSize"  .= unEpochSize eraEpochSize
        , "slotLength" .= getSlotLength eraSlotLength
        , "safeZone"   .= eraSafeZone
        ]

deriving instance ToJSON SafeZone
deriving instance ToJSON SafeBeforeEpoch


--
-- instances for HardForkEnvelopeErr
--

instance All (ToObject `Compose` WrapEnvelopeErr) xs => ToObject (HardForkEnvelopeErr xs) where
    toObject verb (HardForkEnvelopeErrFromEra err) = toObject verb err

    toObject _verb (HardForkEnvelopeErrWrongEra mismatch) =
      mkObject
        [ "kind"       .= String "HardForkEnvelopeErrWrongEra"
        , "currentEra" .= ledgerEraName
        , "blockEra"   .= otherEraName
        ]
      where
        EraMismatch {ledgerEraName, otherEraName} = mkEraMismatch mismatch

instance All (ToObject `Compose` WrapEnvelopeErr) xs => ToObject (OneEraEnvelopeErr xs) where
    toObject verb =
        hcollapse
      . hcmap (Proxy @ (ToObject `Compose` WrapEnvelopeErr)) (K . toObject verb)
      . getOneEraEnvelopeErr

instance ToObject (OtherHeaderEnvelopeError blk) => ToObject (WrapEnvelopeErr blk) where
    toObject verb = toObject verb . unwrapEnvelopeErr


--
-- instances for HardForkValidationErr
--

instance All (ToObject `Compose` WrapValidationErr) xs => ToObject (HardForkValidationErr xs) where
    toObject verb (HardForkValidationErrFromEra err) = toObject verb err

    toObject _verb (HardForkValidationErrWrongEra mismatch) =
      mkObject
        [ "kind"       .= String "HardForkValidationErrWrongEra"
        , "currentEra" .= ledgerEraName
        , "blockEra"   .= otherEraName
        ]
      where
        EraMismatch {ledgerEraName, otherEraName} = mkEraMismatch mismatch

instance All (ToObject `Compose` WrapValidationErr) xs => ToObject (OneEraValidationErr xs) where
    toObject verb =
        hcollapse
      . hcmap (Proxy @ (ToObject `Compose` WrapValidationErr)) (K . toObject verb)
      . getOneEraValidationErr

instance ToObject (ValidationErr (BlockProtocol blk)) => ToObject (WrapValidationErr blk) where
    toObject verb = toObject verb . unwrapValidationErr


--
-- instances for HardForkCannotLead
--

-- It's a type alias:
-- type HardForkCannotLead xs = OneEraCannotLead xs

instance All (ToObject `Compose` WrapCannotLead) xs => ToObject (OneEraCannotLead xs) where
    toObject verb =
        hcollapse
      . hcmap (Proxy @ (ToObject `Compose` WrapCannotLead))
              (K . toObject verb)
      . getOneEraCannotLead

instance ToObject (CannotLead (BlockProtocol blk)) => ToObject (WrapCannotLead blk) where
    toObject verb = toObject verb . unwrapCannotLead


--
-- instances for PerEraChainIndepState
--

instance All (ToObject `Compose` WrapChainIndepState) xs
      => ToObject (PerEraChainIndepState xs) where
  toObject verb =
      mconcat -- Mash all the eras together, hope they do not clash
    . hcollapse
    . hcmap (Proxy @ (ToObject `Compose` WrapChainIndepState))
            (K . toObject verb)
    . getPerEraChainIndepState

instance ToObject (ChainIndepState (BlockProtocol blk))
      => ToObject (WrapChainIndepState blk) where
    toObject verb = toObject verb . unwrapChainIndepState
