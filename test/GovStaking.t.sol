// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {GovStaking} from "../src/GovStaking.sol";
import {QUELLToken} from "../src/QUELLToken.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

contract GovStakingTest is Test {
    GovStaking public staking;
    QUELLToken public gov;
    MockUSDC public usdc;

    address public owner = makeAddr("owner");
    address public treasury = makeAddr("treasury");
    address public vestingWallet = makeAddr("vestingWallet");
    address public feeDistributor = makeAddr("feeDistributor");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

    function setUp() public {
        gov = new QUELLToken(treasury, vestingWallet);
        usdc = new MockUSDC();
        staking = new GovStaking(address(gov), address(usdc), owner);

        // Set fee distributor
        vm.prank(owner);
        staking.setFeeDistributor(feeDistributor);

        // Give alice and bob some GOV from treasury
        vm.startPrank(treasury);
        gov.transfer(alice, 10_000e18);
        gov.transfer(bob, 5_000e18);
        vm.stopPrank();

        // Approve staking contract
        vm.prank(alice);
        gov.approve(address(staking), type(uint256).max);
        vm.prank(bob);
        gov.approve(address(staking), type(uint256).max);
    }

    function testStakeUpdatesBalances() public {
        vm.prank(alice);
        staking.stake(1000e18);

        assertEq(staking.stakedBalance(alice), 1000e18);
        assertEq(staking.totalStaked(), 1000e18);
        assertEq(gov.balanceOf(alice), 9000e18);
    }

    function testRequestUnstakeCooldown() public {
        vm.prank(alice);
        staking.stake(1000e18);

        vm.prank(alice);
        staking.requestUnstake(500e18);

        assertEq(staking.stakedBalance(alice), 500e18);
        assertEq(staking.totalStaked(), 500e18);
        assertEq(staking.pendingUnstake(alice), 500e18);
    }

    function testCompleteUnstakeRevertsBeforeCooldown() public {
        vm.prank(alice);
        staking.stake(1000e18);

        vm.prank(alice);
        staking.requestUnstake(500e18);

        // Warp 6 days (not enough)
        vm.warp(block.timestamp + 6 days);

        vm.prank(alice);
        vm.expectRevert(GovStaking.CooldownNotElapsed.selector);
        staking.completeUnstake();
    }

    function testCompleteUnstakeSucceedsAfterCooldown() public {
        vm.prank(alice);
        staking.stake(1000e18);

        vm.prank(alice);
        staking.requestUnstake(500e18);

        // Warp 7 days + 1 second
        vm.warp(block.timestamp + 7 days + 1);

        vm.prank(alice);
        staking.completeUnstake();

        assertEq(staking.pendingUnstake(alice), 0);
        assertEq(gov.balanceOf(alice), 9500e18);
    }

    function testNotifyRewardRevertsNoStakers() public {
        usdc.mint(feeDistributor, 100e6);

        vm.prank(feeDistributor);
        vm.expectRevert(GovStaking.NoStakers.selector);
        staking.notifyRewardAmount(100e6);
    }

    function testNotifyRewardUpdatesAccumulator() public {
        vm.prank(alice);
        staking.stake(1000e18);

        usdc.mint(address(staking), 100e6);

        vm.prank(feeDistributor);
        staking.notifyRewardAmount(100e6);

        // rewardPerTokenStored = (100e6 * 1e30) / 1000e18
        uint256 expected = (100e6 * 1e30) / 1000e18;
        assertEq(staking.rewardPerTokenStored(), expected);
    }

    function testEarnedZeroBeforeNotification() public {
        vm.prank(alice);
        staking.stake(1000e18);

        assertEq(staking.earned(alice), 0);
    }

    function testProRataRewards() public {
        // Alice stakes 1000, Bob stakes 500
        vm.prank(alice);
        staking.stake(1000e18);
        vm.prank(bob);
        staking.stake(500e18);

        // Distribute 150 USDC rewards
        usdc.mint(address(staking), 150e6);
        vm.prank(feeDistributor);
        staking.notifyRewardAmount(150e6);

        // Alice should earn 2/3 = 100 USDC, Bob 1/3 = 50 USDC
        assertEq(staking.earned(alice), 100e6);
        assertEq(staking.earned(bob), 50e6);
    }

    function testClaimRewards() public {
        vm.prank(alice);
        staking.stake(1000e18);

        usdc.mint(address(staking), 100e6);
        vm.prank(feeDistributor);
        staking.notifyRewardAmount(100e6);

        uint256 balanceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        staking.claimRewards();

        assertEq(usdc.balanceOf(alice) - balanceBefore, 100e6);
        assertEq(staking.earned(alice), 0);
    }

    function testOnlyDistributorCanNotify() public {
        vm.prank(alice);
        staking.stake(1000e18);

        vm.prank(alice);
        vm.expectRevert(GovStaking.OnlyFeeDistributor.selector);
        staking.notifyRewardAmount(100e6);
    }

    function testStakeZeroReverts() public {
        vm.prank(alice);
        vm.expectRevert(GovStaking.ZeroAmount.selector);
        staking.stake(0);
    }

    function testRequestUnstakeInsufficientReverts() public {
        vm.prank(alice);
        vm.expectRevert(GovStaking.InsufficientStake.selector);
        staking.requestUnstake(1000e18);
    }

    function testRequestUnstakeZeroReverts() public {
        vm.prank(alice);
        staking.stake(1000e18);

        vm.prank(alice);
        vm.expectRevert(GovStaking.ZeroAmount.selector);
        staking.requestUnstake(0);
    }

    function testCompleteUnstakeWithNoPendingReverts() public {
        vm.prank(alice);
        vm.expectRevert(GovStaking.NoPendingUnstake.selector);
        staking.completeUnstake();
    }

    function testClaimRewardsZeroEarnedReverts() public {
        vm.prank(alice);
        staking.stake(1000e18);

        // No rewards distributed yet
        vm.prank(alice);
        vm.expectRevert(GovStaking.ZeroAmount.selector);
        staking.claimRewards();
    }

    function testMultipleRequestUnstakeResetsCooldown() public {
        vm.prank(alice);
        staking.stake(1000e18);

        // First request
        vm.prank(alice);
        staking.requestUnstake(200e18);
        uint256 firstRequestTime = block.timestamp;

        // Warp 3 days
        vm.warp(block.timestamp + 3 days);

        // Second request resets cooldown
        vm.prank(alice);
        staking.requestUnstake(300e18);

        // Total pending should be 500
        assertEq(staking.pendingUnstake(alice), 500e18);
        // Cooldown time should be reset to current time (3 days after first)
        assertEq(staking.unstakeRequestTime(alice), firstRequestTime + 3 days);

        // Warp 5 more days (8 total, but only 5 since second request — not enough)
        vm.warp(block.timestamp + 5 days);
        vm.prank(alice);
        vm.expectRevert(GovStaking.CooldownNotElapsed.selector);
        staking.completeUnstake();

        // Warp 2 more days (7 days + 1 since second request)
        vm.warp(block.timestamp + 2 days + 1);
        vm.prank(alice);
        staking.completeUnstake();
        assertEq(staking.pendingUnstake(alice), 0);
        assertEq(gov.balanceOf(alice), 9500e18); // 10000 - 1000 staked + 500 unstaked
    }

    function testMultipleNotifyRewardAccumulation() public {
        vm.prank(alice);
        staking.stake(1000e18);

        // First reward
        usdc.mint(address(staking), 100e6);
        vm.prank(feeDistributor);
        staking.notifyRewardAmount(100e6);

        // Second reward
        usdc.mint(address(staking), 50e6);
        vm.prank(feeDistributor);
        staking.notifyRewardAmount(50e6);

        // Alice should earn 150 USDC total
        assertEq(staking.earned(alice), 150e6);
    }

    function testNonOwnerCannotSetFeeDistributor() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", alice));
        staking.setFeeDistributor(makeAddr("newDistributor"));
    }
}
