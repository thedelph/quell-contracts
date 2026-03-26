// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {RWAVault} from "../src/RWAVault.sol";
import {GovStaking} from "../src/GovStaking.sol";
import {FeeDistributor} from "../src/FeeDistributor.sol";
import {IMorphoAdapter} from "../src/adapters/IMorphoAdapter.sol";

/// @title VerifyDeployment — Read-only post-deploy verification
/// @notice Reads deployed addresses from env vars and verifies all configuration.
///         Usage: forge script script/VerifyDeployment.s.sol --rpc-url $BASE_MAINNET_RPC
contract VerifyDeployment is Script {
    uint256 failures;

    function run() external {
        console.log("=== Quell Post-Deploy Verification ===");
        console.log("");

        _checkVault();
        _checkStaking();
        _checkDistributor();
        _checkAllowance();

        console.log("");
        if (failures == 0) {
            console.log("=== ALL CHECKS PASSED ===");
        } else {
            console.log("=== FAILURES:", failures, "===");
            revert("Verification failed");
        }
    }

    function _checkVault() internal {
        RWAVault vault = RWAVault(vm.envAddress("VAULT_ADDRESS"));
        address timelockAddr = vm.envAddress("TIMELOCK_ADDRESS");

        _check("vault.adapter", address(vault.adapter()) == vm.envAddress("ADAPTER_ADDRESS"));
        _check("vault.feeDistributor", address(vault.feeDistributor()) == vm.envAddress("DISTRIBUTOR_ADDRESS"));
        _check("vault.guardian", vault.guardian() == vm.envAddress("GUARDIAN_ADDRESS"));

        // Ownership: either timelock already accepted, or transfer is pending
        address currentOwner = vault.owner();
        if (currentOwner == timelockAddr) {
            console.log("[PASS] vault.owner == timelock (transfer complete)");
        } else {
            address pendingOwner = vault.pendingOwner();
            if (pendingOwner == timelockAddr) {
                console.log("[WARN] vault.owner != timelock, but pendingOwner == timelock (transfer pending)");
                console.log("       Schedule timelock.acceptOwnership() to complete transfer");
            } else {
                console.log("[FAIL] vault.owner is not timelock and pendingOwner is not timelock");
                failures++;
            }
        }

        _check("vault.managementFeeBps", vault.managementFeeBps() == vm.envOr("EXPECTED_MGMT_FEE_BPS", uint256(20)));
        _check("vault.performanceFeeBps", vault.performanceFeeBps() == vm.envOr("EXPECTED_PERF_FEE_BPS", uint256(1000)));
        _check("vault.tvlCap", vault.tvlCap() == vm.envOr("EXPECTED_TVL_CAP", uint256(100_000e6)));
        _check("vault.paused == false", !vault.paused());
        _check("vault.emergencyMode == false", !vault.emergencyMode());
    }

    function _checkStaking() internal {
        GovStaking staking = GovStaking(vm.envAddress("STAKING_ADDRESS"));

        _check("staking.GOV_TOKEN", address(staking.GOV_TOKEN()) == vm.envAddress("GOV_TOKEN_ADDRESS"));
        _check("staking.REWARD_TOKEN (USDC)", address(staking.REWARD_TOKEN()) == vm.envAddress("USDC_ADDRESS"));
        _check("staking.feeDistributor", staking.feeDistributor() == vm.envAddress("DISTRIBUTOR_ADDRESS"));
    }

    function _checkDistributor() internal {
        FeeDistributor distributor = FeeDistributor(vm.envAddress("DISTRIBUTOR_ADDRESS"));

        _check("distributor.STAKING", address(distributor.STAKING()) == vm.envAddress("STAKING_ADDRESS"));
        _check("distributor.TREASURY", distributor.TREASURY() == vm.envAddress("TREASURY_ADDRESS"));
        _check("distributor.USDC", address(distributor.USDC()) == vm.envAddress("USDC_ADDRESS"));
    }

    function _checkAllowance() internal {
        address vaultAddr = vm.envAddress("VAULT_ADDRESS");
        address adapterAddr = vm.envAddress("ADAPTER_ADDRESS");
        address usdc = vm.envAddress("USDC_ADDRESS");

        address steakhouseVault = IMorphoAdapter(adapterAddr).STEAKHOUSE_VAULT();
        uint256 allowance = IERC20(usdc).allowance(vaultAddr, steakhouseVault);
        _check("USDC allowance vault->steakhouse == max", allowance == type(uint256).max);
    }

    function _check(string memory label, bool condition) internal {
        if (condition) {
            console.log("[PASS]", label);
        } else {
            console.log("[FAIL]", label);
            failures++;
        }
    }
}
