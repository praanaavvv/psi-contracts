// SPDX-License-Identifier: BSL-1.1
pragma solidity 0.8.31;

import { Math } from '@openzeppelin/contracts/utils/math/Math.sol';
import { DataTypes } from './types/DataTypes.sol';
import { IPsiLens } from './interfaces/IPsiLens.sol';
import { IPsiStakingVault } from './interfaces/IPsiStakingVault.sol';

/// @title PsiLens
/// @notice Read-only aggregation contract for batch queries against PsiStakingVault
/// @dev Deployed separately from the vault to reduce vault contract size.
///      All functions are view-only and delegate to the vault's public view functions.
contract PsiLens is IPsiLens {
    using Math for uint256;

    /// @inheritdoc IPsiLens
    address public immutable vault;

    constructor(address vault_) {
        vault = vault_;
    }

    // ============ Batch Queries ============

    /// @inheritdoc IPsiLens
    function batchGetUserShares(address user, bytes32[] calldata conditionIds)
        external
        view
        returns (uint256[] memory yesShares, uint256[] memory noShares)
    {
        IPsiStakingVault v = IPsiStakingVault(vault);
        uint256 len = conditionIds.length;
        yesShares = new uint256[](len);
        noShares = new uint256[](len);

        for (uint256 i = 0; i < len; i++) {
            (yesShares[i], noShares[i]) = v.getUserShares(user, conditionIds[i]);
        }
    }

    /// @inheritdoc IPsiLens
    function batchGetUserAssets(address user, bytes32[] calldata conditionIds)
        external
        view
        returns (uint256[] memory yesAssets, uint256[] memory noAssets)
    {
        IPsiStakingVault v = IPsiStakingVault(vault);
        uint256 len = conditionIds.length;
        yesAssets = new uint256[](len);
        noAssets = new uint256[](len);

        for (uint256 i = 0; i < len; i++) {
            (yesAssets[i], noAssets[i]) = v.getUserAssets(user, conditionIds[i]);
        }
    }

    /// @inheritdoc IPsiLens
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
        )
    {
        if (conditionIds.length != twapPricesYes.length) revert LengthMismatch();

        IPsiStakingVault v = IPsiStakingVault(vault);
        uint256 len = conditionIds.length;
        yesShares = new uint256[](len);
        noShares = new uint256[](len);
        yesAssets = new uint256[](len);
        noAssets = new uint256[](len);
        yesYield = new uint256[](len);
        noYield = new uint256[](len);

        for (uint256 i = 0; i < len; i++) {
            (yesShares[i], noShares[i]) = v.getUserShares(user, conditionIds[i]);
            (yesAssets[i], noAssets[i]) = v.getUserAssets(user, conditionIds[i]);
            (yesYield[i], noYield[i]) = v.getUserYield(user, conditionIds[i], twapPricesYes[i]);
        }
    }

    /// @inheritdoc IPsiLens
    function batchGetUserYield(address user, bytes32[] calldata conditionIds, uint256[] calldata twapPricesYes)
        external
        view
        returns (uint256[] memory yesYield, uint256[] memory noYield)
    {
        if (conditionIds.length != twapPricesYes.length) revert LengthMismatch();

        IPsiStakingVault v = IPsiStakingVault(vault);
        uint256 len = conditionIds.length;
        yesYield = new uint256[](len);
        noYield = new uint256[](len);

        for (uint256 i = 0; i < len; i++) {
            (yesYield[i], noYield[i]) = v.getUserYield(user, conditionIds[i], twapPricesYes[i]);
        }
    }

    /// @inheritdoc IPsiLens
    function batchPreviewDeposit(bytes32[] calldata conditionIds, DataTypes.Side[] calldata sides, uint256[] calldata amounts)
        external
        view
        returns (uint256[] memory shares)
    {
        if (conditionIds.length != sides.length || conditionIds.length != amounts.length) revert LengthMismatch();

        IPsiStakingVault v = IPsiStakingVault(vault);
        uint256 len = conditionIds.length;
        if (len != sides.length || len != amounts.length) revert LengthMismatch();
        shares = new uint256[](len);

        for (uint256 i = 0; i < len; i++) {
            shares[i] = v.previewDeposit(conditionIds[i], sides[i], amounts[i]);
        }
    }

    /// @inheritdoc IPsiLens
    function batchPreviewWithdraw(
        address user,
        bytes32[] calldata conditionIds,
        DataTypes.Side[] calldata sides,
        uint256[] calldata sharesToBurn,
        uint256[] calldata twapPricesYes
    ) external view returns (uint256[] memory tokenAssets, uint256[] memory yieldUsdc) {
        if (conditionIds.length != sides.length || conditionIds.length != sharesToBurn.length || conditionIds.length != twapPricesYes.length) revert LengthMismatch();

        IPsiStakingVault v = IPsiStakingVault(vault);
        uint256 len = conditionIds.length;
        if (len != sides.length || len != sharesToBurn.length || len != twapPricesYes.length) revert LengthMismatch();

        tokenAssets = new uint256[](len);
        yieldUsdc = new uint256[](len);

        for (uint256 i = 0; i < len; i++) {
            (tokenAssets[i], yieldUsdc[i]) = v.previewWithdraw(user, conditionIds[i], sides[i], sharesToBurn[i], twapPricesYes[i]);
        }
    }

    // ============ Market State ============

    /// @inheritdoc IPsiLens
    function batchGetMarketState(bytes32[] calldata conditionIds) external view returns (DataTypes.MarketState[] memory states) {
        IPsiStakingVault v = IPsiStakingVault(vault);
        uint256 len = conditionIds.length;
        states = new DataTypes.MarketState[](len);

        for (uint256 i = 0; i < len; i++) {
            states[i] = v.getMarketState(conditionIds[i]);
        }
    }

    /// @inheritdoc IPsiLens
    function batchGetMarketIndexes(bytes32[] calldata conditionIds, uint256[] calldata twapPricesYes)
        external
        view
        returns (DataTypes.IndexResult[] memory results)
    {
        if (conditionIds.length != twapPricesYes.length) revert LengthMismatch();

        IPsiStakingVault v = IPsiStakingVault(vault);
        uint256 len = conditionIds.length;
        results = new DataTypes.IndexResult[](len);

        for (uint256 i = 0; i < len; i++) {
            results[i] = v.getMarketIndexes(conditionIds[i], twapPricesYes[i]);
        }
    }

    // ============ Capacity Check ============

    /// @inheritdoc IPsiLens
    function checkBatchDepositCapacity(bytes32[] memory conditionIds, uint256[] memory yesAmounts, uint256[] memory noAmounts)
        public
        view
        returns (bool)
    {
        if (conditionIds.length != yesAmounts.length || conditionIds.length != noAmounts.length) revert LengthMismatch();

        IPsiStakingVault v = IPsiStakingVault(vault);
        uint256 internalCapacity = v.getTotalAvailableInternalCapacity();
        uint256 externalCapacity = v.getTotalAvailableCapacity();
        uint256 newMaxPotential = v.getMaximumAdditionalMatchedTokens();
        uint256 totalPairedUsdc;

        for (uint256 i = 0; i < conditionIds.length; i++) {
            (uint256 unpairedYes, uint256 unpairedNo) = v.getUnpairedTokens(conditionIds[i]);

            uint256 newYes = unpairedYes + yesAmounts[i];
            uint256 newNo = unpairedNo + noAmounts[i];

            // Update max potential (simulates _addUnpaired)
            uint256 currentMax = Math.max(unpairedYes, unpairedNo);
            uint256 newMax = Math.max(newYes, newNo);
            if (newMax > currentMax) {
                newMaxPotential += newMax - currentMax;
            }

            // Simulate pairing (simulates _pairAndMerge)
            uint256 pairs = newYes < newNo ? newYes : newNo;
            if (pairs > 0) {
                uint256 maxAfterPair = Math.max(newYes - pairs, newNo - pairs);
                uint256 reduction = newMax - maxAfterPair;
                newMaxPotential = reduction <= newMaxPotential ? newMaxPotential - reduction : 0;
                totalPairedUsdc += pairs;
            }
        }

        // Check internal capacity (potential max vs caps)
        if (internalCapacity != type(uint256).max && newMaxPotential > internalCapacity) {
            return false;
        }

        // Check external capacity (paired USDC vs vault limits)
        if (externalCapacity != type(uint256).max && totalPairedUsdc > externalCapacity) {
            return false;
        }

        return true;
    }

    // ============ Errors ============

    /// @notice Thrown when array lengths don't match
    error LengthMismatch();
}
