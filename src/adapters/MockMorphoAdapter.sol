// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IMorphoAdapter} from "./IMorphoAdapter.sol";

/// @title MockMorphoAdapter — Time-based ~3% APY simulation for testing
/// @notice Linear share price appreciation from 1e18 at deploy, ~3% per year
contract MockMorphoAdapter is IMorphoAdapter {
    address public immutable override STEAKHOUSE_VAULT;

    uint256 public immutable DEPLOY_TIME;

    uint256 public constant INITIAL_PRICE = 1e18;
    uint256 public constant APY_BPS = 300;
    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant SECONDS_PER_YEAR = 365 days;
    uint256 public constant DECIMALS_OFFSET = 1e12;

    /// @param mockVault Address of the mock vault (for STEAKHOUSE_VAULT getter)
    constructor(address mockVault) {
        STEAKHOUSE_VAULT = mockVault;
        DEPLOY_TIME = block.timestamp;
    }

    /// @inheritdoc IMorphoAdapter
    function getSharePrice() public view override returns (uint256) {
        uint256 elapsed = block.timestamp - DEPLOY_TIME;
        return INITIAL_PRICE + (INITIAL_PRICE * APY_BPS * elapsed) / (BPS_DENOMINATOR * SECONDS_PER_YEAR);
    }

    /// @inheritdoc IMorphoAdapter
    function sharesToUsdc(uint256 steakShares) external view override returns (uint256) {
        return (steakShares * getSharePrice()) / 1e18 / DECIMALS_OFFSET;
    }

    /// @inheritdoc IMorphoAdapter
    function usdcToShares(uint256 usdcAmount) external view override returns (uint256) {
        return (usdcAmount * DECIMALS_OFFSET * 1e18) / getSharePrice();
    }
}
