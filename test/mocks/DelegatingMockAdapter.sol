// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IMorphoAdapter} from "../../src/adapters/IMorphoAdapter.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/// @title DelegatingMockAdapter — Delegates to actual vault like the real MorphoAdapter
/// @notice For integration tests where adapter<->vault consistency matters
contract DelegatingMockAdapter is IMorphoAdapter {
    address public immutable override STEAKHOUSE_VAULT;

    uint256 public constant DECIMALS_OFFSET = 1e12;

    constructor(address _vault) {
        STEAKHOUSE_VAULT = _vault;
    }

    function getSharePrice() external view override returns (uint256) {
        return IERC4626(STEAKHOUSE_VAULT).convertToAssets(1e18) * DECIMALS_OFFSET;
    }

    function sharesToUsdc(uint256 steakShares) external view override returns (uint256) {
        return IERC4626(STEAKHOUSE_VAULT).convertToAssets(steakShares);
    }

    function usdcToShares(uint256 usdcAmount) external view override returns (uint256) {
        return IERC4626(STEAKHOUSE_VAULT).convertToShares(usdcAmount);
    }
}
