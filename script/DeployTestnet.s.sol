// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {VestingWallet} from "@openzeppelin/contracts/finance/VestingWallet.sol";

import {QUELLToken} from "../src/QUELLToken.sol";
import {GovStaking} from "../src/GovStaking.sol";
import {FeeDistributor} from "../src/FeeDistributor.sol";
import {RWAVault} from "../src/RWAVault.sol";
import {MockMorphoAdapter} from "../src/adapters/MockMorphoAdapter.sol";
import {IMorphoAdapter} from "../src/adapters/IMorphoAdapter.sol";

// Test mocks (deployed on testnet only)
import {MockUSDC} from "../test/mocks/MockUSDC.sol";
import {MockSteakhouseVault} from "../test/mocks/MockSteakhouseVault.sol";

/// @title DeployTestnet — Base Sepolia deployment script
/// @notice Deploys full protocol with mock contracts for testing
contract DeployTestnet is Script {
    function run() external {
        uint256 deployerPk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPk);

        console.log("Deployer:", deployer);
        console.log("Chain ID:", block.chainid);

        vm.startBroadcast(deployerPk);

        // --- Mock Infrastructure ---
        MockUSDC usdc = new MockUSDC();
        console.log("MockUSDC:", address(usdc));

        MockSteakhouseVault steakhouse = new MockSteakhouseVault(IERC20(address(usdc)));
        console.log("MockSteakhouseVault:", address(steakhouse));

        MockMorphoAdapter adapter = new MockMorphoAdapter(address(steakhouse));
        console.log("MockMorphoAdapter:", address(adapter));

        // --- Step 1: VestingWallet (4yr vest, 1yr cliff) ---
        VestingWallet vestingWallet = new VestingWallet(
            deployer,                          // beneficiary
            uint64(block.timestamp + 365 days), // start (after 1yr cliff)
            uint64(3 * 365 days)               // duration (remaining 3yr)
        );
        console.log("VestingWallet:", address(vestingWallet));

        // --- Step 2: QUELLToken ---
        QUELLToken gov = new QUELLToken(deployer, address(vestingWallet));
        console.log("QUELLToken:", address(gov));

        // --- Step 3: GovStaking ---
        GovStaking staking = new GovStaking(address(gov), address(usdc), deployer);
        console.log("GovStaking:", address(staking));

        // --- Step 4: FeeDistributor ---
        FeeDistributor distributor = new FeeDistributor(address(usdc), address(staking), deployer);
        console.log("FeeDistributor:", address(distributor));

        // --- Step 5: Link staking ↔ distributor ---
        staking.setFeeDistributor(address(distributor));

        // --- Step 6: (adapter already deployed above) ---

        // --- Step 7: TimelockController (48hr delay) ---
        address[] memory proposers = new address[](1);
        proposers[0] = deployer;
        address[] memory executors = new address[](1);
        executors[0] = deployer;
        TimelockController timelock = new TimelockController(
            48 hours,
            proposers,
            executors,
            address(0) // no separate admin
        );
        console.log("TimelockController:", address(timelock));

        // --- Step 8: RWAVault ---
        RWAVault vault = new RWAVault(
            IERC20(address(usdc)),
            IMorphoAdapter(address(adapter)),
            distributor,
            deployer,              // owner (transferred to timelock below)
            deployer,              // guardian (deployer for testnet)
            20,                    // 0.2% management fee
            1000,                  // 10% performance fee
            100_000e6              // 100K USDC TVL cap
        );
        console.log("RWAVault:", address(vault));

        // --- Step 9: Set strategy description ---
        vault.setStrategyDescription(
            "Steakhouse USDC MetaMorpho Vault - RWA-backed yield on Base (TESTNET)"
        );

        // --- Step 10: Transfer vault ownership to timelock (two-step) ---
        // Propose transfer — timelock must call vault.acceptOwnership() to complete
        vault.transferOwnership(address(timelock));
        console.log("Vault ownership transfer proposed to timelock");
        console.log("NOTE: Timelock must call vault.acceptOwnership() to complete transfer");

        // --- Testnet convenience: Mint test USDC ---
        usdc.mint(deployer, 10_000_000e6); // 10M USDC for testing
        console.log("Minted 10M test USDC to deployer");

        vm.stopBroadcast();

        console.log("");
        console.log("=== Testnet deployment complete ===");
        console.log("");

        // --- Structured Address Export ---
        console.log("=== BEGIN DEPLOYED ADDRESSES ===");
        console.log(string.concat("VESTING_WALLET_ADDRESS=", vm.toString(address(vestingWallet))));
        console.log(string.concat("GOV_TOKEN_ADDRESS=", vm.toString(address(gov))));
        console.log(string.concat("STAKING_ADDRESS=", vm.toString(address(staking))));
        console.log(string.concat("DISTRIBUTOR_ADDRESS=", vm.toString(address(distributor))));
        console.log(string.concat("ADAPTER_ADDRESS=", vm.toString(address(adapter))));
        console.log(string.concat("TIMELOCK_ADDRESS=", vm.toString(address(timelock))));
        console.log(string.concat("VAULT_ADDRESS=", vm.toString(address(vault))));
        console.log(string.concat("USDC_ADDRESS=", vm.toString(address(usdc))));
        console.log(string.concat("TREASURY_ADDRESS=", vm.toString(deployer)));
        console.log(string.concat("GUARDIAN_ADDRESS=", vm.toString(deployer)));
        console.log("=== END DEPLOYED ADDRESSES ===");
    }
}
