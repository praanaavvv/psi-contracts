// SPDX-License-Identifier: BSL-1.1
pragma solidity 0.8.31;

/// @title DataTypes
/// @notice Shared types for Psi  vault system
library DataTypes {
    // ============ Constants ============

    /// @notice Basis points denominator (100% = 10000)
    uint256 constant BPS_DENOM = 10_000;

    /// @notice Price scale for Twap prices (1e6 = 100%)
    uint256 constant PRICE_SCALE = 1e6;

    /// @notice Scale for yield index calculations (1e18 = 1.0)
    uint256 constant INDEX_SCALE = 1e18;

    // ============ Polymarket CTF Constants ============

    /// @notice Outcome slot index for the YES outcome
    uint256 constant YES_INDEX = 0;

    /// @notice Outcome slot index for the NO outcome
    uint256 constant NO_INDEX = 1;

    /// @notice Index set bitmask for the YES outcome (binary: 01)
    uint256 constant YES_INDEX_SET = 1;

    /// @notice Index set bitmask for the NO outcome (binary: 10)
    uint256 constant NO_INDEX_SET = 2;

    /// @notice Parent collection ID for top-level positions
    bytes32 constant PARENT_COLLECTION_ID = bytes32(0);

    // ============ Enums ============

    /// @notice Outcome side for deposits/withdrawals
    enum Side {
        YES,
        NO
    }

    // ============ Core Structs ============

    /// @notice Per-market state for accounting
    /// @dev Each market (conditionId) tracks yield indexes and pool state.
    ///      Gas-optimized: timestamps use uint40 (sufficient until year ~36,000),
    ///      TWAP accumulators use uint128 (sufficient for 10,000+ years at max price),
    ///      indexes use uint128 (sufficient: lossIndex maxes at 1e18, yieldPerShare has huge margin).
    ///      Storage layout: 10 slots.
    struct MarketState {
        // --- Full uint256 slots ---
        // Slot 0: Total ERC-1155 shares for YES side
        uint256 totalSharesYes;
        // Slot 1: Total ERC-1155 shares for NO side
        uint256 totalSharesNo;
        // Slot 2: Global pool share tracking
        uint256 marketPoolShares; // This market's share of the global Usdc pool
        // Slot 3: Principal tracking
        uint256 principalContributed; // Total Usdc principal from this market (for yield calculation)
        // Slot 4: Weighted snapshot sum for YES side (for accurate excess loss yield reduction)
        uint256 totalWeightedSnapshotYes; // Σ(user_shares × user_yieldSnapshotYes)
        // Slot 5: Weighted snapshot sum for NO side
        uint256 totalWeightedSnapshotNo; // Σ(user_shares × user_yieldSnapshotNo)
        // --- Packed uint128 pairs (32/32 bytes each) ---
        // Slot 6: Loss indexes packed (2 × uint128 = 256 bits)
        uint128 lossIndexYes; // Starts at INDEX_SCALE, only decreases on loss
        uint128 lossIndexNo;
        // Slot 7: Yield per share packed (2 × uint128 = 256 bits)
        uint128 yieldPerShareYes; // Starts at 0, only increases on gain
        uint128 yieldPerShareNo;
        // --- Partially filled slots ---
        // Slot 8: TWAP checkpoint + yield reduction factor (2 × uint128 = 256 bits)
        uint128 lastYieldTwapCheckpointYes; // Checkpoint when yield was last distributed (twapAccumulatorNo is implicit)
        uint128 yieldReductionFactor; // Starts at INDEX_SCALE, only decreases on excess loss
        // Slot 9: Timestamps (2 × uint40 = 80 bits, 176 bits unused)
        uint40 marketInitTimestamp; // Timestamp of market initialization
        uint40 lastYieldTimestamp; // Timestamp of last yield index update
    }

    /// @notice Token metadata stored on market initialization
    struct MarketTokenInfo {
        bytes32 conditionId;
        DataTypes.Side side;
    }

    /// @notice Per-user per-market state
    /// @dev User shares are tracked via ERC-1155 balanceOf in AccountingMixin.
    ///      Storage layout: 1 slot.
    struct UserMarketState {
        // Slot 1: Yield snapshots packed (2 × uint128 = 256 bits)
        uint128 yieldSnapshotYes; // yieldPerShareYes at last deposit/action
        uint128 yieldSnapshotNo; // yieldPerShareNo at last deposit/action
    }

    /// @notice External ERC-4626 vault configuration
    struct ExternalVault {
        address vault; // ERC-4626 vault address
        uint256 cap; // Max Usdc to deposit (0 = unlimited)
        bool active; // Can accept new deposits
        bool emergencyActivated; // Emergency mode for this specific vault (withdraws funds, prevents deposits)
    }

    /// @notice Twap data package for yield distribution
    /// @dev Signed by trusted backend to update price indexes
    struct TwapData {
        bool required; // Indicates what the off-chain component thinks about the twap requirement; will be checked to assure there is no race condition (requirement is enabled just after an empty twap was signed)
        bytes32 conditionId;
        uint256 startTimestamp; // Must before or equal to market's lastTwapUpdate
        uint256 endTimestamp; // Must be <= block.timestamp
        uint256 twapPriceYes; // Twap YES price (0 to PRICE_SCALE)
        uint256 marketEndedAt; // Optional: timestamp when market finalized (0 = not finalized)
        uint256 marketEndYesPrice; // Optional: final YES price after finalization (0 to PRICE_SCALE)
    }

    /// @notice Batch Twap data (single signature for multiple markets)
    /// @dev Used for batch operations to verify all Twaps with one signature
    struct BatchTwapData {
        TwapData[] markets;
        bytes signature; // ECDSA signature over hash of all TwapData
    }

    //Taken from Polymarket CTF Exchange
    enum SignatureType {
        // 0: ECDSA EIP712 signatures signed by EOAs
        EOA,
        // 1: EIP712 signatures signed by EOAs that own Polymarket Proxy wallets
        POLY_PROXY,
        // 2: EIP712 signatures signed by EOAs that own Polymarket Gnosis safes
        POLY_GNOSIS_SAFE
    }

    /// @notice Signed withdrawal authorization for off-chain execution
    /// @dev Allows users to pre-sign withdrawals that can be executed by anyone
    struct SignedWithdrawal {
        address signer; // Address of the signer
        address user; // Address of the wallet to withdraw from; Usually the user's proxy/safe wallet
        uint256 referralCode;
        bytes32 conditionId;
        uint256 yesShares; // YES shares to withdraw
        uint256 noShares; // NO shares to withdraw
        uint256 minYesTokens; // Minimum YES tokens expected (used with protectAgainstLoss)
        uint256 minNoTokens; // Minimum NO tokens expected (used with protectAgainstLoss)
        address yieldRecipient; // Address to receive the yield; If address(0), the yield will be sent to the user
        bool protectAgainstLoss; // If true, reverts if received tokens < minYesTokens/minNoTokens
        uint256 nonce; // Replay protection per user
        uint256 expiry; // Expiration timestamp
        DataTypes.SignatureType signatureType; // Type of signature
        bytes signature; // EIP-712 signature
    }

    /// @notice Cached Polymarket token info per market
    /// @dev Computed once on first deposit, cached for gas efficiency
    /// @dev Unpaired token amounts are read directly from CTF balanceOf() for gas efficiency
    struct PolymarketTokenInfo {
        uint256 yesPositionId; // ERC-1155 ID for YES outcome
        uint256 noPositionId; // ERC-1155 ID for NO outcome
        bool negRisk; // True if WCOL-backed (NegRisk), false if Usdc-backed
        address collateral; // Usdc or WCOL depending on negRisk
    }

    // ============ Initialization Params ============

    /// @notice Initialization parameters for PsiStakingVault
    /// @dev Used to avoid stack-too-deep in initialize()
    struct InitParams {
        address owner;
        address timelockController;
        uint256 protocolFeeBps;
        address ctf;
        address negRiskAdapter;
        address negRiskCtfExchange;
        address ctfExchange;
        address underlyingUsdc;
        address polymarketWcol;
        address twapOracle;
        address extension;
    }

    // ============ Helper Structs to keep Stack Depth Low ============

    /// @notice Temporary variables for batch deposit processing
    /// @dev Used to avoid stack-too-deep errors in _batchDeposit
    struct BatchDepositVars {
        uint256 len;
        uint256 totalPaired;
        uint256 nonZeroIndex;
        uint256[] ids;
        uint256[] amts;
        uint256[] yesShares;
        uint256[] noShares;
    }

    /// @notice Temporary variables for batch withdrawal processing
    /// @dev Used to avoid stack-too-deep errors in _batchWithdraw
    struct BatchWithdrawVars {
        uint256 len;
        uint256 totalUsdcNeeded;
        uint256 totalYield;
        uint256 nonZeroIndex;
        uint256[] ids;
        uint256[] amts;
    }

    /// @notice Result of burning shares during withdrawal for a single market
    /// @dev Captures token assets, yield, and USDC needed for splits
    struct WithdrawBurnResult {
        uint256 yesAssets; // YES outcome tokens to return
        uint256 noAssets; // NO outcome tokens to return
        uint256 totalNeeded; // Total USDC needed (split + yield)
        uint256 splitNeeded; // USDC needed to split into outcome token pairs
        uint256 yieldNeeded; // USDC needed for yield payout
    }

    /// @notice Local variables for yield/loss index calculation
    /// @dev Used to avoid stack-too-deep in _calculateIndexesWithPoolAssets
    struct YieldCalcLocals {
        uint256 principalContributed;
        uint256 totalSharesYes;
        uint256 totalSharesNo;
        bool isGain;
        uint256 delta;
        uint256 yesBaseline;
        uint256 noBaseline;
        uint256 twapAccumulatorYesDelta;
        uint256 timeDelta;
        uint256 yesDelta;
        uint256 noDelta;
        uint256 yesChange;
        uint256 noChange;
    }

    /// @notice Input parameters for index calculation in IndexCalcLib
    /// @dev Groups pool state, TWAP data, and timestamp to avoid stack-too-deep
    struct IndexCalcInput {
        uint256 totalPoolShares;
        uint256 totalPoolAssets;
        uint256 twapAccumulatorYes;
        uint256 lastTwapUpdate;
        uint256 twapPriceYes;
        uint256 currentTimestamp;
    }

    /// @notice Result of index calculation for a market
    /// @dev Contains all computed indexes and the market's current USDC value
    struct IndexResult {
        uint256 lossIndexYes; // Current YES loss index (decreases on loss)
        uint256 lossIndexNo; // Current NO loss index (decreases on loss)
        uint256 yieldPerShareYes; // Cumulative YES yield per share in USDC
        uint256 yieldPerShareNo; // Cumulative NO yield per share in USDC
        uint256 marketValue; // Market's current USDC value from the global pool
        uint256 yieldReductionFactor; // Factor to reduce yield claims when loss exceeds token backing
    }
}
