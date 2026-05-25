// SPDX-License-Identifier: BSL-1.1
pragma solidity 0.8.31;

/// @title IPsiSignaturesView
/// @notice Sub-interface for SignaturesMixin view functions
interface IPsiSignaturesView {
    /// @notice Get the nonce bitmap for a user at a specific word position
    /// @param user The user address
    /// @param wordPos The word position (nonce / 256)
    /// @return The bitmap for that word (each bit = 1 if nonce used)
    function nonceBitmap(address user, uint256 wordPos) external view returns (uint256);

    /// @notice Check if a specific nonce has been used
    /// @param user The user address
    /// @param nonce The nonce to check
    /// @return isUsed True if the nonce has been used
    function isNonceUsed(address user, uint256 nonce) external view returns (bool isUsed);

    /// @notice Get the EIP-712 domain separator
    /// @return The EIP-712 domain separator
    function domainSeparator() external view returns (bytes32);

    // ============ Constants ============

    /// @notice EIP-712 type hash for signed withdrawal
    /// @return The EIP-712 type hash for signed withdrawal
    /// forge-lint: disable-next-line(mixed-case-function)
    function SIGNED_WITHDRAWAL_TYPEHASH() external view returns (bytes32);
}
