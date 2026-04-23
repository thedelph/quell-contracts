// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {FeeDistributor} from "../src/FeeDistributor.sol";
import {GovStaking} from "../src/GovStaking.sol";
import {QUELLToken} from "../src/QUELLToken.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

contract FeeDistributorTest is Test {
    FeeDistributor public distributor;
    GovStaking public staking;
    QUELLToken public gov;
    MockUSDC public usdc;

    address public owner = makeAddr("owner");
    address public treasuryAddr = makeAddr("treasury");
    address public vestingWallet = makeAddr("vestingWallet");
    address public alice = makeAddr("alice");

    function setUp() public {
        gov = new QUELLToken(treasuryAddr, vestingWallet);
        usdc = new MockUSDC();
        staking = new GovStaking(address(gov), address(usdc), owner);
        distributor = new FeeDistributor(address(usdc), address(staking), treasuryAddr);

        // Link staking to distributor
        vm.prank(owner);
        staking.setFeeDistributor(address(distributor));
    }

    function testRevertsInsufficientFees() public {
        // Balance is 0, which is < 1e6
        vm.expectRevert(abi.encodeWithSelector(FeeDistributor.InsufficientFees.selector, 0));
        distributor.distribute();

        // Also test with balance < 1 USDC
        usdc.mint(address(distributor), 0.5e6);
        vm.expectRevert(abi.encodeWithSelector(FeeDistributor.InsufficientFees.selector, 0.5e6));
        distributor.distribute();
    }

    function testNoStakersTreasuryOnly() public {
        usdc.mint(address(distributor), 100e6);

        distributor.distribute();

        // 40% to treasury
        assertEq(usdc.balanceOf(treasuryAddr), 40e6);
        // 60% held in contract
        assertEq(usdc.balanceOf(address(distributor)), 60e6);
    }

    function testWithStakersCorrectSplit() public {
        // Alice stakes some GOV
        vm.prank(treasuryAddr);
        gov.transfer(alice, 1000e18);
        vm.prank(alice);
        gov.approve(address(staking), type(uint256).max);
        vm.prank(alice);
        staking.stake(1000e18);

        // Distribute 100 USDC
        usdc.mint(address(distributor), 100e6);
        distributor.distribute();

        // 40% to treasury
        assertEq(usdc.balanceOf(treasuryAddr), 40e6);
        // 60% to staking contract
        assertEq(usdc.balanceOf(address(staking)), 60e6);
        // Nothing left in distributor
        assertEq(usdc.balanceOf(address(distributor)), 0);
        // Alice should have earned 60 USDC
        assertEq(staking.earned(alice), 60e6);
    }

    function testFuzzDistributeSplit(uint256 balance) public {
        balance = bound(balance, 1e6, 1_000_000e6); // 1 USDC to 1M USDC

        usdc.mint(address(distributor), balance);
        distributor.distribute();

        uint256 expectedTreasury = balance - (balance * 6000) / 10_000;
        uint256 actualTreasury = usdc.balanceOf(treasuryAddr);
        // Treasury gets 40%, held staker share stays in distributor (no stakers)
        assertEq(actualTreasury, expectedTreasury, "Treasury should get 40%");
        uint256 held = usdc.balanceOf(address(distributor));
        // 60% + 40% should equal original balance (within 1 wei for rounding)
        assertApproxEqAbs(held + actualTreasury, balance, 1, "60/40 split should sum to total");
    }

    function testDoubleDistributeReverts() public {
        usdc.mint(address(distributor), 100e6);
        distributor.distribute();

        // Second call without new fees — distributor balance is 60e6 (held staker share, no stakers)
        // But if stakers exist, balance would be 0
        // Let's test with stakers so balance truly goes to 0
        vm.prank(treasuryAddr);
        gov.transfer(alice, 1000e18);
        vm.prank(alice);
        gov.approve(address(staking), type(uint256).max);
        vm.prank(alice);
        staking.stake(1000e18);

        // Add exactly enough to distribute
        usdc.mint(address(distributor), 100e6);
        distributor.distribute();

        // Now balance is 0, distribute should revert
        vm.expectRevert(abi.encodeWithSelector(FeeDistributor.InsufficientFees.selector, 0));
        distributor.distribute();
    }

    function testAccumulatedDistribution() public {
        // First: no stakers, 100 USDC — 60 held, 40 to treasury
        usdc.mint(address(distributor), 100e6);
        distributor.distribute();
        assertEq(usdc.balanceOf(address(distributor)), 60e6);
        assertEq(usdc.balanceOf(treasuryAddr), 40e6);

        // Now Alice stakes
        vm.prank(treasuryAddr);
        gov.transfer(alice, 1000e18);
        vm.prank(alice);
        gov.approve(address(staking), type(uint256).max);
        vm.prank(alice);
        staking.stake(1000e18);

        // Add another 40 USDC, total in distributor = 60 + 40 = 100
        usdc.mint(address(distributor), 40e6);

        distributor.distribute();

        // Post-audit-fix semantics: heldForStakers is not re-split.
        // New fees this distribute: 40 USDC → 24 to stakers, 16 to treasury.
        // Stakers receive: 60 previously held + 24 new = 84 USDC.
        // Treasury cumulative: 40 (first distribute) + 16 (second) = 56 USDC.
        assertEq(usdc.balanceOf(treasuryAddr), 56e6);
        assertEq(usdc.balanceOf(address(staking)), 84e6);
        assertEq(usdc.balanceOf(address(distributor)), 0);
    }
}
