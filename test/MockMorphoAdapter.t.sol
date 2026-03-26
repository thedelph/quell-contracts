// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {MockMorphoAdapter} from "../src/adapters/MockMorphoAdapter.sol";
import {MockSteakhouseVault} from "./mocks/MockSteakhouseVault.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

contract MockMorphoAdapterTest is Test {
    MockMorphoAdapter public adapter;
    MockSteakhouseVault public vault;
    MockUSDC public usdc;

    function setUp() public {
        usdc = new MockUSDC();
        vault = new MockSteakhouseVault(usdc);
        adapter = new MockMorphoAdapter(address(vault));
    }

    function testInitialSharePrice() public view {
        assertEq(adapter.getSharePrice(), 1e18);
    }

    function testMonotonicIncrease() public {
        uint256 price0 = adapter.getSharePrice();
        vm.warp(block.timestamp + 30 days);
        uint256 price1 = adapter.getSharePrice();
        vm.warp(block.timestamp + 30 days);
        uint256 price2 = adapter.getSharePrice();

        assertGt(price1, price0);
        assertGt(price2, price1);
    }

    function testOneYearAPY() public {
        vm.warp(block.timestamp + 365 days);
        uint256 price = adapter.getSharePrice();
        // Should be ~1.03e18 (3% APY)
        // Allow 0.01% tolerance
        assertApproxEqRel(price, 1.03e18, 0.0001e18);
    }

    function testSharesToUsdcAtDeploy() public view {
        // 1e18 shares = 1e6 USDC at deploy (price = 1e18)
        assertEq(adapter.sharesToUsdc(1e18), 1e6);
    }

    function testUsdcToSharesAtDeploy() public view {
        // 1e6 USDC = 1e18 shares at deploy (price = 1e18)
        assertEq(adapter.usdcToShares(1e6), 1e18);
    }

    function testRoundTrip() public view {
        uint256 usdcIn = 1_000e6; // 1000 USDC
        uint256 shares = adapter.usdcToShares(usdcIn);
        uint256 usdcOut = adapter.sharesToUsdc(shares);
        // Within 1 wei of USDC dust
        assertApproxEqAbs(usdcOut, usdcIn, 1);
    }

    function testRoundTripAfterAppreciation() public {
        vm.warp(block.timestamp + 180 days);
        uint256 usdcIn = 5_000e6;
        uint256 shares = adapter.usdcToShares(usdcIn);
        uint256 usdcOut = adapter.sharesToUsdc(shares);
        assertApproxEqAbs(usdcOut, usdcIn, 1);
    }

    function testSteakhouseVaultAddress() public view {
        assertEq(adapter.STEAKHOUSE_VAULT(), address(vault));
    }
}
