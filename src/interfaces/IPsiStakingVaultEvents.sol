// SPDX-License-Identifier: BSL-1.1
pragma solidity 0.8.31;

import { DataTypes } from '../types/DataTypes.sol';

/// @title IPsiStakingVaultEvents
/// @notice All events for the Psi vault system
interface IPsiStakingVaultEvents {
    // ============ Core User Events ============

    /// @notice Emitted when user batch deposits to multiple markets
    /// @param referralCode Referral code for off-chain tracking (0 = no referral)
    event Deposited(
        address indexed user,
        uint256 indexed referralCode,
        bytes32[] conditionIds,
        uint256[] yesAmounts,
        uint256[] noAmounts,
        uint256[] yesShares,
        uint256[] noShares
    );

    /// @notice Emitted when user batch withdraws from multiple markets
    /// @param referralCode Referral code for off-chain tracking (0 = no referral)
    event Withdrawn(
        address indexed user,
        uint256 indexed referralCode,
        bytes32[] conditionIds,
        uint256[] yesShares,
        uint256[] noShares,
        uint256[] yesAssets,
        uint256[] noAssets,
        uint256 yield,
        uint256 protocolFee
    );

    /// @notice Emitted when a signed withdrawal is executed
    event SignedWithdrawalExecuted(
        address indexed user, bytes32 indexed conditionId, address indexed executor, uint256 yesShares, uint256 noShares, uint256 nonce
    );

    /// @notice Emitted when nonces are invalidated (orders cancelled)
    event NoncesInvalidated(address indexed user, uint256[] nonces);

    /// @notice Emitted when a full nonce word is invalidated
    event NonceWordInvalidated(address indexed user, uint256 wordPos);

    // ============ Yield Index Events ============

    /// @notice Emitted when loss and yield indexes are updated for a market
    event IndexesUpdated(
        bytes32 indexed conditionId,
        uint256 lossIndexYes,
        uint256 lossIndexNo,
        uint256 yieldPerShareYes,
        uint256 yieldPerShareNo,
        uint256 yieldReductionFactor,
        uint256 principalContributed
    );

    // ============ Vault Management Events ============

    /// @notice Emitted when an external ERC-4626 vault is added
    event VaultAdded(address indexed vault, uint256 cap);

    /// @notice Emitted when an external vault is removed
    event VaultRemoved(address indexed vault, uint256 withdrawnAmount);

    /// @notice Emitted when vault cap is updated
    event VaultCapUpdated(address indexed vault, uint256 oldCap, uint256 newCap);

    /// @notice Emitted when vault active status is updated
    event VaultActiveUpdated(address indexed vault, bool active);

    /// @notice Emitted when two vaults are swapped in the processing order
    event VaultsSwapped(address indexed vault1, address indexed vault2, uint256 index1, uint256 index2);

    /// @notice Emitted when funds are deposited to an external vault
    event VaultDeposit(address indexed vault, uint256 amount, uint256 shares);

    /// @notice Emitted when funds are withdrawn from an external vault
    event VaultWithdrawal(address indexed vault, uint256 shares, uint256 amount);

    // ============ Protocol Fee Events ============

    /// @notice Emitted when protocol fee is updated
    event ProtocolFeeUpdated(uint256 oldFeeBps, uint256 newFeeBps);

    /// @notice Emitted when protocol fees are harvested
    event ProtocolFeeHarvested(address indexed to, uint256 amount);

    // ============ Emergency Events ============

    /// @notice Emitted when emergency mode is toggled
    event EmergencyModeUpdated(bool enabled);

    /// @notice Emitted when a vault's emergency mode is toggled
    event VaultEmergencyUpdated(address indexed vault, bool emergencyActivated);

    // ============ Pause Events ============

    /// @notice Emitted when all operations pause state is changed
    event PausedAllSet(bool paused);

    /// @notice Emitted when deposits pause state is changed
    event PausedDepositsSet(bool paused);

    /// @notice Emitted when withdrawals pause state is changed
    event PausedWithdrawalsSet(bool paused);

    // ============ Share Token Events ============

    /// @notice Emitted when share token transfers are paused/unpaused
    event TransfersPausedSet(bool paused);

    /// @notice Emitted when share tokens are transferred between users
    /// @param from Sender address
    /// @param to Receiver address
    /// @param conditionId Market condition ID
    /// @param side Market side (YES or NO)
    /// @param sharesTransferred Amount of shares transferred
    /// @param receiverYieldSnapshot Receiver's yield snapshot for this side after transfer
    event SharesTransferred(
        address indexed from,
        address indexed to,
        bytes32 indexed conditionId,
        DataTypes.Side side,
        uint256 sharesTransferred,
        uint128 receiverYieldSnapshot
    );

    // ============ Market Events ============

    /// @notice Emitted when a new market is auto-initialized on first deposit
    event MarketInitialized(bytes32 indexed conditionId, uint256 yesPositionId, uint256 noPositionId, bool negRisk);

    // ============ Polymarket Events ============

    /// @notice Emitted when tokens are paired and merged to Usdc
    event TokensPaired(bytes32 indexed conditionId, uint256 pairsAmount, uint256 usdcReceived);

    /// @notice Emitted when Usdc is split back to outcome tokens
    event TokensSplit(bytes32 indexed conditionId, uint256 usdcAmount, uint256 tokensReceived);

    // ============ TWAP Control Events ============

    /// @notice Emitted when Twap grace period is updated
    event TwapGracePeriodUpdated(uint256 oldGracePeriod, uint256 newGracePeriod);

    // ============ Extension Events ============

    /// @notice Emitted when the extension contract address is updated
    event ExtensionAddressUpdated(address indexed newExtension);
}
