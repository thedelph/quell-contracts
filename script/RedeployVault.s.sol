// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {RWAVault} from "../src/RWAVault.sol";
import {FeeDistributor} from "../src/FeeDistributor.sol";
import {IMorphoAdapter} from "../src/adapters/IMorphoAdapter.sol";

/// @title RedeployVault — Redeploy only the RWAVault contract
/// @notice Uses existing MorphoAdapter, FeeDistributor, and TimelockController.
///         Reason: fix fee-harvest-before-preview ordering bug in _withdraw.
contract RedeployVault is Script {
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    uint256 constant MANAGEMENT_FEE_BPS = 20;     // 0.2%
    uint256 constant PERFORMANCE_FEE_BPS = 1000;   // 10%
    uint256 constant TVL_CAP = 100_000e6;           // 100K USDC

    function run() external {
        uint256 deployerPk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPk);
        address guardian = vm.envAddress("GUARDIAN_ADDRESS");

        // Existing contracts (unchanged)
        address adapterAddr = vm.envAddress("ADAPTER_ADDRESS");
        address distributorAddr = vm.envAddress("DISTRIBUTOR_ADDRESS");
        address timelockAddr = vm.envAddress("TIMELOCK_ADDRESS");

        require(block.chainid == 8453, "Must deploy on Base Mainnet (chainId 8453)");
        require(guardian != address(0), "Guardian is zero address");
        require(adapterAddr != address(0), "Adapter is zero address");
        require(distributorAddr != address(0), "Distributor is zero address");
        require(timelockAddr != address(0), "Timelock is zero address");

        console.log("=== RWAVault Redeployment ===");
        console.log("Deployer:", deployer);
        console.log("Guardian:", guardian);
        console.log("Adapter (existing):", adapterAddr);
        console.log("Distributor (existing):", distributorAddr);
        console.log("Timelock (existing):", timelockAddr);

        vm.startBroadcast(deployerPk);

        // Deploy new RWAVault with fix
        RWAVault vault = new RWAVault(
            IERC20(USDC),
            IMorphoAdapter(adapterAddr),
            FeeDistributor(distributorAddr),
            deployer,
            guardian,
            MANAGEMENT_FEE_BPS,
            PERFORMANCE_FEE_BPS,
            TVL_CAP
        );
        console.log("New RWAVault:", address(vault));

        // Set strategy description
        vault.setStrategyDescription(
            "Steakhouse USDC MetaMorpho Vault - RWA-backed yield on Base"
        );

        // Transfer ownership to existing timelock (two-step)
        vault.transferOwnership(timelockAddr);
        console.log("Vault ownership transfer proposed to timelock");

        vm.stopBroadcast();

        console.log("");
        console.log("=== Redeployment complete ===");
        console.log(string.concat("NEW_VAULT_ADDRESS=", vm.toString(address(vault))));
        console.log("");
        console.log("Next steps:");
        console.log("1. Update VITE_RWA_VAULT_ADDRESS in .env, .env.production, and Vercel");
        console.log("2. Schedule timelock acceptOwnership (48hr delay)");
        console.log("3. Update frontend ABI if needed (check for new functions)");
        console.log("4. Redeploy frontend");
        console.log("5. Execute timelock acceptOwnership after 48hr");
    }
}
