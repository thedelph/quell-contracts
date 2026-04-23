// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

import {GovStaking} from "../src/GovStaking.sol";
import {FeeDistributor} from "../src/FeeDistributor.sol";
import {RWAVault} from "../src/RWAVault.sol";
import {SparkAdapter} from "../src/adapters/SparkAdapter.sol";
import {IYieldAdapter} from "../src/adapters/IYieldAdapter.sol";

/// @title DeployRemaining -- Complete Arbitrum deployment (contracts 5-10)
/// @notice Picks up from partial deploy: VestingWallet, QUELLToken, GovStaking, FeeDistributor already live
contract DeployRemaining is Script {
    // Already deployed
    address constant STAKING = 0x670d070A38Db80a53cdC55DB4d73C275aD7B1bF6;
    address constant DISTRIBUTOR = 0xCe0044b508ED62B424Aa09E96ec39d5CDC3BdF43;
    address constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;

    uint256 constant MANAGEMENT_FEE_BPS = 20;
    uint256 constant PERFORMANCE_FEE_BPS = 1000;
    uint256 constant TVL_CAP = 100_000e6;

    function run() external {
        uint256 deployerPk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPk);
        address guardian = vm.envAddress("GUARDIAN_ADDRESS");

        require(block.chainid == 42161, "Must deploy on Arbitrum One (chainId 42161)");

        console.log("Deployer:", deployer);
        console.log("Chain ID:", block.chainid);

        vm.startBroadcast(deployerPk);

        // Step 5: Link staking <-> distributor
        GovStaking(STAKING).setFeeDistributor(DISTRIBUTOR);
        console.log("Linked staking <-> distributor");

        // Step 6: SparkAdapter
        SparkAdapter adapter = new SparkAdapter();
        console.log("SparkAdapter:", address(adapter));

        // Step 7: TimelockController (48hr delay)
        address[] memory proposers = new address[](1);
        proposers[0] = deployer;
        address[] memory executors = new address[](1);
        executors[0] = deployer;
        TimelockController timelock = new TimelockController(48 hours, proposers, executors, address(0));
        console.log("TimelockController:", address(timelock));

        // Step 8: RWAVault
        RWAVault vault = new RWAVault(
            IERC20(USDC),
            IYieldAdapter(address(adapter)),
            FeeDistributor(DISTRIBUTOR),
            deployer,
            guardian,
            MANAGEMENT_FEE_BPS,
            PERFORMANCE_FEE_BPS,
            TVL_CAP
        );
        console.log("RWAVault:", address(vault));

        // Step 9: Set strategy description
        vault.setStrategyDescription("Spark sUSDC Vault - RWA-backed yield via Sky Savings Rate on Arbitrum");

        // Step 10: Transfer vault ownership to timelock
        vault.transferOwnership(address(timelock));
        console.log("Vault ownership transfer proposed to timelock");

        vm.stopBroadcast();

        console.log("");
        console.log("=== Remaining deployment complete ===");
        console.log(string.concat("ADAPTER_ADDRESS=", vm.toString(address(adapter))));
        console.log(string.concat("TIMELOCK_ADDRESS=", vm.toString(address(timelock))));
        console.log(string.concat("VAULT_ADDRESS=", vm.toString(address(vault))));
    }
}
