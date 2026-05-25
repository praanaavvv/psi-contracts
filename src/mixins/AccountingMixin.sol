// SPDX-License-Identifier: BSL-1.1
pragma solidity 0.8.31;

import { Initializable } from '@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol';
import { ERC1155Upgradeable } from '@openzeppelin/contracts-upgradeable/token/ERC1155/ERC1155Upgradeable.sol';
import { ReentrancyGuard } from '@openzeppelin/contracts/utils/ReentrancyGuard.sol';
import { Math } from '@openzeppelin/contracts/utils/math/Math.sol';
import { DataTypes } from '../types/DataTypes.sol';
import { ShareMath } from '../libraries/ShareMath.sol';
import { IndexCalcLib } from '../libraries/IndexCalcLib.sol';
import { AccountingLib } from '../libraries/AccountingLib.sol';
import { IPsiStakingVaultEvents } from '../interfaces/IPsiStakingVaultEvents.sol';
import { IPsiStakingVaultErrors } from '../interfaces/IPsiStakingVaultErrors.sol';

import { IPsiTwapOracle } from '../interfaces/IPsiTwapOracle.sol';
import { StorageLib } from '../libraries/StorageLib.sol';

/// @title AccountingMixin
/// @notice ERC-4626-like per-side share accounting with ERC-1155 share representation
/// @dev Uses ERC-7201 namespaced storage pattern for upgradeability.
///      Each (conditionId, side) combination has a unique ERC-1155 token ID.
abstract contract AccountingMixin is Initializable, ERC1155Upgradeable, ReentrancyGuard, IPsiStakingVaultEvents, IPsiStakingVaultErrors {
    using Math for uint256;

    // ============ Constants ============

    /// @notice Default grace period for TWAP timestamp validation (in seconds)
    uint256 public constant DEFAULT_TWAP_GRACE_PERIOD = 60;

    /// @notice Maximum allowed TWAP grace period (in seconds)
    uint256 public constant MAX_TWAP_GRACE_PERIOD = 120;

    // ============ ERC-7201 Namespaced Storage ============

    function _getAccountingStorage() private pure returns (StorageLib.AccountingStorage storage) {
        return StorageLib.getAccountingStorage();
    }

    // ============ Initialization ============

    /// @notice Initialize the accounting mixin
    /// @param uri_ The metadata URI for ERC-1155 tokens
    /// @param protocolFeeBps_ Initial protocol fee in basis points
    /// forge-lint: disable-next-line(mixed-case-function)
    function __AccountingMixin_init(string memory uri_, uint256 protocolFeeBps_, address twapOracle_) internal onlyInitializing {
        if (protocolFeeBps_ > DataTypes.BPS_DENOM) revert InvalidFeeBps(protocolFeeBps_);

        __ERC1155_init(uri_);

        StorageLib.AccountingStorage storage $ = _getAccountingStorage();
        $.protocolFeeBps = protocolFeeBps_;
        $.twapOracle = IPsiTwapOracle(twapOracle_);
        $.twapGracePeriod = DEFAULT_TWAP_GRACE_PERIOD;
    }

    /// @notice Returns the address of the TWAP oracle
    function _getTwapOracle() internal view virtual returns (address) {
        return address(_getAccountingStorage().twapOracle);
    }

    // ============ ERC-1155 Token ID Functions ============

    /// @notice Returns the ERC-1155 token ID for a given condition and side
    function getTokenId(bytes32 conditionId, DataTypes.Side side) public pure virtual returns (uint256) {
        return AccountingLib.getTokenId(conditionId, side);
    }

    /// @notice Returns the condition ID and side for a given ERC-1155 token ID
    function _getTokenInfo(uint256 tokenId) internal view virtual returns (bytes32 conditionId, DataTypes.Side side) {
        DataTypes.MarketTokenInfo storage info = _getAccountingStorage().tokenInfo[tokenId];
        if (info.conditionId == 0) revert UnknownTokenId(tokenId);
        return (info.conditionId, info.side);
    }

    /// @notice Returns the total supply of shares for a given token ID
    function _totalSupply(uint256 tokenId) internal view virtual returns (uint256) {
        (bytes32 conditionId, DataTypes.Side side) = _getTokenInfoInternal(tokenId);
        if (conditionId == 0) return 0; // Not initialized

        DataTypes.MarketState storage market = _getAccountingStorage().markets[conditionId];
        return side == DataTypes.Side.YES ? market.totalSharesYes : market.totalSharesNo;
    }

    /// @notice Returns the total YES shares for a market
    function _getTotalSharesYes(bytes32 conditionId) internal view virtual returns (uint256) {
        return _getAccountingStorage().markets[conditionId].totalSharesYes;
    }

    /// @notice Returns the total NO shares for a market
    function _getTotalSharesNo(bytes32 conditionId) internal view virtual returns (uint256) {
        return _getAccountingStorage().markets[conditionId].totalSharesNo;
    }

    // ============ ERC-1155 Token overrides =================

    function safeTransferFrom(address from, address to, uint256 id, uint256 value, bytes memory data) public override nonReentrant {
        super.safeTransferFrom(from, to, id, value, data);
    }

    function safeBatchTransferFrom(address from, address to, uint256[] memory ids, uint256[] memory values, bytes memory data)
        public
        override
        nonReentrant
    {
        super.safeBatchTransferFrom(from, to, ids, values, data);
    }

    // ============ View Functions - Market State ============

    /// @notice Returns the full market state for a given condition
    function _getMarketState(bytes32 conditionId) internal view virtual returns (DataTypes.MarketState memory) {
        return _getAccountingStorage().markets[conditionId];
    }

    /// @notice Returns whether a market has been initialized
    function isMarketInitialized(bytes32 conditionId) public view virtual returns (bool) {
        return _getAccountingStorage().markets[conditionId].marketInitTimestamp > 0;
    }

    /// @notice Returns the total YES and NO asset values for a market
    /// @dev twapPriceYes not needed because lossIndex does not depend on it
    function _getMarketAssets(bytes32 conditionId) internal view virtual returns (uint256 yesAssets, uint256 noAssets) {
        DataTypes.MarketState storage market = _getAccountingStorage().markets[conditionId];
        DataTypes.IndexResult memory r = _calculateIndexesCurrent(conditionId, DataTypes.PRICE_SCALE + 1);
        yesAssets = ShareMath.sharesToAssetsWithIndex(market.totalSharesYes, r.lossIndexYes, false);
        noAssets = ShareMath.sharesToAssetsWithIndex(market.totalSharesNo, r.lossIndexNo, false);
    }

    /// @notice Returns the current loss and yield indexes for a market given a TWAP price
    function _getMarketIndexes(bytes32 conditionId, uint256 twapPriceYes) internal view virtual returns (DataTypes.IndexResult memory) {
        return _calculateIndexesCurrent(conditionId, twapPriceYes);
    }

    /// @notice Returns the protocol fee in basis points
    function getProtocolFeeBps() public view virtual returns (uint256) {
        return _getAccountingStorage().protocolFeeBps;
    }

    /// @notice Returns the total accumulated protocol fees available for harvest
    function getAccumulatedProtocolFees() public view virtual returns (uint256) {
        return _getAccountingStorage().accumulatedProtocolFees;
    }

    // ============ View Functions - User State ============

    /// @notice Returns the YES and NO share balances for a user in a market
    function _getUserShares(address user, bytes32 conditionId) internal view virtual returns (uint256 yesShares, uint256 noShares) {
        yesShares = balanceOf(user, getTokenId(conditionId, DataTypes.Side.YES));
        noShares = balanceOf(user, getTokenId(conditionId, DataTypes.Side.NO));
    }

    /// @notice Returns the loss-adjusted YES and NO asset values for a user in a market
    /// @dev twapPriceYes is not needed here because lossIndex does not depend on it
    function _getUserAssets(address user, bytes32 conditionId) internal view virtual returns (uint256 yesAssets, uint256 noAssets) {
        DataTypes.IndexResult memory r = _calculateIndexesCurrent(conditionId, DataTypes.PRICE_SCALE + 1);
        (uint256 userSharesYes, uint256 userSharesNo) = _getUserShares(user, conditionId);
        yesAssets = ShareMath.sharesToAssetsWithIndex(userSharesYes, r.lossIndexYes, false);
        noAssets = ShareMath.sharesToAssetsWithIndex(userSharesNo, r.lossIndexNo, false);
    }

    /// @notice Returns the pending USDC yield for a user in a market
    function _getUserYield(address user, bytes32 conditionId, uint256 twapPriceYes)
        internal
        view
        virtual
        returns (uint256 yesYield, uint256 noYield)
    {
        StorageLib.AccountingStorage storage $ = _getAccountingStorage();
        DataTypes.UserMarketState storage userState = $.userStates[user][conditionId];
        DataTypes.IndexResult memory r = _calculateIndexesCurrent(conditionId, twapPriceYes);
        (uint256 userSharesYes, uint256 userSharesNo) = _getUserShares(user, conditionId);

        // Yield = shares × (currentYieldPerShare - userSnapshot) / INDEX_SCALE, then scaled by reductionFactor.
        // The reductionFactor is < 1.0 only when loss has exceeded token pair backing (lossIndex hit 0),
        // meaning yield claims must be reduced to maintain solvency.
        if (userSharesYes > 0 && r.yieldPerShareYes > userState.yieldSnapshotYes) {
            yesYield = userSharesYes.mulDiv(r.yieldPerShareYes - userState.yieldSnapshotYes, DataTypes.INDEX_SCALE, Math.Rounding.Floor);
            yesYield = yesYield.mulDiv(r.yieldReductionFactor, DataTypes.INDEX_SCALE, Math.Rounding.Floor);
        }
        if (userSharesNo > 0 && r.yieldPerShareNo > userState.yieldSnapshotNo) {
            noYield = userSharesNo.mulDiv(r.yieldPerShareNo - userState.yieldSnapshotNo, DataTypes.INDEX_SCALE, Math.Rounding.Floor);
            noYield = noYield.mulDiv(r.yieldReductionFactor, DataTypes.INDEX_SCALE, Math.Rounding.Floor);
        }
    }

    /// @notice Returns the yield snapshots for a user in a market
    function _getUserYieldSnapshots(address user, bytes32 conditionId)
        internal
        view
        virtual
        returns (uint128 yieldSnapshotYes, uint128 yieldSnapshotNo)
    {
        DataTypes.UserMarketState storage userState = _getAccountingStorage().userStates[user][conditionId];
        return (userState.yieldSnapshotYes, userState.yieldSnapshotNo);
    }

    /// @notice Previews the number of shares a deposit would mint
    /// @dev twapPriceYes not needed because lossIndex does not depend on it
    function _previewDeposit(bytes32 conditionId, DataTypes.Side side, uint256 amount) internal view virtual returns (uint256 shares) {
        DataTypes.IndexResult memory r = _calculateIndexesCurrent(conditionId, DataTypes.PRICE_SCALE + 1);
        uint256 lossIndex = side == DataTypes.Side.YES ? r.lossIndexYes : r.lossIndexNo;
        shares = ShareMath.assetsToSharesWithIndex(amount, lossIndex, false);
    }

    /// @notice Returns the asset value of a given number of shares
    /// @dev twapPriceYes not needed because lossIndex does not depend on it
    function _getShareValue(bytes32 conditionId, DataTypes.Side side, uint256 shares) internal view virtual returns (uint256 assets) {
        DataTypes.IndexResult memory r = _calculateIndexesCurrent(conditionId, DataTypes.PRICE_SCALE + 1);
        uint256 lossIndex = side == DataTypes.Side.YES ? r.lossIndexYes : r.lossIndexNo;
        assets = ShareMath.sharesToAssetsWithIndex(shares, lossIndex, false);
    }

    /// @notice Previews the token assets and yield USDC returned from a withdrawal
    function _previewWithdraw(address user, bytes32 conditionId, DataTypes.Side side, uint256 sharesToBurn, uint256 twapPriceYes)
        internal
        view
        virtual
        returns (uint256 tokenAssets, uint256 yieldUsdc)
    {
        StorageLib.AccountingStorage storage $ = _getAccountingStorage();
        DataTypes.UserMarketState storage userState = $.userStates[user][conditionId];

        uint256 tokenId = getTokenId(conditionId, side);
        uint256 userShares = balanceOf(user, tokenId);

        if (userShares == 0 || sharesToBurn > userShares) {
            return (0, 0);
        }

        DataTypes.IndexResult memory r = _calculateIndexesCurrent(conditionId, twapPriceYes);

        if (side == DataTypes.Side.YES) {
            tokenAssets = ShareMath.sharesToAssetsWithIndex(sharesToBurn, r.lossIndexYes, false);
            uint256 yieldDelta = r.yieldPerShareYes > userState.yieldSnapshotYes ? r.yieldPerShareYes - userState.yieldSnapshotYes : 0;
            yieldUsdc = sharesToBurn.mulDiv(yieldDelta, DataTypes.INDEX_SCALE, Math.Rounding.Floor);
            yieldUsdc = yieldUsdc.mulDiv(r.yieldReductionFactor, DataTypes.INDEX_SCALE, Math.Rounding.Floor);
        } else {
            tokenAssets = ShareMath.sharesToAssetsWithIndex(sharesToBurn, r.lossIndexNo, false);
            uint256 yieldDelta = r.yieldPerShareNo > userState.yieldSnapshotNo ? r.yieldPerShareNo - userState.yieldSnapshotNo : 0;
            yieldUsdc = sharesToBurn.mulDiv(yieldDelta, DataTypes.INDEX_SCALE, Math.Rounding.Floor);
            yieldUsdc = yieldUsdc.mulDiv(r.yieldReductionFactor, DataTypes.INDEX_SCALE, Math.Rounding.Floor);
        }
    }

    /// @notice Returns the current TWAP grace period in seconds
    function _getTwapGracePeriod() internal view virtual returns (uint256) {
        return _getAccountingStorage().twapGracePeriod;
    }

    // ============ Internal Functions - Market Management ============

    /// @notice Initialize a market (called on first deposit or manually)
    function _initializeMarket(bytes32 conditionId, uint256 yesPositionId, uint256 noPositionId, bool negRisk) internal {
        AccountingLib.initializeMarket(conditionId, yesPositionId, noPositionId, negRisk);
    }

    // ============ Internal Functions - Share Operations ============

    /// @notice Mint shares to user for deposit (delegated to AccountingLib)
    function _mintShares(address user, bytes32 conditionId, DataTypes.Side side, uint256 assets) internal returns (uint256 shares) {
        uint256 tokenId = getTokenId(conditionId, side);
        uint256 oldShares = balanceOf(user, tokenId);
        (shares, tokenId) = AccountingLib.mintShares(user, conditionId, side, assets, oldShares);
        _mint(user, tokenId, shares, '');
    }

    /// @notice Burn shares from user for withdrawal (delegated to AccountingLib)
    function _burnShares(address user, bytes32 conditionId, DataTypes.Side side, uint256 shares)
        internal
        returns (uint256 tokenAssets, uint256 yieldUsdc)
    {
        uint256 tokenId = getTokenId(conditionId, side);
        uint256 userShares = balanceOf(user, tokenId);
        (tokenAssets, yieldUsdc, tokenId) = AccountingLib.burnShares(user, conditionId, side, shares, userShares);
        _burn(user, tokenId, shares);
    }

    // ============ Internal Functions - Pool Management ============

    /// @notice Add Usdc to the global pool from a market (delegated to AccountingLib)
    function _addToPool(bytes32 conditionId, uint256 amount) internal {
        AccountingLib.addToPool(conditionId, amount);
    }

    /// @notice Remove Usdc from the global pool for a market (delegated to AccountingLib)
    function _removeFromPool(bytes32 conditionId, uint256 amount) internal returns (uint256 actualAmount) {
        return AccountingLib.removeFromPool(conditionId, amount);
    }

    /// @notice Update pool assets snapshot
    /// @dev this is setting the snapshot value which can be used during withdrawals and deposits to have a consitent value for calculations.
    /// (Other than using _getTotalPoolAssetsCurrent which is only for accuracy of view functions)
    /// @param newTotalAssets New total assets in external vaults + contract balance
    function _updatePoolAssets(uint256 newTotalAssets) internal {
        _getAccountingStorage().totalPoolAssets = newTotalAssets;
    }

    // ============ Internal Functions - Yield Index Updates ============

    /// @notice Update loss indexes and yield-per-share (delegated to AccountingLib)
    function _updateYieldIndexes(bytes32 conditionId) internal {
        AccountingLib.updateYieldIndexes(conditionId);
    }

    /// @notice Get current total pool assets for view functions
    /// @dev Override in child contract to return getTotalUsdcValue() for real-time view calculations
    /// @return Current total USDC value
    function _getTotalPoolAssetsCurrent() internal view virtual returns (uint256);

    /// @notice Calculate indexes using current pool assets (for view functions)
    /// @param conditionId Market to simulate
    /// @param twapPriceYes If <= PRICE_SCALE, simulate TWAP accumulator extension to block.timestamp
    function _calculateIndexesCurrent(bytes32 conditionId, uint256 twapPriceYes) internal view returns (DataTypes.IndexResult memory) {
        StorageLib.AccountingStorage storage $ = _getAccountingStorage();
        (uint256 twapAccumulatorYes, uint256 lastTwapUpdate) = AccountingLib.getTwapAccumulatorYes(conditionId);
        return IndexCalcLib.calculateIndexes(
            $.markets[conditionId],
            DataTypes.IndexCalcInput({
                totalPoolShares: $.totalPoolShares,
                totalPoolAssets: _getTotalPoolAssetsCurrent(),
                twapAccumulatorYes: twapAccumulatorYes,
                lastTwapUpdate: lastTwapUpdate,
                twapPriceYes: twapPriceYes,
                currentTimestamp: block.timestamp
            })
        );
    }

    // ============ Internal Functions - Protocol Fees ============

    /// @notice Add to accumulated protocol fees
    /// @param amount Amount to add to protocol fees
    function _addProtocolFee(uint256 amount) internal {
        _getAccountingStorage().accumulatedProtocolFees += amount;
    }

    /// @notice Set protocol fee
    function _setProtocolFeeBps(uint256 newFeeBps) internal {
        if (newFeeBps > DataTypes.BPS_DENOM) revert InvalidFeeBps(newFeeBps);
        StorageLib.AccountingStorage storage $ = _getAccountingStorage();
        uint256 oldFeeBps = $.protocolFeeBps;
        $.protocolFeeBps = newFeeBps;
        emit ProtocolFeeUpdated(oldFeeBps, newFeeBps);
    }

    /// @notice Harvest accumulated protocol fees
    /// @return amount Fees harvested
    function _harvestProtocolFees() internal returns (uint256 amount) {
        StorageLib.AccountingStorage storage $ = _getAccountingStorage();
        amount = $.accumulatedProtocolFees;
        if (amount == 0) revert NoFeesToHarvest();
        $.accumulatedProtocolFees = 0;
    }

    // ============ Internal Functions - Twap Oracle ============
    /// @notice Set the Twap grace period
    /// @param gracePeriod New grace period in seconds
    function _setTwapGracePeriod(uint256 gracePeriod) internal {
        if (gracePeriod > MAX_TWAP_GRACE_PERIOD) revert TwapGracePeriodExceedsMax(gracePeriod, MAX_TWAP_GRACE_PERIOD);
        StorageLib.AccountingStorage storage $ = _getAccountingStorage();
        uint256 oldGracePeriod = $.twapGracePeriod;
        $.twapGracePeriod = gracePeriod;
        emit TwapGracePeriodUpdated(oldGracePeriod, gracePeriod);
    }

    /// @notice Set the Twap Oracle
    /// @param twapOracle_ The Twap Oracle address
    function _setTwapOracle(address twapOracle_) internal {
        _getAccountingStorage().twapOracle = IPsiTwapOracle(twapOracle_);
    }

    /// @notice Handle the accounting updates for a share transfer (delegated to AccountingLib)
    function _handleTransferAccounting(address from, address to, uint256 tokenId, uint256 sharesTx, uint256 receiverShares) internal {
        AccountingLib.handleTransferAccounting(from, to, tokenId, sharesTx, receiverShares);
    }

    /// @notice Internal helper to get token info without reverting
    /// @param tokenId The ERC-1155 token ID to look up
    /// @return conditionId The market condition ID (bytes32(0) if not initialized)
    /// @return side The market side (defaults to YES if not initialized)
    function _getTokenInfoInternal(uint256 tokenId) private view returns (bytes32 conditionId, DataTypes.Side side) {
        DataTypes.MarketTokenInfo storage info = _getAccountingStorage().tokenInfo[tokenId];
        if (info.conditionId == 0) return (0, DataTypes.Side.YES);
        return (info.conditionId, info.side);
    }
}
