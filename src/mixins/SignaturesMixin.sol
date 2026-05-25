// SPDX-License-Identifier: BSL-1.1
pragma solidity 0.8.31;

import { Initializable } from '@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol';
import { EIP712Upgradeable } from '@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol';
import { ECDSA } from '@openzeppelin/contracts/utils/cryptography/ECDSA.sol';
import { DataTypes } from '../types/DataTypes.sol';

import { IPsiStakingVaultEvents } from '../interfaces/IPsiStakingVaultEvents.sol';
import { IPsiStakingVaultErrors } from '../interfaces/IPsiStakingVaultErrors.sol';
import { IPolyFactoryHelper } from '../interfaces/external/IPolyFactoryHelper.sol';
import { StorageLib } from '../libraries/StorageLib.sol';

/// @title SignaturesMixin
/// @notice EIP-712 signature verification for signed withdrawals
/// @dev Uses ERC-7201 namespaced storage pattern for upgradeability
abstract contract SignaturesMixin is Initializable, EIP712Upgradeable, IPsiStakingVaultEvents, IPsiStakingVaultErrors {
    // ============ EIP-712 Type Hashes ============

    /// @notice EIP-712 type hash for signed withdrawal structs
    bytes32 public constant SIGNED_WITHDRAWAL_TYPEHASH = keccak256(
        'SignedWithdrawal(address signer,address user,uint256 referralCode,bytes32 conditionId,uint256 yesShares,uint256 noShares,uint256 minYesTokens,uint256 minNoTokens,address yieldRecipient,bool protectAgainstLoss,uint256 nonce,uint256 expiry,uint8 signatureType)'
    );

    uint256 private constant ONE_BIT = 1;

    // ============ ERC-7201 Namespaced Storage ============

    function _getSignaturesStorage() private pure returns (StorageLib.SignaturesStorage storage) {
        return StorageLib.getSignaturesStorage();
    }

    // ============ Initialization ============

    /// @notice Initialize the signatures mixin
    /// @param name EIP-712 domain name
    /// @param version EIP-712 domain version
    /// forge-lint: disable-next-line(mixed-case-function)
    function __SignaturesMixin_init(string memory name, string memory version, address polymarketFactoryHelper_) internal onlyInitializing {
        __EIP712_init(name, version);
        StorageLib.SignaturesStorage storage $ = _getSignaturesStorage();
        $.polymarketFactoryHelper = IPolyFactoryHelper(polymarketFactoryHelper_);
    }

    // ============ View Functions ============

    /// @notice Returns the nonce bitmap word for a user at a given word position
    function nonceBitmap(address user, uint256 wordPos) public view virtual returns (uint256) {
        return _getSignaturesStorage().nonceBitmap[user][wordPos];
    }

    /// @notice Returns whether a specific nonce has been used by a user
    function isNonceUsed(address user, uint256 nonce) public view virtual returns (bool isUsed) {
        (isUsed,,) = _getNonceInformation(user, nonce);
    }

    /// @notice Returns the EIP-712 domain separator
    function domainSeparator() public view virtual returns (bytes32) {
        return _domainSeparatorV4();
    }

    // ============ Internal Functions - Nonce Management ============

    /// @notice Invalidate nonces to cancel signed withdrawals
    /// @dev Sets bits in the bitmap for the given nonces, making them unusable
    /// @param nonces Array of nonces to invalidate
    function _invalidateNonces(address user, uint256[] calldata nonces) internal {
        StorageLib.SignaturesStorage storage $ = _getSignaturesStorage();
        for (uint256 i = 0; i < nonces.length; i++) {
            uint256 nonce = nonces[i];
            (uint256 wordPos, uint256 bit) = _splitNonce(nonce);
            $.nonceBitmap[user][wordPos] |= bit;
        }
    }

    /// @notice Invalidate all nonces in a word (cancel up to 256 orders at once)
    /// @dev Sets the entire word to max value, invalidating all 256 nonces in that range
    /// @param wordPos The word position to invalidate (invalidates nonces wordPos*256 to wordPos*256+255)
    function _invalidateNonceWord(address user, uint256 wordPos) internal {
        _getSignaturesStorage().nonceBitmap[user][wordPos] = type(uint256).max;
    }

    /// @notice Split a nonce into its bitmap word position and bit mask
    /// @dev Nonces are stored as a bitmap: each uint256 word holds 256 nonces.
    ///      nonce / 256 gives the word, nonce % 256 gives the bit within that word.
    ///      This nonce system is used to be able to cancel withdraw orders (limit orders) independently of each other.
    /// @param nonce The nonce to check
    /// @return wordPos The word position of the nonce
    /// @return bit The bit position of the nonce
    function _splitNonce(uint256 nonce) internal pure returns (uint256 wordPos, uint256 bit) {
        wordPos = nonce >> 8;
        bit = ONE_BIT << (nonce & 0xff);
    }

    /// @notice Get the usage status and bitmap position for a nonce
    /// @param user The user address
    /// @param nonce The nonce to look up
    /// @return isUsed Whether the nonce has been consumed
    /// @return wordPos The word position in the bitmap (nonce / 256)
    /// @return bit The bit mask for this nonce within the word
    function _getNonceInformation(address user, uint256 nonce) internal view returns (bool isUsed, uint256 wordPos, uint256 bit) {
        (wordPos, bit) = _splitNonce(nonce);
        uint256 bitmap = _getSignaturesStorage().nonceBitmap[user][wordPos];
        isUsed = bitmap & bit != 0;
    }

    // ============ Internal Functions - Signed Withdrawal ============

    /// @notice Hash a signed withdrawal struct for EIP-712 signing
    function _hashSignedWithdrawal(DataTypes.SignedWithdrawal calldata withdrawal) internal pure returns (bytes32 hash) {
        bytes32 typeHash = SIGNED_WITHDRAWAL_TYPEHASH;
        address signer = withdrawal.signer;
        address user = withdrawal.user;
        bytes32 conditionId = withdrawal.conditionId;
        uint256 referralCode = withdrawal.referralCode;
        uint256 yesShares = withdrawal.yesShares;
        uint256 noShares = withdrawal.noShares;
        uint256 minYesTokens = withdrawal.minYesTokens;
        uint256 minNoTokens = withdrawal.minNoTokens;
        address yieldRecipient = withdrawal.yieldRecipient;
        bool protectAgainstLoss = withdrawal.protectAgainstLoss;
        uint256 nonce = withdrawal.nonce;
        uint256 expiry = withdrawal.expiry;
        uint8 signatureType = uint8(withdrawal.signatureType);

        assembly {
            let ptr := mload(0x40)
            mstore(ptr, typeHash)
            mstore(add(ptr, 0x20), signer)
            mstore(add(ptr, 0x40), user)
            mstore(add(ptr, 0x60), referralCode)
            mstore(add(ptr, 0x80), conditionId)
            mstore(add(ptr, 0xa0), yesShares)
            mstore(add(ptr, 0xc0), noShares)
            mstore(add(ptr, 0xe0), minYesTokens)
            mstore(add(ptr, 0x100), minNoTokens)
            mstore(add(ptr, 0x120), yieldRecipient)
            mstore(add(ptr, 0x140), protectAgainstLoss)
            mstore(add(ptr, 0x160), nonce)
            mstore(add(ptr, 0x180), expiry)
            mstore(add(ptr, 0x1a0), signatureType)
            hash := keccak256(ptr, 0x1c0)
        }
    }

    /// @notice Verify and consume a signed withdrawal
    /// @param withdrawal Signed withdrawal data
    /// @return True if valid, reverts otherwise
    function _verifyAndConsumeSignedWithdrawal(DataTypes.SignedWithdrawal calldata withdrawal) internal returns (bool) {
        StorageLib.SignaturesStorage storage $ = _getSignaturesStorage();

        // Check expiry
        if (block.timestamp > withdrawal.expiry) {
            revert WithdrawalExpired(withdrawal.expiry, block.timestamp);
        }

        // Check and consume nonce using bitmap
        (bool isUsed, uint256 wordPos, uint256 bit) = _getNonceInformation(withdrawal.user, withdrawal.nonce);
        if (isUsed) {
            revert WithdrawalNonceUsed(withdrawal.user, withdrawal.nonce);
        }

        // Verify signature
        bytes32 structHash = _hashSignedWithdrawal(withdrawal);
        bytes32 digest = _hashTypedDataV4(structHash);
        address signer = ECDSA.recover(digest, withdrawal.signature);

        if (signer != withdrawal.signer || !_verifySignerForUser(withdrawal.signer, withdrawal.user, withdrawal.signatureType)) {
            revert InvalidWithdrawalSignature();
        }

        // Consume nonce by setting the bit
        $.nonceBitmap[withdrawal.user][wordPos] |= bit;

        return true;
    }

    /// @notice Verify that a signer is authorized to act on behalf of a user
    /// @dev Supports EOA (direct match), Polymarket proxy wallets, and Polymarket Gnosis safes
    /// @param signer The address that produced the signature
    /// @param user The address of the wallet being acted upon
    /// @param signatureType The type of signer-to-user relationship
    /// @return True if the signer is authorized for the given user and signature type
    function _verifySignerForUser(address signer, address user, DataTypes.SignatureType signatureType) internal view returns (bool) {
        StorageLib.SignaturesStorage storage $ = _getSignaturesStorage();
        if (signatureType == DataTypes.SignatureType.EOA) {
            return user == signer;
        } else if (signatureType == DataTypes.SignatureType.POLY_PROXY) {
            return user == $.polymarketFactoryHelper.getPolyProxyWalletAddress(signer);
        } else if (signatureType == DataTypes.SignatureType.POLY_GNOSIS_SAFE) {
            return user == $.polymarketFactoryHelper.getSafeAddress(signer);
        }
        return false;
    }
}
