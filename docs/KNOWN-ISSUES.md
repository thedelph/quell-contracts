# Known Issues and Design Decisions

This document describes intentional design decisions, known edge cases, and trust assumptions in the Quell protocol. It is intended for auditors and security reviewers.

## Scope

**In scope:** RWAVault, GovStaking, FeeDistributor, QUELLToken, SparkAdapter, IYieldAdapter

**Out of scope:** MockYieldAdapter (test-only, simulates ~3% APY via linear time-based pricing), all files in `test/mocks/`, OpenZeppelin v5 contracts (used unmodified via inheritance)


## 1. Intentional Design Decisions

### 1.1 Dead Shares (Inflation Attack Protection)

**File:** `RWAVault.sol:134-137`

On the first deposit (`totalSupply() == 0`), 1000 shares are minted to `address(0xdead)`. This is a standard mitigation against the ERC-4626 inflation attack where an attacker front-runs the first depositor by donating assets to manipulate the share price. The dead shares are permanent and cannot be recovered.

### 1.2 Decimal Offset of 12

**File:** `RWAVault.sol:102-104`

USDC has 6 decimals. The vault overrides `_decimalsOffset()` to return 12, giving rvUSDC shares 18 decimals of precision. This prevents precision loss in share price calculations when the underlying asset has low decimals.

`SparkAdapter.sol:12` defines a matching `DECIMALS_OFFSET = 1e12` constant for share price conversions.

### 1.3 Emergency Mode Is Irreversible

**File:** `RWAVault.sol:290-294`

`setEmergencyMode()` sets both `emergencyMode = true` and `paused = true`. There is no function to set `emergencyMode = false`. This is intentional: once activated, the only recovery path is for users to redeem, then the owner (timelock) calls `setAdapter()` to point to a new strategy, then calls `setPaused(false)` to resume. The migration path is documented at line 299.

Emergency mode blocks all deposits but allows all redemptions. There is no owner sweep function.

### 1.4 Fee Harvest Try/Catch

**File:** `RWAVault.sol:256-268`

Fee harvesting redeems yield vault shares to collect fees. This is wrapped in a try/catch so that a revert from the underlying yield vault (e.g., temporary liquidity issue) does not block user deposits or withdrawals. If the fee harvest fails, it is silently skipped and retried on the next operation after `MIN_HARVEST_INTERVAL` (1 hour). The `highWaterMark` and `lastFeeHarvest` state updates are only committed inside the try block's success path, ensuring no permanent fee loss on failed redemptions.

### 1.5 Performance Fee Single-Division Formula

**File:** `RWAVault.sol:228-233`

The performance fee uses a single-division formula with 1e30 precision:
```
currentPPS = (currentAssets * 1e30) / supply
perfFee = (yieldSinceHWM * supply * performanceFeeBps) / (1e30 * BPS_DENOMINATOR)
```

This avoids splitting into multiple divisions which would introduce truncation risk. The high water mark (`highWaterMark`) is initialized to `1e18` and only updated upward when performance fees are charged.

### 1.6 Fixed Token Supply

**File:** `QUELLToken.sol:9-21`

QUELL has a fixed 100M supply minted entirely in the constructor. There is no `mint()` function. The contract intentionally does not inherit any minting capability beyond the initial constructor