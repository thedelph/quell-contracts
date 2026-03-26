// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IMorphoAdapter} from "./IMorphoAdapter.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/// @title MorphoAdapter — Mainnet Steakhouse USDC MetaMorpho vault adapter
/// @notice Stateless read-only adapter. Delegates to the Steakhouse vault for all conversions.
contract MorphoAdapter is IMorphoAdapter {
    address public constant override STEAKHOUSE_VAULT = 0xbeeF010f9cb27031ad51e3333f9aF9C6B1228183;

    uint256 public constant DECIMALS_OFFSET = 1e12;

    /// @inheritdoc IMorphoAdapter
    function getSharePrice() external view override returns (uint256) {
        return IERC4626(STEAKHOUSE_VAULT).convertToAssets(1e18) * DECIMALS_OFFSET;
    }

    /// @inheritdoc IMorphoAdapter
    function sharesToUsdc(uint256 steakShares) external view override returns (uint256) {
        return IERC4626(STEAKHOUSE_VAULT).convertToAssets(steakShares);
    }

    /// @inheritdoc IMorphoAdapter
    function usdcToShares(uint256 usdcAmount) external view override returns (uint256) {
        return IERC4626(STEAKHOUSE_VAULT).convertToShares(usdcAmount);
    }
}
