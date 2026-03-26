// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IMorphoAdapter} from "./adapters/IMorphoAdapter.sol";
import {FeeDistributor} from "./FeeDistributor.sol";

/// @title RWAVault — ERC-4626 vault routing USDC to Steakhouse MetaMorpho for RWA yield
/// @notice Custom pause logic: emergency mode blocks deposits but allows redemptions
contract RWAVault is ERC4626, Ownable2Step {
    using SafeERC20 for IERC20;

    // --- Constants ---
    uint256 public constant DEAD_SHARES = 1000;
    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant SECONDS_PER_YEAR = 365 days;
    uint256 public constant MIN_HARVEST_INTERVAL = 1 hours;
    uint256 public constant MAX_MANAGEMENT_FEE_BPS = 500; // 5%
    uint256 public constant MAX_PERFORMANCE_FEE_BPS = 3000; // 30%

    // --- State ---
    IMorphoAdapter public adapter;
    FeeDistributor public feeDistributor;
    address public guardian;

    uint256 public managementFeeBps;
    uint256 public performanceFeeBps;
    uint256 public tvlCap;
    uint256 public highWaterMark;
    uint256 public lastFeeHarvest;
    string public strategyDescription;

    bool public paused;
    bool public emergencyMode;

    // --- Events ---
    event FeesHarvested(uint256 managementFee, uint256 performanceFee);
    event AdapterUpdated(address indexed oldAdapter, address indexed newAdapter);
    event FeesUpdated(uint256 managementFeeBps, uint256 performanceFeeBps);
    event TvlCapUpdated(uint256 newCap);
    event GuardianUpdated(address indexed newGuardian);
    event PausedStateChanged(bool paused);
    event EmergencyModeActivated();
    event StrategyDescriptionUpdated(string description);

    // --- Custom Errors ---
    error Paused();
    error TvlCapExceeded();
    error FeeTooHigh();
    error NotGuardianOrOwner();
    error ExcessiveRounding();
    error SlippageExceeded();

    // --- Modifiers ---
    modifier onlyGuardianOrOwner() {
        if (msg.sender != guardian && msg.sender != owner()) revert NotGuardianOrOwner();
        _;
    }

    /// @param _usdc USDC token address
    /// @param _adapter Initial MorphoAdapter
    /// @param _feeDistributor FeeDistributor contract
    /// @param _owner Vault owner (later transferred to timelock)
    /// @param _guardian Guardian address for pause/emergency
    /// @param _managementFeeBps Management fee in basis points
    /// @param _performanceFeeBps Performance fee in basis points
    /// @param _tvlCap Maximum TVL in USDC (6 decimals)
    constructor(
        IERC20 _usdc,
        IMorphoAdapter _adapter,
        FeeDistributor _feeDistributor,
        address _owner,
        address _guardian,
        uint256 _managementFeeBps,
        uint256 _performanceFeeBps,
        uint256 _tvlCap
    ) ERC4626(_usdc) ERC20("RWA Vault USDC", "rvUSDC") Ownable(_owner) {
        if (_managementFeeBps > MAX_MANAGEMENT_FEE_BPS) revert FeeTooHigh();
        if (_performanceFeeBps > MAX_PERFORMANCE_FEE_BPS) revert FeeTooHigh();

        adapter = _adapter;
        feeDistributor = _feeDistributor;
        guardian = _guardian;
        managementFeeBps = _managementFeeBps;
        performanceFeeBps = _performanceFeeBps;
        tvlCap = _tvlCap;
        highWaterMark = 1e18;
        lastFeeHarvest = block.timestamp;

        // Approve Steakhouse vault for deposits
        IERC20(asset()).approve(_adapter.STEAKHOUSE_VAULT(), type(uint256).max);
    }

    // --- ERC4626 Overrides ---

    function _decimalsOffset() internal pure override returns (uint8) {
        return 12;
    }

    function totalAssets() public view override returns (uint256) {
        address steakhouseVault = adapter.STEAKHOUSE_VAULT();
        uint256 steakShares = IERC20(steakhouseVault).balanceOf(address(this));
        if (steakShares == 0) return 0;
        return adapter.sharesToUsdc(steakShares);
    }

    function maxDeposit(address) public view override returns (uint256) {
        if (paused || emergencyMode) return 0;
        uint256 currentAssets = totalAssets();
        if (currentAssets >= tvlCap) return 0;
        return tvlCap - currentAssets;
    }

    function maxMint(address) public view override returns (uint256) {
        if (paused || emergencyMode) return 0;
        return type(uint256).max;
    }

    function maxRedeem(address owner_) public view override returns (uint256) {
        if (paused && !emergencyMode) return 0;
        return balanceOf(owner_);
    }

    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        if (paused || emergencyMode) revert Paused();
        if (totalAssets() + assets > tvlCap) revert TvlCapExceeded();

        // Dead shares on first deposit (inflation attack protection)
        if (totalSupply() == 0) {
            _mint(address(0xdead), DEAD_SHARES);
        }

        _harvestFees();

        // Pull USDC from caller
        SafeERC20.safeTransferFrom(IERC20(asset()), caller, address(this), assets);

        // Deposit into Steakhouse vault (uses constructor's max approval)
        IERC4626(adapter.STEAKHOUSE_VAULT()).deposit(assets, address(this));

        // Mint vault shares to receiver
        _mint(receiver, shares);

        emit Deposit(caller, receiver, assets, shares);
    }

    /// @notice Override redeem to harvest fees before ERC-4626 preview calculation
    /// @dev Ensures previewRedeem uses post-harvest totalAssets, preventing Steakhouse share overshoot
    function redeem(uint256 shares, address receiver, address owner_) public override returns (uint256) {
        _harvestFees();
        return super.redeem(shares, receiver, owner_);
    }

    /// @notice Override withdraw to harvest fees before ERC-4626 preview calculation
    function withdraw(uint256 assets, address receiver, address owner_) public override returns (uint256) {
        _harvestFees();
        return super.withdraw(assets, receiver, owner_);
    }

    function _withdraw(
        address caller,
        address receiver,
        address owner_,
        uint256 assets,
        uint256 shares
    ) internal override {
        if (paused && !emergencyMode) revert Paused();

        // Fee harvest already done in redeem()/withdraw() overrides before previewRedeem
        // MIN_HARVEST_INTERVAL ensures this is a no-op, but kept for direct _withdraw calls
        _harvestFees();

        if (caller != owner_) {
            _spendAllowance(owner_, caller, shares);
        }

        _burn(owner_, shares);

        // Redeem from Steakhouse vault
        address steakhouseVault = adapter.STEAKHOUSE_VAULT();
        uint256 steakSharesToRedeem = adapter.usdcToShares(assets);
        // Cap to actual balance for dust rounding — overshoot must be < 0.01%
        uint256 steakBalance = IERC20(steakhouseVault).balanceOf(address(this));
        if (steakSharesToRedeem > steakBalance) {
            if (steakSharesToRedeem - steakBalance > steakSharesToRedeem / 10000) {
                revert ExcessiveRounding();
            }
            steakSharesToRedeem = steakBalance;
        }
        uint256 usdcReceived = IERC4626(steakhouseVault).redeem(
            steakSharesToRedeem, address(this), address(this)
        );

        // Dust tolerance: allow up to 2 wei less than expected
        if (usdcReceived + 2 < assets) revert ExcessiveRounding();

        // Send USDC to receiver
        IERC20(asset()).safeTransfer(receiver, usdcReceived);

        emit Withdraw(caller, receiver, owner_, usdcReceived, shares);
    }

    // --- Fee Harvesting ---

    function _harvestFees() internal {
        if (block.timestamp < lastFeeHarvest + MIN_HARVEST_INTERVAL) return;

        uint256 currentAssets = totalAssets();
        uint256 supply = totalSupply();
        if (currentAssets == 0 || supply == 0) return;

        uint256 timeDelta = block.timestamp - lastFeeHarvest;
        lastFeeHarvest = block.timestamp;

        uint256 totalFee = 0;

        // Management fee
        uint256 mgmtFee = (currentAssets * managementFeeBps * timeDelta) / (BPS_DENOMINATOR * SECONDS_PER_YEAR);
        totalFee += mgmtFee;

        // Performance fee (only above high water mark)
        uint256 currentPPS = (currentAssets * 1e30) / supply;
        if (currentPPS > highWaterMark) {
            uint256 yieldSinceHWM = currentPPS - highWaterMark;
            uint256 perfFee = (yieldSinceHWM * supply * performanceFeeBps) / (1e30 * BPS_DENOMINATOR);
            totalFee += perfFee;
            highWaterMark = currentPPS;
        }

        if (totalFee == 0) return;

        // Redeem steakShares worth totalFee and send to FeeDistributor
        // Wrapped in try/catch so a Steakhouse revert doesn't block user deposits/withdrawals
        address steakhouseVault = adapter.STEAKHOUSE_VAULT();
        uint256 steakSharesToRedeem = adapter.usdcToShares(totalFee);
        if (steakSharesToRedeem == 0) return;

        try IERC4626(steakhouseVault).redeem(
            steakSharesToRedeem, address(this), address(this)
        ) returns (uint256 feeUsdc) {
            if (feeUsdc > 0) {
                IERC20(asset()).safeTransfer(address(feeDistributor), feeUsdc);
                emit FeesHarvested(mgmtFee, totalFee - mgmtFee);
            }
        } catch {
            // Fee harvest failed — skip silently, don't block user operations
        }
    }

    // --- Slippage Wrappers ---

    /// @notice Deposit with slippage protection
    /// @param assets USDC amount to deposit
    /// @param receiver Address to receive rvUSDC shares
    /// @param minShares Minimum acceptable shares
    /// @return shares Actual shares minted
    function depositWithSlippage(uint256 assets, address receiver, uint256 minShares) external returns (uint256 shares) {
        // Pre-check: preview may change after _harvestFees, so use minShares - 1
        if (minShares > 0 && previewDeposit(assets) < minShares - 1) revert SlippageExceeded();
        shares = deposit(assets, receiver);
        if (shares < minShares) revert SlippageExceeded();
    }

    /// @notice Redeem with slippage protection
    /// @param shares Shares to redeem
    /// @param receiver Address to receive USDC
    /// @param owner_ Share owner
    /// @param minAssets Minimum acceptable USDC
    /// @return assets Actual USDC received
    function redeemWithSlippage(uint256 shares, address receiver, address owner_, uint256 minAssets) external returns (uint256 assets) {
        assets = redeem(shares, receiver, owner_);
        if (assets < minAssets) revert SlippageExceeded();
    }

    // --- Guardian Functions ---

    /// @notice Pause or unpause the vault
    function setPaused(bool _paused) external onlyGuardianOrOwner {
        paused = _paused;
        emit PausedStateChanged(_paused);
    }

    /// @notice Activate emergency mode (deposits blocked, redeems allowed, irreversible by guardian)
    function setEmergencyMode() external onlyGuardianOrOwner {
        emergencyMode = true;
        paused = true;
        emit EmergencyModeActivated();
    }

    // --- Owner Functions ---

    /// @notice Update the Morpho adapter (revokes old approval, sets new)
    /// @dev Migration requires users to withdraw first: emergency mode → users redeem → setAdapter → unpause
    function setAdapter(IMorphoAdapter _newAdapter) external onlyOwner {
        address oldVault = adapter.STEAKHOUSE_VAULT();
        IERC20(asset()).approve(oldVault, 0);

        address oldAdapter = address(adapter);
        adapter = _newAdapter;

        address newVault = _newAdapter.STEAKHOUSE_VAULT();
        IERC20(asset()).approve(newVault, type(uint256).max);

        emit AdapterUpdated(oldAdapter, address(_newAdapter));
    }

    /// @notice Update fee parameters
    function setFees(uint256 _managementFeeBps, uint256 _performanceFeeBps) external onlyOwner {
        if (_managementFeeBps > MAX_MANAGEMENT_FEE_BPS) revert FeeTooHigh();
        if (_performanceFeeBps > MAX_PERFORMANCE_FEE_BPS) revert FeeTooHigh();
        managementFeeBps = _managementFeeBps;
        performanceFeeBps = _performanceFeeBps;
        emit FeesUpdated(_managementFeeBps, _performanceFeeBps);
    }

    /// @notice Update TVL cap
    function setTvlCap(uint256 _tvlCap) external onlyOwner {
        tvlCap = _tvlCap;
        emit TvlCapUpdated(_tvlCap);
    }

    /// @notice Update guardian address
    function setGuardian(address _guardian) external onlyOwner {
        guardian = _guardian;
        emit GuardianUpdated(_guardian);
    }

    /// @notice Set strategy description (informational)
    function setStrategyDescription(string calldata _description) external onlyOwner {
        strategyDescription = _description;
        emit StrategyDescriptionUpdated(_description);
    }
}
