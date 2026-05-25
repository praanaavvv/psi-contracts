// SPDX-License-Identifier: BSL-1.1
pragma solidity 0.8.31;

/// @title IPsiStakingVaultErrors
/// @notice All custom errors for the Psi vault system
interface IPsiStakingVaultErrors {
    // ============ Input Validation Errors ============

    /// @notice Thrown when zero address is provided
    error ZeroAddress();

    /// @notice Thrown when zero amount is provided
    error ZeroAmount();

    /// @notice Thrown when array lengths don't match
    error LengthMismatch();

    /// @notice Thrown when conditionId is invalid (zero or unrecognized)
    error InvalidConditionId(bytes32 conditionId);

    /// @notice Thrown when an invalid side is specified
    error InvalidSide();

    /// @notice Thrown when fee exceeds maximum
    error InvalidFeeBps(uint256 bps);

    // ============ Share/Balance Errors ============

    /// @notice Thrown when user has insufficient shares
    error InsufficientShares(uint256 requested, uint256 available);

    /// @notice Thrown when contract has insufficient liquidity for withdrawal
    error InsufficientLiquidity(uint256 needed);

    /// @notice Thrown when there's insufficient unpaired tokens
    error InsufficientUnpairedTokens(uint256 needed, uint256 available);

    // ============ Twap Errors ============

    /// @notice Thrown when Twap grace period exceeds maximum
    error TwapGracePeriodExceedsMax(uint256 requested, uint256 max);

    // ============ Signed Withdrawal Errors ============

    /// @notice Thrown when signed withdrawal has expired
    error WithdrawalExpired(uint256 expiry, uint256 currentTime);

    /// @notice Thrown when withdrawal nonce has been used
    error WithdrawalNonceUsed(address user, uint256 nonce);

    /// @notice Thrown when withdrawal signature is invalid
    error InvalidWithdrawalSignature();

    /// @notice Thrown when withdrawal would result in loss and protectAgainstLoss is enabled
    error WithdrawalWouldResultInLoss();

    // ============ External Vault Errors ============

    /// @notice Thrown when vault is not found in the list
    error VaultNotFound(address vault);

    /// @notice Thrown when vault already exists
    error VaultAlreadyExists(address vault);

    /// @notice Thrown when vault cap would be exceeded
    error VaultCapExceeded(address vault, uint256 cap, uint256 requested);

    /// @notice Thrown when vault withdrawal fails
    error VaultWithdrawalFailed(address vault);

    /// @notice Thrown when no vaults are available for deposit
    error NoVaultsAvailable();

    /// @notice Thrown when deposit would exceed total vault capacity
    error CapacityExceeded(uint256 capacityNeeded, uint256 capacityAvailable);

    /// @notice Thrown when supply to vaults fails to deposit all Usdc
    error SupplyOverflow(uint256 remaining, uint256 expected);

    // ============ Market Errors ============

    /// @notice Thrown when trying to operate on uninitialized market
    error MarketNotInitialized(bytes32 conditionId);

    /// @notice Thrown when market is already initialized
    error MarketAlreadyInitialized(bytes32 conditionId);

    /// @notice Thrown when market doesn't have exactly 2 outcome slots
    error InvalidOutcomeSlotCount(bytes32 conditionId, uint256 count);

    /// @notice Thrown when depositing into a side whose lossIndex has reached zero (total loss)
    error MarketSideBroken();

    /// @notice Thrown when condition is not listed on any exchange
    error UnlistedCondition(bytes32 conditionId);

    // ============ Polymarket Errors ============

    /// @notice Thrown when CTF approval is not granted
    error CTFApprovalRequired();

    /// @notice Thrown when merge fails due to insufficient pairs
    error MergeInsufficientPairs(uint256 yesAvailable, uint256 noAvailable);

    /// @notice Thrown when split operation fails
    error SplitFailed();

    // ============ Emergency/Pause Errors ============

    /// @notice Thrown when operation is blocked due to emergency mode
    error EmergencyModeActive();

    /// @notice Thrown when trying to exit emergency but not in emergency
    error NotInEmergencyMode();

    /// @notice Thrown when all operations are paused
    error PausedAll();

    /// @notice Thrown when deposits are paused
    error PausedDeposits();

    /// @notice Thrown when withdrawals are paused
    error PausedWithdrawals();

    /// @notice Thrown when share transfers are paused
    error TransfersPaused();

    // ============ Share Token Errors ============

    /// @notice Thrown when token ID is unknown (not initialized)
    error UnknownTokenId(uint256 tokenId);

    // ============ Protocol Fee Errors ============

    /// @notice Thrown when there are no fees to harvest
    error NoFeesToHarvest();
}
