// SPDX-License-Identifier: BSL-1.1
pragma solidity 0.8.31;

import { IERC20 } from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import { SafeERC20 } from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import { Math } from '@openzeppelin/contracts/utils/math/Math.sol';
import { DataTypes } from '../types/DataTypes.sol';
import { IPsiStakingVaultEvents } from '../interfaces/IPsiStakingVaultEvents.sol';
import { IPsiStakingVaultErrors } from '../interfaces/IPsiStakingVaultErrors.sol';
import { IConditionalTokens } from '../interfaces/external/IConditionalTokens.sol';
import { IRegistry } from '../interfaces/external/IRegistry.sol';
import { StorageLib } from './StorageLib.sol';

/// @title PolymarketLib
/// @notice Externally-deployed library for Polymarket CTF integration operations
/// @dev Deployed as a separate contract and called via DELEGATECALL to reduce vault bytecode.
///      Accesses PolymarketMixin's ERC-7201 namespaced storage directly via the same slot constant.
library PolymarketLib {
    using SafeERC20 for IERC20;

    function _getStorage() private pure returns (StorageLib.PolymarketStorage storage $) {
        return StorageLib.getPolymarketStorage();
    }

    // ============ Market Initialization ============

    /// @notice Initialize market token info on first deposit
    /// @dev Auto-detects negRisk vs regular market
    function initializePolymarketInfo(bytes32 conditionId) external returns (DataTypes.PolymarketTokenInfo memory info) {
        StorageLib.PolymarketStorage storage $ = _getStorage();
        IConditionalTokens ctf = $.ctf;

        // Validate binary market
        uint256 outcomeSlotCount = ctf.getOutcomeSlotCount(conditionId);
        if (outcomeSlotCount != 2) revert IPsiStakingVaultErrors.InvalidOutcomeSlotCount(conditionId, outcomeSlotCount);

        // Compute collections
        bytes32 yesColl = ctf.getCollectionId(DataTypes.PARENT_COLLECTION_ID, conditionId, DataTypes.YES_INDEX_SET);
        bytes32 noColl = ctf.getCollectionId(DataTypes.PARENT_COLLECTION_ID, conditionId, DataTypes.NO_INDEX_SET);

        // Auto-detect market type
        bool negRisk = _decideVaultMode($, conditionId);
        address collateral = negRisk ? $.polymarketWcol : $.underlyingUsdc;

        // Compute position IDs
        info.yesPositionId = ctf.getPositionId(collateral, yesColl);
        info.noPositionId = ctf.getPositionId(collateral, noColl);
        info.negRisk = negRisk;
        info.collateral = collateral;

        // Store info
        $.tokenInfo[conditionId] = info;

        emit IPsiStakingVaultEvents.MarketInitialized(conditionId, info.yesPositionId, info.noPositionId, negRisk);
    }

    // ============ Token Transfers ============

    /// @notice Pull outcome tokens from a user via CTF batch transfer
    /// @dev Requires the user to have approved this contract on the CTF
    /// @param ids Array of CTF position IDs to transfer
    /// @param amts Array of amounts to transfer per position
    /// @param from Address to transfer tokens from
    function takeOutcomeTokens(uint256[] memory ids, uint256[] memory amts, address from) external {
        StorageLib.PolymarketStorage storage $ = _getStorage();
        IConditionalTokens ctf = $.ctf;

        if (!ctf.isApprovedForAll(from, address(this))) revert IPsiStakingVaultErrors.CTFApprovalRequired();

        if (ids.length == 1) {
            ctf.safeTransferFrom(from, address(this), ids[0], amts[0], '');
        } else {
            ctf.safeBatchTransferFrom(from, address(this), ids, amts, '');
        }
    }

    /// @notice Send outcome tokens to a user via CTF batch transfer
    /// @param ids Array of CTF position IDs to transfer
    /// @param amts Array of amounts to transfer per position
    /// @param to Address to transfer tokens to
    function giveOutcomeTokens(uint256[] memory ids, uint256[] memory amts, address to) external {
        StorageLib.PolymarketStorage storage $ = _getStorage();
        IConditionalTokens ctf = $.ctf;

        if (ids.length == 1) {
            ctf.safeTransferFrom(address(this), to, ids[0], amts[0], '');
        } else {
            ctf.safeBatchTransferFrom(address(this), to, ids, amts, '');
        }
    }

    // ============ Merge / Split ============

    /// @notice Split Usdc into YES+NO token pairs
    /// @param conditionId Market condition ID
    /// @param usdcAmount Amount of Usdc to split
    function split(bytes32 conditionId, uint256 usdcAmount) external {
        StorageLib.PolymarketStorage storage $ = _getStorage();
        DataTypes.PolymarketTokenInfo storage info = $.tokenInfo[conditionId];

        uint256[] memory partition = new uint256[](2);
        partition[0] = DataTypes.YES_INDEX_SET;
        partition[1] = DataTypes.NO_INDEX_SET;

        if (info.negRisk) {
            $.negRiskAdapter.splitPosition($.underlyingUsdc, DataTypes.PARENT_COLLECTION_ID, conditionId, partition, usdcAmount);
        } else {
            $.ctf.splitPosition(info.collateral, DataTypes.PARENT_COLLECTION_ID, conditionId, partition, usdcAmount);
        }

        // Update max potential (tokens already added by split, so current is NEW state)
        (uint256 newYes, uint256 newNo) = getUnpairedTokens(conditionId);
        _updateMaxPotential($, newYes - usdcAmount, newNo - usdcAmount, newYes, newNo);

        emit IPsiStakingVaultEvents.TokensSplit(conditionId, usdcAmount, usdcAmount);
    }

    /// @notice Pair unpaired tokens and merge to Usdc
    /// @param conditionId Market condition ID
    /// @return pairedAmount Amount of Usdc created from pairing
    function pairAndMerge(bytes32 conditionId) external returns (uint256 pairedAmount) {
        StorageLib.PolymarketStorage storage $ = _getStorage();

        // Get current unpaired balances
        (uint256 yesBalance, uint256 noBalance) = getUnpairedTokens(conditionId);

        // Pair the minimum of both
        uint256 pairs = yesBalance < noBalance ? yesBalance : noBalance;

        if (pairs > 0) {
            pairedAmount = _merge($, conditionId, pairs);
        }
    }

    // ============ Max Potential Tracking ============

    /// @notice Update maximum potential matched tokens
    function updateMaxPotential(uint256 oldYes, uint256 oldNo, uint256 newYes, uint256 newNo) external {
        StorageLib.PolymarketStorage storage $ = _getStorage();
        _updateMaxPotential($, oldYes, oldNo, newYes, newNo);
    }

    // ============ Private Functions ============

    /// @notice Decide if market is NegRisk (WCOL) or Regular (Usdc)
    /// @dev Polymarket has two exchange types: NegRisk (backed by WCOL/wrapped collateral) and
    ///      Regular (backed by USDC.e directly). We auto-detect by checking which exchange has
    ///      the token listed. Both YES/NO orderings are checked because the exchange may store
    ///      the complement relationship in either direction.
    function _decideVaultMode(StorageLib.PolymarketStorage storage $, bytes32 conditionId) private view returns (bool isNegRisk) {
        IConditionalTokens ctf = $.ctf;

        bytes32 yesColl = ctf.getCollectionId(bytes32(0), conditionId, DataTypes.YES_INDEX_SET);
        bytes32 noColl = ctf.getCollectionId(bytes32(0), conditionId, DataTypes.NO_INDEX_SET);

        // Check NegRisk (WCOL-backed) first
        uint256 yesId = ctf.getPositionId($.polymarketWcol, yesColl);
        uint256 noId = ctf.getPositionId($.polymarketWcol, noColl);
        bool negRiskListed = _listedOn($.negRiskCtfExchange, yesId, noId, conditionId) || _listedOn($.negRiskCtfExchange, noId, yesId, conditionId);

        // Check Regular (Usdc-backed)
        yesId = ctf.getPositionId($.underlyingUsdc, yesColl);
        noId = ctf.getPositionId($.underlyingUsdc, noColl);
        bool regularListed = _listedOn($.ctfExchange, yesId, noId, conditionId) || _listedOn($.ctfExchange, noId, yesId, conditionId);

        assert(!(negRiskListed && regularListed));
        if (negRiskListed) {
            return true; // NegRisk → WCOL
        } else if (regularListed) {
            return false; // Regular → USDC.e
        }

        revert IPsiStakingVaultErrors.UnlistedCondition(conditionId);
    }

    /// @notice Check if a token pair is listed on a Polymarket exchange registry
    /// @param ex The exchange registry to query
    /// @param id The primary token position ID
    /// @param complement The expected complement token position ID
    /// @param cond The expected condition ID for both tokens
    /// @return True if the token and its complement are both listed under the given condition
    function _listedOn(IRegistry ex, uint256 id, uint256 complement, bytes32 cond) private view returns (bool) {
        if (address(ex) == address(0)) return false;

        try ex.getConditionId(id) returns (bytes32 c) {
            if (c != cond) return false;
        } catch {
            return false;
        }

        try ex.getComplement(id) returns (uint256 comp) {
            if (comp == 0 || comp != complement) return false;
            try ex.getConditionId(comp) returns (bytes32 c2) {
                return c2 == cond;
            } catch {
                return false;
            }
        } catch {
            return false;
        }
    }

    /// @notice Merge paired YES+NO tokens into Usdc
    /// @param conditionId Market condition ID
    /// @param pairs Amount of pairs to merge
    /// @return usdcReceived Amount of Usdc received
    function _merge(StorageLib.PolymarketStorage storage $, bytes32 conditionId, uint256 pairs) private returns (uint256 usdcReceived) {
        DataTypes.PolymarketTokenInfo storage info = $.tokenInfo[conditionId];

        uint256 beforeBal = IERC20($.underlyingUsdc).balanceOf(address(this));

        uint256[] memory partition = new uint256[](2);
        partition[0] = DataTypes.YES_INDEX_SET;
        partition[1] = DataTypes.NO_INDEX_SET;

        if (info.negRisk) {
            $.negRiskAdapter.mergePositions($.underlyingUsdc, DataTypes.PARENT_COLLECTION_ID, conditionId, partition, pairs);
        } else {
            $.ctf.mergePositions(info.collateral, DataTypes.PARENT_COLLECTION_ID, conditionId, partition, pairs);
        }

        uint256 afterBal = IERC20($.underlyingUsdc).balanceOf(address(this));
        usdcReceived = afterBal - beforeBal;

        // Update max potential (tokens already merged/burned, so current is NEW state)
        // get unpaired tokens
        (uint256 newYes, uint256 newNo) = getUnpairedTokens(conditionId);
        _updateMaxPotential($, newYes + pairs, newNo + pairs, newYes, newNo);

        emit IPsiStakingVaultEvents.TokensPaired(conditionId, pairs, usdcReceived);
    }

    /// @notice Internal helper to update max potential matched tokens
    /// @dev Tracks how much additional USDC would enter the pool if all unpaired tokens across all
    ///      markets were optimally matched. For a single market, the "potential" is max(YES, NO) because
    ///      that's the maximum number of pairs that could exist. This is used for capacity checks:
    ///      even if tokens aren't paired yet, we want to ensure the vault can absorb the USDC when they are.
    ///      Otherwise, one side could keep depositing tokens and dilute the yield, while the other side can not catch up because it would exceed the limit.
    function _updateMaxPotential(StorageLib.PolymarketStorage storage $, uint256 oldYes, uint256 oldNo, uint256 newYes, uint256 newNo) private {
        uint256 oldMax = Math.max(oldYes, oldNo);
        uint256 newMax = Math.max(newYes, newNo);

        if (newMax > oldMax) {
            $.maximumAdditionalMatchedTokens += newMax - oldMax;
        } else if (oldMax > newMax) {
            $.maximumAdditionalMatchedTokens -= oldMax - newMax;
        }
    }

    /// @notice Returns the unpaired YES and NO token balances for a market
    function getUnpairedTokens(bytes32 conditionId) public view returns (uint256 yesAmount, uint256 noAmount) {
        StorageLib.PolymarketStorage storage $ = _getStorage();
        DataTypes.PolymarketTokenInfo storage info = $.tokenInfo[conditionId];
        yesAmount = $.ctf.balanceOf(address(this), info.yesPositionId);
        noAmount = $.ctf.balanceOf(address(this), info.noPositionId);
    }
}
