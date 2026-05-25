// SPDX-License-Identifier: BSL-1.1
pragma solidity 0.8.31;

/// @title IPsiYieldStrategyView
/// @notice Sub-interface for YieldStrategyMixin view functions
interface IPsiYieldStrategyView {
    /// @notice Get all external vaults with their current state
    /// @return addresses Array of external vault addresses
    /// @return balances Array of current balances of the external vaults in USDC
    /// @return caps Array of maximum capacities of the external vaults in USDC
    /// @return activeFlags Array of active flags of the external vaults
    /// @return emergencyFlags Array of emergency flags of the external vaults
    function getExternalVaults()
        external
        view
        returns (
            address[] memory addresses,
            uint256[] memory balances,
            uint256[] memory caps,
            bool[] memory activeFlags,
            bool[] memory emergencyFlags
        );

    /// @notice Get total value across all external vaults
    /// @return total USDC value across all external vaults
    function getTotalVaultValue() external view returns (uint256);

    /// @notice Get current value of our position in a vault
    /// @param vault Address of the ERC-4626 vault to check
    /// @return value Current value of our position in the vault in USDC
    function getVaultValue(address vault) external view returns (uint256);

    /// @notice Get total Usdc available (in contract + in vaults)
    /// @return total Total USDC value across all external vaults and idle USDC in the contract
    function getTotalUsdcValue() external view returns (uint256);

    /// @notice Get total available capacity across all active vaults
    /// @return total Total capacity available for new deposits
    function getTotalAvailableCapacity() external view returns (uint256);

    /// @notice Get total available capacity across all active vaults based on the caps set by the admin, but disregarding the limits of external vaults.
    /// @return total Total capacity available for new deposits
    function getTotalAvailableInternalCapacity() external view returns (uint256);

    /// @notice Get available deposit capacity for a specific vault
    /// @param vault Address of the ERC-4626 vault to check
    /// @return Available capacity in USDC terms (considering both cap and vault limits)
    function getAvailableCapacity(address vault) external view returns (uint256);

    /// @notice Check if emergency mode is active
    /// @return True if emergency mode is active
    function isEmergencyMode() external view returns (bool);
}
