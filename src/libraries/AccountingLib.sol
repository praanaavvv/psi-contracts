// SPDX-License-Identifier: BSL-1.1
pragma solidity 0.8.31;

import { Math } from '@openzeppelin/contracts/utils/math/Math.sol';
import { DataTypes } from '../types/DataTypes.sol';
import { ShareMath } from './ShareMath.sol';
import { IndexCalcLib } from './IndexCalcLib.sol';
import { IPsiStakingVaultEvents } from '../interfaces/IPsiStakingVaultEvents.sol';
import { IPsiStakingVaultErrors } from '../interfaces/IPsiStakingVaultErrors.sol';
import { StorageLib } from './StorageLib.sol';

/// @title AccountingLib
/// @notice External library for AccountingMixin pool management and yield index updates
/// @dev Uses ERC-7201 namespaced storage (same slot as AccountingMixin). Called via DELEGATECALL.
library AccountingLib {
    using Math for uint256;

    function _getAccountingStorage() private pure returns (StorageLib.AccountingStorage storage $) {
        return StorageLib.getAccountingStorage();
    }

    // ============ View functions ============

    function getTokenId(bytes32 conditionId, DataTypes.Side side) public pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(conditionId, uint8(side))));
    }

    function getTwapAccumulatorYes(bytes32 conditionId) public view returns (uint256 twapAccumulatorYes, uint256 lastUpdate) {
        StorageLib.AccountingStorage storage $ = _getAccountingStorage();
        (twapAccumulatorYes, lastUpdate) = $.twapOracle.getCurrentTwapAccumulator(conditionId);
        if (lastUpdate == 0) revert IPsiStakingVaultErrors.MarketNotInitialized(conditionId);
    }

    // ============ Pool Management ============

    /// @notice Add USDC to the global pool from a market
    /// @dev this is the mechanism responsible for tracking each market's share of the global yield earning pool.
    function addToPool(bytes32 conditionId, uint256 amount) external {
        StorageLib.AccountingStorage storage $ = _getAccountingStorage();
        DataTypes.MarketState storage market = $.markets[conditionId];

        // Calculate shares for this market in the global pool
        uint256 poolShares = ShareMath.assetsToShares(amount, $.totalPoolAssets, $.totalPoolShares, false);

        market.marketPoolShares += poolShares;
        market.principalContributed += amount;

        $.totalPoolShares += poolShares;
        $.totalPoolAssets += amount;
    }

    /// @notice Remove USDC from the global pool for a market
    /// @dev this is the mechanism responsible for tracking each market's share of the global yield earning pool.
    function removeFromPool(bytes32 conditionId, uint256 amount) external returns (uint256 actualAmount) {
        StorageLib.AccountingStorage storage $ = _getAccountingStorage();
        DataTypes.MarketState storage market = $.markets[conditionId];

        // Calculate how many pool shares this market needs to burn
        uint256 sharesToBurn = ShareMath.assetsToShares(amount, $.totalPoolAssets, $.totalPoolShares, true);

        // Cap at market's available shares
        if (sharesToBurn > market.marketPoolShares) {
            sharesToBurn = market.marketPoolShares;
        }

        // Calculate actual assets for these shares
        actualAmount = ShareMath.sharesToAssets(sharesToBurn, $.totalPoolAssets, $.totalPoolShares, false);

        market.marketPoolShares -= sharesToBurn;
        if (market.principalContributed > actualAmount) {
            market.principalContributed -= actualAmount;
        } else {
            market.principalContributed = 0;
        }

        $.totalPoolShares -= sharesToBurn;
        $.totalPoolAssets -= actualAmount;
    }

    // ============ Market Initialization ============

    /// @notice Initialize a market (called on first deposit or manually)
    function initializeMarket(bytes32 conditionId, uint256 yesPositionId, uint256 noPositionId, bool negRisk) external {
        StorageLib.AccountingStorage storage $ = _getAccountingStorage();
        DataTypes.MarketState storage market = $.markets[conditionId];

        if (market.marketInitTimestamp > 0) revert IPsiStakingVaultErrors.MarketAlreadyInitialized(conditionId);

        uint40 currentTime = uint40(block.timestamp);
        market.marketInitTimestamp = currentTime;

        // Initialize loss indexes to 1:1 (shares = assets initially, no loss)
        market.lossIndexYes = uint128(DataTypes.INDEX_SCALE);
        market.lossIndexNo = uint128(DataTypes.INDEX_SCALE);
        //yieldPerShareYes/No default to 0 (no yield)

        //yieldReductionFactor default to 1:1 (no reduction)
        market.yieldReductionFactor = uint128(DataTypes.INDEX_SCALE);

        market.lastYieldTimestamp = currentTime;

        // Store token Ids
        uint256 tokenIdYes = getTokenId(conditionId, DataTypes.Side.YES);
        $.tokenInfo[tokenIdYes] = DataTypes.MarketTokenInfo({ conditionId: conditionId, side: DataTypes.Side.YES });
        uint256 tokenIdNo = getTokenId(conditionId, DataTypes.Side.NO);
        $.tokenInfo[tokenIdNo] = DataTypes.MarketTokenInfo({ conditionId: conditionId, side: DataTypes.Side.NO });

        $.twapOracle.initializeMarket(conditionId, yesPositionId, noPositionId, negRisk);
    }

    // ============ Yield Index Updates ============

    /// @notice Update loss indexes and yield-per-share based on current pool value
    /// @dev Loss indexes track token value reduction (only decrease).
    ///      Yield-per-share tracks cumulative USDC yield per share (only increase).
    ///      Yield/loss is split between YES/NO using Twap-weighted distribution.
    /// @dev We use lastTwapUpdate to distribute the yield that was earned until block.timestamp.
    ///      LastTwapUpdate is checked to be too much in the past. So it's only slightly inaccurate.
    function updateYieldIndexes(bytes32 conditionId) external {
        StorageLib.AccountingStorage storage $ = _getAccountingStorage();
        DataTypes.MarketState storage market = $.markets[conditionId];

        // Get TWAP accumulator
        (uint256 twapAccumulatorYes, uint256 lastTwapUpdate) = getTwapAccumulatorYes(conditionId);

        uint256 timeDelta = block.timestamp - lastTwapUpdate;
        uint256 gracePeriod = $.twapGracePeriod;
        if (timeDelta > gracePeriod) revert IPsiStakingVaultErrors.TwapGracePeriodExceedsMax(timeDelta, gracePeriod);

        // Calculate indexes
        DataTypes.IndexResult memory r = IndexCalcLib.calculateIndexes(
            market,
            DataTypes.IndexCalcInput({
                totalPoolShares: $.totalPoolShares,
                totalPoolAssets: $.totalPoolAssets,
                twapAccumulatorYes: twapAccumulatorYes,
                lastTwapUpdate: lastTwapUpdate,
                twapPriceYes: DataTypes.PRICE_SCALE + 1,
                currentTimestamp: block.timestamp
            })
        );

        // If no index changed, still advance the TWAP checkpoint to avoid re-processing the same period.
        // This happens when marketValue == principalContributed (no gain or loss).
        if (
            market.lossIndexYes == r.lossIndexYes && market.lossIndexNo == r.lossIndexNo && market.yieldPerShareYes == r.yieldPerShareYes
                && market.yieldPerShareNo == r.yieldPerShareNo && market.yieldReductionFactor == r.yieldReductionFactor
        ) {
            market.lastYieldTwapCheckpointYes = uint128(twapAccumulatorYes);
            market.lastYieldTimestamp = uint40(lastTwapUpdate);
            return;
        }

        market.lossIndexYes = uint128(r.lossIndexYes);
        market.lossIndexNo = uint128(r.lossIndexNo);
        market.yieldPerShareYes = uint128(r.yieldPerShareYes);
        market.yieldPerShareNo = uint128(r.yieldPerShareNo);
        market.yieldReductionFactor = uint128(r.yieldReductionFactor);

        // Update tracking for next calculation
        market.lastYieldTwapCheckpointYes = uint128(twapAccumulatorYes);
        market.lastYieldTimestamp = uint40(lastTwapUpdate);

        // Always update principal to current market value (prevents re-counting the same loss)
        market.principalContributed = r.marketValue;

        emit IPsiStakingVaultEvents.IndexesUpdated(
            conditionId, r.lossIndexYes, r.lossIndexNo, r.yieldPerShareYes, r.yieldPerShareNo, r.yieldReductionFactor, r.marketValue
        );
    }

    // ============ Share Operations ============

    /// @notice Compute and apply mint shares accounting. Caller must call ERC1155._mint after.
    /// @param user User address
    /// @param conditionId Market condition ID
    /// @param side YES or NO
    /// @param assets Amount of assets being deposited
    /// @param oldShares User's current balance of the token (from balanceOf)
    /// @return shares Number of shares to mint
    /// @return tokenId ERC-1155 token ID to mint
    /// @dev Updates indexes before minting to ensure accurate share price.
    ///      Shares are minted as ERC-1155 tokens. Uses lossIndex for share price.
    ///      Records weighted-average yield snapshot for yield entitlement tracking.
    function mintShares(address user, bytes32 conditionId, DataTypes.Side side, uint256 assets, uint256 oldShares)
        external
        returns (uint256 shares, uint256 tokenId)
    {
        StorageLib.AccountingStorage storage $ = _getAccountingStorage();
        DataTypes.MarketState storage market = $.markets[conditionId];
        DataTypes.UserMarketState storage userState = $.userStates[user][conditionId];

        tokenId = uint256(keccak256(abi.encodePacked(conditionId, uint8(side))));

        if (side == DataTypes.Side.YES) {
            if (market.lossIndexYes == 0) revert IPsiStakingVaultErrors.MarketSideBroken();
            // Calculate shares at current loss index
            shares = ShareMath.assetsToSharesWithIndex(assets, market.lossIndexYes, false);
            if (shares == 0) revert IPsiStakingVaultErrors.ZeroAmount();
            // Record weighted-average yield snapshot before minting
            userState.yieldSnapshotYes = uint128(_weightedAverageSnapshot(userState.yieldSnapshotYes, oldShares, market.yieldPerShareYes, shares));
            // Update total shares, weighted snapshot tracking
            market.totalSharesYes += shares;
            market.totalWeightedSnapshotYes += shares * uint256(market.yieldPerShareYes);
        } else {
            if (market.lossIndexNo == 0) revert IPsiStakingVaultErrors.MarketSideBroken();
            shares = ShareMath.assetsToSharesWithIndex(assets, market.lossIndexNo, false);
            if (shares == 0) revert IPsiStakingVaultErrors.ZeroAmount();
            userState.yieldSnapshotNo = uint128(_weightedAverageSnapshot(userState.yieldSnapshotNo, oldShares, market.yieldPerShareNo, shares));
            market.totalSharesNo += shares;
            market.totalWeightedSnapshotNo += shares * uint256(market.yieldPerShareNo);
        }
    }

    /// @notice Compute and apply burn shares accounting. Caller must call ERC1155._burn after.
    /// @dev Updates indexes before burning to ensure accurate calculations.
    ///      Returns token assets (loss-adjusted) and USDC yield separately.
    /// @param user User address
    /// @param conditionId Market condition ID
    /// @param side YES or NO
    /// @param shares Amount of shares to burn
    /// @param userShares User's current balance (from balanceOf)
    /// @return tokenAssets Amount of outcome tokens to return
    /// @return yieldUsdc Amount of USDC yield earned
    /// @return tokenId ERC-1155 token ID to burn
    function burnShares(address user, bytes32 conditionId, DataTypes.Side side, uint256 shares, uint256 userShares)
        external
        returns (uint256 tokenAssets, uint256 yieldUsdc, uint256 tokenId)
    {
        StorageLib.AccountingStorage storage $ = _getAccountingStorage();
        DataTypes.MarketState storage market = $.markets[conditionId];
        DataTypes.UserMarketState storage userState = $.userStates[user][conditionId];

        tokenId = uint256(keccak256(abi.encodePacked(conditionId, uint8(side))));

        if (shares > userShares) {
            revert IPsiStakingVaultErrors.InsufficientShares(shares, userShares);
        }

        if (side == DataTypes.Side.YES) {
            // Token assets via lossIndex (loss-adjusted only, no yield baked in)
            tokenAssets = ShareMath.sharesToAssetsWithIndex(shares, market.lossIndexYes, false);
            // USDC yield from yieldPerShare delta, scaled by reduction factor
            uint256 yieldDelta = market.yieldPerShareYes > userState.yieldSnapshotYes ? market.yieldPerShareYes - userState.yieldSnapshotYes : 0;
            yieldUsdc = shares.mulDiv(yieldDelta, DataTypes.INDEX_SCALE, Math.Rounding.Floor);
            yieldUsdc = yieldUsdc.mulDiv(market.yieldReductionFactor, DataTypes.INDEX_SCALE, Math.Rounding.Floor);
            // Update totalWeightedSnapshot: subtract burned shares' contribution to the weighted sum.
            // Uses the user's snapshot (not current yieldPerShare) because that's what was added on deposit.
            // This bookkeeping enables O(1) computation of total outstanding yield in _applyExcessLossReduction.
            uint256 contributionYes = shares * uint256(userState.yieldSnapshotYes);
            market.totalWeightedSnapshotYes =
                contributionYes < market.totalWeightedSnapshotYes ? market.totalWeightedSnapshotYes - contributionYes : 0;
            market.totalSharesYes -= shares;
        } else {
            tokenAssets = ShareMath.sharesToAssetsWithIndex(shares, market.lossIndexNo, false);
            uint256 yieldDelta = market.yieldPerShareNo > userState.yieldSnapshotNo ? market.yieldPerShareNo - userState.yieldSnapshotNo : 0;
            yieldUsdc = shares.mulDiv(yieldDelta, DataTypes.INDEX_SCALE, Math.Rounding.Floor);
            yieldUsdc = yieldUsdc.mulDiv(market.yieldReductionFactor, DataTypes.INDEX_SCALE, Math.Rounding.Floor);
            uint256 contributionNo = shares * uint256(userState.yieldSnapshotNo);
            market.totalWeightedSnapshotNo = contributionNo < market.totalWeightedSnapshotNo ? market.totalWeightedSnapshotNo - contributionNo : 0;
            market.totalSharesNo -= shares;
        }
    }

    // ============ Transfer Accounting ============

    /// @notice Handle accounting updates for a share transfer
    /// @dev When shares are transferred, the yield claim transfers with them. The receiver's yield
    ///      snapshot is blended with the sender's snapshot, so the
    ///      receiver inherits the sender's yield entitlement for the transferred shares. Uses
    ///      weighted-average blending by share amounts.
    /// @param from Sender address
    /// @param to Receiver address
    /// @param tokenId ERC-1155 token ID
    /// @param sharesTx Amount of shares transferred
    /// @param receiverShares Receiver's current balance of the token a this point in the batch
    function handleTransferAccounting(address from, address to, uint256 tokenId, uint256 sharesTx, uint256 receiverShares) external {
        StorageLib.AccountingStorage storage $ = _getAccountingStorage();
        DataTypes.MarketTokenInfo storage info = $.tokenInfo[tokenId];

        // Skip if token not initialized (shouldn't happen for valid transfers)
        if (info.conditionId == 0) return;

        bytes32 conditionId = info.conditionId;
        DataTypes.Side side = info.side;

        DataTypes.UserMarketState storage senderState = $.userStates[from][conditionId];
        DataTypes.UserMarketState storage receiverState = $.userStates[to][conditionId];

        uint128 receiverSnapshot;

        if (side == DataTypes.Side.YES) {
            // Transfer yield snapshot: weighted average of receiver's old snapshot and sender's snapshot
            receiverSnapshot =
                uint128(_weightedAverageSnapshot(receiverState.yieldSnapshotYes, receiverShares, senderState.yieldSnapshotYes, sharesTx));
            receiverState.yieldSnapshotYes = receiverSnapshot;
        } else {
            receiverSnapshot = uint128(_weightedAverageSnapshot(receiverState.yieldSnapshotNo, receiverShares, senderState.yieldSnapshotNo, sharesTx));
            receiverState.yieldSnapshotNo = receiverSnapshot;
        }

        emit IPsiStakingVaultEvents.SharesTransferred(from, to, conditionId, side, sharesTx, receiverSnapshot);
    }

    // ============ Internal Helpers ============

    /// @dev Blends the user's existing snapshot with the current yieldPerShare for new shares.
    ///      This ensures new depositors only earn yield accrued AFTER their deposit, not historical yield.
    function _weightedAverageSnapshot(uint256 oldSnapshot, uint256 oldShares, uint256 currentYieldPerShare, uint256 newShares)
        private
        pure
        returns (uint256)
    {
        if (oldShares == 0) return currentYieldPerShare;
        uint256 totalShares = oldShares + newShares;
        uint256 contribution = oldSnapshot * oldShares + currentYieldPerShare * newShares;
        //Always round up (favors vault)
        return (contribution + totalShares - 1) / totalShares;
    }
}
