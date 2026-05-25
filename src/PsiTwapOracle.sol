// SPDX-License-Identifier: BSL-1.1
pragma solidity 0.8.31;

import { Initializable } from '@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol';
import { UUPSUpgradeable } from '@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol';
import { AccessControlUpgradeable } from '@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol';
import { Math } from '@openzeppelin/contracts/utils/math/Math.sol';
import { DataTypes } from './types/DataTypes.sol';
import { TwapMath } from './libraries/TwapMath.sol';
import { IPsiTwapOracle } from './interfaces/IPsiTwapOracle.sol';
import { EIP712Upgradeable } from '@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol';
import { PausableUpgradeable } from '@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol';
import { ECDSA } from '@openzeppelin/contracts/utils/cryptography/ECDSA.sol';

/// @title PsiTwapOracle
/// @notice Oracle for Psi Twap markets
contract PsiTwapOracle is Initializable, UUPSUpgradeable, AccessControlUpgradeable, EIP712Upgradeable, PausableUpgradeable, IPsiTwapOracle {
    using Math for uint256;

    // ============ Roles ============

    /// @inheritdoc IPsiTwapOracle
    bytes32 public constant DEFAULT_MANAGER_ROLE = keccak256('DEFAULT_MANAGER_ROLE');

    /// @inheritdoc IPsiTwapOracle
    bytes32 public constant TIMELOCKED_ROLE = keccak256('TIMELOCKED_ROLE');

    /// @inheritdoc IPsiTwapOracle
    bytes32 public constant VAULT_ROLE = keccak256('VAULT_ROLE');

    // ============ Constants ============

    /// @inheritdoc IPsiTwapOracle
    bytes32 public constant TWAP_TYPEHASH = keccak256(
        'TwapData(bool required,bytes32 conditionId,uint256 startTimestamp,uint256 endTimestamp,uint256 twapPriceYes,uint256 marketEndedAt,uint256 marketEndYesPrice)'
    );

    /// @inheritdoc IPsiTwapOracle
    bytes32 public constant BATCH_TWAP_TYPEHASH = keccak256(
        'BatchTwapData(TwapData[] markets)TwapData(bool required,bytes32 conditionId,uint256 startTimestamp,uint256 endTimestamp,uint256 twapPriceYes,uint256 marketEndedAt,uint256 marketEndYesPrice)'
    );

    // ============ Storage ============
    /// @custom:storage-location erc7201:robin.storage.TwapOracle
    struct TwapOracleStorage {
        // Per-market state: conditionId => MarketState
        mapping(bytes32 => MarketState) markets;
        // Trusted signer for Twap data
        address twapSigner;
        // TWAP control switches
        bool defaultTwapRequired; // Default twapRequired for newly initialized markets
        bool globalTwapRequired; // Forces TWAP for all markets (overrides individual market settings)
        bool globalTwapDisabled; // Disables TWAP for all markets (highest priority, overrides everything; used for example when Oracle temporarily ceased to function)
    }

    /// @dev keccak256(abi.encode(uint256(keccak256("robin.storage.TwapOracle")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant TWAP_ORACLE_STORAGE_LOCATION = 0x477cea75feb6824a9b11e7a008dffe5153af5479f4ebf06b77fd3ef00c863500;

    function _getTwapOracleStorage() private pure returns (TwapOracleStorage storage $) {
        assembly {
            $.slot := TWAP_ORACLE_STORAGE_LOCATION
        }
    }

    // ============ Constructor ============

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // ============ Initialization ============

    /// @notice Initialize the Psi Twap Oracle
    function initialize(address initialOwner, address timelockController, string memory name, string memory version, address twapSigner)
        external
        initializer
    {
        if (initialOwner == address(0)) revert ZeroAddress();

        __AccessControl_init();
        __EIP712_init(name, version);
        __Pausable_init();

        // Grant roles
        _grantRole(DEFAULT_ADMIN_ROLE, initialOwner);
        _grantRole(DEFAULT_MANAGER_ROLE, initialOwner);

        // Setup Timelock
        _grantRole(TIMELOCKED_ROLE, timelockController);
        // Make TIMELOCKED_ROLE self-administered
        _setRoleAdmin(TIMELOCKED_ROLE, TIMELOCKED_ROLE);

        if (twapSigner == address(0)) revert ZeroAddress();
        TwapOracleStorage storage $ = _getTwapOracleStorage();
        $.twapSigner = twapSigner;
    }

    // ============ External Functions ============

    /// @inheritdoc IPsiTwapOracle
    function initializeMarket(bytes32 conditionId, uint256 yesPositionId, uint256 noPositionId, bool negRisk) external onlyRole(VAULT_ROLE) {
        MarketState storage market = _getTwapOracleStorage().markets[conditionId];

        if (market.lastTwapUpdate > 0) return;

        uint40 nowStamp = uint40(block.timestamp);
        market.marketInitTimestamp = nowStamp;
        market.lastTwapUpdate = nowStamp;
        // Set twapRequired based on global default
        market.twapRequired = _getTwapOracleStorage().defaultTwapRequired;

        //We emit this also from the main contract, but we need it here as well for indexing
        emit MarketInitialized(conditionId, yesPositionId, noPositionId, negRisk);
    }

    /// @inheritdoc IPsiTwapOracle
    function submitTwap(DataTypes.BatchTwapData calldata twapData) external whenNotPaused {
        if (twapData.markets.length == 0) revert ZeroAmount();

        bool signatureRequired = false;
        for (uint256 i = 0; i < twapData.markets.length; i++) {
            if (!isMarketInitialized(twapData.markets[i].conditionId)) continue;

            bool marketSignatureRequired = _processTwapForMarket(twapData.markets[i]);
            if (marketSignatureRequired) {
                signatureRequired = true;
            }
        }

        if (signatureRequired && !_verifyBatchTwapSignature(twapData)) revert InvalidTwapSignature();
    }

    // ============ View Functions ============

    /// @inheritdoc IPsiTwapOracle
    function domainSeparator() public view returns (bytes32) {
        return _domainSeparatorV4();
    }

    /// @inheritdoc IPsiTwapOracle
    function getMarketState(bytes32 conditionId) public view returns (MarketState memory) {
        return _getTwapOracleStorage().markets[conditionId];
    }

    /// @inheritdoc IPsiTwapOracle
    function isMarketInitialized(bytes32 conditionId) public view returns (bool) {
        return _getTwapOracleStorage().markets[conditionId].lastTwapUpdate > 0;
    }

    /// @inheritdoc IPsiTwapOracle
    function getTwapAccumulators(bytes32 conditionId)
        public
        view
        returns (uint256 twapAccumulatorYes, uint256 twapAccumulatorNo, uint256 lastUpdate)
    {
        MarketState storage market = _getTwapOracleStorage().markets[conditionId];
        twapAccumulatorYes = market.twapAccumulatorYes;
        lastUpdate = market.lastTwapUpdate;
        // Calculate twapAccumulatorNo from twapAccumulatorYes and total time
        if (lastUpdate > 0) {
            uint256 totalTime = lastUpdate - market.marketInitTimestamp;
            twapAccumulatorNo = TwapMath.calculateTwapAccumulatorNo(twapAccumulatorYes, totalTime);
        }
    }

    /// @inheritdoc IPsiTwapOracle
    function batchGetMarketState(bytes32[] calldata conditionIds) public view returns (MarketState[] memory states, bool[] memory signatureRequired) {
        uint256 len = conditionIds.length;
        states = new MarketState[](len);
        signatureRequired = new bool[](len);
        for (uint256 i = 0; i < len; i++) {
            states[i] = _getTwapOracleStorage().markets[conditionIds[i]];
            signatureRequired[i] = isTwapSignatureRequired(conditionIds[i]);
        }
    }

    /// @inheritdoc IPsiTwapOracle
    function getTwapSigner() public view returns (address) {
        return _getTwapOracleStorage().twapSigner;
    }

    /// @inheritdoc IPsiTwapOracle
    function getDefaultTwapRequired() public view returns (bool) {
        return _getTwapOracleStorage().defaultTwapRequired;
    }

    /// @inheritdoc IPsiTwapOracle
    function getGlobalTwapRequired() public view returns (bool) {
        return _getTwapOracleStorage().globalTwapRequired;
    }

    /// @inheritdoc IPsiTwapOracle
    function getGlobalTwapDisabled() public view returns (bool) {
        return _getTwapOracleStorage().globalTwapDisabled;
    }

    /// @inheritdoc IPsiTwapOracle
    function isMarketTwapRequired(bytes32 conditionId) public view returns (bool) {
        return _getTwapOracleStorage().markets[conditionId].twapRequired;
    }

    /// @inheritdoc IPsiTwapOracle
    function isMarketFinalized(bytes32 conditionId) public view returns (bool) {
        return _getTwapOracleStorage().markets[conditionId].marketEndedAt > 0;
    }

    /// @inheritdoc IPsiTwapOracle
    /// @dev Priority: globalTwapDisabled > globalTwapRequired > individual market setting
    function isEffectiveTwapRequired(bytes32 conditionId) public view returns (bool) {
        if (_getTwapOracleStorage().globalTwapDisabled) return false;
        if (_getTwapOracleStorage().globalTwapRequired) return true;
        return _getTwapOracleStorage().markets[conditionId].twapRequired;
    }

    /// @inheritdoc IPsiTwapOracle
    function isTwapSignatureRequired(bytes32 conditionId) public view returns (bool) {
        return isEffectiveTwapRequired(conditionId) && !isMarketFinalized(conditionId);
    }

    /// @inheritdoc IPsiTwapOracle
    function getCurrentTwapAccumulator(bytes32 conditionId) external view returns (uint256 twapAccumulatorYes, uint256 lastUpdate) {
        MarketState storage market = _getTwapOracleStorage().markets[conditionId];

        if (market.marketEndedAt > 0) {
            uint256 timeDiff = block.timestamp - market.marketEndedAt;
            uint256 twapAccumulatorYesDelta = market.marketEndYesPrice * timeDiff;
            twapAccumulatorYes = market.twapAccumulatorYes + twapAccumulatorYesDelta;
            return (twapAccumulatorYes, block.timestamp);
        }

        if (!isEffectiveTwapRequired(conditionId)) {
            uint256 timeDiff = block.timestamp - market.lastTwapUpdate;
            uint256 twapAccumulatorYesDelta = TwapMath.defaultPrice() * timeDiff;
            twapAccumulatorYes = market.twapAccumulatorYes + twapAccumulatorYesDelta;
            return (twapAccumulatorYes, block.timestamp);
        }

        return (market.twapAccumulatorYes, market.lastTwapUpdate);
    }

    // ============ Admin Functions ============

    /// @notice Set Twap requirement for a market
    function setMarketTwapRequired(bytes32 conditionId, bool required) public onlyRole(DEFAULT_MANAGER_ROLE) {
        if (!isMarketInitialized(conditionId)) revert MarketNotInitialized(conditionId); //if we need to set it before initializing, call initializeMarket on the vault contract.
        _getTwapOracleStorage().markets[conditionId].twapRequired = required;
        emit MarketTwapRequirementUpdated(conditionId, required);
    }

    /// @inheritdoc IPsiTwapOracle
    function setDefaultTwapRequired(bool required) public onlyRole(DEFAULT_MANAGER_ROLE) {
        _getTwapOracleStorage().defaultTwapRequired = required;
        emit DefaultTwapRequiredUpdated(required);
    }

    /// @inheritdoc IPsiTwapOracle
    function setGlobalTwapRequired(bool required) public onlyRole(DEFAULT_MANAGER_ROLE) {
        _getTwapOracleStorage().globalTwapRequired = required;
        emit GlobalTwapRequiredUpdated(required);
    }

    /// @inheritdoc IPsiTwapOracle
    function setGlobalTwapDisabled(bool disabled) public onlyRole(DEFAULT_MANAGER_ROLE) {
        _getTwapOracleStorage().globalTwapDisabled = disabled;
        emit GlobalTwapDisabledUpdated(disabled);
    }

    /// @inheritdoc IPsiTwapOracle
    function setTwapSigner(address newSigner) public onlyRole(DEFAULT_MANAGER_ROLE) {
        if (newSigner == address(0)) revert ZeroAddress();
        TwapOracleStorage storage $ = _getTwapOracleStorage();
        address oldSigner = $.twapSigner;
        $.twapSigner = newSigner;
        emit TwapSignerUpdated(oldSigner, newSigner);
    }

    /// @inheritdoc IPsiTwapOracle
    function pause() public onlyRole(DEFAULT_MANAGER_ROLE) {
        _pause();
    }

    /// @inheritdoc IPsiTwapOracle
    function unpause() public onlyRole(DEFAULT_MANAGER_ROLE) {
        _unpause();
    }

    // ============ Internal Functions ============

    /// @notice Authorize a UUPS upgrade to a new implementation
    /// @dev Restricted to TIMELOCKED_ROLE to enforce governance delay on upgrades
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(TIMELOCKED_ROLE) { }

    /// @notice Process Twap for a single market
    /// @dev Uses isEffectiveTwapRequired which considers global flags.
    ///      For finalized markets, signature verification is skipped and the final price will be applied. This is so that the Twap oracle doesn't have to run forever if someone withdraws after an eternity
    function _processTwapForMarket(DataTypes.TwapData memory twapData) internal returns (bool signatureRequired) {
        bytes32 conditionId = twapData.conditionId;
        // If market is already finalized, we don't update the twap accumulator anymore and just extrapolate on read
        if (isMarketFinalized(conditionId)) {
            return false;
        }

        bool isTwapRequired = isEffectiveTwapRequired(conditionId);

        // If this twap includes market finalization, process it regardless of twapRequired setting
        if (twapData.marketEndedAt > 0) {
            if (!twapData.required) revert TwapRequired(conditionId);
            _applyFinalTwap(conditionId, twapData, isTwapRequired);
            return true; //always true, signature needs to be checked because of finalization parameters
        }

        // If Twap not required, apply default 50:50
        if (!isTwapRequired) {
            _applyDefaultTwap(conditionId);
            return false;
        }

        if (!twapData.required) revert TwapRequired(conditionId);

        _applyTwap(conditionId, twapData);

        return true;
    }

    /// @notice Update Twap index for a market
    /// @param conditionId Market condition ID
    /// @param twapData Twap data
    function _applyTwap(bytes32 conditionId, DataTypes.TwapData memory twapData) internal {
        MarketState storage market = _getTwapOracleStorage().markets[conditionId];
        // Early return if no time has passed (e.g. market just auto-initialized in this tx)
        uint256 timeDelta = twapData.endTimestamp - market.lastTwapUpdate;
        if (timeDelta == 0) return;

        TwapMath._validateTwapData(twapData, market.lastTwapUpdate);

        // Accumulate: twapAccumulatorYes += twapPriceYes * timeDelta
        // This tracks cumulative (price * time) for YES side
        uint256 twapAccumulatorYesDelta = twapData.twapPriceYes * timeDelta;
        uint256 newTwapAccumulatorYes = market.twapAccumulatorYes + twapAccumulatorYesDelta;

        market.twapAccumulatorYes = uint128(newTwapAccumulatorYes);
        market.lastTwapUpdate = uint40(twapData.endTimestamp);
        emit TwapUpdated(conditionId, newTwapAccumulatorYes, twapData.endTimestamp);
    }

    /// @notice Update last Twap index for a finalized market
    /// @dev will use the submitted twap until market end time and then apply the fixed price for the rest of the time
    /// @param conditionId Market condition ID
    /// @param twapData Twap data
    function _applyFinalTwap(bytes32 conditionId, DataTypes.TwapData memory twapData, bool twapRequired) internal {
        if (twapData.marketEndedAt == 0) revert TwapTimestampInvalid(0, 0, 0);
        MarketState storage market = _getTwapOracleStorage().markets[conditionId];
        // Early return if no time has passed (e.g. market just auto-initialized in this tx)
        uint256 timeDelta = block.timestamp - market.lastTwapUpdate;
        if (timeDelta == 0) return;

        //Only validate twap data if twap is required for the market, just like the regular twap updates.
        //Otherwise, front-running can prevent finalizations
        if (twapRequired) TwapMath._validateTwapData(twapData, market.lastTwapUpdate);

        // Market is being finalized
        // Apply twap from lastTwapUpdate to marketEndedAt
        if (twapData.marketEndedAt <= market.lastTwapUpdate) {
            revert TwapTimestampInvalid(market.lastTwapUpdate, twapData.marketEndedAt, market.lastTwapUpdate + 1);
        }
        if (twapData.marketEndedAt > block.timestamp) {
            revert TwapTimestampInvalid(market.lastTwapUpdate, twapData.marketEndedAt, block.timestamp);
        }
        if (twapData.marketEndYesPrice > DataTypes.PRICE_SCALE) {
            revert TwapPriceOutOfRange(twapData.marketEndYesPrice);
        }

        //On non-twap required markets, we apply the default price for the rest of the market time.
        uint256 twapPriceYes = twapRequired ? twapData.twapPriceYes : TwapMath.defaultPrice();

        uint256 timeToEnd = twapData.marketEndedAt - market.lastTwapUpdate;
        uint256 twapAccumulatorYesDelta = twapPriceYes * timeToEnd;

        //don't accumulate the final price, it will be applied only on read

        uint256 newTwapAccumulatorYes = market.twapAccumulatorYes + twapAccumulatorYesDelta;
        market.twapAccumulatorYes = uint128(newTwapAccumulatorYes);
        market.lastTwapUpdate = uint40(block.timestamp);

        // Store finalization info
        market.marketEndedAt = uint40(twapData.marketEndedAt);
        market.marketEndYesPrice = uint64(twapData.marketEndYesPrice);

        emit TwapUpdated(conditionId, newTwapAccumulatorYes, block.timestamp);
        emit MarketFinalized(conditionId, twapData.marketEndedAt, twapData.marketEndYesPrice);
    }

    /// @notice Apply default 50:50 Twap update (when Twap not required)
    /// @param conditionId Market condition ID
    function _applyDefaultTwap(bytes32 conditionId) internal {
        MarketState storage market = _getTwapOracleStorage().markets[conditionId];

        uint256 timeDelta = block.timestamp - market.lastTwapUpdate;
        if (timeDelta == 0) return;

        // Apply 50:50 price
        uint256 defaultPrice = TwapMath.defaultPrice();
        uint256 twapAccumulatorYesDelta = defaultPrice * timeDelta;
        market.twapAccumulatorYes += uint128(twapAccumulatorYesDelta);
        market.lastTwapUpdate = uint40(block.timestamp);

        emit TwapUpdated(conditionId, market.twapAccumulatorYes, block.timestamp);
    }

    // ============ Signature Check Functions ============

    /// @notice Hash a single Twap data struct for EIP-712 signing
    /// @dev Uses assembly to pack fields into scratch memory and keccak256 in a single pass.
    ///      Equivalent to keccak256(abi.encode(TWAP_TYPEHASH, required, conditionId, ...)) but cheaper.
    function _hashTwapData(DataTypes.TwapData memory data) internal pure returns (bytes32 hash) {
        bytes32 typeHash = TWAP_TYPEHASH;
        bool required = data.required;
        bytes32 conditionId = data.conditionId;
        uint256 startTimestamp = data.startTimestamp;
        uint256 endTimestamp = data.endTimestamp;
        uint256 twapPriceYes = data.twapPriceYes;
        uint256 marketEndedAt = data.marketEndedAt;
        uint256 marketEndYesPrice = data.marketEndYesPrice;

        assembly {
            let ptr := mload(0x40)
            mstore(ptr, typeHash)
            mstore(add(ptr, 0x20), required)
            mstore(add(ptr, 0x40), conditionId)
            mstore(add(ptr, 0x60), startTimestamp)
            mstore(add(ptr, 0x80), endTimestamp)
            mstore(add(ptr, 0xa0), twapPriceYes)
            mstore(add(ptr, 0xc0), marketEndedAt)
            mstore(add(ptr, 0xe0), marketEndYesPrice)
            hash := keccak256(ptr, 0x100)
        }
    }

    /// @notice Hash batch Twap data for EIP-712 signing
    /// @dev Standard EIP-712 array encoding: hash each element, then hash the concatenated hashes.
    function _hashBatchTwapData(DataTypes.TwapData[] memory markets) internal pure returns (bytes32 hash) {
        bytes32[] memory twapHashes = new bytes32[](markets.length);
        for (uint256 i = 0; i < markets.length; i++) {
            twapHashes[i] = _hashTwapData(markets[i]);
        }

        // keccak256 over the packed array of individual struct hashes (EIP-712 array encoding)
        bytes32 twapArrayHash;
        assembly {
            let dataPtr := add(twapHashes, 0x20)
            let dataLen := mul(mload(twapHashes), 0x20)
            twapArrayHash := keccak256(dataPtr, dataLen)
        }

        bytes32 typeHash = BATCH_TWAP_TYPEHASH;

        assembly {
            let ptr := mload(0x40)
            mstore(ptr, typeHash)
            mstore(add(ptr, 0x20), twapArrayHash)
            hash := keccak256(ptr, 0x40)
        }
    }

    /// @notice Verify batch Twap signature
    /// @param twapData Batch Twap data with signature
    /// @return True if signature is valid
    function _verifyBatchTwapSignature(DataTypes.BatchTwapData memory twapData) internal view returns (bool) {
        if (twapData.markets.length == 0) return true; // Empty is valid (for non-Twap markets)

        bytes32 structHash = _hashBatchTwapData(twapData.markets);
        bytes32 digest = _hashTypedDataV4(structHash);
        address signer = ECDSA.recover(digest, twapData.signature);

        return signer == _getTwapOracleStorage().twapSigner;
    }
}
