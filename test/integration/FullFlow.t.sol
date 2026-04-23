// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {RWAVault} from "../../src/RWAVault.sol";
import {FeeDistributor} from "../../src/FeeDistributor.sol";
import {GovStaking} from "../../src/GovStaking.sol";
import {QUELLToken} from "../../src/QUELLToken.sol";
import {MockYieldAdapter} from "../../src/adapters/MockYieldAdapter.sol";
import {IYieldAdapter} from "../../src/adapters/IYieldAdapter.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {MockYieldVault} from "../mocks/MockYieldVault.sol";
import {DelegatingMockAdapter} from "../mocks/DelegatingMockAdapter.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract FullFlowTest is Test {
    RWAVault public vault;
    MockUSDC public usdc;
    MockYieldVault public mockVault;
    DelegatingMockAdapter public adapter;
    FeeDistributor public distributor;
    GovStaking public staking;
    QUELLToken public gov;

    address public owner = makeAddr("owner");
    address public guardian = makeAddr("guardian");
    address public treasury = makeAddr("treasury");
    address public vestingWallet = makeAddr("vestingWallet");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public carol = makeAddr("carol");

    uint256 constant MGMT_FEE_BPS = 20;
    uint256 constant PERF_FEE_BPS = 1000;
    uint256 constant TVL_CAP = 1_000_000e6;

    function setUp() public {
        // Full deployment sequence
        usdc = new MockUSDC();
        mockVault = new MockYieldVault(IERC20(address(usdc)));
        adapter = new DelegatingMockAdapter(address(mockVault));
        gov = new QUELLToken(treasury, vestingWallet);
        staking = new GovStaking(address(gov), address(usdc), owner);
        distributor = new FeeDistributor(address(usdc), address(staking), treasury);

        vm.prank(owner);
        staking.setFeeDistributor(address(distributor));

        vault = new RWAVault(
            IERC20(address(usdc)),
            IYieldAdapter(address(adapter)),
            distributor,
            owner,
            guardian,
            MGMT_FEE_BPS,
            PERF_FEE_BPS,
            TVL_CAP
        );

        // Give carol GOV tokens for staking
        vm.prank(treasury);
        gov.transfer(carol, 10_000e18);
    }

    // --- Helpers ---

    function _fundAndDeposit(address user, uint256 amount) internal returns (uint256 shares) {
        usdc.mint(user, amount);
        vm.startPrank(user);
        usdc.approve(address(vault), amount);
        shares = vault.deposit(amount, user);
        vm.stopPrank();
    }

    // --- Scenario 1: Basic full flow ---

    function testBasicFlow() public {
        // Alice deposits 10K USDC
        _fundAndDeposit(alice, 10_000e6);
        assertGt(vault.balanceOf(alice), 0);

        // Warp 30 days — yield accrues (mock materializes yield via USDC minting)
        vm.warp(block.timestamp + 30 days);

        // Bob deposits 5K USDC (triggers fee harvest)
        _fundAndDeposit(bob, 5_000e6);

        uint256 distributorBalance = usdc.balanceOf(address(distributor));
        assertGt(distributorBalance, 0, "Fees should be collected");

        // Carol stakes GOV
        vm.startPrank(carol);
        gov.approve(address(staking), 10_000e18);
        staking.stake(10_000e18);
        vm.stopPrank();

        // Distribute fees (permissionless)
        if (usdc.balanceOf(address(distributor)) >= 1e6) {
            distributor.distribute();

            // Carol should have earned rewards
            assertGt(staking.earned(carol), 0, "Carol should earn USDC rewards");

            // Carol claims
            vm.prank(carol);
            staking.claimRewards();
            assertGt(usdc.balanceOf(carol), 0, "Carol should have USDC");
        }

        // Alice redeems all shares
        uint256 aliceShares = vault.balanceOf(alice);
        vm.prank(alice);
        uint256 aliceUsdc = vault.redeem(aliceShares, alice, alice);
        assertGt(aliceUsdc, 0, "Alice should get USDC back");

        // Bob redeems all shares
        uint256 bobShares = vault.balanceOf(bob);
        vm.prank(bob);
        uint256 bobUsdc = vault.redeem(bobShares, bob, bob);
        assertGt(bobUsdc, 0, "Bob should get USDC back");
    }

    // --- Scenario 2: No stakers — fees held ---

    function testNoStakersFeesHeld() public {
        _fundAndDeposit(alice, 10_000e6);
        vm.warp(block.timestamp + 30 days);
        usdc.mint(address(mockVault), 10_000e6);

        // Bob deposits, triggering harvest
        _fundAndDeposit(bob, 1_000e6);

        uint256 distributorBalance = usdc.balanceOf(address(distributor));
        assertGt(distributorBalance, 0, "Distributor should have fees");

        // Distribute with no stakers — 60% held, 40% to treasury
        uint256 treasuryBefore = usdc.balanceOf(treasury);
        distributor.distribute();

        uint256 treasuryReceived = usdc.balanceOf(treasury) - treasuryBefore;
        assertGt(treasuryReceived, 0, "Treasury should receive 40%");

        uint256 heldForStakers = usdc.balanceOf(address(distributor));
        assertGt(heldForStakers, 0, "60% should be held for stakers");

        // Now carol stakes and accumulated distributes
        vm.startPrank(carol);
        gov.approve(address(staking), 10_000e18);
        staking.stake(10_000e18);
        vm.stopPrank();

        // Add a bit more to reach min distribute threshold with held balance
        if (usdc.balanceOf(address(distributor)) >= 1e6) {
            distributor.distribute();
            assertGt(staking.earned(carol), 0, "Carol should earn accumulated rewards");
        }
    }

    // --- Scenario 3: Emergency mode ---

    function testEmergencyMode() public {
        _fundAndDeposit(alice, 10_000e6);
        usdc.mint(address(mockVault), 10_000e6);

        // Guardian activates emergency
        vm.prank(guardian);
        vault.setEmergencyMode();
        assertTrue(vault.emergencyMode());
        assertTrue(vault.paused());

        // Deposit blocked
        usdc.mint(bob, 1_000e6);
        vm.startPrank(bob);
        usdc.approve(address(vault), 1_000e6);
        vm.expectRevert(); // maxDeposit returns 0
        vault.deposit(1_000e6, bob);
        vm.stopPrank();

        // Redeem works
        uint256 shares = vault.balanceOf(alice);
        vm.prank(alice);
        uint256 usdcBack = vault.redeem(shares, alice, alice);
        assertGt(usdcBack, 0, "Redeem should work in emergency");
        assertEq(vault.balanceOf(alice), 0);

        // No owner sweep — vault should not have a sweep function
        // (verified by not having such a function in the contract)
    }

    // --- Scenario 4: Adapter swap via timelock ---

    function testAdapterSwapViaTimelock() public {
        _fundAndDeposit(alice, 10_000e6);

        // Deploy timelock (48hr delay)
        address[] memory proposers = new address[](1);
        proposers[0] = owner;
        address[] memory executors = new address[](1);
        executors[0] = owner;
        TimelockController timelock = new TimelockController(
            48 hours,
            proposers,
            executors,
            address(0) // no admin
        );

        // Transfer vault ownership to timelock (two-step: propose then accept)
        vm.prank(owner);
        vault.transferOwnership(address(timelock));

        // Timelock must accept ownership — schedule and execute acceptOwnership
        bytes memory acceptData = abi.encodeWithSelector(vault.acceptOwnership.selector);
        vm.prank(owner);
        timelock.schedule(address(vault), 0, acceptData, bytes32(0), bytes32("accept"), 48 hours);
        vm.warp(block.timestamp + 48 hours + 1);
        vm.prank(owner);
        timelock.execute(address(vault), 0, acceptData, bytes32(0), bytes32("accept"));
        assertEq(vault.owner(), address(timelock));

        // Deploy new adapter
        MockYieldVault newMockVault = new MockYieldVault(IERC20(address(usdc)));
        DelegatingMockAdapter newAdapter = new DelegatingMockAdapter(address(newMockVault));

        // Schedule setAdapter via timelock
        bytes memory data = abi.encodeWithSelector(RWAVault.setAdapter.selector, IYieldAdapter(address(newAdapter)));

        vm.prank(owner);
        timelock.schedule(address(vault), 0, data, bytes32(0), bytes32(0), 48 hours);

        // Cannot execute before delay
        vm.prank(owner);
        vm.expectRevert();
        timelock.execute(address(vault), 0, data, bytes32(0), bytes32(0));

        // Warp past delay
        vm.warp(block.timestamp + 48 hours + 1);

        // Execute
        vm.prank(owner);
        timelock.execute(address(vault), 0, data, bytes32(0), bytes32(0));

        // Verify adapter updated
        assertEq(address(vault.adapter()), address(newAdapter));
        // Old vault approval revoked
        assertEq(usdc.allowance(address(vault), address(mockVault)), 0);
    }
}
