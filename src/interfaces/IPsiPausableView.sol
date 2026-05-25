// SPDX-License-Identifier: BSL-1.1
pragma solidity 0.8.31;

/// @title IPsiPausableView
/// @notice Sub-interface for PausableMixin view functions
interface IPsiPausableView {
    /// @notice Check if all operations are paused
    /// @return True if the global pause is active
    function isPausedAll() external view returns (bool);

    /// @notice Check if deposits are paused (either globally or deposits specifically)
    /// @return True if deposits are currently blocked
    function isPausedDeposits() external view returns (bool);

    /// @notice Check if withdrawals are paused (either globally or withdrawals specifically)
    /// @return True if withdrawals are currently blocked
    function isPausedWithdrawals() external view returns (bool);

    /// @notice Check if share transfers are paused (either globally or transfers specifically)
    /// @return True if ERC-1155 share transfers are currently blocked
    function isTransfersPaused() external view returns (bool);
}
