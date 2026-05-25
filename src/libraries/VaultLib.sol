// SPDX-License-Identifier: BSL-1.1
pragma solidity 0.8.31;

import { IERC20 } from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import { SafeERC20 } from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import { IERC4626 } from '@openzeppelin/contracts/interfaces/IERC4626.sol';
import { DataTypes } from '../types/DataTypes.sol';
import { IPsiStakingVaultEvents } from '../interfaces/IPsiStakingVaultEvents.sol';
import { IPsiStakingVaultErrors } from '../interfaces/IPsiStakingVaultErrors.sol';
import { StorageLib } from './StorageLib.sol';

/// @title VaultLib
/// @notice Externally-deployed library for ERC-4626 vault management operations
/// @dev Deployed as a separate contract and called via DELEGATECALL to reduce vault bytecode.
///      Accesses YieldStrategyMixin's ERC-7201 namespaced storage directly via the same slot constant.
library VaultLib {
    using SafeERC20 for IERC20;

    function _getStorage() private pure returns (StorageLib.YieldStrategyStorage storage $) {
        return StorageLib.getYieldStrategyStorage();
    }

    // ============ Vault Management ============

    /// @notice Add a new external vault
    /// @param vault Address of the ERC-4626 vault
    /// @param cap Maximum USDC to deposit (0 = unlimited)
    /// @param reservedUsdc Amount of USDC reserved (protocol fees) — not available for vault supply
    function addVault(address vault, uint256 cap, uint256 reservedUsdc) external {
        StorageLib.YieldStrategyStorage storage $ = _getStorage();

        if (vault == address(0)) revert IPsiStakingVaultErrors.ZeroAddress();
        if ($.vaultIndex[vault] != 0) revert IPsiStakingVaultErrors.VaultAlreadyExists(vault);

        // Validate it's an ERC-4626 vault with correct asset
        address asset = IERC4626(vault).asset();
        if (asset != $.underlyingUsdc) revert IPsiStakingVaultErrors.ZeroAddress(); // Wrong asset

        $.vaults.push(DataTypes.ExternalVault({ vault: vault, cap: cap, active: true, emergencyActivated: false }));
        $.vaultIndex[vault] = $.vaults.length; // 1-indexed

        emit IPsiStakingVaultEvents.VaultAdded(vault, cap);

        if (!$.emergencyMode) {
            _trySupplyIdleToVaults(reservedUsdc);
        }
    }

    /// @notice Remove a vault (withdraws all, redistributes)
    /// @param vault Address of the vault to remove
    /// @param reservedUsdc Amount of USDC reserved (protocol fees)
    /// @return withdrawn Amount withdrawn from the vault
    function removeVault(address vault, uint256 reservedUsdc) external returns (uint256 withdrawn) {
        StorageLib.YieldStrategyStorage storage $ = _getStorage();

        uint256 idx = $.vaultIndex[vault];
        if (idx == 0) revert IPsiStakingVaultErrors.VaultNotFound(vault);
        idx--; // Convert to 0-indexed

        // Withdraw everything from this vault
        withdrawn = _withdrawAllFromVault(vault);

        // Remove approval
        IERC20($.underlyingUsdc).forceApprove(vault, 0);

        // Remove from array by swapping with last
        uint256 lastIdx = $.vaults.length - 1;
        if (idx != lastIdx) {
            DataTypes.ExternalVault storage lastVault = $.vaults[lastIdx];
            $.vaults[idx] = lastVault;
            $.vaultIndex[lastVault.vault] = idx + 1;
        }
        $.vaults.pop();
        delete $.vaultIndex[vault];

        emit IPsiStakingVaultEvents.VaultRemoved(vault, withdrawn);

        // Try to redeposit to remaining vaults if not in emergency mode
        // Non-reverting: any leftover stays idle in contract
        if (!$.emergencyMode && withdrawn > 0) {
            _trySupplyToVaults(withdrawn, reservedUsdc);
        }
    }

    /// @notice Update vault cap
    function setVaultCap(address vault, uint256 newCap) external {
        StorageLib.YieldStrategyStorage storage $ = _getStorage();

        uint256 idx = $.vaultIndex[vault];
        if (idx == 0) revert IPsiStakingVaultErrors.VaultNotFound(vault);
        idx--;

        uint256 oldCap = $.vaults[idx].cap;
        $.vaults[idx].cap = newCap;

        emit IPsiStakingVaultEvents.VaultCapUpdated(vault, oldCap, newCap);
    }

    /// @notice Enable or disable a vault for new deposits
    function setVaultActive(address vault, bool active) external {
        StorageLib.YieldStrategyStorage storage $ = _getStorage();

        uint256 idx = $.vaultIndex[vault];
        if (idx == 0) revert IPsiStakingVaultErrors.VaultNotFound(vault);
        idx--;

        $.vaults[idx].active = active;

        emit IPsiStakingVaultEvents.VaultActiveUpdated(vault, active);
    }

    /// @notice Swap the order of two vaults in the processing queue
    /// @dev Vault order matters for efficiency - vaults are processed in array order.
    ///      Higher-APY or preferred vaults should be placed earlier.
    /// @param vault1 First vault address
    /// @param vault2 Second vault address
    function swapVaultOrder(address vault1, address vault2) external {
        StorageLib.YieldStrategyStorage storage $ = _getStorage();

        if (vault1 == vault2) return;

        // Get indexes (1-indexed in mapping)
        uint256 idx1 = $.vaultIndex[vault1];
        uint256 idx2 = $.vaultIndex[vault2];

        if (idx1 == 0) revert IPsiStakingVaultErrors.VaultNotFound(vault1);
        if (idx2 == 0) revert IPsiStakingVaultErrors.VaultNotFound(vault2);

        // Convert to 0-indexed
        idx1--;
        idx2--;

        // Swap in array
        DataTypes.ExternalVault memory temp = $.vaults[idx1];
        $.vaults[idx1] = $.vaults[idx2];
        $.vaults[idx2] = temp;

        // Update index mapping (back to 1-indexed)
        $.vaultIndex[vault1] = idx2 + 1;
        $.vaultIndex[vault2] = idx1 + 1;

        emit IPsiStakingVaultEvents.VaultsSwapped(vault1, vault2, idx1, idx2);
    }

    // ============ Emergency Mode ============

    /// @notice Enable emergency mode (withdraw all from vaults)
    function enableEmergencyMode() external {
        StorageLib.YieldStrategyStorage storage $ = _getStorage();

        if ($.emergencyMode) return;

        // Withdraw from all vaults
        for (uint256 i = 0; i < $.vaults.length; i++) {
            _withdrawMaxFromVault($.vaults[i].vault);
        }

        $.emergencyMode = true;
        emit IPsiStakingVaultEvents.EmergencyModeUpdated(true);
    }

    /// @notice Withdraw maximum possible from vaults during emergency
    /// @param vault Optional specific vault address. If address(0), withdraws from all vaults (requires global emergency mode)
    /// @dev If vault is specified, withdraws from that vault only (regardless of emergency mode)
    function withdrawMaxDuringEmergency(address vault) external {
        StorageLib.YieldStrategyStorage storage $ = _getStorage();

        // If withdrawing from specific vault, allow regardless of global emergency mode
        if (vault != address(0)) {
            _withdrawMaxFromVault(vault);
            return;
        }

        // For withdrawing from all vaults, require global emergency mode
        if (!$.emergencyMode) revert IPsiStakingVaultErrors.NotInEmergencyMode();

        // Withdraw from all vaults
        for (uint256 i = 0; i < $.vaults.length; i++) {
            _withdrawMaxFromVault($.vaults[i].vault);
        }
    }

    /// @notice Disable emergency mode
    /// @param reservedUsdc Amount of USDC reserved (protocol fees)
    function disableEmergencyMode(uint256 reservedUsdc) external {
        StorageLib.YieldStrategyStorage storage $ = _getStorage();

        if (!$.emergencyMode) revert IPsiStakingVaultErrors.NotInEmergencyMode();

        $.emergencyMode = false;
        emit IPsiStakingVaultEvents.EmergencyModeUpdated(false);

        // Try to redeposit idle Usdc to vaults
        // Non-reverting: any leftover stays idle in contract
        _trySupplyIdleToVaults(reservedUsdc);
    }

    /// @notice Enable emergency mode for a specific vault
    /// @dev Use when a single vault is compromised but others are safe
    /// @param vault Address of the vault to put in emergency mode
    /// @return withdrawn Amount withdrawn from the vault
    function enableVaultEmergency(address vault) external returns (uint256 withdrawn) {
        StorageLib.YieldStrategyStorage storage $ = _getStorage();

        uint256 idx = $.vaultIndex[vault];
        if (idx == 0) revert IPsiStakingVaultErrors.VaultNotFound(vault);
        idx--;

        DataTypes.ExternalVault storage v = $.vaults[idx];
        if (v.emergencyActivated) return 0;

        // Withdraw as much as possible from the vault
        withdrawn = _withdrawMaxFromVault(vault);
        v.emergencyActivated = true;

        emit IPsiStakingVaultEvents.VaultEmergencyUpdated(vault, true);

        return withdrawn;
    }

    /// @notice Disable emergency mode for a specific vault
    /// @param vault Address of the vault
    /// @param reservedUsdc Amount of USDC reserved (protocol fees)
    function disableVaultEmergency(address vault, uint256 reservedUsdc) external {
        StorageLib.YieldStrategyStorage storage $ = _getStorage();

        uint256 idx = $.vaultIndex[vault];
        if (idx == 0) revert IPsiStakingVaultErrors.VaultNotFound(vault);
        idx--;

        DataTypes.ExternalVault storage v = $.vaults[idx];
        if (!v.emergencyActivated) return;

        // Clear emergency flag
        v.emergencyActivated = false;

        emit IPsiStakingVaultEvents.VaultEmergencyUpdated(vault, false);

        // Try to redeposit idle Usdc to vaults (non-reverting)
        if (!$.emergencyMode) {
            _trySupplyIdleToVaults(reservedUsdc);
        }
    }

    // ============ Supply / Withdraw ============

    /// @notice Supply all idle USDC to external vaults (reverts if cannot supply all)
    /// Does prioritize existing idle funds that might be in the pool from removing vaults; If it can not be supplied in full, new depositors are not allowed.
    /// @dev Use for deposit flows where capacity was checked upfront
    /// @param reservedUsdc Amount of USDC reserved (protocol fees)
    function supplyToVaults(uint256 reservedUsdc) external {
        uint256 toBeSupplied = _getIdleUsdc(reservedUsdc);
        uint256 remaining = _trySupplyToVaults(toBeSupplied, reservedUsdc);
        if (remaining > 0) {
            revert IPsiStakingVaultErrors.SupplyOverflow(remaining, toBeSupplied);
        }
    }

    /// @notice Try to supply idle USDC to vaults (non-reverting)
    /// @dev Returns remaining amount that couldn't be supplied
    /// @param reservedUsdc Amount of USDC reserved (protocol fees)
    /// @return remaining Amount that couldn't be supplied
    function trySupplyIdleToVaults(uint256 reservedUsdc) external returns (uint256 remaining) {
        uint256 idle = _getIdleUsdc(reservedUsdc);
        if (idle == 0) return 0;
        remaining = _trySupplyToVaults(idle, reservedUsdc);
    }

    /// @notice Ensure contract has enough USDC available, withdrawing from vaults if needed
    /// @dev Also attempts to supply any excess idle Usdc back to vaults
    /// @param amount Amount of USDC needed
    /// @param reservedUsdc Amount of USDC reserved (protocol fees)
    function ensureUsdcBalance(uint256 amount, uint256 reservedUsdc) external {
        if (amount == 0) return;

        uint256 currentAvailable = _getIdleUsdc(reservedUsdc);

        // If we need more, withdraw from vaults
        if (currentAvailable < amount) {
            _withdrawFromVaults(amount - currentAvailable);
            return; //there is no excess if we had to withdraw more
        }

        // Try to supply any excess idle Usdc back to vaults
        // Anything above "amount" is excess
        if (currentAvailable > amount) {
            uint256 excess = currentAvailable - amount;
            _trySupplyToVaults(excess, reservedUsdc);
        }
    }

    /// @notice Withdraw USDC from external vaults
    /// @param amount Amount of USDC needed
    function withdrawFromVaults(uint256 amount) external {
        _withdrawFromVaults(amount);
    }

    // ============ Internal Functions ============

    /// @notice Try to supply USDC to external vaults (non-reverting)
    /// @dev Returns remaining amount that couldn't be supplied
    /// @param amount Amount of USDC to supply
    /// @param reservedUsdc Amount of USDC reserved — unused param kept for API consistency
    /// @return remaining Amount that couldn't be deposited
    function _trySupplyToVaults(uint256 amount, uint256 reservedUsdc) private returns (uint256 remaining) {
        // reservedUsdc is used only for _getIdleUsdc, not directly here
        (reservedUsdc);
        if (amount == 0) return 0;
        StorageLib.YieldStrategyStorage storage $ = _getStorage();

        if ($.emergencyMode) return amount;

        remaining = amount;

        // Fill vaults in order of priority
        for (uint256 i = 0; i < $.vaults.length && remaining > 0; i++) {
            DataTypes.ExternalVault storage v = $.vaults[i];
            if (!v.active || v.emergencyActivated) continue;

            uint256 canDeposit = _getAvailableCapacity(v);
            if (canDeposit == 0) continue;

            uint256 toDeposit = remaining < canDeposit ? remaining : canDeposit;

            IERC20($.underlyingUsdc).forceApprove(v.vault, toDeposit);
            uint256 shares = IERC4626(v.vault).deposit(toDeposit, address(this));
            IERC20($.underlyingUsdc).forceApprove(v.vault, 0);

            emit IPsiStakingVaultEvents.VaultDeposit(v.vault, toDeposit, shares);

            remaining -= toDeposit;
        }
    }

    /// @notice Supply all idle USDC to vaults (non-reverting)
    /// @dev Idle = contract balance - reserved amounts. Non-reverting.
    /// @return remaining Amount that couldn't be supplied to vaults
    function _trySupplyIdleToVaults(uint256 reservedUsdc) private returns (uint256 remaining) {
        uint256 idle = _getIdleUsdc(reservedUsdc);
        if (idle == 0) return 0;
        remaining = _trySupplyToVaults(idle, reservedUsdc);
    }

    /// @notice Withdraw USDC from external vaults
    /// @param amount Amount of Usdc needed
    function _withdrawFromVaults(uint256 amount) private {
        StorageLib.YieldStrategyStorage storage $ = _getStorage();

        if (amount == 0) return;

        uint256 remaining = amount;

        // Withdraw from vaults (reverse order for LIFO-like behavior)
        for (uint256 i = $.vaults.length; i > 0 && remaining > 0; i--) {
            DataTypes.ExternalVault storage v = $.vaults[i - 1];

            uint256 maxWithdraw = IERC4626(v.vault).maxWithdraw(address(this));
            if (maxWithdraw == 0) continue;

            uint256 toWithdraw = remaining < maxWithdraw ? remaining : maxWithdraw;
            // Calculate shares to redeem
            uint256 shares = IERC4626(v.vault).withdraw(toWithdraw, address(this), address(this));

            emit IPsiStakingVaultEvents.VaultWithdrawal(v.vault, shares, toWithdraw);

            remaining -= toWithdraw;
        }

        if (remaining > 0) revert IPsiStakingVaultErrors.InsufficientLiquidity(remaining);
    }

    /// @notice Withdraw as much as possible from a specific vault (non-reverting)
    /// @dev does not revert
    function _withdrawMaxFromVault(address vault) private returns (uint256 shares) {
        uint256 maxWithdraw = IERC4626(vault).maxWithdraw(address(this));
        if (maxWithdraw == 0) return 0;

        shares = IERC4626(vault).withdraw(maxWithdraw, address(this), address(this));

        emit IPsiStakingVaultEvents.VaultWithdrawal(vault, shares, maxWithdraw);
    }

    /// @notice Withdraw all from a specific vault (reverts if not all can be withdrawn)
    /// @dev reverts if not all can be withdrawn
    function _withdrawAllFromVault(address vault) private returns (uint256 withdrawn) {
        uint256 shares = IERC4626(vault).balanceOf(address(this));
        if (shares == 0) return 0;

        withdrawn = IERC4626(vault).redeem(shares, address(this), address(this));

        emit IPsiStakingVaultEvents.VaultWithdrawal(vault, shares, withdrawn);
    }

    // ============ View Functions ============

    /// @notice Returns the current USDC value of shares held in a specific vault
    function getVaultValue(address vault) external view returns (uint256) {
        return _getVaultValue(vault);
    }

    /// @notice Returns the total USDC value across all external vaults
    function getTotalVaultValue() external view returns (uint256) {
        return _getTotalVaultValue();
    }

    /// @notice Returns the total USDC value (idle balance plus vault deposits)
    function getTotalUsdcValue(uint256 reservedUsdc) external view returns (uint256) {
        return _getIdleUsdc(reservedUsdc) + _getTotalVaultValue();
    }

    /// @notice Returns whether the vault is in emergency mode
    function isEmergencyMode() external view returns (bool) {
        return _getStorage().emergencyMode;
    }

    /// @notice Returns all external vault addresses, balances, caps, and status flags
    function getExternalVaults()
        external
        view
        returns (
            address[] memory addresses,
            uint256[] memory balances,
            uint256[] memory caps,
            bool[] memory activeFlags,
            bool[] memory emergencyFlags
        )
    {
        StorageLib.YieldStrategyStorage storage $ = _getStorage();

        uint256 len = $.vaults.length;
        addresses = new address[](len);
        balances = new uint256[](len);
        caps = new uint256[](len);
        activeFlags = new bool[](len);
        emergencyFlags = new bool[](len);

        for (uint256 i = 0; i < len; i++) {
            DataTypes.ExternalVault storage v = $.vaults[i];
            addresses[i] = v.vault;
            caps[i] = v.cap;
            activeFlags[i] = v.active;
            emergencyFlags[i] = v.emergencyActivated;
            balances[i] = _getVaultValue(v.vault);
        }
    }

    /// @notice Returns the total available deposit capacity across all active vaults
    function getTotalAvailableCapacity(uint256 reservedUsdc) external view returns (uint256 total) {
        StorageLib.YieldStrategyStorage storage $ = _getStorage();

        if ($.emergencyMode) return 0;

        for (uint256 i = 0; i < $.vaults.length; i++) {
            DataTypes.ExternalVault storage v = $.vaults[i];
            if (!v.active || v.emergencyActivated) continue;

            uint256 capacity = _getAvailableCapacity(v);
            if (capacity == type(uint256).max) return type(uint256).max; //prevent potential overflow
            total += capacity;
        }

        // Subtract idle USDC (already in contract, pending deposit)
        uint256 idle = _getIdleUsdc(reservedUsdc);
        if (idle >= total) return 0;
        return total - idle;
    }

    /// @notice Returns the total available internal capacity based on vault caps
    function getTotalAvailableInternalCapacity(uint256 reservedUsdc) external view returns (uint256 total) {
        StorageLib.YieldStrategyStorage storage $ = _getStorage();

        if ($.emergencyMode) return 0;

        for (uint256 i = 0; i < $.vaults.length; i++) {
            DataTypes.ExternalVault storage v = $.vaults[i];
            if (!v.active || v.emergencyActivated) continue;
            if (v.cap == 0) return type(uint256).max;

            uint256 currentValue = _getVaultValue(v.vault);
            if (currentValue >= v.cap) continue;

            total += v.cap - currentValue;
        }

        // Subtract idle USDC (already in contract, pending deposit)
        uint256 idle = _getIdleUsdc(reservedUsdc);
        if (idle >= total) return 0;
        return total - idle;
    }

    /// @notice Returns the available deposit capacity for a specific vault
    function getAvailableCapacityByAddress(address vault) external view returns (uint256) {
        StorageLib.YieldStrategyStorage storage $ = _getStorage();
        uint256 index = $.vaultIndex[vault];
        DataTypes.ExternalVault storage v = $.vaults[index - 1];
        return _getAvailableCapacity(v);
    }

    // ============ Private Helpers ============

    /// @notice Get available deposit capacity for a vault
    function _getAvailableCapacity(DataTypes.ExternalVault storage v) private view returns (uint256) {
        if (!v.active || v.emergencyActivated) return 0;

        // Check vault's own max deposit
        uint256 maxDeposit = IERC4626(v.vault).maxDeposit(address(this));
        if (maxDeposit == 0) return 0;

        if (v.cap == 0) {
            // Unlimited cap
            return maxDeposit;
        }

        uint256 currentValue = _getVaultValue(v.vault);
        if (currentValue >= v.cap) return 0;

        uint256 capRemaining = v.cap - currentValue;
        return capRemaining < maxDeposit ? capRemaining : maxDeposit;
    }

    /// @notice Get the current USDC value of shares held in a vault
    function _getVaultValue(address vault) private view returns (uint256) {
        uint256 shares = IERC4626(vault).balanceOf(address(this));
        //using previewRedeem instead of convertToAssets to account for withdraw fees. This means that the vault cap does not include the fees.
        return IERC4626(vault).previewRedeem(shares);
    }

    /// @notice Get the total USDC value across all external vaults
    function _getTotalVaultValue() private view returns (uint256 total) {
        StorageLib.YieldStrategyStorage storage $ = _getStorage();
        for (uint256 i = 0; i < $.vaults.length; i++) {
            total += _getVaultValue($.vaults[i].vault);
        }
    }

    /// @notice Get idle USDC that can be supplied to vaults
    /// @dev Returns contract balance minus reserved amounts
    function _getIdleUsdc(uint256 reservedUsdc) private view returns (uint256) {
        StorageLib.YieldStrategyStorage storage $ = _getStorage();
        uint256 balance = IERC20($.underlyingUsdc).balanceOf(address(this));
        return balance > reservedUsdc ? balance - reservedUsdc : 0;
    }
}
