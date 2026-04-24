// SPDX-License-Identifier: BSL-1.1
pragma solidity 0.8.31;

import { DataTypes } from '../types/DataTypes.sol';
import { IRobinStakingVaultEvents } from './IRobinStakingVaultEvents.sol';
import { IRobinStakingVaultErrors } from './IRobinStakingVaultErrors.sol';
import { IRobinAccountingView } from './IRobinAccountingView.sol';
import { IRobinPolymarketView } from './IRobinPolymarketView.sol';
import { IRobinYieldStrategyView } from './IRobinYieldStrategyView.sol';
import { IRobinSignaturesView } from './IRobinSignaturesView.sol';
import { IRobinPausableView } from './IRobinPausableView.sol';
import { IAccessControl } from '@openzeppelin/contracts/access/IAccessControl.sol';

/// @title IRobinStakingVault
/// @notice Full interface for the Robin vault
interface IRobinStakingVault is
    IAccessControl,
    IRobinAccountingView,
    IRobinPolymarketView,
    IRobinYieldStrategyView,
    IRobinSignaturesView,
    IRobinPausableView,
    IRobinStakingVaultEvents,
    IRobinStakingVaultErrors
{
    // ============ Initialization ============

    /// @notice Initialize the vault
    /// @param params Initialization parameters struct
    function initialize(DataTypes.InitParams calldata params) external;

    // ============ User Functions - Single Market ============

    /// @notice Deposit outcome tokens to a single market
    /// @param conditionId Polymarket condition ID
    /// @param yesAmount Amount of YES outcome tokens to deposit
    /// @param noAmount Amount of NO outcome tokens to deposit
    /// @param referralCode Referral code for off-chain tracking (0 = no referral)
    function deposit(bytes32 conditionId, uint256 yesAmount, uint256 noAmount, uint256 referralCode) external;

    /// @notice Withdraw outcome tokens from a single market
    /// @param conditionId Polymarket condition ID
    /// @param yesShares YES shares to burn (0 if none)
    /// @param noShares NO shares to burn (0 if none)
    /// @param yieldRecipient Address to receive the yield; If address(0), the yield will be sent to msg.sender
    /// @param referralCode Referral code for off-chain tracking (0 = no referral)
    function withdraw(bytes32 conditionId, uint256 yesShares, uint256 noShares, address yieldRecipient, uint256 referralCode) external;

    // ============ User Functions - Batch ============

    /// @notice Batch deposit to multiple markets
    /// @param conditionIds Array of condition IDs
    /// @param yesAmounts Array of YES amounts per market
    /// @param noAmounts Array of NO amounts per market
    /// @param nonZeroLength Length of non-zero amounts in yesAmounts and noAmounts arrays. Needed to decide the length of the arrays for the batch transfer. (better calculate offchain)
    /// @param referralCode Referral code for off-chain tracking (0 = no referral)
    function batchDeposit(
        bytes32[] calldata conditionIds,
        uint256[] calldata yesAmounts,
        uint256[] calldata noAmounts,
        uint256 nonZeroLength,
        uint256 referralCode
    ) external;

    /// @notice Batch withdraw from multiple markets
    /// @param conditionIds Array of condition IDs
    /// @param yesShares Array of YES shares to burn per market
    /// @param noShares Array of NO shares to burn per market
    /// @param yieldRecipient Address to receive the yield; If address(0), the yield will be sent to msg.sender
    /// @param nonZeroLength Length of non-zero amounts in yesShares and noShares arrays. Needed to decide the length of the arrays for the batch transfer. (better calculate offchain)
    /// @param referralCode Referral code for off-chain tracking (0 = no referral)
    function batchWithdraw(
        bytes32[] calldata conditionIds,
        uint256[] calldata yesShares,
        uint256[] calldata noShares,
        address yieldRecipient,
        uint256 nonZeroLength,
        uint256 referralCode
    ) external;

    // ============ User Functions - Signed Withdrawal ============

    /// @notice Execute a pre-signed withdrawal (single market only)
    /// @param signedWithdrawal Signed withdrawal data
    function executeSignedWithdrawal(DataTypes.SignedWithdrawal calldata signedWithdrawal) external;

    /// @notice Invalidate specific nonces to cancel signed withdrawals
    /// @param nonces Array of nonces to invalidate
    function invalidateNonces(uint256[] calldata nonces) external;

    /// @notice Invalidate all nonces in a word (cancel up to 256 orders at once)
    /// @param wordPos The word position to invalidate (invalidates nonces wordPos*256 to wordPos*256+255)
    function invalidateNonceWord(uint256 wordPos) external;

    // ============ Market Initialization ============

    /// @notice Initialize a market; Typically called by the backend right before a user transaction to save gas for the user
    /// @param conditionId Market condition ID
    function initializeMarket(bytes32 conditionId) external;

    // ============ Admin Functions - Vault Management ============

    /// @notice Add an external ERC-4626 vault
    /// @param vault Address of the external ERC-4626 vault
    /// @param cap Maximum capacity of the vault in USDC (0 = unlimited)
    function addVault(address vault, uint256 cap) external;

    /// @notice Remove an external vault
    /// @param vault Address of the external ERC-4626 vault
    function removeVault(address vault) external;

    /// @notice Update vault cap
    /// @param vault Address of the external ERC-4626 vault
    /// @param cap Maximum capacity of the vault in USDC (0 = unlimited)
    function setVaultCap(address vault, uint256 cap) external;

    /// @notice Enable or disable a vault for new deposits
    /// @param vault Address of the external ERC-4626 vault
    /// @param active True to enable, false to disable
    function setVaultActive(address vault, bool active) external;

    /// @notice Swap the order of two vaults in the processing queue
    /// @param vault1 Address of the first vault
    /// @param vault2 Address of the second vault
    function swapVaultOrder(address vault1, address vault2) external;

    /// @notice Manually supply idle Usdc to vaults
    /// @return supplied Amount that was successfully supplied to vaults
    function supplyIdleToVaults() external returns (uint256 supplied);

    // ============ Admin Functions - Protocol Fees ============

    /// @notice Set protocol fee
    /// @param newFeeBps New protocol fee in basis points (max 10000 = 100%)
    function setProtocolFeeBps(uint256 newFeeBps) external;

    /// @notice Harvest accumulated protocol fees
    /// @param to Address to receive the harvested protocol fees
    function harvestProtocolFee(address to) external;

    // ============ Admin Functions - Twap ============

    /// @notice Update Twap grace period
    /// @param gracePeriod New grace period in seconds (max 120 seconds)
    function setTwapGracePeriod(uint256 gracePeriod) external;

    /// @notice Set the Twap Oracle
    /// @param twapOracle Address of the Twap Oracle
    function setTwapOracle(address twapOracle) external;

    // ============ Admin Functions - Emergency ============

    /// @notice Enable emergency mode (withdraws all from vaults)
    function enableEmergencyMode() external;

    /// @notice Withdraw maximum possible from vaults during emergency
    /// @param vault Optional specific vault address. If address(0), withdraws from all vaults
    function withdrawMaxDuringEmergency(address vault) external;

    /// @notice Disable emergency mode and deposit idle Usdc back to vaults
    function disableEmergencyMode() external;

    /// @notice Enable emergency mode for a specific vault
    /// @param vault Address of the vault to put in emergency mode
    function enableVaultEmergency(address vault) external;

    /// @notice Disable emergency mode for a specific vault
    /// @param vault Address of the vault to disable emergency mode for
    function disableVaultEmergency(address vault) external;

    // ============ Admin Functions - Pause ============

    /// @notice Pause or unpause all vault operations
    /// @param paused True to pause, false to unpause
    function setPauseAll(bool paused) external;

    /// @notice Pause or unpause deposits only
    /// @param paused True to pause, false to unpause
    function setPauseDeposits(bool paused) external;

    /// @notice Pause or unpause withdrawals only
    /// @param paused True to pause, false to unpause
    function setPauseWithdrawals(bool paused) external;

    /// @notice Pause/unpause share token transfers
    /// @param paused True to pause, false to unpause
    function setPauseTransfers(bool paused) external;

    // ============ Admin Functions - ERC-1155 Metadata ============

    /// @notice Update the ERC-1155 metadata URI
    /// @param newuri New metadata URI (use {id} placeholder for token ID substitution)
    function setUri(string calldata newuri) external;

    // ============ Admin Functions - Extension ============

    /// @notice Set the extension contract address (for upgrades to the extension)
    /// @param newExtension Address of the new extension contract
    function setExtensionAddress(address newExtension) external;

    // ============ Roles ============

    /// @notice Role for general vault management operations (URI, signer updates)
    /// forge-lint: disable-next-line(mixed-case-function)
    function DEFAULT_MANAGER_ROLE() external view returns (bytes32);

    /// @notice Role for harvesting accumulated protocol fees
    /// forge-lint: disable-next-line(mixed-case-function)
    function FEE_HARVESTER_ROLE() external view returns (bytes32);

    /// @notice Role restricted to the timelock controller for sensitive operations (upgrades, fee changes)
    /// forge-lint: disable-next-line(mixed-case-function)
    function TIMELOCKED_ROLE() external view returns (bytes32);

    /// @notice Role for pausing and unpausing vault operations
    /// forge-lint: disable-next-line(mixed-case-function)
    function PAUSER_ROLE() external view returns (bytes32);

    /// @notice Role for managing external ERC-4626 yield vaults and emergency controls
    /// forge-lint: disable-next-line(mixed-case-function)
    function EXTERNAL_VAULT_MANAGER_ROLE() external view returns (bytes32);
}
