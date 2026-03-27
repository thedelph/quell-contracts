// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

interface IMockUSDCMintable {
    function mint(address to, uint256 amount) external;
}

/// @title MockYieldVault -- Minimal ERC-4626 with time-based appreciation
/// @notice Simulates ~3% APY for testing. Materializes yield by minting USDC so
///         totalAssets() always matches actual balance (no phantom appreciation).
contract MockYieldVault is ERC4626 {
    using Math for uint256;

    uint256 public constant APY_BPS = 300;
    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant SECONDS_PER_YEAR = 365 days;

    uint256 public lastYieldUpdate;

    constructor(IERC20 asset_) ERC4626(asset_) ERC20("Mock Yield USDC", "mockUSDC") {
        lastYieldUpdate = block.timestamp;
    }

    /// @notice 18-decimal shares (USDC 6 + offset 12 = 18)
    function _decimalsOffset() internal pure override returns (uint8) {
        return 12;
    }

    /// @notice Materialize accrued yield by minting USDC to this vault
    function _accrueYield() internal {
        uint256 elapsed = block.timestamp - lastYieldUpdate;
        if (elapsed == 0) return;

        uint256 balance = IERC20(asset()).balanceOf(address(this));
        if (balance == 0) {
            lastYieldUpdate = block.timestamp;
            return;
        }

        uint256 yield_ = (balance * APY_BPS * elapsed) / (BPS_DENOMINATOR * SECONDS_PER_YEAR);
        lastYieldUpdate = block.timestamp;

        if (yield_ > 0) {
            IMockUSDCMintable(asset()).mint(address(this), yield_);
        }
    }

    /// @notice totalAssets is just the actual balance (yield has been materialized)
    function totalAssets() public view override returns (uint256) {
        uint256 balance = IERC20(asset()).balanceOf(address(this));
        uint256 elapsed = block.timestamp - lastYieldUpdate;
        if (elapsed == 0 || balance == 0) return balance;
        uint256 pendingYield = (balance * APY_BPS * elapsed) / (BPS_DENOMINATOR * SECONDS_PER_YEAR);
        return balance + pendingYield;
    }

    /// @dev Accrue yield before any deposit/withdraw to keep accounting clean
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        _accrueYield();
        super._deposit(caller, receiver, assets, shares);
    }

    function _withdraw(address caller, address receiver, address owner_, uint256 assets, uint256 shares) internal override {
        _accrueYield();
        super._withdraw(caller, receiver, owner_, assets, shares);
    }
}
