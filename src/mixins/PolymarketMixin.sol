// SPDX-License-Identifier: BSL-1.1
pragma solidity 0.8.31;

import { Initializable } from '@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol';
import { ERC1155Holder } from '@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol';
import { IERC20 } from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import { SafeERC20 } from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import { DataTypes } from '../types/DataTypes.sol';
import { IPsiStakingVaultEvents } from '../interfaces/IPsiStakingVaultEvents.sol';
import { IPsiStakingVaultErrors } from '../interfaces/IPsiStakingVaultErrors.sol';

import { IConditionalTokens } from '../interfaces/external/IConditionalTokens.sol';
import { INegRiskAdapter } from '../interfaces/external/INegRiskAdapter.sol';
import { IRegistry } from '../interfaces/external/IRegistry.sol';

import { PolymarketLib } from '../libraries/PolymarketLib.sol';
import { StorageLib } from '../libraries/StorageLib.sol';

/// @title PolymarketMixin
/// @notice Polymarket CTF integration for multi-market singleton vault
/// @dev Uses ERC-7201 namespaced storage pattern for upgradeability.
///      Heavy logic delegated to PolymarketLib (external library) to reduce bytecode.
abstract contract PolymarketMixin is Initializable, ERC1155Holder, IPsiStakingVaultEvents, IPsiStakingVaultErrors {
    using SafeERC20 for IERC20;

    // ============ ERC-7201 Namespaced Storage ============

    function _getPolymarketStorage() private pure returns (StorageLib.PolymarketStorage storage) {
        return StorageLib.getPolymarketStorage();
    }

    // ============ Initialization ============

    /// @notice Initialize the Polymarket mixin
    /// forge-lint: disable-next-line(mixed-case-function)
    function __PolymarketMixin_init(
        address ctf_,
        address negRiskAdapter_,
        address negRiskCtfExchange_,
        address ctfExchange_,
        address underlyingUsdc_,
        address polymarketWcol_
    ) internal onlyInitializing {
        StorageLib.PolymarketStorage storage $ = _getPolymarketStorage();
        $.ctf = IConditionalTokens(ctf_);
        $.negRiskAdapter = INegRiskAdapter(negRiskAdapter_);
        $.negRiskCtfExchange = IRegistry(negRiskCtfExchange_);
        $.ctfExchange = IRegistry(ctfExchange_);
        $.underlyingUsdc = underlyingUsdc_;
        $.polymarketWcol = polymarketWcol_;

        // Approve CTF and NegRiskAdapter
        IERC20(polymarketWcol_).safeIncreaseAllowance(ctf_, type(uint256).max);
        IERC20(underlyingUsdc_).safeIncreaseAllowance(ctf_, type(uint256).max);
        IERC20(underlyingUsdc_).safeIncreaseAllowance(negRiskAdapter_, type(uint256).max);

        // Approve CTF for ERC-1155 transfers to NegRiskAdapter
        IConditionalTokens(ctf_).setApprovalForAll(negRiskAdapter_, true);
    }

    // ============ View Functions ============

    /// @notice Returns the Polymarket token info for a market
    function getPolymarketTokenInfo(bytes32 conditionId) public view returns (DataTypes.PolymarketTokenInfo memory) {
        return _getPolymarketStorage().tokenInfo[conditionId];
    }

    /// @notice Returns the unpaired YES and NO token balances for a market
    function getUnpairedTokens(bytes32 conditionId) public view returns (uint256 yesAmount, uint256 noAmount) {
        return PolymarketLib.getUnpairedTokens(conditionId);
    }

    /// @notice Returns the address of the underlying USDC token
    function getUnderlyingUsdc() public view virtual returns (address) {
        return _getPolymarketStorage().underlyingUsdc;
    }

    /// @notice Returns the maximum additional matched tokens that could be paired
    function getMaximumAdditionalMatchedTokens() public view returns (uint256) {
        return _getPolymarketStorage().maximumAdditionalMatchedTokens;
    }

    // ============ Internal Functions (delegated to PolymarketLib) ============

    /// @notice Initialize market token info on first deposit
    function _initializePolymarketInfo(bytes32 conditionId) internal returns (DataTypes.PolymarketTokenInfo memory info) {
        return PolymarketLib.initializePolymarketInfo(conditionId);
    }

    /// @notice Pull outcome tokens from a user via CTF batch transfer
    function _takeOutcomeTokens(uint256[] memory ids, uint256[] memory amts, address from) internal {
        PolymarketLib.takeOutcomeTokens(ids, amts, from);
    }

    /// @notice Send outcome tokens to a user via CTF batch transfer
    function _giveOutcomeTokens(uint256[] memory ids, uint256[] memory amts, address to) internal {
        PolymarketLib.giveOutcomeTokens(ids, amts, to);
    }

    /// @notice Pair unpaired tokens and merge to Usdc
    function _pairAndMerge(bytes32 conditionId) internal returns (uint256 pairedAmount) {
        return PolymarketLib.pairAndMerge(conditionId);
    }

    /// @notice Split Usdc into YES+NO token pairs
    function _split(bytes32 conditionId, uint256 usdcAmount) internal {
        PolymarketLib.split(conditionId, usdcAmount);
    }

    /// @notice Update maximum potential matched tokens
    function _updateMaxPotential(uint256 oldYes, uint256 oldNo, uint256 newYes, uint256 newNo) internal {
        PolymarketLib.updateMaxPotential(oldYes, oldNo, newYes, newNo);
    }
}
