# Lobster Vault System

A modular, secure vault system built on ERC4626 with multi-signature operation validation and specialized Uniswap V3 integration capabilities.

## 🏗️ Architecture Overview

The Lobster Vault System consists of three main components working together to provide secure, flexible vault operations:

```
┌───────────────────────────────────────────────────────────────────────┐
│                              Vault Layer                              │
├──────────────────────────┬─────────────────────┬──────────────────────┤
│  ERC4626WithOpValidator  │    LobsterVault     │  UniV3LobsterVault   │
│  (Basic Operations)      │  (Dual-Token Base)  │  (Uniswap V3)        │
└──────────────────────────┴─────────────────────┴──────────────────────┘
                                    │
┌───────────────────────────────────────────────────────────────────────┐
│                           Modular Base Layer                          │
├───────────────────────────────────────────────────────────────────────┤
│                     Modular (Operation Execution)                     │
└───────────────────────────────────────────────────────────────────────┘
                                    │
┌───────────────────────────────────────────────────────────────────────┐
│                           Validation Layer                            │
├───────────────────────────────────────────────────────────────────────┤
│             MuSigOpValidator (Multi-Signature Validation)             │
└───────────────────────────────────────────────────────────────────────┘
```

**Key Design Principles:**
- **Security First**: All external operations require multi-signature approval
- **Modularity**: Components can be mixed and matched for different use cases
- **Immutable Whitelists**: Operation restrictions cannot be changed after deployment
- **Flexible Governance**: Signer configuration can evolve via multi-sig approval

## 📦 Vault Types

### ERC4626WithOpValidator
**Purpose**: Standard ERC4626 vault with secure operation execution capabilities

**Features:**
- Standard deposit/withdraw/mint/redeem functionality
- Multi-signature validated external operations
- Custom ERC20 share token naming
- Clean separation between vault operations and extended functionality

**⚠️ Customization Note**: This is a **base implementation** that should be inherited and customized for specific protocols. You'll need to override `deposit()`, `withdraw()`, `totalAssets()`, and other ERC4626 functions to implement your specific integration logic (e.g., lending protocols, yield strategies, etc.).

### LobsterVault
**Purpose**: Dual-token vault foundation supporting two separate assets

**Features:**
- Manages two distinct ERC20 tokens simultaneously
- Packed uint256 representation for gas efficiency: `(token0Amount << 128) | token1Amount`
- Proportional share calculations using limiting token approach
- Built-in operation validation system

**⚠️ Customization Note**: This is a **foundational contract** designed to be extended. To integrate with specific protocols, you must inherit from this contract and implement custom logic in `deposit()`, `withdraw()`, `totalAssets()`, and related functions. The base implementation only handles direct token transfers.

### UniV3LobsterVault
**Purpose**: Production-ready Uniswap V3 position management vault

**Features:**
- Complete Uniswap V3 NFT position lifecycle management
- Automated liquidity provision and removal
- Fee collection with configurable protocol fee cuts
- Proportional withdrawal based on vault share ownership
- Gas-optimized batch position processing

**Integration Ready**: This vault is **production-ready** and doesn't require customization for Uniswap V3 use cases.

## 🔐 MuSigOpValidator

**Purpose**: Multi-signature operation validator providing secure, quorum-based approval for vault operations.

### Core Features

**🛡️ Security Model**
- **Immutable Whitelist**: Operation restrictions set at deployment cannot be changed
- **Weight-Based Voting**: Flexible signer weights
- **Replay Protection**: Sequential nonce system prevents transaction replay attacks
- **Cross-Chain Safety**: Chain ID inclusion prevents cross-chain replay attacks

**⚙️ Operation Control**
- **Granular Permissions**: Separate controls for ETH transfers and function calls
- **Parameter Validation**: Custom validation logic for function parameters
- **Batch Operations**: Atomic execution of multiple operations
- **Gas Optimization**: Efficient signature verification and validation

**👥 Governance Flexibility**
- **Mutable Signers**: Add, remove, or update signer weights via multi-sig
- **Dynamic Quorum**: Adjust approval thresholds as organization evolves

### Signature Requirements

- **Format**: ECDSA signatures _(BLS signatures will be implemented later)_
- **Ordering**: Signatures can be in any order
- **Uniqueness**: Each signer can only sign once per operation
- **Threshold**: Total signature weight must meet or exceed quorum

## 🚀 Development Setup

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
forge test --match-path test/VaultTest.sol
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

## 🔧 Integration Guidelines

### For Protocol Integrators

1. **Inherit Base Contracts**: Extend `ERC4626WithOpValidator` or `LobsterVault`
2. **Override Key Functions**: Implement your protocol-specific logic in:
   - `deposit()` - Custom deposit handling
   - `withdraw()` - Custom withdrawal logic  
   - `totalAssets()` - Asset valuation for your protocol
   - `_convertToShares()` / `_convertToAssets()` - Share conversion logic
   - All the `preview*`and `max*` functions if necessary

3. **Configure Validator**: Set up operation whitelist for your protocol's contracts
4. **Test Thoroughly**: Use fuzz testing for edge cases

### Security Considerations

- **Whitelist Carefully**: Only whitelist necessary operations and targets
- **Validate Parameters**: Implement custom parameter validators for complex operations
- **Monitor Operations**: Set up monitoring for unusual operation patterns
- **Regular Audits**: Have custom implementations audited before mainnet deployment

## 📄 License

This project is licensed under the GNU AGPL v3.0 License - see the [LICENSE](LICENSE) file for details.

## ⚠️ Disclaimer

This software is provided "as is" without warranty. Use at your own risk. Always conduct thorough testing and auditing before deploying to mainnet with real funds.√