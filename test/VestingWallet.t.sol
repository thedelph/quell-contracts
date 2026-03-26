// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {VestingWallet} from "@openzeppelin/contracts/finance/VestingWallet.sol";
import {QUELLToken} from "../src/QUELLToken.sol";

contract VestingWalletTest is Test {
    VestingWallet public vesting;
    QUELLToken public gov;

    address public beneficiary = makeAddr("beneficiary");
    address public treasury = makeAddr("treasury");

    uint64 public cliffDuration = 365 days;
    uint64 public linearDuration = 3 * 365 days; // 3yr linear after 1yr cliff = 4yr total
    uint256 public constant FOUNDER_ALLOCATION = 25_000_000e18;

    uint256 public vestingStart;

    function setUp() public {
        vestingStart = block.timestamp + cliffDuration;

        // Deploy vesting wallet: start after cliff, linear over 3 years
        vesting = new VestingWallet(beneficiary, uint64(vestingStart), linearDuration);

        // Deploy QUELLToken — mints 25M QUELL to vesting wallet
        gov = new QUELLToken(treasury, address(vesting));
    }

    function testSetup() public view {
        assertEq(vesting.owner(), beneficiary);
        assertEq(vesting.start(), vestingStart);
        assertEq(vesting.duration(), linearDuration);
        assertEq(vesting.end(), vestingStart + linearDuration);
        assertEq(gov.balanceOf(address(vesting)), FOUNDER_ALLOCATION);
    }

    function testReleasableAtDeployment() public view {
        assertEq(vesting.releasable(address(gov)), 0);
    }

    function testReleasableBeforeCliff() public {
        // Warp to just before cliff ends (364d + 23h)
        vm.warp(block.timestamp + cliffDuration - 1 hours);
        assertEq(vesting.releasable(address(gov)), 0);
    }

    function testReleasableAtCliffBoundary() public {
        // Warp to 1 second after cliff ends (vesting start + 1s)
        vm.warp(vestingStart + 1);
        assertGt(vesting.releasable(address(gov)), 0);
    }

    function testReleasableAfterCliff() public {
        // Warp to 1 year into linear period (1/3 of 3yr duration)
        vm.warp(vestingStart + 365 days);

        uint256 releasable = vesting.releasable(address(gov));
        // Should be ~8.33M (25M / 3)
        uint256 expectedOneThird = FOUNDER_ALLOCATION / 3;
        assertApproxEqRel(releasable, expectedOneThird, 0.001e18, "Should be ~1/3 vested");
    }

    function testFullyVestedAtEnd() public {
        // Warp to end of vesting
        vm.warp(vesting.end());
        assertEq(vesting.releasable(address(gov)), FOUNDER_ALLOCATION);
    }

    function testReleaseTransfersTokens() public {
        // Warp past cliff + some linear
        vm.warp(vestingStart + 365 days);

        uint256 releasable = vesting.releasable(address(gov));
        assertGt(releasable, 0);

        // Anyone can call release, tokens go to beneficiary (owner)
        vesting.release(address(gov));

        assertEq(gov.balanceOf(beneficiary), releasable);
        assertEq(gov.balanceOf(address(vesting)), FOUNDER_ALLOCATION - releasable);
    }

    function testNoReleaseBeforeCliff() public {
        vm.warp(block.timestamp + cliffDuration - 1);

        uint256 balBefore = gov.balanceOf(beneficiary);
        vesting.release(address(gov));
        assertEq(gov.balanceOf(beneficiary), balBefore, "No tokens should transfer before cliff");
    }

    function testPartialRelease() public {
        // First release at 1yr into linear
        vm.warp(vestingStart + 365 days);
        uint256 firstReleasable = vesting.releasable(address(gov));
        vesting.release(address(gov));
        uint256 firstBalance = gov.balanceOf(beneficiary);
        assertEq(firstBalance, firstReleasable);

        // Second release at 2yr into linear
        vm.warp(vestingStart + 2 * 365 days);
        uint256 secondReleasable = vesting.releasable(address(gov));
        assertGt(secondReleasable, 0);
        vesting.release(address(gov));

        uint256 totalReleased = gov.balanceOf(beneficiary);
        assertEq(totalReleased, firstBalance + secondReleasable);

        // Should be ~2/3 of total
        uint256 expectedTwoThirds = (FOUNDER_ALLOCATION * 2) / 3;
        assertApproxEqRel(totalReleased, expectedTwoThirds, 0.001e18, "Should be ~2/3 vested");
    }
}
