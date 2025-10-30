# Lobster Vault System

A production-ready Uniswap V3 liquidity management vault with role-based access control, fee collection mechanisms, and emergency safeguards.

## Architecture Overview

The Lobster Vault System provides a streamlined architecture for managing Uniswap V3 liquidity positions with built-in fee mechanisms and governance controls:

```
┌───────────────────────────────────────────────────────────────────────┐
│                           Factory Layer                               │
├───────────────────────────────────────────────────────────────────────┤
│              UniV3LpVaultFactory (CREATE2 Deployment)                 │
└───────────────────────────────────────────────────────────────────────┘
                                    │
┌───────────────────────────────────────────────────────────────────────┐
│                         Vault Implementation                          │
├───────────────────────────────────────────────────────────────────────┤
│          UniV3LpVault (Uniswap V3 Position Management)                │
└───────────────────────────────────────────────────────────────────────┘
                                    │
┌───────────────────────────────────────────────────────────────────────┐
│                              Uniswap Pool                             │
└───────────────────────────────────────────────────────────────────────┘
```

## Core Components

### SingleVault (Base Contract)
**Purpose**: Provides foundational access control and emergency safety mechanisms

**Features:**
- **Two-Tier Access Control**:
  - **Owner**: Full vault control, can update allocator, lock vault, and execute all operations
  - **Allocator**: Limited operational control for position management (can be blocked by lock)
- **Emergency Lock**: Owner can freeze allocator operations without affecting owner access
- **Secure Ownership Transfer**: Uses OpenZeppelin's `Ownable2Step` for safe ownership changes
- **Reentrancy Protection**: Built-in guards against reentrancy attacks
- **ETH Rejection**: Prevents accidental ETH deposits

### UniV3LpVault
**Features:**
- **Complete Position Lifecycle Management**:
  - Mint new positions with customizable tick ranges
  - Burn liquidity from existing positions
  - Collect trading fees from positions
  - Automatic position tracking and cleanup
- **Dual Fee System**:
  - **TVL Fee**: Annualized management fee on total assets
  - **Performance Fee**: Fee on vault growth with delta-weighted price adjustment
- **Protocol Fee**: (optionnal) Percentage cut from all fees sent to the factory
- **Delta-Weighted Performance Calculation**: Adjusts for relative token price changes
- **Automated Fee Collection**: Fees auto-collect during deposits/withdrawals
- **TWAP-Based Valuation**: time-weighted average price for accurate asset valuation
- **Proportional Withdrawals**: Users withdraw based on their share of vault assets

**Security Features:**
- Timelocked fee updates (14-day delay)
- Maximum fee cap (30%)
- Deadline-based transaction expiry

### UniV3LpVaultFactory
**Purpose**: Factory contract for deterministic vault deployment

**Features:**
- **Vault Registry**: Tracks all deployed vaults via `isVault` mapping
- **Address Prediction**: Compute vault address before deployment with `computeVaultAddress()`
- **Deployment Transparency**: Events emitted for all deployments
- **Configurable Delta**: Allows customization of performance fee calculation weight
- **Protocol Fee Management**: Factory owner can collect and manage protocol fees
- **Fee Updates**: Factory owner can update protocol fee for future vault deployments

## Access Control Model

### Owner
- Full vault control
- Can deposit/withdraw assets
- Can update allocator address
- Can lock/unlock vault
- Can execute all position operations

### Allocator
- Can mint new positions
- Can burn existing positions
- Can collect trading fees
- **Cannot** deposit/withdraw vault assets
- **Blocked** when vault is locked

### Fee Collector
- Collects accumulated fees via `collectPendingFees()`
- Initiates fee parameter updates via `updateFees()`
- Enforces timelocked fee changes via `enforceFeeUpdate()`

### Factory/Protocol
- Receives protocol fee from all fee collections (TVL and performance fees)
- Factory owner can withdraw accumulated protocol fees via `withdrawToken()` or `withdrawETH()`
- Factory owner can update protocol fee for future vault deployments
- Cannot modify fees for already deployed vaults

## Development Setup

### Prerequisites

```bash
# Install Foundry
curl -L https://foundry.paradigm.xyz | bash
foundryup

# Verify installation
forge --version
```

### Building

```bash
# Install dependencies
forge install

# Build contracts
forge build
```

### Testing

```bash
# Run all tests
forge test

# Run tests with verbosity
forge test -vvv

# Run specific test file
forge test --match-path test/UniV3LpVault.t.sol

# Get coverage report
forge coverage --report lcov --report-file coverage.lcov --ir-minimum
genhtml coverage.lcov -o coverage-html --branch-coverage --function-coverage
open coverage-html/index.html
```

### Code Quality

```bash
# Format code
forge fmt

# Check formatting without changes
forge fmt --check

# Generate documentation
forge doc --build
```

## Fee Mechanics

### TVL Management Fee
- **Type**: Annualized percentage of total assets
- **Calculation**: Accrues linearly over time based on asset value
- **Formula**: `fee = tvlFee * timeElapsed / 365 days`
- **Collection**: Automatic during deposits/withdrawals or manual via `collectPendingFees()`
- **Max Rate**: 30% (configurable via `MAX_FEE`)

### Performance Fee
- **Type**: Percentage of vault growth (adjusted for price changes)
- **Calculation**: Only charged when vault TVL increases above a delta-weighted baseline
- **Delta Parameter**: Controls sensitivity to relative token price changes (0 to 1e18)
- **Collection**: Automatic when vault performs positively
- **Max Rate**: 30% (configurable via `MAX_FEE`)

### Protocol Fee
- **Type**: Percentage cut from both TVL and performance fees
- **Collection**: Automatically deducted when fees are collected and sent to the factory
- **Configuration**: Set at the factory level during deployment
- **Recipient**: The factory contract (which can withdraw to the factory owner)
- **Per-Vault Setting**: Each vault receives the protocol fee value at deployment time
- **Updates**: Factory owner can update the protocol fee, but only newly deployed vaults will use the new rate
- **Optional**: Can be set to 0 if no protocol fee is desired
- **Max Rate**: 100% (scaled by `MAX_SCALED_PERCENTAGE`, e.g., 10e18 = 10%)

**Example**: If the protocol fee is 10% and the vault collects 100 USDC in TVL fees:
- 90 USDC goes to the fee collector
- 10 USDC goes to the factory (as protocol fee)

**Note**: The protocol fee is taken from the gross fees before distribution to the fee collector. This ensures the protocol receives its share of all fee revenue generated by the vault.

#### Understanding Delta

The `delta` parameter controls how the performance fee accounts for relative token value changes:

**Formula**: `baseTvl0 = lastVaultTvl0 × (delta × (lastQuote / currentQuote)² + (1 - delta))`

**Delta Values**:
- **delta = 0**: Performance based entirely on token0 accumulation relative to token1
  - Best for strategies focused on accumulating the base token
  - Example: ETH/USDC vault aiming to maximize ETH holdings

- **delta = 0.5e18** (50%): Equal weighting of both tokens
  - Balanced approach for neutral strategies
  - Fair for portfolios maintaining roughly equal token ratios

- **delta = 1e18** (100%): Performance based entirely on token1 accumulation relative to token0
  - Best for strategies focused on accumulating the quote token
  - Example: Stablecoin farming where you want to measure USD value growth

**Example Scenarios**:

**Scenario 1: USDC/WETH Vault (δ = 0)**

|  | USDC | WETH | WETH Price | WETH Equivalent |
|-------|------|------|------------|-----------------|
| Initial | 20,000 | 10 | $2,000 | 20 WETH |
| Later | 18,000 | 12 | $2,200 | 20.18 WETH |

**Performance**: +0.18 WETH outperformance

**Focus**: Maximizing WETH accumulation

---

**Scenario 2: USDC/WETH Vault (δ = 0.5e18)**

|  | USDC | WETH | WETH Price | WETH Equivalent |
|-------|------|------|------------|-----------------|
| Initial | 20,000 | 10 | $2,000 | 20 WETH |
| Later | 30,000 | 8 | $2,200 | 21.63 WETH |

**Performance**: +0.63 WETH (as normal hold value 50/50)

**Result**: Should leave a +5% performance on a +10% performance on underlying

**Focus**: Balanced 50/50 portfolio approach

---

**Scenario 3: USDC/WETH Vault (δ = 1e18)**

|  | USDC | WETH | WETH Price | WETH Equivalent |
|-------|------|------|------------|-----------------|
| Initial | 20,000 | 10 | $2,000 | 20 WETH |
| Later | 25,000 | 11 | $2,200 | 22.36 WETH |

**Performance**: +0.36 WETH (as counted on USDC)
**Focus**: Token value counted on WETH (outperformance counted on USDC)


### Fee Update Process

The vault implements a two-step timelock mechanism for fee changes:

1. **Initiate Update**: Fee collector calls `updateFees(newTvlFee, newPerformanceFee)`
   - Starts 14-day timelock period
   - Emits `FeeUpdateInitialized` event

2. **Enforce Update**: After 14 days, call `enforceFeeUpdate()`
   - Collects all pending fees at old rates
   - Activates new fee parameters
   - Emits `FeeUpdateEnforced` event

## Important Considerations

### TWAP Requirements

The vault uses a TWAP for accurate price calculations. For proper operation:
- **Pool must have swap activity** to populate TWAP observations
- New pools without sufficient history may revert on operations requiring TWAP → solution: add some observations or do some swaps


### Position Management Best Practices

1. **Limit Active Positions**: Keep 1-3 simultaneous positions for gas efficiency
2. **Monitor Liquidity Depth**: Remove positions with very low liquidity
3. **Regular Rebalancing**: Collect fees and rebalance positions periodically
4. **Slippage Protection**: Always set appropriate `amount0Min` and `amount1Min`
5. **Gas Optimization**: Batch operations when possible to reduce transaction costs

### Choosing the Right Delta

Consider your vault's investment strategy when setting delta:

- **Long Token0 Strategy**: Set delta closer to 0
- **Long Token1 Strategy**: Set delta closer to 1e18
- **Market Neutral Strategy**: Set delta around 0.5e18
- **Stablecoin Pairs**: Set delta to 0.5e18 for balanced measurement

## Deployment Guide

### Factory Deployment

```solidity
// Deploy the factory
UniV3LpVaultFactory factory = new UniV3LpVaultFactory(implementation, owner, protocolFee);
```

## Key Functions

### Owner Functions
- `deposit(uint256 assets0, uint256 assets1)` - Deposit tokens into vault
- `withdraw(uint256 scaledPercentage, address recipient)` - Withdraw percentage of holdings

### Allocator Functions
- `mint(MinimalMintParams params)` - Create new liquidity position
- `burn(int24 tickLower, int24 tickUpper, uint128 amount)` - Remove liquidity
- `collect(int24 tickLower, int24 tickUpper, uint128 amount0Max, uint128 amount1Max)` - Collect fees

### Fee Collector Functions
- `collectPendingFees()` - Manually trigger fee collection
- `updateFees(uint80 newTvlFee, uint80 newPerformanceFee)` - Initiate fee update
- `enforceFeeUpdate()` - Apply pending fee update after timelock

### Factory Owner Functions
- `withdrawToken(address token, address to, uint256 amount)` - Withdraw protocol fees (ERC20)
- `withdrawETH(address to, uint256 amount)` - Withdraw protocol fees (ETH)

### View Functions
- `rawAssetsValue()` - Total vault assets before fees
- `netAssetsValue()` - Vault assets after deducting pending fees
- `pendingTvlFee()` - Calculate pending management fees
- `pendingPerformanceFee()` - Calculate pending performance fees
- `totalLpValue()` - Value locked in LP positions
- `getPosition(uint256 index)` - Get position details
- `positionsLength()` - Number of active positions

## License

This project is licensed under the GPL-3.0-or-later License - see the [LICENSE](./LICENSE) file for details.

## Disclaimer

This software is provided "as is" without warranty. Use at your own risk.

**IMPORTANT**:
- Always conduct thorough testing before mainnet deployment
- Have contracts professionally audited before using with real funds
- Understand the risks of impermanent loss in liquidity provision
- Monitor positions regularly for optimal performance
- Be aware of gas costs for position management operations
- Carefully choose delta parameter based on your strategy
- Understand how fee calculations work before deploying
- Protocol fees are automatically deducted from all fee collections

## Additional Resources

- [Uniswap V3 Documentation](https://docs.uniswap.org/protocol/concepts/V3-overview/concentrated-liquidity)
- [OpenZeppelin Contracts](https://docs.openzeppelin.com/contracts/)
- [Foundry Book](https://book.getfoundry.sh/)

---

**Need Help?** Open an issue or reach out to the development team.
