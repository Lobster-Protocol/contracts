todo: 
- rm the vault fees
- add entry/exit and aum fees in vault flow
- test rebase vault flow
- test uniswap vault flow
- add max and preview functions in vault flow (use bit shifting to know if we have to use default function or vault flow function)





# Lobster Vault

A modular ERC4626 vault system with customizable fee structures, operation validation, and asset management.

## Overview

Lobster Vault is a Solidity-based implementation of the ERC4626 tokenized vault standard with a custom fee structures including entry, exit, and management fees and modular extensions that enable:

- Operation validation with hooks for pre and post-execution
- Customizable asset valuation (NAV) logic
- Modular deposit and withdrawal flows
- Secure operation execution via validation modules

The system is designed to be highly flexible while maintaining security and composability with existing DeFi protocols.

## Key Components

### Core Contracts

- **ERC4626Fees**: Extension to ERC4626 that adds comprehensive fee mechanisms with timelock changes
- **Modular**: Base contract that provides module-related events, errors, and state variables
- **LobsterVault**: The main vault contract that inherits from ERC4626Fees and implements modular functionality

### Modules

- **IOpValidatorModule**: Responsible for approving or denying vault operations
- **IHook**: Executes custom logic before and after vault operations
- **INav**: Provides custom total asset calculation logic
- **IVaultFlowModule**: Customizes deposit and withdrawal behavior

### Helpers

- **ParameterValidator**: Validates operation parameters for added security
- **UniswapFeeCollectorHook**: Example hook for collecting fees from Uniswap positions

## Security Features

- Timelocked fee changes with mandatory delay period (2 weeks)
- Operation validation with per-function parameter checking
- Pre and post-operation hooks for additional validation and actions
- Secure execution context tracking to prevent unauthorized hook calls
- Comprehensive permission system for operation targets

## Fee System

The vault implements a comprehensive fee system including:

- **Entry Fees**: Charged when assets are deposited
- **Exit Fees**: Charged when assets are withdrawn
- **Management Fees**: Charged continuously based on assets under management

All fee changes require a timelock period (default: 2 weeks) before they can be enforced, giving users time to exit the vault if they disagree with new fee rates.

### Installation

```bash
git clone https://github.com/Lobster-Protocol/contracts.git
```
```
cd contracts && forge install
```
```
# Build the contracts
forge build

# Run tests
forge test
```

> Note: Ensure you have [Foundry](https://book.getfoundry.sh/) installed.

## License

GNU AGPL v3.0

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.