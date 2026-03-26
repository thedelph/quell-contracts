// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {RWAVault} from "../../src/RWAVault.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {MockSteakhouseVault} from "../mocks/MockSteakhouseVault.sol";

/// @title RWAVaultHandler — Bounded random actions for invariant fuzzing
contract RWAVaultHandler is Test {
    RWAVault public vault;
    MockUSDC public usdc;
    MockSteakhouseVault public steakhouse;

    address[3] public actors;

    // Ghost variables for invariant checks
    uint256 public ghost_previousSharePrice;
    uint256 public ghost_previousHWM;
    uint256 public ghost_depositCount;
    uint256 public ghost_redeemCount;

    constructor(RWAVault _vault, MockUSDC _usdc, MockSteakhouseVault _steakhouse) {
        vault = _vault;
        usdc = _usdc;
        steakhouse = _steakhouse;

        actors[0] = makeAddr("actor0");
        actors[1] = makeAddr("actor1");
        actors[2] = makeAddr("actor2");

        // Snapshot initial state
        ghost_previousHWM = vault.highWaterMark();
    }

    function deposit(uint256 actorSeed, uint256 amount) external {
        address actor = actors[actorSeed % 3];

        uint256 maxDep = vault.maxDeposit(actor);
        if (maxDep == 0) return;

        amount = bound(amount, 1e6, maxDep > 100_000e6 ? 100_000e6 : maxDep);

        _snapshotState();

        usdc.mint(actor, amount);
        vm.startPrank(actor);
        usdc.approve(address(vault), amount);
        vault.deposit(amount, actor);
        vm.stopPrank();

        ghost_depositCount++;
    }

    function redeem(uint256 actorSeed, uint256 shareFraction) external {
        address actor = actors[actorSeed % 3];
        uint256 shares = vault.balanceOf(actor);
        if (shares == 0) return;

        shareFraction = bound(shareFraction, 1, 100);
        uint256 toRedeem = (shares * shareFraction) / 100;
        if (toRedeem == 0) return;

        _snapshotState();

        vm.prank(actor);
        vault.redeem(toRedeem, actor, actor);

        ghost_redeemCount++;
    }

    function warpTime(uint256 seconds_) external {
        seconds_ = bound(seconds_, 1, 30 days);
        vm.warp(block.timestamp + seconds_);
    }

    function harvestViaDeposit() external {
        address actor = actors[0];
        uint256 maxDep = vault.maxDeposit(actor);
        if (maxDep == 0) return;

        uint256 amount = 1e6; // Minimal deposit to trigger harvest
        if (amount > maxDep) return;

        _snapshotState();

        usdc.mint(actor, amount);
        vm.startPrank(actor);
        usdc.approve(address(vault), amount);
        vault.deposit(amount, actor);
        vm.stopPrank();

        ghost_depositCount++;
    }

    function _snapshotState() internal {
        uint256 supply = vault.totalSupply();
        // Only snapshot PPS when meaningful supply exists (not just dead shares)
        if (supply > 1000) {
            ghost_previousSharePrice = (vault.totalAssets() * 1e30) / supply;
        }
        ghost_previousHWM = vault.highWaterMark();
    }
}
