# Quell Protocol

ERC-4626 USDC yield vault on Arbitrum, routing deposits to Spark sUSDC for RWA-backed yield via the Sky Savings Rate.

**Live:** [app.quell.fi](https://app.quell.fi) | **Website:** [quell.fi](https://quell.fi)

## Architecture

```
User deposits USDC
        |
        v
   RWAVault (ERC-4626)
   Issues rvUSDC shares
        |
        +---> Spark sUSDC Vault ---> RWA yield (~4.5% APY)
        |     (Sky Savings Rate: US Treasury bills + institutional lending)
        |
        +---> Fee harvest (on each user operation)
                    |
                    v
              FeeDistributor
              /           \
           60%            40%
            |              |
       GovStaking       Treasury
    (QUELL stakers
     earn USDC)
```

**Governance:**
- `TimelockController` (48-hour delay) owns RWAVault admin functions
- `Guardian` (EOA) can immediately pause/activate emergency mode
- Emergency mode blocks deposits, preserves redemptions, no owner sweep

## Contracts

| Contract | Description | LoC |
|---|---|---|
| `RWAVault.sol` | ERC-4626 vault. USDC in, rvUSDC shares out. Decimal offset of 12. Dead shares for inflation protection. | ~340 |
| `GovStaking.sol` | Stake QUELL, earn USDC. 7-day unstake cooldown. 1e30 precision accumulator. | ~145 |
| `FeeDistributor.sol` | Permissionless 60/40 USDC split between stakers and treasury. | ~58 |
| `QUELLToken.sol` | Fixed 100M supply ERC-20. No mint post-deploy. 75M treasury / 25M vesting. | ~23 |
| `SparkAdapter.sol` | Stateless read-only interface to Spark sUSDC vault. | ~29 |
| `IYieldAdapter.sol` | Adapter interface (generic, supports strategy rotation). | ~22 |
| `MockYieldAdapter.sol` | Test-only. Time-based ~3% APY simulation. | ~35 |

## Mainnet Addresses (Arbitrum One)

| Contract | Address |
|---|---|
| RWAVault (rvUSDC) | [`0x25cf6D8BacCFbF66DC0567844182F063b8BD0051`](https://arbiscan.io/address/0x25cf6D8BacCFbF66DC0567844182F063b8BD0051) |
| SparkAdapter | [`0xfec4ff82F8fb2d33cb7db41fd25ca92EC1A9d0E5`](https://arbiscan.io/address/0xfec4ff82F8fb2d33cb7db41fd25ca92EC1A9d0E5) |
| QUELLToken | [`0xC7c338fDE3A335dfB5cE1124329540d7F0A8ceED`](https://arbiscan.io/address/0xC7c338fDE3A335dfB5cE1124329540d7F0A8ceED) |
| GovStaking | [`0x670d070A38Db80a53cdC55DB4d73C275aD7B1bF6`](https://arbiscan.io/address/0x670d070A38Db80a53cdC55DB4d73C275aD7B1bF6) |
| FeeDistributor | [`0xCe0044b508ED62B424Aa09E96ec39d5CDC3BdF43`](https://arbiscan.io/address/0xCe0044b508ED62B424Aa09E96ec39d5CDC3BdF43) |
| TimelockController | [`0x0f1760cf5BBdbB9A5Be1122a13179542d6DA395A`](https://arbiscan.io/address/0x0f1760cf5BBdbB9A5Be1122a13179542d6DA395A) |

**External dependencies:**
- USDC (Arbitrum): `0xaf88d065e77c8cC2239327C5EDb3A432268e5831`
- Spark sUSDC Vault: `0x940098b108fB7D0a7E374f6eDED7760787464609`

## Build & Test

Requires [Foundry](https://book.getfoundry.sh/getting-started/installation).

```bash
# Install dependencies
forge install

# Compile
forge build

# Run all tests (101 tests)
forge test -vvv

# Run a specific test
forge test --match-test testName -vvv

# Coverage
forge coverage

# Static analysis (requires Slither)
slither src/ --checklist
```

## Configuration

```toml
solc = "0.8.24"
optimizer = true
optimizer_runs = 200
remappings = ["@openzeppelin/=lib/openzeppelin-contracts/"]
```

## Security

- 101 Foundry tests (unit, fuzz, invariant, integration)
- Slither static analysis: clean
- 34-point security checklist: all passing
- 48-hour timelock on admin actions
- Emergency pause mechanism (no owner sweep)
- $100K TVL cap as pre-audit precaution
- Dead shares for ERC-4626 inflation attack protection
- Professional audit: Nethermind (scheduled)

See [`docs/KNOWN-ISSUES.md`](docs/KNOWN-ISSUES.md) for intentional design decisions, edge cases, and trust assumptions.

## Deployment

```bash
# Copy env template
cp .env.example .env
# Fill in your values, then:

# Arbitrum One
source .env
forge script script/Deploy.s.sol --rpc-url $ARBITRUM_RPC --broadcast --slow --skip-simulation --verify
```

**Deployment order is critical:** VestingWallet -> QUELLToken -> GovStaking -> FeeDistributor -> Link staking<->distributor -> SparkAdapter -> TimelockController -> RWAVault -> Set strategy description -> Transfer vault ownership to timelock

## License

MIT
