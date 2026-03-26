// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title IMorphoAdapter — Interface for Morpho/Steakhouse vault adapters
/// @notice Stateless read-only interface to query vault share prices and conversions
interface IMorphoAdapter {
    /// @notice Returns the address of the underlying Steakhouse vault
    function STEAKHOUSE_VAULT() external view returns (address);

    /// @notice Returns the current share price in 18-decimal precision
    function getSharePrice() external view returns (uint256);

    /// @notice Converts Steakhouse vault shares (18-dec) to USDC amount (6-dec)
    /// @param steakShares Amount of Steakhouse shares
    /// @return usdcAmount Equivalent USDC value
    function sharesToUsdc(uint256 steakShares) external view returns (uint256 usdcAmount);

    /// @notice Converts USDC amount (6-dec) to Steakhouse vault shares (18-dec)
    /// @param usdcAmount Amount of USDC
    /// @return steakShares Equivalent Steakhouse shares
    function usdcToShares(uint256 usdcAmount) external view returns (uint256 steakShares);
}
