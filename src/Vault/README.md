# Lobster Protocol - Modular ERC4626 Vault

This directory contains the core implementation of Lobster's modular vault system, based on the ERC4626 tokenized vault standard with extensions for customizable fee structures and operational flexibility.

## Architecture Overview

The Lobster vault implementation follows a modular design pattern, allowing different components to be interchanged without modifying the core vault logic. The system consists of the following key components:

### Core Components

1. **LobsterVault** - Main implementation of the ERC4626 standard with modular extensions
2. **ERC4626Fees** - Fee management with support for entry, exit, and management fees
3. **IERC4626FeesEvents** - Interface defining events and errors related to fee operations

### Modules

The vault supports pluggable modules for customizing behavior:

- **OpValidator Module** - Validates and approves operations executed by the vault
- **Hook Module** - Executes logic before and after vault operations
- **NAV Module** - Provides custom asset valuation logic
- **VaultFlow Module** - Handles custom deposit and withdrawal logic

## Fee Structure

### Management Fees
- Annual percentage fee charged on assets under management
- Accrues continuously and is collected during deposits, withdrawals, or manual collection
- Pro-rated based on time elapsed since last collection
- Configurable with a timelock mechanism for updates
- Set to 0% by default

### Entry Fees (Deposit Fees)
- Fixed percentage fee charged when assets are deposited
- Deducted from the deposit amount before shares are minted
- Configurable with a timelock mechanism for updates
- Set to 0% by default

### Exit Fees (Withdrawal Fees)
- Fixed percentage fee charged when shares are redeemed or assets withdrawn
- Additional shares are burned to cover the fee amount
- Configurable with a timelock mechanism for updates
- Set to 0% by default

### Insurance Fees *(not implemented yet)*
A portion of the collected fees will be allocated to insure the vault against hacks or other exceptional circumstances. The insurance will be provided by a third party, with the exact allocation to be determined.

### Performance Fees *(not implemented yet)*
- Fixed percentage that can be updated by Lobster governance
- Will be collected during each rebase event

## Fee Update Mechanism

All fees implement a timelock mechanism that requires:

1. A fee update proposal with the new fee value
2. A waiting period of 2 weeks before the update can be enforced
3. An explicit enforcement transaction to apply the new fee

This gives users time to exit the vault if they disagree with the proposed fee changes.

## Technical Implementation Notes

### Operation Execution Flow

1. Operations must be validated by the OpValidator module (if set)
2. Pre-operation hooks are executed (if a Hook module is set)
3. The operation is executed
4. Post-operation hooks are executed (if a Hook module is set)

### Asset Valuation

By default, the vault uses the token balance as the total assets value. When a NAV module is set, the valuation can include external positions (such as tokens locked on another protocol) or complex calculations.

### Deposit and Withdrawal Flow

The vault can delegate deposit and withdrawal logic to a VaultFlow module, allowing for customized handling of assets, like:
- Integration with external protocols (automatic deposit / withdrawal from / to other protocols)
- Custom share calculation logic
- Additional validation or restrictions

### Hook System

Hooks can be attached to operations for additional functionality:
- Fee collection on specific actions
- Position management
- Asset rebalancing

## Usage Guidelines

### Module Configuration

Modules must be configured during vault deployment, and **cannot be updated**. The following considerations apply:

- A Hook cannot be installed if there is no OpValidator
- Custom VaultFlow modules should be carefully audited as they have direct access to mint and burn vault shares
- NAV modules must ensure accurate asset valuation to maintain proper share pricing

### Fee Recommendations

- Management fees should reflect the operational costs and expected returns
- Entry and exit fees should be balanced to discourage short-term trading while allowing reasonable liquidity
- Fee updates should be communicated well in advance of the timelock proposal
