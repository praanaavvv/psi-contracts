// SPDX-License-Identifier: BSL-1.1
pragma solidity 0.8.31;

import { DataTypes } from '../types/DataTypes.sol';
import { IERC1155 } from '@openzeppelin/contracts/token/ERC1155/IERC1155.sol';

/// @title IPsiAccountingView
/// @notice Sub-interface for AccountingMixin view functions
interface IPsiAccountingView is IERC1155 {
    /// @notice Get the Twap Oracle
    /// @return The Twap Oracle address
    function getTwapOracle() external view returns (address);

    // ============ ERC-1155 Token ID Functions ============

    /// @notice Get the ERC-1155 token ID for a market side
    /// @param conditionId The market condition ID
    /// @param side The market side (YES or NO)
    /// @return tokenId The unique token ID
    function getTokenId(bytes32 conditionId, DataTypes.Side side) external pure returns (uint256);

    /// @notice Get the market info for a token ID
    /// @param tokenId The ERC-1155 token ID
    /// @return conditionId The market condition ID
    /// @return side The market side
    function getTokenInfo(uint256 tokenId) external view returns (bytes32 conditionId, DataTypes.Side side);

    /// @notice Get total supply for a token ID
    /// @param tokenId The ERC-1155 token ID
    /// @return The total supply of that token
    function totalSupply(uint256 tokenId) external view returns (uint256);

    /// @notice Get total YES shares for a market
    /// @param conditionId Market condition ID
    /// @return The total YES shares for the market
    function getTotalSharesYes(bytes32 conditionId) external view returns (uint256);

    /// @notice Get total NO shares for a market
    /// @param conditionId Market condition ID
    /// @return The total NO shares for the market
    function getTotalSharesNo(bytes32 conditionId) external view returns (uint256);

    // ============ Market State ============

    /// @notice Get market state for a condition
    /// @param conditionId Market condition ID
    /// @return The market state
    function getMarketState(bytes32 conditionId) external view returns (DataTypes.MarketState memory);

    /// @notice Check if a market is initialized
    /// @param conditionId Market condition ID
    /// @return True if the market is initialized
    function isMarketInitialized(bytes32 conditionId) external view returns (bool);

    /// @notice Get market token assets breakdown (loss-adjusted, excludes yield)
    /// @param conditionId Market condition ID
    /// @return yesAssets Total YES side token assets
    /// @return noAssets Total NO side token assets
    function getMarketAssets(bytes32 conditionId) external view returns (uint256 yesAssets, uint256 noAssets);

    /// @notice Get current market indexes
    /// @param conditionId Market condition ID
    /// @param twapPriceYes Average YES TWAP price since last update for accurate yield split (> PRICE_SCALE to use stored)
    /// @return Computed index result with loss indexes, yield per share, and reduction factor
    function getMarketIndexes(bytes32 conditionId, uint256 twapPriceYes) external view returns (DataTypes.IndexResult memory);

    // ============ Protocol Fees ============

    /// @notice Get protocol fee configuration
    /// @return The protocol fee in basis points (max 10000 = 100%)
    function getProtocolFeeBps() external view returns (uint256);

    /// @notice Get accumulated protocol fees ready to harvest
    /// @return The accumulated protocol fees in USDC
    function getAccumulatedProtocolFees() external view returns (uint256);

    // ============ User State ============

    /// @notice Get user's shares for a market (from ERC-1155 balances)
    /// @param user User address
    /// @param conditionId Market condition ID
    /// @return yesShares User's YES side share balance
    /// @return noShares User's NO side share balance
    function getUserShares(address user, bytes32 conditionId) external view returns (uint256 yesShares, uint256 noShares);

    /// @notice Get user's current token assets (loss-adjusted, excludes yield)
    /// @param user User address
    /// @param conditionId Market condition ID
    /// @return yesAssets User's YES side token assets
    /// @return noAssets User's NO side token assets
    function getUserAssets(address user, bytes32 conditionId) external view returns (uint256 yesAssets, uint256 noAssets);

    /// @notice Get user's pending USDC yield for a market
    /// @param user User address
    /// @param conditionId Market condition ID
    /// @param twapPriceYes Average YES TWAP price since last update for accurate yield split (> PRICE_SCALE to use stored)
    /// @return yesYield Pending YES side yield in USDC
    /// @return noYield Pending NO side yield in USDC
    function getUserYield(address user, bytes32 conditionId, uint256 twapPriceYes) external view returns (uint256 yesYield, uint256 noYield);

    /// @notice Get user's yield snapshots for a market
    /// @param user User address
    /// @param conditionId Market condition ID
    /// @return yieldSnapshotYes User's YES side yield snapshot
    /// @return yieldSnapshotNo User's NO side yield snapshot
    function getUserYieldSnapshots(address user, bytes32 conditionId) external view returns (uint128 yieldSnapshotYes, uint128 yieldSnapshotNo);

    /// @notice Preview shares that would be minted for a deposit
    /// @param conditionId Market condition ID
    /// @param side YES or NO
    /// @param amount Token amount to deposit
    /// @return shares Shares that would be minted
    function previewDeposit(bytes32 conditionId, DataTypes.Side side, uint256 amount) external view returns (uint256 shares);

    /// @notice Get the token asset value of shares (loss-adjusted, excludes yield)
    /// @param conditionId Market condition ID
    /// @param side YES or NO
    /// @param shares Number of shares
    /// @return assets Current YES/NO token value of those shares
    function getShareValue(bytes32 conditionId, DataTypes.Side side, uint256 shares) external view returns (uint256 assets);

    /// @notice Preview a withdrawal - shows token assets and USDC yield for given shares
    /// @param user User address
    /// @param conditionId Market condition ID
    /// @param side YES or NO
    /// @param sharesToBurn Amount of shares to burn
    /// @param twapPriceYes Average YES TWAP price since last update for accurate yield split (> PRICE_SCALE to use stored)
    /// @return tokenAssets Token amount received (loss-adjusted)
    /// @return yieldUsdc USDC yield received
    function previewWithdraw(address user, bytes32 conditionId, DataTypes.Side side, uint256 sharesToBurn, uint256 twapPriceYes)
        external
        view
        returns (uint256 tokenAssets, uint256 yieldUsdc);

    // ============ TWAP Configuration ============

    /// @notice Get the current Twap grace period
    /// @return The current Twap grace period in seconds
    function getTwapGracePeriod() external view returns (uint256);

    // ============ Constants ============

    /// @notice Default Twap grace period (60 seconds)
    /// forge-lint: disable-next-line(mixed-case-function)
    function DEFAULT_TWAP_GRACE_PERIOD() external view returns (uint256);

    /// @notice Maximum allowed Twap grace period (2 minutes)
    /// forge-lint: disable-next-line(mixed-case-function)
    function MAX_TWAP_GRACE_PERIOD() external view returns (uint256);
}
