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
import {SparkAdapter} from "../src/adapters/SparkAdapter.sol";
import {IYieldAdapter} from "../src/adapters/IYieldAdapter.sol";

/// @title Deploy -- Arbitrum Mainnet deployment script
/// @notice Full 10-step deployment sequence per PRD
contract Deploy is Script {
    // --- Arbitrum Mainnet Addresses ---
    address constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;

    // --- Default Parameters ---
    uint256 constant MANAGEMENT_FEE_BPS = 20; // 0.2%
    uint256 constant PERFORMANCE_FEE_BPS = 1000; // 10%
    uint256 constant TVL_CAP = 100_000e6; // 100K USDC at launch

    function run() external {
        uint256 deployerPk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPk);
        address treasury = vm.envAddress("TREASURY_ADDRESS");
        address guardian = vm.envAddress("GUARDIAN_ADDRESS");

        // --- Env var validation ---
        require(treasury != address(0), "Treasury is zero address");
        require(guardian != address(0), "Guardian is zero address");
        require(treasury != deployer, "Treasury must differ from deployer");
        require(guardian != deployer, "Guardian must differ from deployer");
        require(treasury != guardian, "Treasury must differ from guardian");
        require(block.chainid == 42161, "Must deploy on Arbitrum One (chainId 42161)");

        console.log("Deployer:", deployer);
        console.log("Treasury:", treasury);
        console.log("Guardian:", guardian);
        console.log("Chain ID:", block.chainid);

        vm.startBroadcast(deployerPk);

        // --- Step 1: VestingWallet (4yr vest, 1yr cliff) ---
        VestingWallet vestingWallet = new VestingWallet(
            deployer, // beneficiary (founder)
            uint64(block.timestamp + 365 days), // start (after 1yr cliff)
            uint64(3 * 365 days) // duration (remaining 3yr)
        );
        console.log("VestingWallet:", address(vestingWallet));

        // --- Step 2: QUELLToken ---
        QUELLToken gov = new QUELLToken(treasury, address(vestingWallet));
        console.log("QUELLToken:", address(gov));

        // --- Step 3: GovStaking ---
        GovStaking staking = new GovStaking(address(gov), USDC, deployer);
        console.log("GovStaking:", address(staking));

        // --- Step 4: FeeDistributor ---
        FeeDistributor distributor = new FeeDistributor(USDC, address(staking), treasury);
        console.log("FeeDistributor:", address(distributor));

        // --- Step 5: Link staking <-> distributor ---
        staking.setFeeDistributor(address(distributor));

        // --- Step 6: SparkAdapter (uses constant YIELD_VAULT = Spark sUSDC on Arb) ---
        SparkAdapter adapter = new SparkAdapter();
        console.log("SparkAdapter:", address(adapter));

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
            IERC20(USDC),
            IYieldAdapter(address(adapter)),
            distributor,
            deployer, // owner (transferred to timelock in step 10)
            guardian,
            MANAGEMENT_FEE_BPS,
            PERFORMANCE_FEE_BPS,
            TVL_CAP
        );
        console.log("RWAVault:", address(vault));

        // --- Step 9: Set strategy description ---
        vault.setStrategyDescription("Spark sUSDC Vault - RWA-backed yield via Sky Savings Rate on Arbitrum");

        // --- Step 10: Transfer vault ownership to timelock (two-step) ---
        // Propose transfer -- timelock must call vault.acceptOwnership() to complete
        vault.transferOwnership(address(timelock));
        console.log("Vault ownership transfer proposed to timelock");
        console.log("NOTE: Timelock must call vault.acceptOwnership() to complete transfer");

        vm.stopBroadcast();

        console.log("");
        console.log("=== Arbitrum deployment complete ===");
        console.log("");

        // --- Structured Address Export ---
        // Copy-paste the block below into your .env.deploy file
        console.log("=== BEGIN DEPLOYED ADDRESSES ===");
        console.log(string.concat("VESTING_WALLET_ADDRESS=", vm.toString(address(vestingWallet))));
        console.log(string.concat("GOV_TOKEN_ADDRESS=", vm.toString(address(gov))));
        console.log(string.concat("STAKING_ADDRESS=", vm.toString(address(staking))));
        console.log(string.concat("DISTRIBUTOR_ADDRESS=", vm.toString(address(distributor))));
        console.log(string.concat("ADAPTER_ADDRESS=", vm.toString(address(adapter))));
        console.log(string.concat("TIMELOCK_ADDRESS=", vm.toString(address(timelock))));
        console.log(string.concat("VAULT_ADDRESS=", vm.toString(address(vault))));
        console.log(string.concat("USDC_ADDRESS=", vm.toString(USDC)));
        console.log(string.concat("TREASURY_ADDRESS=", vm.toString(treasury)));
        console.log(string.concat("GUARDIAN_ADDRESS=", vm.toString(guardian)));
        console.log("=== END DEPLOYED ADDRESSES ===");
        console.log("");
        console.log("To verify: save the above block to .env.deploy, then run:");
        console.log("  source .env.deploy && forge script script/VerifyDeployment.s.sol --rpc-url $ARBITRUM_RPC");
    }
}
