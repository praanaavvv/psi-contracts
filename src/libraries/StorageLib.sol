// SPDX-License-Identifier: BSL-1.1
pragma solidity 0.8.31;

import { DataTypes } from '../types/DataTypes.sol';
import { IPsiTwapOracle } from '../interfaces/IPsiTwapOracle.sol';
import { IConditionalTokens } from '../interfaces/external/IConditionalTokens.sol';
import { INegRiskAdapter } from '../interfaces/external/INegRiskAdapter.sol';
import { IRegistry } from '../interfaces/external/IRegistry.sol';
import { IPolyFactoryHelper } from '../interfaces/external/IPolyFactoryHelper.sol';

/// @title StorageLib
/// @notice Single source of truth for all ERC-7201 namespaced storage structs, slot constants, and accessors.
/// @dev Both mixins and external libraries import from here to guarantee struct layout and slot alignment.
library StorageLib {
    // ============ Accounting ============

    /// @custom:storage-location erc7201:robin.storage.Accounting
    struct AccountingStorage {
        // Per-market state: conditionId => MarketState
        mapping(bytes32 => DataTypes.MarketState) markets;
        // Per-user per-market state: user => conditionId => UserMarketState
        mapping(address => mapping(bytes32 => DataTypes.UserMarketState)) userStates;
        // Global pool tracking
        uint256 totalPoolShares; // Sum of all market pool shares
        uint256 totalPoolAssets; // Actual Usdc in pool (principal + yield - loss)
        // Protocol fees
        uint256 protocolFeeBps; // Fee on yield (max 10000 = 100%)
        uint256 accumulatedProtocolFees; // Fees ready to harvest
        // Grace period for Twap timestamp validation (in seconds)
        uint256 twapGracePeriod;
        IPsiTwapOracle twapOracle;
        // ERC-1155 Share Token tracking
        mapping(uint256 => DataTypes.MarketTokenInfo) tokenInfo; // tokenId => metadata for reverse lookup
    }

    bytes32 internal constant ACCOUNTING_STORAGE_LOCATION = 0x07a8aa3d7f8084dac32d7935aa186166c18da33ac7814436fe3ae78cdd22ea00;

    function getAccountingStorage() internal pure returns (AccountingStorage storage $) {
        assembly {
            $.slot := ACCOUNTING_STORAGE_LOCATION
        }
    }

    // ============ YieldStrategy ============

    /// @custom:storage-location erc7201:robin.storage.YieldStrategy
    struct YieldStrategyStorage {
        // External ERC-4626 vaults (ordered for deposit priority)
        // This will only hold 2-3 vaults in production
        DataTypes.ExternalVault[] vaults;
        mapping(address => uint256) vaultIndex; // vault address => index + 1 (0 = not in list)
        // Underlying Usdc token
        address underlyingUsdc;
        // Emergency mode
        bool emergencyMode; // If true, no vault deposits, Usdc stays in contract
    }

    bytes32 internal constant YIELDSTRATEGY_STORAGE_LOCATION = 0xd8eb9ade092aa0dc31a799bb7e00aef9dc4ce6cbdc1173946b33cbcbb48c9c00;

    function getYieldStrategyStorage() internal pure returns (YieldStrategyStorage storage $) {
        assembly {
            $.slot := YIELDSTRATEGY_STORAGE_LOCATION
        }
    }

    // ============ Polymarket ============

    /// @custom:storage-location erc7201:robin.storage.Polymarket
    struct PolymarketStorage {
        // Polymarket infrastructure addresses
        IConditionalTokens ctf; // Conditional Tokens Framework
        INegRiskAdapter negRiskAdapter;
        IRegistry negRiskCtfExchange;
        IRegistry ctfExchange;
        address underlyingUsdc; // Usdc.e
        address polymarketWcol; // WCOL
        uint256 maximumAdditionalMatchedTokens; // Total amount of matched tokens that could additionally be paired
        // Per-market Polymarket token info: conditionId => PolymarketTokenInfo
        mapping(bytes32 => DataTypes.PolymarketTokenInfo) tokenInfo;
    }

    bytes32 internal constant POLYMARKET_STORAGE_LOCATION = 0x996716fa23045e0aecf8c8f0b6f4eb21669555365c754469b4d4dd3e1cee6a00;

    function getPolymarketStorage() internal pure returns (PolymarketStorage storage $) {
        assembly {
            $.slot := POLYMARKET_STORAGE_LOCATION
        }
    }

    // ============ Pausable ============

    /// @custom:storage-location erc7201:robin.storage.Pausable
    struct PausableStorage {
        bool pausedAll;
        bool pausedDeposits;
        bool pausedWithdrawals;
        bool pausedTransfers;
    }

    bytes32 internal constant PAUSABLE_STORAGE_LOCATION = 0x8e24408939e53bc18e64f6e826fe4328418837db5b32e520c88d102d39b0c100;

    function getPausableStorage() internal pure returns (PausableStorage storage $) {
        assembly {
            $.slot := PAUSABLE_STORAGE_LOCATION
        }
    }

    // ============ Signatures ============

    /// @custom:storage-location erc7201:robin.storage.Signatures
    struct SignaturesStorage {
        /// @notice The Polymarket CTF Exchange Contract
        IPolyFactoryHelper polymarketFactoryHelper;
        // Bitmap nonce tracking for signed withdrawals: user => wordPos => bitmap
        // Each bit represents whether a nonce has been used (1 = used, 0 = available)
        // nonce n is stored at: bitmap[user][n / 256] & (1 << (n % 256))
        mapping(address => mapping(uint256 => uint256)) nonceBitmap;
    }

    bytes32 internal constant SIGNATURES_STORAGE_LOCATION = 0x19e9f82ffdb8e399c53e4874d0c95cc8fb0c18c1634beccc867c55a407691b00;

    function getSignaturesStorage() internal pure returns (SignaturesStorage storage $) {
        assembly {
            $.slot := SIGNATURES_STORAGE_LOCATION
        }
    }

    // ============ Extension ============

    /// @custom:storage-location erc7201:robin.storage.Extension
    struct ExtensionStorage {
        address extension;
    }

    bytes32 internal constant EXTENSION_STORAGE_LOCATION = 0x1018adf3f8510fb79a0ec37a7a5650016754d9443e0fe3393d69ee144be5f600;

    function getExtensionStorage() internal pure returns (ExtensionStorage storage $) {
        assembly {
            $.slot := EXTENSION_STORAGE_LOCATION
        }
    }
}
