// SPDX-License-Identifier: BSL-1.1
pragma solidity 0.8.31;

import { AccessControlUpgradeable } from '@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol';
import { ERC1155Upgradeable } from '@openzeppelin/contracts-upgradeable/token/ERC1155/ERC1155Upgradeable.sol';

import { DataTypes } from './types/DataTypes.sol';
import { IPsiStakingVaultErrors } from './interfaces/IPsiStakingVaultErrors.sol';
import { IPsiStakingVaultEvents } from './interfaces/IPsiStakingVaultEvents.sol';
import { AccountingMixin } from './mixins/AccountingMixin.sol';
import { YieldStrategyMixin } from './mixins/YieldStrategyMixin.sol';
import { PausableMixin } from './mixins/PausableMixin.sol';
import { StorageLib } from './libraries/StorageLib.sol';
import {
    DEFAULT_MANAGER_ROLE as _DEFAULT_MANAGER_ROLE,
    FEE_HARVESTER_ROLE as _FEE_HARVESTER_ROLE,
    TIMELOCKED_ROLE as _TIMELOCKED_ROLE,
    PAUSER_ROLE as _PAUSER_ROLE,
    EXTERNAL_VAULT_MANAGER_ROLE as _EXTERNAL_VAULT_MANAGER_ROLE
} from './types/Roles.sol';

/// @title PsiStakingVaultExtension
/// @notice Extension contract for admin functions, reached via fallback delegation from PsiStakingVault
/// @dev This contract is NOT proxied directly. It is DELEGATECALLed from the main vault implementation
///      via its fallback() function. Shares the same ERC-7201 namespaced storage as the main contract.
contract PsiStakingVaultExtension is AccessControlUpgradeable, AccountingMixin, YieldStrategyMixin, PausableMixin {
    // ============ Roles (sourced from Roles.sol) ============

    bytes32 public constant DEFAULT_MANAGER_ROLE = _DEFAULT_MANAGER_ROLE;
    bytes32 public constant FEE_HARVESTER_ROLE = _FEE_HARVESTER_ROLE;
    bytes32 public constant TIMELOCKED_ROLE = _TIMELOCKED_ROLE;
    bytes32 public constant PAUSER_ROLE = _PAUSER_ROLE;
    bytes32 public constant EXTERNAL_VAULT_MANAGER_ROLE = _EXTERNAL_VAULT_MANAGER_ROLE;

    // ============ ERC-7201 Extension Storage ============

    function _getExtensionStorage() private pure returns (StorageLib.ExtensionStorage storage) {
        return StorageLib.getExtensionStorage();
    }

    // ============ Admin Functions - Extension Address ============

    /// @notice Set the extension contract address (for upgrades to the extension)
    /// @param newExtension Address of the new extension contract
    function setExtensionAddress(address newExtension) external onlyRole(TIMELOCKED_ROLE) {
        if (newExtension == address(0)) revert IPsiStakingVaultErrors.ZeroAddress();
        _getExtensionStorage().extension = newExtension;
        emit IPsiStakingVaultEvents.ExtensionAddressUpdated(newExtension);
    }

    // ============ Admin Functions - Vault Management ============

    function addVault(address vault, uint256 cap) external onlyRole(EXTERNAL_VAULT_MANAGER_ROLE) {
        _addVault(vault, cap);
    }

    function removeVault(address vault) external onlyRole(EXTERNAL_VAULT_MANAGER_ROLE) {
        _removeVault(vault);
    }

    function setVaultCap(address vault, uint256 cap) external onlyRole(EXTERNAL_VAULT_MANAGER_ROLE) {
        _setVaultCap(vault, cap);
    }

    function setVaultActive(address vault, bool active) external onlyRole(EXTERNAL_VAULT_MANAGER_ROLE) {
        _setVaultActive(vault, active);
    }

    /// @dev vault order matters - vaults are processed in array order for deposits.
    ///      Place higher-APY or preferred vaults first.
    function swapVaultOrder(address vault1, address vault2) external onlyRole(EXTERNAL_VAULT_MANAGER_ROLE) {
        _swapVaultOrder(vault1, vault2);
    }

    /// @dev Use when Usdc is sitting idle and capacity is available
    function supplyIdleToVaults() external onlyRole(EXTERNAL_VAULT_MANAGER_ROLE) returns (uint256 supplied) {
        return _trySupplyIdleToVaults();
    }

    // ============ Admin Functions - Protocol Fees ============

    function setProtocolFeeBps(uint256 newFeeBps) external onlyRole(TIMELOCKED_ROLE) {
        _setProtocolFeeBps(newFeeBps);
    }

    /// @dev Withdraws from vaults if contract doesn't have enough Usdc
    function harvestProtocolFee(address to) external onlyRole(FEE_HARVESTER_ROLE) {
        if (to == address(0)) revert IPsiStakingVaultErrors.ZeroAddress();
        uint256 amount = _harvestProtocolFees();

        // Ensure we have enough Usdc (withdraw from vaults if needed)
        // after harvest, _getReserveUsdc() returns 0, so _getIdleUsdc() = full contract balance
        uint256 contractBalance = _getContractUsdcBalance();
        if (contractBalance < amount) {
            _withdrawFromVaults(amount - contractBalance);
        }

        _transferUsdc(to, amount);
        emit IPsiStakingVaultEvents.ProtocolFeeHarvested(to, amount);
    }

    // ============ Admin Functions - Twap ============

    function setTwapGracePeriod(uint256 gracePeriod) external onlyRole(DEFAULT_MANAGER_ROLE) {
        _setTwapGracePeriod(gracePeriod);
    }

    function setTwapOracle(address twapOracle) external onlyRole(DEFAULT_MANAGER_ROLE) {
        _setTwapOracle(twapOracle);
    }

    // ============ Admin Functions - Emergency ============

    function enableEmergencyMode() external onlyRole(EXTERNAL_VAULT_MANAGER_ROLE) {
        _enableEmergencyMode();
    }

    function withdrawMaxDuringEmergency(address vault) external onlyRole(EXTERNAL_VAULT_MANAGER_ROLE) {
        _withdrawMaxDuringEmergency(vault);
    }

    function disableEmergencyMode() external onlyRole(EXTERNAL_VAULT_MANAGER_ROLE) {
        _disableEmergencyMode();
    }

    function enableVaultEmergency(address vault) external onlyRole(EXTERNAL_VAULT_MANAGER_ROLE) {
        _enableVaultEmergency(vault);
    }

    function disableVaultEmergency(address vault) external onlyRole(EXTERNAL_VAULT_MANAGER_ROLE) {
        _disableVaultEmergency(vault);
    }

    // ============ Admin Functions - Pause ============

    function setPauseAll(bool paused) external onlyRole(PAUSER_ROLE) {
        _setPauseAll(paused);
    }

    function setPauseDeposits(bool paused) external onlyRole(PAUSER_ROLE) {
        _setPauseDeposits(paused);
    }

    function setPauseWithdrawals(bool paused) external onlyRole(PAUSER_ROLE) {
        _setPauseWithdrawals(paused);
    }

    function setPauseTransfers(bool paused) external onlyRole(PAUSER_ROLE) {
        _setPauseTransfers(paused);
    }

    // ============ Admin Functions - ERC-1155 Metadata ============

    function setUri(string calldata newuri) external onlyRole(DEFAULT_MANAGER_ROLE) {
        _setURI(newuri);
    }

    // ============ View Functions - AccountingMixin Wrappers ============

    function getTwapOracle() public view returns (address) {
        return _getTwapOracle();
    }

    function getTokenInfo(uint256 tokenId) public view returns (bytes32 conditionId, DataTypes.Side side) {
        return _getTokenInfo(tokenId);
    }

    function totalSupply(uint256 tokenId) public view returns (uint256) {
        return _totalSupply(tokenId);
    }

    function getTotalSharesYes(bytes32 conditionId) public view returns (uint256) {
        return _getTotalSharesYes(conditionId);
    }

    function getTotalSharesNo(bytes32 conditionId) public view returns (uint256) {
        return _getTotalSharesNo(conditionId);
    }

    function getMarketState(bytes32 conditionId) public view returns (DataTypes.MarketState memory) {
        return _getMarketState(conditionId);
    }

    function getMarketAssets(bytes32 conditionId) public view returns (uint256 yesAssets, uint256 noAssets) {
        return _getMarketAssets(conditionId);
    }

    function getMarketIndexes(bytes32 conditionId, uint256 twapPriceYes) public view returns (DataTypes.IndexResult memory) {
        return _getMarketIndexes(conditionId, twapPriceYes);
    }

    function getUserShares(address user, bytes32 conditionId) public view returns (uint256 yesShares, uint256 noShares) {
        return _getUserShares(user, conditionId);
    }

    function getUserAssets(address user, bytes32 conditionId) public view returns (uint256 yesAssets, uint256 noAssets) {
        return _getUserAssets(user, conditionId);
    }

    function getUserYield(address user, bytes32 conditionId, uint256 twapPriceYes) public view returns (uint256 yesYield, uint256 noYield) {
        return _getUserYield(user, conditionId, twapPriceYes);
    }

    function getUserYieldSnapshots(address user, bytes32 conditionId) public view returns (uint128 yieldSnapshotYes, uint128 yieldSnapshotNo) {
        return _getUserYieldSnapshots(user, conditionId);
    }

    function previewDeposit(bytes32 conditionId, DataTypes.Side side, uint256 amount) public view returns (uint256 shares) {
        return _previewDeposit(conditionId, side, amount);
    }

    function getShareValue(bytes32 conditionId, DataTypes.Side side, uint256 shares) public view returns (uint256 assets) {
        return _getShareValue(conditionId, side, shares);
    }

    function previewWithdraw(address user, bytes32 conditionId, DataTypes.Side side, uint256 sharesToBurn, uint256 twapPriceYes)
        public
        view
        returns (uint256 tokenAssets, uint256 yieldUsdc)
    {
        return _previewWithdraw(user, conditionId, side, sharesToBurn, twapPriceYes);
    }

    function getTwapGracePeriod() public view returns (uint256) {
        return _getTwapGracePeriod();
    }

    // ============ View Functions - YieldStrategyMixin Wrappers ============

    function getExternalVaults()
        public
        view
        returns (
            address[] memory addresses,
            uint256[] memory balances,
            uint256[] memory caps,
            bool[] memory activeFlags,
            bool[] memory emergencyFlags
        )
    {
        return _getExternalVaults();
    }

    function isEmergencyMode() public view returns (bool) {
        return _isEmergencyMode();
    }

    function getTotalAvailableCapacity() public view returns (uint256) {
        return _getTotalAvailableCapacity();
    }

    function getAvailableCapacity(address vault) public view returns (uint256) {
        return _getAvailableCapacityByAddress(vault);
    }

    function getTotalUsdcValue() public view returns (uint256) {
        return _getTotalUsdcValue();
    }

    function getTotalAvailableInternalCapacity() public view returns (uint256) {
        return _getTotalAvailableInternalCapacity();
    }

    // ============ View Functions - PausableMixin Wrappers ============

    function isPausedAll() public view returns (bool) {
        return _isPausedAll();
    }

    function isPausedDeposits() public view returns (bool) {
        return _isPausedDeposits();
    }

    function isPausedWithdrawals() public view returns (bool) {
        return _isPausedWithdrawals();
    }

    function isTransfersPaused() public view returns (bool) {
        return _isTransfersPaused();
    }

    // ============ Overrides ============

    /// @notice Get Usdc reserved for protocol fees (should not be supplied to vaults)
    function _getReservedUsdc() internal view override returns (uint256) {
        return getAccumulatedProtocolFees();
    }

    /// @notice Get current total USDC value for view function calculations
    function _getTotalPoolAssetsCurrent() internal view override returns (uint256) {
        return _getTotalUsdcValue();
    }

    /// @notice Override to resolve diamond inheritance conflict
    function supportsInterface(bytes4 interfaceId) public view override(AccessControlUpgradeable, ERC1155Upgradeable) returns (bool) {
        return AccessControlUpgradeable.supportsInterface(interfaceId) || ERC1155Upgradeable.supportsInterface(interfaceId);
    }
}
