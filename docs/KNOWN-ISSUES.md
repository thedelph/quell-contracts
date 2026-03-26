# Known Issues and Design Decisions

This document describes intentional design decisions, known edge cases, and trust assumptions in the Quell protocol. It is intended for auditors and security reviewers.

## Scope

**In scope:** RWAVault, GovStaking, FeeDistributor, QUELLToken, MorphoAdapter, IMorphoAdapter

**Out of scope:** MockMorphoAdapter (test-only, simulates ~3% APY via linear time-based pricing), all files in `test/mocks/`, OpenZeppelin v5 contracts (used unmodified via inheritance)

---

## 1. Intentional Design Decisions

### 1.1 Dead Shares (Inflation Attack Protection)

**File:** `RWAVault.sol:134-137`

On the first deposit (`totalSupply() == 0`), 1000 shares are minted to `address(0xdead)`. This is a standard mitigation against the ERC-4626 inflation attack where an attacker front-runs the first depositor by donating assets to manipulate the share price. The dead shares are permanent and cannot be recovered.

### 1.2 Decimal Offset of 12

**File:** `RWAVault.sol:102-104`

USDC has 6 decimals. The vault overrides `_decimalsOffset()` to return 12, giving rvUSDC shares 18 decimals of precision. This prevents precision loss in share price calculations when the underlying asset has low decimals.

`MorphoAdapter.sol:12` defines a matching `DECIMALS_OFFSET = 1e12` constant for share price conversions.

### 1.3 Emergency Mode Is Irreversible

**File:** `RWAVault.sol:290-294`

`setEmergencyMode()` sets both `emergencyMode = true` and `paused = true`. There is no function to set `emergencyMode = false`. This is intentional: once activated, the only recovery path is for users to redeem, then the owner (timelock) calls `setAdapter()` to point to a new strategy, then calls `setPaused(false)` to resume. The migration path is documented at line 299.

Emergency mode blocks all deposits but allows all redemptions. There is no owner sweep function.

### 1.4 Fee Harvest Try/Catch

**File:** `RWAVault.sol:244-253`

Fee harvesting redeems Steakhouse vault shares to collect fees. This is wrapped in a try/catch so that a revert from the Steakhouse vault (e.g., temporary liquidity issue) does not block user deposits or withdrawals. If the fee harvest fails, it is silently skipped and retried on the next operation after `MIN_HARVEST_INTERVAL` (1 hour).

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

QUELL has a fixed 100M supply minted entirely in the constructor. There is no `mint()` function. The contract intentionally does not inherit any minting capability beyond the initial constructor mint. 75M goes to treasury, 25M to a VestingWallet with 4-year linear vesting and 1-year cliff.

### 1.7 GovStaking 1e30 Precision Accumulator

**File:** `GovStaking.sol:22, 126, 136`

The reward distribution uses 30-decimal precision (`PRECISION = 1e30`) in the accumulator pattern:
```
rewardPerTokenStored += (amount * PRECISION) / totalStaked
earned = rewards[account] + (stakedBalance[account] * (rewardPerTokenStored - userRewardPerTokenPaid[account])) / PRECISION
```

This prevents precision loss when distributing small USDC amounts (6 decimals) across large QUELL staking positions (18 decimals).

### 1.8 Immutable FeeDistributor Configuration

**File:** `FeeDistributor.sol:14-16`

`USDC`, `STAKING`, and `TREASURY` are all `immutable`. The 60/40 split ratio is a constant (`STAKER_SHARE_BPS = 6000`). None of these values can be changed post-deployment. If any address needs to change, a new FeeDistributor must be deployed and the vault's `feeDistributor` reference updated via the timelock.

---

## 2. Known Edge Cases

### 2.1 Zero Stakers: Fees Held in FeeDistributor

**File:** `FeeDistributor.sol:47-55`, `GovStaking.sol:124`

If `totalStaked == 0` when `distribute()` is called:
- Treasury still receives their 40% immediately
- The staker share (60%) remains in the FeeDistributor contract
- `GovStaking.notifyRewardAmount()` reverts with `NoStakers()` if `totalStaked == 0`, so the transfer is skipped

The accumulated staker share is distributed on the next `distribute()` call after someone has staked. This requires a manual (or bot-driven) `distribute()` call — it is not automatic.

### 2.2 Withdrawal Dust Tolerance

**File:** `RWAVault.sol:188-201`

Two rounding tolerances exist on withdrawals:

1. **Steakhouse share overshoot (line 190-194):** If the calculated Steakhouse shares to redeem exceed the vault's actual balance, the difference must be less than 0.01% of the redemption amount. Otherwise reverts with `ExcessiveRounding()`.

2. **USDC received shortfall (line 200-201):** The actual USDC received from Steakhouse may be up to 2 wei less than the expected amount. This accounts for rounding in Steakhouse's ERC-4626 conversion. Larger discrepancies revert with `ExcessiveRounding()`.

### 2.3 Slippage Pre-Check Uses minShares - 1

**File:** `RWAVault.sol:264-265`

`depositWithSlippage()` pre-checks `previewDeposit(assets) < minShares - 1` (not `minShares`). This is because `_harvestFees()` is called inside `_deposit()`, which changes `totalAssets()` and `totalSupply()` between the preview and the actual mint. The `-1` accounts for this state change. The final check on line 267 (`shares < minShares`) enforces the exact minimum.

### 2.4 Double Fee Harvest on Redeem/Withdraw

**File:** `RWAVault.sol:155-177`

`redeem()` and `withdraw()` call `_harvestFees()` before delegating to `super.redeem()`/`super.withdraw()`, which eventually calls `_withdraw()` which also calls `_harvestFees()`. The second call is a no-op due to `MIN_HARVEST_INTERVAL` (line 212), but it is intentionally left in for safety in case `_withdraw()` is called directly.

---

## 3. Trust Assumptions

### 3.1 Steakhouse Vault

The protocol trusts that the Steakhouse USDC MetaMorpho vault (`0xbeeF010f9cb27031ad51e3333f9aF9C6B1228183`):
- Returns accurate share price conversions
- Honors withdrawal requests without excessive delay
- Does not have a malicious upgrade path that could trap funds

The fee harvest try/catch (Section 1.4) provides partial protection against temporary Steakhouse issues, but a permanently malicious or broken Steakhouse vault would require emergency mode and adapter migration.

### 3.2 Guardian (EOA)

The guardian can immediately pause deposits and activate emergency mode without timelock delay. This is intentional for rapid incident response. The guardian **cannot**: change fees, change the adapter, change the TVL cap, or extract funds.

### 3.3 Timelock Centralization

The TimelockController (48-hour delay) currently has a single proposer/executor (the deployer). This is a centralization risk. The intent is to migrate to DAO governance post-launch. All timelocked functions have a 48-hour delay, giving users time to exit if they disagree with a proposed change.

### 3.4 Max Approval to Steakhouse

**File:** `RWAVault.sol:97`

The constructor grants `type(uint256).max` approval of USDC to the Steakhouse vault. This is standard for vault-to-vault integrations but means the Steakhouse vault contract could theoretically transfer all USDC held by RWAVault. This risk is accepted because deposits are immediately forwarded to Steakhouse — USDC only transits through RWAVault briefly.

---

## 4. Known Limitations

| Limitation | Description |
|---|---|
| **Single chain** | Deployed on Base only. No cross-chain bridging or interoperability. |
| **Single strategy** | All deposits route to Steakhouse MetaMorpho. No multi-strategy diversification. |
| **No flash loan protection** | The vault does not implement flash loan guards. ERC-4626 share price manipulation via flash loans is mitigated by dead shares and the decimal offset. |
| **Fee harvest interval** | Fees are only harvested on user operations (deposit/withdraw/redeem), minimum once per hour. Accrued fees between operations are not lost but are delayed. |
| **No partial unstake cooldown** | A second `requestUnstake()` resets the cooldown timer for the entire pending amount. Users must wait a full 7 days from the last request. |
| **TVL cap is a soft limit** | Checked on `maxDeposit()` and `_deposit()`. Yield accrual can push `totalAssets()` above the cap. The cap only limits new deposits. |

---

## 5. Deployment Configuration (Mainnet)

| Parameter | Value |
|---|---|
| Management fee | 200 bps (2%) |
| Performance fee | 2000 bps (20%) |
| TVL cap | 100,000 USDC |
| Timelock delay | 48 hours |
| Unstake cooldown | 7 days |
| Min harvest interval | 1 hour |
| USDC | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` |
| Steakhouse vault | `0xbeeF010f9cb27031ad51e3333f9aF9C6B1228183` |

---

## 6. Mainnet Contract Addresses

| Contract | Address |
|---|---|
| RWAVault (rvUSDC) | `0xd85A4301706124699CbA8d0b59E5ED635360868b` |
| MorphoAdapter | `0xc804F2F92Fd45d7A5bd8cf49DBC795EEd874328C` |
| QUELLToken | `0xab1F67524ab5248E06ac1992478959E0A7503399` |
| GovStaking | `0x30A7e517799e409d5E68AAf0b34543b9c8BB1aC7` |
| FeeDistributor | `0xeb39D2C50Fb70235120a853CdDFeD5325bc3D3d7` |
