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
import {RWAVaultHandler} from "./RWAVaultHandler.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract RWAVaultInvariants is Test {
    RWAVault public vault;
    MockUSDC public usdc;
    MockYieldVault public mockVault;
    MockYieldAdapter public adapter;
    FeeDistributor public distributor;
    GovStaking public staking;
    QUELLToken public gov;
    RWAVaultHandler public handler;

    address public owner = makeAddr("owner");
    address public guardian = makeAddr("guardian");
    address public treasury = makeAddr("treasury");
    address public vestingWallet = makeAddr("vestingWallet");

    function setUp() public {
        usdc = new MockUSDC();
        mockVault = new MockYieldVault(IERC20(address(usdc)));
        adapter = new MockYieldAdapter(address(mockVault));
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
            20,   // 0.2% mgmt fee
            1000, // 10% perf fee
            100_000e6 // 100K TVL cap
        );

        handler = new RWAVaultHandler(vault, usdc, mockVault);

        // Target only the handler for fuzzer calls
        targetContract(address(handler));
    }

    /// @notice totalAssets matches adapter's view of mockVault shares held by vault
    function invariant_totalAssetsConsistent() public view {
        address mockVaultVault = adapter.YIELD_VAULT();
        uint256 steakShares = IERC20(mockVaultVault).balanceOf(address(vault));

        if (steakShares == 0) {
            assertEq(vault.totalAssets(), 0);
        } else {
            uint256 adapterView = adapter.sharesToUsdc(steakShares);
            assertEq(vault.totalAssets(), adapterView);
        }
    }

    /// @notice Dead shares at 0xdead are immutable once minted
    function invariant_deadSharesImmutable() public view {
        uint256 supply = vault.totalSupply();
        if (supply > 0) {
            assertEq(vault.balanceOf(address(0xdead)), 1000);
        }
    }

    /// @notice TVL at deposit time is capped; yield accrual may push above
    /// @dev Allows up to 3% overshoot from yield growth (mock ~3% APY, warps up to 30d × depth)
    function invariant_tvlCapRespected() public view {
        uint256 maxWithYield = vault.tvlCap() + (vault.tvlCap() * 3) / 100;
        assertLe(vault.totalAssets(), maxWithYield);
    }

    /// @notice High water mark never decreases
    function invariant_hwmNonDecreasing() public view {
        assertGe(vault.highWaterMark(), handler.ghost_previousHWM());
    }

    /// @notice Vault remains solvent: totalAssets > 0 whenever shares exist beyond dead shares
    function invariant_solvent() public view {
        uint256 supply = vault.totalSupply();
        if (supply <= 1000) return; // Only dead shares — skip
        assertGt(vault.totalAssets(), 0, "Vault insolvent: shares exist but no assets");
    }
}
