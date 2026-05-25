// SPDX-License-Identifier: BSL-1.1
pragma solidity 0.8.31;

import { Initializable } from '@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol';
import { IERC20 } from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import { SafeERC20 } from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import { DataTypes } from '../types/DataTypes.sol';
import { IPsiStakingVaultEvents } from '../interfaces/IPsiStakingVaultEvents.sol';
import { IPsiStakingVaultErrors } from '../interfaces/IPsiStakingVaultErrors.sol';

import { VaultLib } from '../libraries/VaultLib.sol';
import { StorageLib } from '../libraries/StorageLib.sol';

/// @title YieldStrategyMixin
/// @notice Generic ERC-4626 vault management for yield generation
/// @dev Uses ERC-7201 namespaced storage pattern for upgradeability.
///      Heavy logic delegated to VaultLib (external library) to reduce bytecode.
abstract contract YieldStrategyMixin is Initializable, IPsiStakingVaultEvents, IPsiStakingVaultErrors {
    using SafeERC20 for IERC20;

    // ============ ERC-7201 Namespaced Storage ============

    function _getYieldStrategyStorage() private pure returns (StorageLib.YieldStrategyStorage storage) {
        return StorageLib.getYieldStrategyStorage();
    }

    // ============ Initialization ============

    /// @notice Initialize the yield strategy mixin
    /// forge-lint: disable-next-line(mixed-case-function)
    function __YieldStrategyMixin_init(address underlyingUsdc_) internal onlyInitializing {
        _getYieldStrategyStorage().underlyingUsdc = underlyingUsdc_;
    }

    // ============ View Functions (delegated to VaultLib) ============

    /// @notice Returns all external vault addresses, balances, caps, and status flags
    function _getExternalVaults()
        internal
        view
        virtual
        returns (
            address[] memory addresses,
            uint256[] memory balances,
            uint256[] memory caps,
            bool[] memory activeFlags,
            bool[] memory emergencyFlags
        )
    {
        return VaultLib.getExternalVaults();
    }

    /// @notice Returns the total USDC value across all external vaults
    function getTotalVaultValue() public view virtual returns (uint256) {
        return VaultLib.getTotalVaultValue();
    }

    /// @notice Returns the current USDC value of shares held in a specific vault
    function getVaultValue(address vault) public view virtual returns (uint256) {
        return VaultLib.getVaultValue(vault);
    }

    /// @notice Returns the total USDC value (idle balance plus vault deposits)
    function _getTotalUsdcValue() internal view returns (uint256) {
        return VaultLib.getTotalUsdcValue(_getReservedUsdc());
    }

    /// @notice Returns whether the vault is in emergency mode
    function _isEmergencyMode() internal view virtual returns (bool) {
        return VaultLib.isEmergencyMode();
    }

    /// @notice Returns the total available deposit capacity across all active vaults
    function _getTotalAvailableCapacity() internal view virtual returns (uint256) {
        return VaultLib.getTotalAvailableCapacity(_getReservedUsdc());
    }

    /// @notice Returns the total available internal capacity based on vault caps
    function _getTotalAvailableInternalCapacity() internal view returns (uint256) {
        return VaultLib.getTotalAvailableInternalCapacity(_getReservedUsdc());
    }

    /// @notice Returns the available deposit capacity for a specific vault
    function _getAvailableCapacityByAddress(address vault) internal view virtual returns (uint256) {
        return VaultLib.getAvailableCapacityByAddress(vault);
    }

    // ============ Internal Functions - Vault Management (delegated to VaultLib) ============

    /// @notice Add a new external vault
    function _addVault(address vault, uint256 cap) internal {
        VaultLib.addVault(vault, cap, _getReservedUsdc());
    }

    /// @notice Remove a vault (withdraws all, redistributes)
    function _removeVault(address vault) internal returns (uint256 withdrawn) {
        return VaultLib.removeVault(vault, _getReservedUsdc());
    }

    /// @notice Update vault cap
    function _setVaultCap(address vault, uint256 newCap) internal {
        VaultLib.setVaultCap(vault, newCap);
    }

    /// @notice Enable or disable a vault for new deposits
    function _setVaultActive(address vault, bool active) internal {
        VaultLib.setVaultActive(vault, active);
    }

    /// @notice Swap the order of two vaults in the processing queue
    function _swapVaultOrder(address vault1, address vault2) internal {
        VaultLib.swapVaultOrder(vault1, vault2);
    }

    /// @notice Enable emergency mode (withdraw all from vaults)
    function _enableEmergencyMode() internal {
        VaultLib.enableEmergencyMode();
    }

    /// @notice Withdraw maximum possible from vaults during emergency
    function _withdrawMaxDuringEmergency(address vault) internal {
        VaultLib.withdrawMaxDuringEmergency(vault);
    }

    /// @notice Disable emergency mode
    function _disableEmergencyMode() internal {
        VaultLib.disableEmergencyMode(_getReservedUsdc());
    }

    /// @notice Enable emergency mode for a specific vault
    function _enableVaultEmergency(address vault) internal returns (uint256 withdrawn) {
        return VaultLib.enableVaultEmergency(vault);
    }

    /// @notice Disable emergency mode for a specific vault
    function _disableVaultEmergency(address vault) internal {
        VaultLib.disableVaultEmergency(vault, _getReservedUsdc());
    }

    // ============ Internal Functions - Supply/Withdraw (delegated to VaultLib) ============

    /// @notice Supply all idle Usdc to external vaults (reverts if cannot supply all)
    function _supplyToVaults() internal {
        VaultLib.supplyToVaults(_getReservedUsdc());
    }

    /// @notice Supply all idle Usdc to vaults (non-reverting)
    function _trySupplyIdleToVaults() internal returns (uint256 remaining) {
        return VaultLib.trySupplyIdleToVaults(_getReservedUsdc());
    }

    /// @notice Ensure contract has enough Usdc available, withdrawing from vaults if needed
    function _ensureUsdcBalance(uint256 amount) internal {
        VaultLib.ensureUsdcBalance(amount, _getReservedUsdc());
    }

    /// @notice Withdraw Usdc from external vaults
    function _withdrawFromVaults(uint256 amount) internal {
        VaultLib.withdrawFromVaults(amount);
    }

    // ============ Internal Functions - Helpers ============

    /// @notice Get Usdc balance in contract (not in vaults)
    function _getContractUsdcBalance() internal view returns (uint256) {
        StorageLib.YieldStrategyStorage storage $ = _getYieldStrategyStorage();
        return IERC20($.underlyingUsdc).balanceOf(address(this));
    }

    /// @notice Get Usdc that is reserved and should not be supplied to vaults
    /// @dev Override in child contract to account for protocol fees.
    function _getReservedUsdc() internal view virtual returns (uint256);

    /// @notice Transfer Usdc from contract
    function _transferUsdc(address to, uint256 amount) internal {
        StorageLib.YieldStrategyStorage storage $ = _getYieldStrategyStorage();
        IERC20($.underlyingUsdc).safeTransfer(to, amount);
    }
}
