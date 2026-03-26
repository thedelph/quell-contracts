// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/// @title GovStaking — Stake QUELL tokens, earn real USDC yield
/// @notice 7-day unstake cooldown. 30-decimal precision reward accumulator.
contract GovStaking is Ownable2Step {
    using SafeERC20 for IERC20;

    IERC20 public immutable GOV_TOKEN;
    IERC20 public immutable REWARD_TOKEN;

    address public feeDistributor;
    uint256 public totalStaked;
    uint256 public rewardPerTokenStored;

    uint256 public constant COOLDOWN_PERIOD = 7 days;
    uint256 public constant PRECISION = 1e30;

    mapping(address => uint256) public stakedBalance;
    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public rewards;
    mapping(address => uint256) public unstakeRequestTime;
    mapping(address => uint256) public pendingUnstake;

    event Staked(address indexed user, uint256 amount);
    event UnstakeRequested(address indexed user, uint256 amount);
    event UnstakeCompleted(address indexed user, uint256 amount);
    event RewardsClaimed(address indexed user, uint256 amount);
    event RewardNotified(uint256 amount);
    event FeeDistributorSet(address indexed distributor);

    error ZeroAmount();
    error NoStakers();
    error CooldownNotElapsed();
    error NoPendingUnstake();
    error InsufficientStake();
    error OnlyFeeDistributor();

    /// @param _govToken Address of the QUELL token
    /// @param _rewardToken Address of the reward token (USDC)
    /// @param initialOwner Initial owner of the contract
    constructor(address _govToken, address _rewardToken, address initialOwner) Ownable(initialOwner) {
        GOV_TOKEN = IERC20(_govToken);
        REWARD_TOKEN = IERC20(_rewardToken);
    }

    /// @notice Set the fee distributor address
    /// @param _feeDistributor Address of the FeeDistributor contract
    function setFeeDistributor(address _feeDistributor) external onlyOwner {
        feeDistributor = _feeDistributor;
        emit FeeDistributorSet(_feeDistributor);
    }

    /// @notice Stake QUELL tokens to earn USDC rewards
    /// @param amount Amount of QUELL to stake
    function stake(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();

        _updateReward(msg.sender);

        stakedBalance[msg.sender] += amount;
        totalStaked += amount;

        GOV_TOKEN.safeTransferFrom(msg.sender, address(this), amount);

        emit Staked(msg.sender, amount);
    }

    /// @notice Request to unstake QUELL tokens (starts 7-day cooldown)
    /// @param amount Amount of QUELL to unstake
    function requestUnstake(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        if (stakedBalance[msg.sender] < amount) revert InsufficientStake();

        _updateReward(msg.sender);

        stakedBalance[msg.sender] -= amount;
        totalStaked -= amount;
        pendingUnstake[msg.sender] += amount;
        unstakeRequestTime[msg.sender] = block.timestamp;

        emit UnstakeRequested(msg.sender, amount);
    }

    /// @notice Complete unstake after cooldown period
    function completeUnstake() external {
        uint256 amount = pendingUnstake[msg.sender];
        if (amount == 0) revert NoPendingUnstake();
        if (block.timestamp < unstakeRequestTime[msg.sender] + COOLDOWN_PERIOD) {
            revert CooldownNotElapsed();
        }

        pendingUnstake[msg.sender] = 0;
        unstakeRequestTime[msg.sender] = 0;

        GOV_TOKEN.safeTransfer(msg.sender, amount);

        emit UnstakeCompleted(msg.sender, amount);
    }

    /// @notice Claim accumulated USDC rewards
    function claimRewards() external {
        _updateReward(msg.sender);

        uint256 reward = rewards[msg.sender];
        if (reward == 0) revert ZeroAmount();

        rewards[msg.sender] = 0;

        REWARD_TOKEN.safeTransfer(msg.sender, reward);

        emit RewardsClaimed(msg.sender, reward);
    }

    /// @notice Called by FeeDistributor to notify of new reward amount
    /// @param amount Amount of USDC rewards to distribute
    function notifyRewardAmount(uint256 amount) external {
        if (msg.sender != feeDistributor) revert OnlyFeeDistributor();
        if (totalStaked == 0) revert NoStakers();

        rewardPerTokenStored += (amount * PRECISION) / totalStaked;

        emit RewardNotified(amount);
    }

    /// @notice Calculate earned rewards for an account
    /// @param account Address to check
    /// @return Earned USDC rewards (6-decimal)
    function earned(address account) public view returns (uint256) {
        return rewards[account]
            + (stakedBalance[account] * (rewardPerTokenStored - userRewardPerTokenPaid[account])) / PRECISION;
    }

    /// @dev Update reward state for an account before any state change
    function _updateReward(address account) internal {
        rewards[account] = earned(account);
        userRewardPerTokenPaid[account] = rewardPerTokenStored;
    }
}
