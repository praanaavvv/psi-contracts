// SPDX-License-Identifier: BSL-1.1
pragma solidity 0.8.31;

import { DataTypes } from '../types/DataTypes.sol';

/// @title IPsiPolymarketView
/// @notice Sub-interface for PolymarketMixin view functions
interface IPsiPolymarketView {
    /// @notice Get Polymarket token info for a market
    /// @param conditionId Market condition ID
    /// @return Cached Polymarket token info (position IDs, negRisk flag, collateral)
    function getPolymarketTokenInfo(bytes32 conditionId) external view returns (DataTypes.PolymarketTokenInfo memory);

    /// @notice Get unpaired token amounts for a market
    /// @param conditionId Market condition ID
    /// @return yesAmount Unpaired YES outcome tokens held by the vault
    /// @return noAmount Unpaired NO outcome tokens held by the vault
    function getUnpairedTokens(bytes32 conditionId) external view returns (uint256 yesAmount, uint256 noAmount);

    /// @notice Get underlying USDC address
    /// @return The USDC token address used by the vault
    function getUnderlyingUsdc() external view returns (address);

    /// @notice Get maximum additional matched tokens across all markets
    /// @return Total maximum additional matched tokens
    function getMaximumAdditionalMatchedTokens() external view returns (uint256);
}
