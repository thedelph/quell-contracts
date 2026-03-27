// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IYieldAdapter} from "./IYieldAdapter.sol";

/// @title MockYieldAdapter -- Time-based ~3% APY simulation for testing
/// @notice Linear share price appreciation from 1e18 at deploy, ~3% per year
contract MockYieldAdapter is IYieldAdapter {
    address public immutable override YIELD_VAULT;

    uint256 public immutable DEPLOY_TIME;

    uint256 public constant INITIAL_PRICE = 1e18;
    uint256 public constant APY_BPS = 300;
    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant SECONDS_PER_YEAR = 365 days;
    uint256 public constant DECIMALS_OFFSET = 1e12;

    /// @param mockVault Address of the mock vault (for YIELD_VAULT getter)
    constructor(address mockVault) {
        YIELD_VAULT = mockVault;
        DEPLOY_TIME = block.timestamp;
    }

    /// @inheritdoc IYieldAdapter
    function getSharePrice() public view override returns (uint256) {
        uint256 elapsed = block.timestamp - DEPLOY_TIME;
        return INITIAL_PRICE + (INITIAL_PRICE * APY_BPS * elapsed) / (BPS_DENOMINATOR * SECONDS_PER_YEAR);
    }

    /// @inheritdoc IYieldAdapter
    function sharesToUsdc(uint256 shares) external view override returns (uint256) {
        return (shares * getSharePrice()) / 1e18 / DECIMALS_OFFSET;
    }

    /// @inheritdoc IYieldAdapter
    function usdcToShares(uint256 usdcAmount) external view override returns (uint256) {
        return (usdcAmount * DECIMALS_OFFSET * 1e18) / getSharePrice();
    }
}
