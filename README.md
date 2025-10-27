# Lobster Vault System

A production-ready Uniswap V3 liquidity management vault with fee collection, role-based access control, and emergency safeguards.

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
**Purpose**: Production-ready Uniswap V3 liquidity position management with fee collection

**Features:**
- **Complete Position Lifecycle Management**:
  - Mint new positions with customizable tick ranges
  - Burn liquidity from existing positions
  - Collect trading fees from positions
  - Automatic position tracking and cleanup
- **Dual Fee System**:
  - **TVL Fee**: Annualized management fee on total assets
  - **Performance Fee**: Fee on vault growth (only charged on positive returns)
- **Automated Fee Collection**: Fees auto-collect during deposits/withdrawals
- **TWAP-Based Valuation**: 7-day time-weighted average price for accurate asset valuation
- **Proportional Withdrawals**: Users withdraw based on their share of vault assets

**Security Features:**
- Timelocked fee updates (14-day delay)
- Maximum fee cap (30%)
- Deadline-based transaction expiry

### UniV3LpVaultFactory
**Purpose**: Factory contract for deterministic vault deployment

**Features:**
- **CREATE2 Deployment**: Predictable vault addresses using salt-based generation
- **Vault Registry**: Tracks all deployed vaults via `isVault` mapping
- **Address Prediction**: Compute vault address before deployment
- **Deployment Transparency**: Events emitted for all deployments

## Access Control Model

### Owner
- Full vault control
- Can deposit/withdraw assets
- Can update allocator address
- Can lock/unlock vault
- Can execute all position operations
- Update fee parameters (with timelock)

### Allocator
- Can mint new positions
- Can burn existing positions
- Can collect trading fees
- **Cannot** deposit/withdraw vault assets
- **Blocked** when vault is locked

### Fee Collector
- Collects accumulated fees
- Initiates fee parameter updates
- Enforces timelocked fee changes

## Development Setup

### Prerequisites

```bash
# Install Foundry
curl -L https://foundry.paradigm.xyz | bash
foundryup

# Verify installation
forge --version
cast --version
anvil --version
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

# Lint with slither (requires installation)
slither .

# Generate documentation
forge doc --build
```

## Deployment Guide

### Using the Factory

```solidity
// 1. Deploy the factory
UniV3LpVaultFactory factory = new UniV3LpVaultFactory();

// 2. Compute vault address (optional, for verification)
bytes32 salt = keccak256(abi.encodePacked("my-vault-v1"));
address predictedAddress = factory.computeVaultAddress(
    salt,
    owner,
    allocator,
    token0,
    token1,
    pool,
    feeCollector,
    tvlFee,     // e.g., 2e18 = 2% annual
    perfFee     // e.g., 20e18 = 20% of profits
);

// 3. Deploy vault
address vault = factory.deployVault(
    salt,
    owner,
    allocator,
    token0,
    token1,
    pool,
    feeCollector,
    tvlFee,
    perfFee
);

// 4. Verify deployment
require(factory.isVault(vault), "Deployment failed");
require(vault == predictedAddress, "Address mismatch");
```

## 📊 Fee Mechanics

### TVL Management Fee
- **Type**: Annualized percentage of total assets
- **Calculation**: Accrues linearly over time based on asset value
- **Collection**: Automatic during deposits/withdrawals or manual via `collectPendingFees()`
- **Max Rate**: 30% (configurable via `MAX_FEE`)

### Performance Fee
- **Type**: Percentage of vault growth
- **Calculation**: Only charged when vault TVL (in token0) increases
- **Benchmark**: Tracks `lastVaultTvl0` to measure growth
- **Collection**: Automatic when vault performs positively
- **Max Rate**: 30% (configurable via `MAX_FEE`)

**Example**:
```
Initial TVL: 100,000 USDC
After trading: 120,000 USDC
Growth: 20,000 USDC
Performance Fee (20%): 4,000 USDC
```

## Important Considerations

### TWAP Requirements
The vault uses a 7-day TWAP for accurate price calculations. For proper operation:
- **Pool must have existed for at least 7 days**
- **Pool must have swap activity** to populate TWAP observations
- New pools without sufficient history will revert on certain operations

### Position Management Best Practices
1. **Limit Active Positions**: Keep 1-3 positions for gas efficiency
2. **Monitor Liquidity Depth**: Remove positions with very low liquidity
3. **Regular Rebalancing**: Collect fees and rebalance positions periodically
4. **Slippage Protection**: Always set appropriate `amount0Min` and `amount1Min`

### Security Checklist
- [ ] Verify token0 < token1 (address ordering)
- [ ] Confirm pool matches token pair
- [ ] Set reasonable initial fees (≤30%)
- [ ] Use secure allocator address
- [ ] Test with small amounts first
- [ ] Monitor fee accrual rates
- [ ] Set up emergency procedures for lock mechanism

## Known Issues & TODOs

**From Contract Comments:**
```solidity
// TODO: In UniV3LpVault._withdrawFromPositions
// Must empty positions left with low liquidity after withdrawal
// and burn NFT to avoid accumulating dust positions
```

**Recommendation**: Implement a minimum liquidity threshold check after withdrawals that automatically closes positions falling below the threshold.

## License

This project is licensed under the GNU AGPL v3.0 License - see the [LICENSE](LICENSE) file for details.

## Disclaimer

This software is provided "as is" without warranty. Use at your own risk.

**IMPORTANT**:
- Always conduct thorough testing before mainnet deployment
- Have contracts professionally audited before using with real funds
- Understand the risks of impermanent loss in liquidity provision
- Monitor positions regularly for optimal performance
- Be aware of gas costs for position management operations

## Additional Resources

- [Uniswap V3 Documentation](https://docs.uniswap.org/protocol/concepts/V3-overview/concentrated-liquidity)
- [OpenZeppelin Contracts](https://docs.openzeppelin.com/contracts/)
- [Foundry Book](https://book.getfoundry.sh/)

---

**Need Help?** Open an issue or reach out to the development team.
