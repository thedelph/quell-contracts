# Quell Protocol

ERC-4626 USDC yield vault on Base, routing deposits to the Steakhouse USDC MetaMorpho vault for RWA-backed yield.

**Live:** [app.quell.fi](https://app.quell.fi) | **Website:** [quell.fi](https://quell.fi)

## Architecture

```
User deposits USDC
        |
        v
   RWAVault (ERC-4626)
   Issues rvUSDC shares
        |
        +---> Steakhouse MetaMorpho Vault ---> RWA yield (~3-4% APY)
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
| `MorphoAdapter.sol` | Stateless read-only interface to Steakhouse vault. | ~29 |
| `IMorphoAdapter.sol` | Adapter interface. | ~22 |
| `MockMorphoAdapter.sol` | Test-only. Time-based ~3% APY simulation. | ~35 |

## Mainnet Addresses (Base)

| Contract | Address |
|---|---|
| RWAVault (rvUSDC) | [`0xd85A4301706124699CbA8d0b59E5ED635360868b`](https://basescan.org/address/0xd85A4301706124699CbA8d0b59E5ED635360868b) |
| MorphoAdapter | [`0xc804F2F92Fd45d7A5bd8cf49DBC795EEd874328C`](https://basescan.org/address/0xc804F2F92Fd45d7A5bd8cf49DBC795EEd874328C) |
| QUELLToken | [`0xab1F67524ab5248E06ac1992478959E0A7503399`](https://basescan.org/address/0xab1F67524ab5248E06ac1992478959E0A7503399) |
| GovStaking | [`0x30A7e517799e409d5E68AAf0b34543b9c8BB1aC7`](https://basescan.org/address/0x30A7e517799e409d5E68AAf0b34543b9c8BB1aC7) |
| FeeDistributor | [`0xeb39D2C50Fb70235120a853CdDFeD5325bc3D3d7`](https://basescan.org/address/0xeb39D2C50Fb70235120a853CdDFeD5325bc3D3d7) |

**External dependencies:**
- USDC (Base): `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913`
- Steakhouse USDC MetaMorpho Vault: `0xbeeF010f9cb27031ad51e3333f9aF9C6B1228183`

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

See [`docs/KNOWN-ISSUES.md`](docs/KNOWN-ISSUES.md) for intentional design decisions, edge cases, and trust assumptions.

## Deployment

```bash
# Copy env template
cp .env.example .env
# Fill in your values, then:

# Testnet (Base Sepolia)
source .env
forge script script/DeployTestnet.s.sol --rpc-url $BASE_SEPOLIA_RPC --broadcast --verify

# Mainnet (Base)
source .env
forge script script/Deploy.s.sol --rpc-url $BASE_MAINNET_RPC --broadcast --verify
```

**Deployment order is critical:** VestingWallet -> QUELLToken -> GovStaking -> FeeDistributor -> Link staking<->distributor -> MorphoAdapter -> TimelockController -> RWAVault -> Set strategy description -> Transfer vault ownership to timelock

## License

MIT
