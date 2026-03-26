// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title QUELLToken — Quell Governance Token
/// @notice Fixed 100M supply, minted entirely in constructor. No mint function post-deploy.
contract QUELLToken is ERC20 {
    uint256 public constant TOTAL_SUPPLY = 100_000_000e18;
    uint256 public constant TREASURY_ALLOCATION = 75_000_000e18;
    uint256 public constant FOUNDER_ALLOCATION = 25_000_000e18;

    /// @param treasury Receives 75M QUELL — unallocated protocol treasury
    /// @param vestingWallet Receives 25M QUELL — founder vesting (4yr vest, 1yr cliff)
    constructor(address treasury, address vestingWallet) ERC20("Quell Governance", "QUELL") {
        require(treasury != address(0), "QUELLToken: zero treasury");
        require(vestingWallet != address(0), "QUELLToken: zero vesting");

        _mint(treasury, TREASURY_ALLOCATION);
        _mint(vestingWallet, FOUNDER_ALLOCATION);
    }
}
