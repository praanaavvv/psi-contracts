// SPDX-License-Identifier: BSL-1.1
pragma solidity 0.8.31;

import { TimelockController } from '@openzeppelin/contracts/governance/TimelockController.sol';

/// @title PsiTimeLockController
/// @notice Timelock controller for governance-enforced delays on critical vault operations
/// @dev Wraps OpenZeppelin's TimelockController with no additional admin (address(0))
contract PsiTimeLockController is TimelockController {
    /// @notice Deploy the timelock controller
    /// @param minDelay Minimum delay in seconds before a queued operation can be executed
    /// @param proposers Addresses allowed to propose (schedule) operations
    /// @param executors Addresses allowed to execute ready operations
    constructor(uint256 minDelay, address[] memory proposers, address[] memory executors)
        TimelockController(minDelay, proposers, executors, address(0))
    { }
}
