// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title IYieldAdapter -- Interface for yield vault adapters
/// @notice Stateless read-only interface to query vault share prices and conversions
interface IYieldAdapter {
    /// @notice Returns the address of the underlying yield vault
    function YIELD_VAULT() external view returns (address);

    /// @notice Returns the current share price in 18-decimal precision
    function getSharePrice() external view returns (uint256);

    /// @notice Converts yield vault shares (18-dec) to USDC amount (6-dec)
    /// @param shares Amount of yield vault shares
    /// @return usdcAmount Equivalent USDC value
    function sharesToUsdc(uint256 shares) external view returns (uint256 usdcAmount);

    /// @notice Converts USDC amount (6-dec) to yield vault shares (18-dec)
    /// @param usdcAmount Amount of USDC
    /// @return shares Equivalent yield vault shares
    function usdcToShares(uint256 usdcAmount) external view returns (uint256 shares);
}
