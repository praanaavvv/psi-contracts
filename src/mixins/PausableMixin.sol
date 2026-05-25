// SPDX-License-Identifier: BSL-1.1
pragma solidity 0.8.31;

import { Initializable } from '@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol';

import { IPsiStakingVaultEvents } from '../interfaces/IPsiStakingVaultEvents.sol';
import { IPsiStakingVaultErrors } from '../interfaces/IPsiStakingVaultErrors.sol';
import { StorageLib } from '../libraries/StorageLib.sol';

/// @title PausableMixin
/// @notice Granular pause controls for the Psi  vault
/// @dev Uses ERC-7201 namespaced storage pattern for upgradeability
abstract contract PausableMixin is Initializable, IPsiStakingVaultEvents, IPsiStakingVaultErrors {
    // ============ ERC-7201 Namespaced Storage ============

    function _getPausableStorage() private pure returns (StorageLib.PausableStorage storage) {
        return StorageLib.getPausableStorage();
    }

    // ============ Modifiers ============

    /// @notice Reverts if deposits are paused (either globally or deposits specifically)
    modifier whenDepositsNotPaused() {
        StorageLib.PausableStorage storage $ = _getPausableStorage();
        if ($.pausedAll) revert PausedAll();
        if ($.pausedDeposits) revert PausedDeposits();
        _;
    }

    /// @notice Reverts if withdrawals are paused (either globally or withdrawals specifically)
    modifier whenWithdrawalsNotPaused() {
        StorageLib.PausableStorage storage $ = _getPausableStorage();
        if ($.pausedAll) revert PausedAll();
        if ($.pausedWithdrawals) revert PausedWithdrawals();
        _;
    }

    // ============ View Functions ============

    /// @notice Returns whether all operations are paused
    function _isPausedAll() internal view virtual returns (bool) {
        return _getPausableStorage().pausedAll;
    }

    /// @notice Returns whether deposits are paused
    function _isPausedDeposits() internal view virtual returns (bool) {
        StorageLib.PausableStorage storage $ = _getPausableStorage();
        return $.pausedAll || $.pausedDeposits;
    }

    /// @notice Returns whether withdrawals are paused
    function _isPausedWithdrawals() internal view virtual returns (bool) {
        StorageLib.PausableStorage storage $ = _getPausableStorage();
        return $.pausedAll || $.pausedWithdrawals;
    }

    /// @notice Returns whether share transfers are paused
    function _isTransfersPaused() internal view virtual returns (bool) {
        StorageLib.PausableStorage storage $ = _getPausableStorage();
        return $.pausedAll || $.pausedTransfers;
    }

    // ============ Internal Functions ============

    /// @notice Set pause all operations
    /// @param paused True to pause, false to unpause
    function _setPauseAll(bool paused) internal {
        StorageLib.PausableStorage storage $ = _getPausableStorage();
        $.pausedAll = paused;
        emit PausedAllSet(paused);
    }

    /// @notice Set pause deposits
    /// @param paused True to pause, false to unpause
    function _setPauseDeposits(bool paused) internal {
        StorageLib.PausableStorage storage $ = _getPausableStorage();
        $.pausedDeposits = paused;
        emit PausedDepositsSet(paused);
    }

    /// @notice Set pause withdrawals
    /// @param paused True to pause, false to unpause
    function _setPauseWithdrawals(bool paused) internal {
        StorageLib.PausableStorage storage $ = _getPausableStorage();
        $.pausedWithdrawals = paused;
        emit PausedWithdrawalsSet(paused);
    }

    /// @notice Set pause transfers
    /// @param paused True to pause, false to unpause
    function _setPauseTransfers(bool paused) internal {
        StorageLib.PausableStorage storage $ = _getPausableStorage();
        $.pausedTransfers = paused;
        emit TransfersPausedSet(paused);
    }

    /// @notice Check if transfers are effectively not paused (either globally or transfers specifically)
    function _checkTransfersNotPaused() internal view {
        StorageLib.PausableStorage storage $ = _getPausableStorage();
        if ($.pausedAll) revert PausedAll();
        if ($.pausedTransfers) revert TransfersPaused();
    }
}
