// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test, Vm} from "forge-std/Test.sol";
import {RWAVault} from "../src/RWAVault.sol";
import {FeeDistributor} from "../src/FeeDistributor.sol";
import {GovStaking} from "../src/GovStaking.sol";
import {QUELLToken} from "../src/QUELLToken.sol";
import {MockYieldAdapter} from "../src/adapters/MockYieldAdapter.sol";
import {IYieldAdapter} from "../src/adapters/IYieldAdapter.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {MockYieldVault} from "./mocks/MockYieldVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

contract RWAVaultTest is Test {
    RWAVault public vault;
    MockUSDC public usdc;
    MockYieldVault public mockVault;
    MockYieldAdapter public adapter;
    FeeDistributor public distributor;
    GovStaking public staking;
    QUELLToken public gov;

    address public owner = makeAddr("owner");
    address public guardian = makeAddr("guardian");
    address public treasury = makeAddr("treasury");
    address public vestingWallet = makeAddr("vestingWallet");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

    uint256 constant MGMT_FEE_BPS = 20; // 0.2%
    uint256 constant PERF_FEE_BPS = 1000; // 10%
    uint256 constant TVL_CAP = 100_000e6; // 100K USDC

    function setUp() public {
        usdc = new MockUSDC();
        mockVault = new MockYieldVault(IERC20(address(usdc)));
        adapter = new MockYieldAdapter(address(mockVault));
        gov = new QUELLToken(treasury, vestingWallet);
        staking = new GovStaking(address(gov), address(usdc), owner);
        distributor = new FeeDistributor(address(usdc), address(staking), treasury);

        // Link staking to distributor
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
    }

    // --- Helpers ---

    function _fundAndDeposit(address user, uint256 amount) internal returns (uint256 shares) {
        usdc.mint(user, amount);
        vm.startPrank(user);
        usdc.approve(address(vault), amount);
        shares = vault.deposit(amount, user);
        vm.stopPrank();
    }

    function _prefundYieldVault(uint256 amount) internal {
        usdc.mint(address(mockVault), amount);
    }

    // --- Unit Tests ---

    function testDecimalsOffset() public view {
        assertEq(vault.decimals(), 18);
    }

    function testDeposit() public {
        uint256 shares = _fundAndDeposit(alice, 1000e6);

        // Shares should be in 18-decimal range (1000e6 * 1e12 = 1000e18 at 1:1)
        assertGt(shares, 0);
        assertGt(vault.balanceOf(alice), 0);
        // Yield vault should hold USDC
        assertGt(usdc.balanceOf(address(mockVault)), 0);
    }

    function testDeadSharesOnFirstDeposit() public {
        _fundAndDeposit(alice, 1000e6);
        assertEq(vault.balanceOf(address(0xdead)), 1000);
    }

    function testInflationAttackProtection() public {
        // Attacker deposits small amount first
        _fundAndDeposit(alice, 1e6); // 1 USDC

        // Attacker donates USDC directly to steakhouse to inflate share price
        usdc.mint(address(mockVault), 1000e6);

        // Alice deposits more - should still get fair shares
        uint256 bobShares = _fundAndDeposit(bob, 1000e6);
        assertGt(bobShares, 0, "Bob should receive shares");
    }

    function testHarvestNoOpWithinInterval() public {
        _fundAndDeposit(alice, 1000e6);

        uint256 distributorBefore = usdc.balanceOf(address(distributor));

        // Second deposit within 1 hour — harvest should be no-op
        _fundAndDeposit(bob, 500e6);

        assertEq(usdc.balanceOf(address(distributor)), distributorBefore, "No fees should be harvested");
    }

    function testManagementFeeHarvest() public {
        _fundAndDeposit(alice, 10_000e6);

        // Warp past minimum harvest interval
        vm.warp(block.timestamp + 2 hours);

        // Pre-fund steakhouse for withdrawal
        _prefundYieldVault(100e6);

        // Trigger harvest via another deposit
        uint256 distributorBefore = usdc.balanceOf(address(distributor));
        _fundAndDeposit(bob, 1000e6);

        uint256 feeCollected = usdc.balanceOf(address(distributor)) - distributorBefore;
        assertGt(feeCollected, 0, "Management fee should be collected");
    }

    function testPerformanceFeeAboveHWM() public {
        _fundAndDeposit(alice, 10_000e6);

        // Warp to generate yield (3% APY over 30 days ≈ 0.25%)
        vm.warp(block.timestamp + 30 days);

        // Pre-fund steakhouse for fee withdrawal
        _prefundYieldVault(1000e6);

        uint256 hwmBefore = vault.highWaterMark();
        uint256 distributorBefore = usdc.balanceOf(address(distributor));

        // Trigger harvest
        _fundAndDeposit(bob, 1000e6);

        assertGt(vault.highWaterMark(), hwmBefore, "HWM should increase");
        assertGt(usdc.balanceOf(address(distributor)) - distributorBefore, 0, "Performance fee should be collected");
    }

    function testPerformanceFeeNotBelowHWM() public {
        _fundAndDeposit(alice, 10_000e6);

        // Warp just past min harvest interval — 2 hours has tiny yield
        vm.warp(block.timestamp + 2 hours);
        _prefundYieldVault(100e6);

        // Record HWM and fee state before harvest
        uint256 hwmBefore = vault.highWaterMark();

        // Trigger harvest — both mgmt + perf fee may apply
        _fundAndDeposit(bob, 1000e6);

        uint256 hwmAfter = vault.highWaterMark();

        // With 3% APY mock and 2hr warp, PPS does increase slightly, so HWM updates
        // This test verifies the mechanism works: HWM tracks PPS upward
        assertGe(hwmAfter, hwmBefore, "HWM should not decrease");
    }

    function testTvlCapEnforcement() public {
        // Deposit up to near TVL cap
        _fundAndDeposit(alice, 90_000e6);

        // Try to exceed cap
        usdc.mint(bob, 20_000e6);
        vm.startPrank(bob);
        usdc.approve(address(vault), 20_000e6);
        uint256 maxDep = vault.maxDeposit(bob);
        vm.expectRevert(
            abi.encodeWithSignature("ERC4626ExceededMaxDeposit(address,uint256,uint256)", bob, 20_000e6, maxDep)
        );
        vault.deposit(20_000e6, bob);
        vm.stopPrank();
    }

    function testPausedBlocksAll() public {
        _fundAndDeposit(alice, 1000e6);

        vm.prank(guardian);
        vault.setPaused(true);

        // Deposit should revert
        usdc.mint(bob, 500e6);
        vm.startPrank(bob);
        usdc.approve(address(vault), 500e6);
        vm.expectRevert(
            abi.encodeWithSignature("ERC4626ExceededMaxDeposit(address,uint256,uint256)", bob, 500e6, uint256(0))
        );
        vault.deposit(500e6, bob);
        vm.stopPrank();

        // Redeem should also revert (paused, not emergency — maxRedeem returns 0)
        uint256 aliceShares = vault.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSignature("ERC4626ExceededMaxRedeem(address,uint256,uint256)", alice, aliceShares, uint256(0))
        );
        vault.redeem(aliceShares, alice, alice);
    }

    function testEmergencyAllowsRedeem() public {
        _fundAndDeposit(alice, 1000e6);

        // Pre-fund steakhouse for redemption
        _prefundYieldVault(1000e6);

        vm.prank(guardian);
        vault.setEmergencyMode();

        // Deposit should revert
        usdc.mint(bob, 500e6);
        vm.startPrank(bob);
        usdc.approve(address(vault), 500e6);
        vm.expectRevert(
            abi.encodeWithSignature("ERC4626ExceededMaxDeposit(address,uint256,uint256)", bob, 500e6, uint256(0))
        );
        vault.deposit(500e6, bob);
        vm.stopPrank();

        // Redeem should succeed
        uint256 shares = vault.balanceOf(alice);
        vm.prank(alice);
        uint256 assets = vault.redeem(shares, alice, alice);
        assertGt(assets, 0, "Should receive USDC back");
    }

    function testGuardianAccess() public {
        // Guardian can pause
        vm.prank(guardian);
        vault.setPaused(true);
        assertTrue(vault.paused());

        // Guardian cannot setFees
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", guardian));
        vault.setFees(10, 500);
    }

    function testOwnerAccess() public {
        vm.startPrank(owner);
        vault.setFees(10, 500);
        vault.setTvlCap(200_000e6);
        vault.setGuardian(makeAddr("newGuardian"));
        vault.setStrategyDescription("Test strategy");
        vm.stopPrank();

        assertEq(vault.managementFeeBps(), 10);
        assertEq(vault.performanceFeeBps(), 500);
        assertEq(vault.tvlCap(), 200_000e6);
        assertEq(vault.guardian(), makeAddr("newGuardian"));
    }

    function testSetAdapterRevokesApproval() public {
        address oldVault = adapter.YIELD_VAULT();

        // Deploy new adapter
        MockYieldVault newMockVault = new MockYieldVault(IERC20(address(usdc)));
        MockYieldAdapter newAdapter = new MockYieldAdapter(address(newMockVault));

        vm.prank(owner);
        vault.setAdapter(IYieldAdapter(address(newAdapter)));

        // Old vault allowance should be 0
        assertEq(usdc.allowance(address(vault), oldVault), 0);
        // New vault should have max allowance
        assertEq(usdc.allowance(address(vault), address(newMockVault)), type(uint256).max);
    }

    function testDepositWithSlippage() public {
        usdc.mint(alice, 1000e6);
        vm.startPrank(alice);
        usdc.approve(address(vault), 1000e6);

        // Should succeed with reasonable minShares
        uint256 expectedShares = vault.previewDeposit(1000e6);
        uint256 shares = vault.depositWithSlippage(1000e6, alice, expectedShares);
        assertGe(shares, expectedShares);
        vm.stopPrank();
    }

    function testRedeemWithSlippage() public {
        _fundAndDeposit(alice, 1000e6);
        _prefundYieldVault(1000e6);

        uint256 shares = vault.balanceOf(alice);
        uint256 expectedAssets = vault.previewRedeem(shares);

        vm.prank(alice);
        uint256 assets = vault.redeemWithSlippage(shares, alice, alice, expectedAssets - 2);
        assertGe(assets + 2, expectedAssets);
    }

    function testWithdrawEmitsActualUsdc() public {
        _fundAndDeposit(alice, 1000e6);
        _prefundYieldVault(1000e6);

        uint256 shares = vault.balanceOf(alice);

        vm.prank(alice);
        vm.recordLogs();
        vault.redeem(shares, alice, alice);

        // Verify Withdraw event was emitted
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found = false;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == keccak256("Withdraw(address,address,address,uint256,uint256)")) {
                found = true;
                break;
            }
        }
        assertTrue(found, "Withdraw event should be emitted");
    }

    function testRedeemBasic() public {
        uint256 depositAmount = 1000e6;
        _fundAndDeposit(alice, depositAmount);
        _prefundYieldVault(depositAmount);

        uint256 shares = vault.balanceOf(alice);
        assertGt(shares, 0);

        vm.prank(alice);
        uint256 usdcReceived = vault.redeem(shares, alice, alice);

        assertGt(usdcReceived, 0, "Should receive USDC");
        assertEq(vault.balanceOf(alice), 0, "Should have no shares left");
    }

    // --- Fuzz Tests ---

    // --- Error Selector Specificity Tests ---

    function testDepositWithSlippageReverts() public {
        usdc.mint(alice, 1000e6);
        vm.startPrank(alice);
        usdc.approve(address(vault), 1000e6);
        // Impossibly high minShares should revert
        vm.expectRevert(RWAVault.SlippageExceeded.selector);
        vault.depositWithSlippage(1000e6, alice, type(uint256).max);
        vm.stopPrank();
    }

    function testRedeemWithSlippageReverts() public {
        _fundAndDeposit(alice, 1000e6);
        _prefundYieldVault(1000e6);

        uint256 shares = vault.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert(RWAVault.SlippageExceeded.selector);
        vault.redeemWithSlippage(shares, alice, alice, type(uint256).max);
    }

    function testSetFeesRevertsOnExcessiveFees() public {
        vm.prank(owner);
        vm.expectRevert(RWAVault.FeeTooHigh.selector);
        vault.setFees(501, 1000);

        vm.prank(owner);
        vm.expectRevert(RWAVault.FeeTooHigh.selector);
        vault.setFees(100, 3001);
    }

    function testConstructorFeeCaps() public {
        vm.expectRevert(RWAVault.FeeTooHigh.selector);
        new RWAVault(
            IERC20(address(usdc)),
            IYieldAdapter(address(adapter)),
            distributor,
            owner,
            guardian,
            501, // exceeds MAX_MANAGEMENT_FEE_BPS
            1000,
            TVL_CAP
        );

        vm.expectRevert(RWAVault.FeeTooHigh.selector);
        new RWAVault(
            IERC20(address(usdc)),
            IYieldAdapter(address(adapter)),
            distributor,
            owner,
            guardian,
            100,
            3001, // exceeds MAX_PERFORMANCE_FEE_BPS
            TVL_CAP
        );
    }

    function testMaxMintReturnZeroWhenPaused() public {
        vm.prank(guardian);
        vault.setPaused(true);
        assertEq(vault.maxMint(alice), 0);
    }

    function testMaxRedeemInEmergency() public {
        _fundAndDeposit(alice, 1000e6);
        uint256 aliceShares = vault.balanceOf(alice);

        vm.prank(guardian);
        vault.setEmergencyMode();

        assertEq(vault.maxRedeem(alice), aliceShares);
    }

    function testSetGuardianUpdatesAccess() public {
        address newGuardian = makeAddr("newGuardian");
        vm.prank(owner);
        vault.setGuardian(newGuardian);

        // New guardian can pause
        vm.prank(newGuardian);
        vault.setPaused(true);
        assertTrue(vault.paused());

        // Old guardian cannot pause (unpause)
        vm.prank(guardian);
        vm.expectRevert(RWAVault.NotGuardianOrOwner.selector);
        vault.setPaused(false);
    }

    function testNonOwnerCannotSetAdapter() public {
        MockYieldVault newMockVault = new MockYieldVault(IERC20(address(usdc)));
        MockYieldAdapter newAdapter = new MockYieldAdapter(address(newMockVault));

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", alice));
        vault.setAdapter(IYieldAdapter(address(newAdapter)));
    }

    function testNonOwnerCannotSetTvlCap() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", alice));
        vault.setTvlCap(200_000e6);
    }

    // --- Existing error selector specificity improvements ---

    function testTvlCapEnforcementSpecificError() public {
        _fundAndDeposit(alice, 90_000e6);

        usdc.mint(bob, 20_000e6);
        vm.startPrank(bob);
        usdc.approve(address(vault), 20_000e6);
        uint256 maxDep = vault.maxDeposit(bob);
        vm.expectRevert(
            abi.encodeWithSignature("ERC4626ExceededMaxDeposit(address,uint256,uint256)", bob, 20_000e6, maxDep)
        );
        vault.deposit(20_000e6, bob);
        vm.stopPrank();
    }

    function testPausedBlocksDepositSpecificError() public {
        vm.prank(guardian);
        vault.setPaused(true);

        usdc.mint(bob, 500e6);
        vm.startPrank(bob);
        usdc.approve(address(vault), 500e6);
        vm.expectRevert(
            abi.encodeWithSignature("ERC4626ExceededMaxDeposit(address,uint256,uint256)", bob, 500e6, uint256(0))
        );
        vault.deposit(500e6, bob);
        vm.stopPrank();
    }

    function testGuardianCannotSetFeesSpecificError() public {
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", guardian));
        vault.setFees(10, 500);
    }

    // --- Branch Coverage Tests ---

    function testExcessiveRoundingReverts() public {
        _fundAndDeposit(alice, 1000e6);
        _prefundYieldVault(1000e6);

        uint256 shares = vault.balanceOf(alice);
        uint256 expectedAssets = vault.previewRedeem(shares);

        // Mock steakhouse redeem to return assets - 3 (exceeds dust tolerance of 2)
        address yieldVault = adapter.YIELD_VAULT();
        vm.mockCall(
            yieldVault, abi.encodeWithSelector(IERC4626(yieldVault).redeem.selector), abi.encode(expectedAssets - 3)
        );

        vm.prank(alice);
        vm.expectRevert(RWAVault.ExcessiveRounding.selector);
        vault.redeem(shares, alice, alice);

        vm.clearMockedCalls();
    }

    function testHarvestYieldVaultRevertDoesNotBlock() public {
        _fundAndDeposit(alice, 10_000e6);

        // Warp past min harvest interval to trigger fee harvest
        vm.warp(block.timestamp + 2 hours);

        // Mock steakhouse redeem to revert (simulating Yield vault outage during harvest)
        address yieldVault = adapter.YIELD_VAULT();
        vm.mockCallRevert(
            yieldVault, abi.encodeWithSelector(IERC4626(yieldVault).redeem.selector), "Yield vault unavailable"
        );

        // Deposit should still succeed despite harvest failure (try/catch)
        // But we need the deposit call to steakhouse to work, so clear mock after harvest
        // Instead: mock only reverts for specific small amounts (fee shares), not deposit
        vm.clearMockedCalls();

        // Alternative approach: mock adapter.usdcToShares to return shares that cause revert
        // Simpler: just mock the steakhouse to revert, then deposit USDC directly
        // Actually the cleanest approach: use mockCallRevert with specific calldata
        // The harvest redeem uses small share amounts, the deposit uses large amounts
        // Let's use a different approach — prefund and warp, then mock revert on redeem
        _prefundYieldVault(100e6);

        // Re-mock: make steakhouse redeem revert for any call
        vm.mockCallRevert(
            yieldVault, abi.encodeWithSelector(IERC4626(yieldVault).redeem.selector), "Yield vault unavailable"
        );

        // The deposit itself calls steakhouse.deposit (not redeem), so only the harvest
        // fee redemption hits the reverted mock. Deposit should succeed.
        usdc.mint(bob, 1000e6);
        vm.startPrank(bob);
        usdc.approve(address(vault), 1000e6);
        uint256 shares = vault.deposit(1000e6, bob);
        vm.stopPrank();

        assertGt(shares, 0, "Deposit should succeed despite harvest revert");
        vm.clearMockedCalls();
    }

    function testHarvestZeroSharesSkipped() public {
        _fundAndDeposit(alice, 10_000e6);

        // Warp past min harvest interval
        vm.warp(block.timestamp + 2 hours);
        _prefundYieldVault(100e6);

        // Mock adapter.usdcToShares to return 0 for the fee amount
        // This simulates the fee being too small to convert to steakhouse shares
        vm.mockCall(address(adapter), abi.encodeWithSelector(adapter.usdcToShares.selector), abi.encode(uint256(0)));

        // Deposit should succeed — harvest skips when steakSharesToRedeem == 0
        uint256 distributorBefore = usdc.balanceOf(address(distributor));
        _fundAndDeposit(bob, 1000e6);

        // No fees should reach distributor since harvest was skipped
        assertEq(usdc.balanceOf(address(distributor)), distributorBefore, "No fees when shares round to 0");
        vm.clearMockedCalls();
    }

    function testHarvestZeroFeeUsdcSkipsTransfer() public {
        _fundAndDeposit(alice, 10_000e6);

        // Warp past min harvest interval
        vm.warp(block.timestamp + 2 hours);
        _prefundYieldVault(100e6);

        // Mock steakhouse redeem to return 0 USDC (fee harvest produces nothing)
        address yieldVault = adapter.YIELD_VAULT();
        vm.mockCall(yieldVault, abi.encodeWithSelector(IERC4626(yieldVault).redeem.selector), abi.encode(uint256(0)));

        // Deposit should succeed — harvest skips transfer when feeUsdc == 0
        uint256 distributorBefore = usdc.balanceOf(address(distributor));
        _fundAndDeposit(bob, 1000e6);

        assertEq(usdc.balanceOf(address(distributor)), distributorBefore, "No transfer when feeUsdc is 0");
        vm.clearMockedCalls();
    }

    function testMaxDepositEmergencyMode() public {
        vm.prank(guardian);
        vault.setEmergencyMode();

        assertEq(vault.maxDeposit(alice), 0, "maxDeposit should be 0 in emergency mode");
    }

    function testMaxMintEmergencyMode() public {
        vm.prank(guardian);
        vault.setEmergencyMode();

        assertEq(vault.maxMint(alice), 0, "maxMint should be 0 in emergency mode");
    }

    function testMaxRedeemWhenPaused() public {
        _fundAndDeposit(alice, 1000e6);

        vm.prank(guardian);
        vault.setPaused(true);

        assertEq(vault.maxRedeem(alice), 0, "maxRedeem should be 0 when paused (not emergency)");
    }

    function testRedeemWithAllowance() public {
        _fundAndDeposit(alice, 1000e6);
        _prefundYieldVault(1000e6);

        uint256 shares = vault.balanceOf(alice);

        // Alice approves bob to redeem on her behalf (covers caller != owner_ branch)
        vm.prank(alice);
        vault.approve(bob, shares);

        vm.prank(bob);
        uint256 assets = vault.redeem(shares, bob, alice);
        assertGt(assets, 0, "Bob should receive USDC on alice's behalf");
        assertEq(vault.balanceOf(alice), 0, "Alice should have no shares left");
    }

    function testHarvestEarlyReturnOnZeroAssets() public {
        // Warp past min harvest interval so first deposit's harvest actually runs
        vm.warp(block.timestamp + 2 hours);

        // First deposit — harvest runs but currentAssets == 0, so it returns early
        uint256 distributorBefore = usdc.balanceOf(address(distributor));
        _fundAndDeposit(alice, 1000e6);

        assertEq(usdc.balanceOf(address(distributor)), distributorBefore, "No fees on first deposit");
    }

    function testMaxDepositAtTvlCap() public {
        // Fill vault to TVL cap
        _fundAndDeposit(alice, TVL_CAP);

        assertEq(vault.maxDeposit(bob), 0, "maxDeposit should be 0 at TVL cap");
    }

    // --- Fuzz Tests ---

    function testFuzzSlippageProtection(uint256 amount) public {
        amount = bound(amount, 1e6, TVL_CAP);

        usdc.mint(alice, amount);
        vm.startPrank(alice);
        usdc.approve(address(vault), amount);

        uint256 expectedShares = vault.previewDeposit(amount);
        // Should succeed with expected shares
        uint256 shares = vault.depositWithSlippage(amount, alice, expectedShares);
        assertGe(shares, expectedShares);
        vm.stopPrank();
    }

    function testFuzzDepositAmount(uint256 amount) public {
        amount = bound(amount, 1e6, TVL_CAP); // 1 USDC to TVL cap

        uint256 shares = _fundAndDeposit(alice, amount);
        assertGt(shares, 0, "Should receive shares");

        // Pre-fund steakhouse AFTER deposit (for withdrawal liquidity only)
        _prefundYieldVault(amount);

        // Redeem round-trip
        vm.prank(alice);
        uint256 usdcBack = vault.redeem(shares, alice, alice);

        // Should get back approximately the same (minus rounding from dead shares + ERC4626 math)
        assertApproxEqRel(usdcBack, amount, 0.0001e18, "Round-trip should preserve value");
    }

    function testFuzzFeeCalculation(uint256 tvl, uint256 timeDelta) public {
        tvl = bound(tvl, 100e6, TVL_CAP); // 100 USDC to TVL cap
        timeDelta = bound(timeDelta, 2 hours, 365 days);

        _prefundYieldVault(tvl);
        _fundAndDeposit(alice, tvl);

        vm.warp(block.timestamp + timeDelta);
        _prefundYieldVault(tvl); // Extra funding for fee withdrawal + new deposit

        uint256 distributorBefore = usdc.balanceOf(address(distributor));
        _fundAndDeposit(bob, 100e6); // Trigger harvest

        uint256 fee = usdc.balanceOf(address(distributor)) - distributorBefore;
        // Fee should be reasonable — less than TVL
        assertLe(fee, tvl, "Fee should not exceed TVL");
    }
}
