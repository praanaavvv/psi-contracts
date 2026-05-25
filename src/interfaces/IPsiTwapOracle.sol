// SPDX-License-Identifier: BSL-1.1
pragma solidity 0.8.31;

import { DataTypes } from '../types/DataTypes.sol';

/// @title IPsiTwapOracle
/// @notice Interface for the Psi Twap Oracle
interface IPsiTwapOracle {
    // ============ Errors ============

    error ZeroAddress();

    error ZeroAmount();

    error MarketNotInitialized(bytes32 conditionId);

    /// @notice Thrown when Twap is required but not provided
    error TwapRequired(bytes32 conditionId);

    /// @notice Thrown when Twap signature is invalid
    error InvalidTwapSignature();

    /// @notice Thrown when Twap timestamps are invalid
    error TwapTimestampInvalid(uint256 start, uint256 end, uint256 expected);

    /// @notice Thrown when Twap price is out of valid range
    error TwapPriceOutOfRange(uint256 price);

    /// @notice Thrown when Twap conditionId doesn't match expected
    error TwapConditionMismatch(bytes32 expected, bytes32 provided);

    // ============ Events ============
    event MarketInitialized(bytes32 indexed conditionId, uint256 yesPositionId, uint256 noPositionId, bool negRisk);

    /// @notice Emitted when trusted Twap signer is updated
    event TwapSignerUpdated(address indexed oldSigner, address indexed newSigner);

    /// @notice Emitted when Twap requirement is changed for a market
    event MarketTwapRequirementUpdated(bytes32 indexed conditionId, bool required);

    /// @notice Emitted when default TWAP requirement for new markets is updated
    event DefaultTwapRequiredUpdated(bool required);

    /// @notice Emitted when global TWAP required flag is updated
    event GlobalTwapRequiredUpdated(bool required);

    /// @notice Emitted when global TWAP disabled flag is updated
    event GlobalTwapDisabledUpdated(bool disabled);

    /// @notice Emitted when Twap accumulators are updated for a market
    event TwapUpdated(bytes32 indexed conditionId, uint256 twapAccumulatorYes, uint256 timestamp);

    /// @notice Emitted when a market is finalized with a fixed price
    event MarketFinalized(bytes32 indexed conditionId, uint256 marketEndedAt, uint256 marketEndYesPrice);

    // ============ Structs ============
    struct MarketState {
        // Slot 0: TWAP & price data (uint128 + uint64 + bool = 25/32 bytes)
        uint128 twapAccumulatorYes; // Accumulates: twapPriceYes × timeDelta
        bool twapRequired; // If false, treat as 50:50 split (default)
        uint64 marketEndYesPrice; // Final YES price when finalized (0 to PRICE_SCALE); Usually 0ct or 100ct, but could be 50ct
        // Slot 1: Timestamps (3×uint40 = 15/32 bytes)
        uint40 marketEndedAt; // Timestamp when market was finalized (0 = not finalized)
        uint40 marketInitTimestamp; // Timestamp when market was initialized
        uint40 lastTwapUpdate; // Timestamp of last Twap update
    }

    /// @notice Get the EIP-712 domain separator
    /// @return The EIP-712 domain separator
    function domainSeparator() external view returns (bytes32);

    /// @notice Get the trusted Twap signer address
    /// @return The address of the trusted Twap signer
    function getTwapSigner() external view returns (address);

    /// @notice Check if a market is initialized
    /// @param conditionId Market condition ID
    /// @return True if the market is initialized
    function isMarketInitialized(bytes32 conditionId) external view returns (bool);

    /// @notice Get market state for a condition
    /// @param conditionId Market condition ID
    /// @return The market state
    function getMarketState(bytes32 conditionId) external view returns (MarketState memory);

    /// @notice Check if a market is finalized
    /// @param conditionId Market condition ID
    /// @return True if the market is finalized
    function isMarketFinalized(bytes32 conditionId) external view returns (bool);

    /// @notice Get Twap price accumulators for a market
    /// @param conditionId Market condition ID
    /// @return twapAccumulatorYes YES side Twap accumulator
    /// @return twapAccumulatorNo NO side Twap accumulator
    /// @return lastUpdate Last Twap update time
    function getTwapAccumulators(bytes32 conditionId)
        external
        view
        returns (uint256 twapAccumulatorYes, uint256 twapAccumulatorNo, uint256 lastUpdate);

    /// @notice Get current Twap accumulator for a market, extrapolated to the current time if possible
    /// @param conditionId Market condition ID
    /// @return twapAccumulatorYes YES side Twap accumulator
    /// @return lastUpdate Last Twap update time
    function getCurrentTwapAccumulator(bytes32 conditionId) external view returns (uint256 twapAccumulatorYes, uint256 lastUpdate);

    /// @notice Batch query market state and signature requirements for multiple markets
    /// @param conditionIds Array of market condition IDs
    /// @return states Array of market states
    /// @return signatureRequired Array of whether a TWAP signature is required per market
    function batchGetMarketState(bytes32[] calldata conditionIds) external view returns (MarketState[] memory states, bool[] memory signatureRequired);

    /// @notice Submit valid signed Twap to advance accumulators (no deposit/withdraw)
    /// @param twapData Signed Twap data
    function submitTwap(DataTypes.BatchTwapData calldata twapData) external;

    // ============ TWAP Configuration ============

    /// @notice Get default TWAP requirement for new markets
    /// @return True if newly initialized markets require TWAP by default
    function getDefaultTwapRequired() external view returns (bool);

    /// @notice Get global TWAP required flag (forces TWAP for all markets)
    /// @return True if TWAP is required for all markets regardless of individual settings
    function getGlobalTwapRequired() external view returns (bool);

    /// @notice Get global TWAP disabled flag (disables TWAP for all markets)
    /// @return True if TWAP is disabled for all markets (highest priority, overrides everything)
    function getGlobalTwapDisabled() external view returns (bool);

    /// @notice Check if a market has TWAP required
    /// @param conditionId Market condition ID
    /// @return True if the market has TWAP required
    function isMarketTwapRequired(bytes32 conditionId) external view returns (bool);

    /// @notice Check effective TWAP requirement for a market
    /// @param conditionId Market condition ID
    /// @return True if twap is effectively required for the market based on global and market twapRequired settings
    function isEffectiveTwapRequired(bytes32 conditionId) external view returns (bool);

    /// @notice Check if a Twap signature is required for a market
    /// @param conditionId Market condition ID
    /// @return True if a Twap signature is required for the market (based on effective twapRequired and market finalization)
    function isTwapSignatureRequired(bytes32 conditionId) external view returns (bool);

    // ============ Market Management ============

    /// @notice Initialize a market on the oracle (restricted to VAULT_ROLE)
    /// @param conditionId Market condition ID
    /// @param yesPositionId YES position ID
    /// @param noPositionId NO position ID
    /// @param negRisk True if the market is a negRisk market
    function initializeMarket(bytes32 conditionId, uint256 yesPositionId, uint256 noPositionId, bool negRisk) external;

    // ============ Pausable Functions ============
    /// @notice Pause the Twap Oracle
    function pause() external;

    /// @notice Unpause the Twap Oracle
    function unpause() external;

    // ============ Configuration Functions ============

    /// @notice Set default TWAP requirement for new markets
    function setDefaultTwapRequired(bool required) external;

    /// @notice Set global TWAP required flag (forces TWAP for all markets)
    function setGlobalTwapRequired(bool required) external;

    /// @notice Set global TWAP disabled flag (disables TWAP for all markets)
    function setGlobalTwapDisabled(bool disabled) external;

    /// @notice Set the trusted Twap signer
    function setTwapSigner(address newSigner) external;

    // ============ Roles ============

    /// @notice Role for managing TWAP configuration
    /// forge-lint: disable-next-line(mixed-case-function)
    function DEFAULT_MANAGER_ROLE() external view returns (bytes32);

    /// @notice Role for timelocked operations (upgrades)
    /// forge-lint: disable-next-line(mixed-case-function)
    function TIMELOCKED_ROLE() external view returns (bytes32);

    /// @notice Role for the vault to initialize markets
    /// forge-lint: disable-next-line(mixed-case-function)
    function VAULT_ROLE() external view returns (bytes32);

    // ============ Constants ============

    /// @notice EIP-712 type hash for individual Twap data
    /// @return The EIP-712 type hash for individual Twap data
    /// forge-lint: disable-next-line(mixed-case-function)
    function TWAP_TYPEHASH() external view returns (bytes32);

    /// @notice EIP-712 type hash for batch Twap data (standard EIP-712 nested struct encoding)
    /// @return The EIP-712 type hash for batch Twap data
    /// forge-lint: disable-next-line(mixed-case-function)
    function BATCH_TWAP_TYPEHASH() external view returns (bytes32);
}
