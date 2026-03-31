// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {GovStaking} from "./GovStaking.sol";

/// @title FeeDistributor — Permissionless 60/40 fee split
/// @notice Splits USDC fees: 60% to QUELL stakers, 40% to treasury.
///         If no stakers, staker share is held in contract for later distribution.
contract FeeDistributor {
    using SafeERC20 for IERC20;

    IERC20 public immutable USDC;
    GovStaking public immutable STAKING;
    address public immutable TREASURY;

    uint256 public constant STAKER_SHARE_BPS = 6000;
    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant MIN_DISTRIBUTE_AMOUNT = 1e6;

    /// @notice USDC held for stakers when no one is staked
    uint256 public heldForStakers;

    event Distributed(uint256 stakerAmount, uint256 treasuryAmount);
    event HeldForStakers(uint256 amount);

    error InsufficientFees(uint256 balance);

    /// @param _usdc Address of USDC token
    /// @param _staking Address of GovStaking contract
    /// @param _treasury Address of the treasury
    constructor(address _usdc, address _staking, address _treasury) {
        USDC = IERC20(_usdc);
        STAKING = GovStaking(_staking);
        TREASURY = _treasury;
    }

    /// @notice Distribute all USDC held by this contract. Permissionless.
    /// @dev Previously held staker funds are sent entirely to stakers, not re-split
    function distribute() external {
        uint256 balance = USDC.balanceOf(address(this));
        if (balance < MIN_DISTRIBUTE_AMOUNT) revert InsufficientFees(balance);

        uint256 newFees = balance - heldForStakers;
        uint256 newStakerAmount = (newFees * STAKER_SHARE_BPS) / BPS_DENOMINATOR;
        uint256 treasuryAmount = newFees - newStakerAmount;
        uint256 totalStakerAmount = newStakerAmount + heldForStakers;

        // Treasury gets 40% of new fees only
        if (treasuryAmount > 0) {
            USDC.safeTransfer(TREASURY, treasuryAmount);
        }

        if (STAKING.totalStaked() > 0) {
            // Transfer to staking and notify
            heldForStakers = 0;
            USDC.safeTransfer(address(STAKING), totalStakerAmount);
            STAKING.notifyRewardAmount(totalStakerAmount);
            emit Distributed(totalStakerAmount, treasuryAmount);
        } else {
            // Hold staker share in contract for later distribution
            heldForStakers = totalStakerAmount;
            emit HeldForStakers(totalStakerAmount);
        }
    }
}
