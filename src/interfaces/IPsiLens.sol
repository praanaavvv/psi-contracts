// SPDX-License-Identifier: BSL-1.1
pragma solidity 0.8.31;

import { DataTypes } from '../types/DataTypes.sol';

/// @title IPsiLens
/// @notice Read-only aggregation contract for batch queries against PsiStakingVault
interface IPsiLens {
    // ============ Batch Queries ============

    /// @notice Batch query user's shares across multiple markets
    /// @param user User address
    /// @param conditionIds Array of market condition IDs
    /// @return yesShares Array of YES share balances
    /// @return noShares Array of NO share balances
    function batchGetUserShares(address user, bytes32[] calldata conditionIds)
        external
        view
        returns (uint256[] memory yesShares, uint256[] memory noShares);

    /// @notice Batch query user's current assets (loss-adjusted) across multiple markets
    /// @param user User address
    /// @param conditionIds Array of market condition IDs
    /// @return yesAssets Array of YES asset values (loss-adjusted)
    /// @return noAssets Array of NO asset values (loss-adjusted)
    function batchGetUserAssets(address user, bytes32[] calldata conditionIds)
        external
        view
        returns (uint256[] memory yesAssets, uint256[] memory noAssets);

    /// @notice Batch query user's pending yield across multiple markets
    /// @param user User address
    /// @param conditionIds Array of market condition IDs
    /// @param twapPricesYes Array of Average YES TWAP price since last updates per market (> PRICE_SCALE to use stored)
    /// @return yesYield Array of pending YES side yield in USDC
    /// @return noYield Array of pending NO side yield in USDC
    function batchGetUserYield(address user, bytes32[] calldata conditionIds, uint256[] calldata twapPricesYes)
        external
        view
        returns (uint256[] memory yesYield, uint256[] memory noYield);

    /// @notice Comprehensive batch query for user portfolio data
    /// @param user User address
    /// @param conditionIds Array of market condition IDs
    /// @param twapPricesYes Array of Average YES TWAP price since last updates per market (> PRICE_SCALE to use stored)
    /// @return yesShares Array of YES share balances
    /// @return noShares Array of NO share balances
    /// @return yesAssets Array of YES token values (loss-adjusted)
    /// @return noAssets Array of NO token values (loss-adjusted)
    /// @return yesYield Array of pending YES side USDC yield
    /// @return noYield Array of pending NO side USDC yield
    function batchGetUserPortfolio(address user, bytes32[] calldata conditionIds, uint256[] calldata twapPricesYes)
        external
        view
        returns (
            uint256[] memory yesShares,
            uint256[] memory noShares,
            uint256[] memory yesAssets,
            uint256[] memory noAssets,
            uint256[] memory yesYield,
            uint256[] memory noYield
        );

    /// @notice Batch preview deposits across multiple markets and sides
    /// @param conditionIds Array of market condition IDs
    /// @param sides Array of sides (YES or NO) per market
    /// @param amounts Array of token amounts to deposit per market
    /// @return shares Array of shares that would be minted per market
    function batchPreviewDeposit(bytes32[] calldata conditionIds, DataTypes.Side[] calldata sides, uint256[] calldata amounts)
        external
        view
        returns (uint256[] memory shares);

    /// @notice Batch preview withdrawals for multiple markets
    /// @param user User address
    /// @param conditionIds Array of market condition IDs
    /// @param sides Array of sides (YES or NO) for each market
    /// @param sharesToBurn Array of share amounts to burn for each market
    /// @param twapPricesYes Array of Average YES TWAP price since last updates per market (> PRICE_SCALE to use stored)
    /// @return tokenAssets Array of token assets that would be received (loss-adjusted)
    /// @return yieldUsdc Array of USDC yield that would be received
    function batchPreviewWithdraw(
        address user,
        bytes32[] calldata conditionIds,
        DataTypes.Side[] calldata sides,
        uint256[] calldata sharesToBurn,
        uint256[] calldata twapPricesYes
    ) external view returns (uint256[] memory tokenAssets, uint256[] memory yieldUsdc);

    // ============ Market State ============

    /// @notice Batch query full market state across multiple markets
    /// @param conditionIds Array of market condition IDs
    /// @return states Array of market states (indexes, pool shares, timestamps, etc.)
    function batchGetMarketState(bytes32[] calldata conditionIds) external view returns (DataTypes.MarketState[] memory states);

    /// @notice Batch query computed market indexes across multiple markets
    /// @dev Simulates pending yield since last update when twapPriceYes <= PRICE_SCALE
    /// @param conditionIds Array of market condition IDs
    /// @param twapPricesYes Array of average YES TWAP price since last update per market (> PRICE_SCALE to use stored)
    /// @return results Array of computed index results (loss indexes, yield per share, reduction factor, market value)
    function batchGetMarketIndexes(bytes32[] calldata conditionIds, uint256[] calldata twapPricesYes)
        external
        view
        returns (DataTypes.IndexResult[] memory results);

    // ============ Capacity Check ============

    /// @notice Check if a batch deposit would succeed or fail due to capacity limits
    /// @param conditionIds Array of condition IDs
    /// @param yesAmounts Array of YES amounts
    /// @param noAmounts Array of NO amounts
    /// @return True if deposit would succeed, false if it would revert due to exceeded capacity
    function checkBatchDepositCapacity(bytes32[] memory conditionIds, uint256[] memory yesAmounts, uint256[] memory noAmounts)
        external
        view
        returns (bool);

    // ============ Vault Reference ============

    /// @notice Get the address of the PsiStakingVault this lens reads from
    /// @return The vault address
    function vault() external view returns (address);
}
