// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {QUELLToken} from "../src/QUELLToken.sol";

contract QUELLTokenTest is Test {
    QUELLToken public gov;

    address public treasury = makeAddr("treasury");
    address public vestingWallet = makeAddr("vestingWallet");
    address public deployer = makeAddr("deployer");

    function setUp() public {
        vm.prank(deployer);
        gov = new QUELLToken(treasury, vestingWallet);
    }

    function testTotalSupply() public view {
        assertEq(gov.totalSupply(), 100_000_000e18);
    }

    function testDistribution() public view {
        assertEq(gov.balanceOf(treasury), 75_000_000e18);
        assertEq(gov.balanceOf(vestingWallet), 25_000_000e18);
    }

    function testDeployerHasNoTokens() public view {
        assertEq(gov.balanceOf(deployer), 0);
    }

    function testTransfer() public {
        address alice = makeAddr("alice");
        vm.prank(treasury);
        gov.transfer(alice, 1000e18);
        assertEq(gov.balanceOf(alice), 1000e18);
        assertEq(gov.balanceOf(treasury), 75_000_000e18 - 1000e18);
    }

    function testApproveAndTransferFrom() public {
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");

        vm.prank(treasury);
        gov.approve(alice, 500e18);

        vm.prank(alice);
        gov.transferFrom(treasury, bob, 500e18);

        assertEq(gov.balanceOf(bob), 500e18);
        assertEq(gov.allowance(treasury, alice), 0);
    }

    function testNameAndSymbol() public view {
        assertEq(gov.name(), "Quell Governance");
        assertEq(gov.symbol(), "QUELL");
    }

    function testRevertsZeroTreasury() public {
        vm.expectRevert("QUELLToken: zero treasury");
        new QUELLToken(address(0), vestingWallet);
    }

    function testRevertsZeroVesting() public {
        vm.expectRevert("QUELLToken: zero vesting");
        new QUELLToken(treasury, address(0));
    }
}
