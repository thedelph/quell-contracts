// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IYieldAdapter} from "./IYieldAdapter.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/// @title SparkAdapter -- Spark sUSDC vault adapter on Arbitrum
/// @notice Stateless read-only adapter. Delegates to Spark sUSDC for all conversions.
contract SparkAdapter is IYieldAdapter {
    address public constant override YIELD_VAULT = 0x940098b108fB7D0a7E374f6eDED7760787464609;

    uint256 public constant DECIMALS_OFFSET = 1e12;

    /// @inheritdoc IYieldAdapter
    function getSharePrice() external view override returns (uint256) {
        return IERC4626(YIELD_VAULT).convertToAssets(1e18) * DECIMALS_OFFSET;
    }

    /// @inheritdoc IYieldAdapter
    function sharesToUsdc(uint256 shares) external view override returns (uint256) {
        return IERC4626(YIELD_VAULT).convertToAssets(shares);
    }

    /// @inheritdoc IYieldAdapter
    function usdcToShares(uint256 usdcAmount) external view override returns (uint256) {
        return IERC4626(YIELD_VAULT).convertToShares(usdcAmount);
    }
}
