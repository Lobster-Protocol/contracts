# Lobster Protocol - ERC4626 Vault

The Lobster Protocol Vault is a smart contract allowing users to deposit and withdraw ERC20 tokens. The Vault is designed so that the assets are managed by the lobster algorithm, which is an offchain script that determines the optimal allocation of assets in the vault. The lobster algorithm is not part of the smart contract and is not open source.

## Core Concepts

### Rebasing
Since some tokens can be in other blockchain (Derive chain for instance) or protocols, the vault cannot know the exact value of the assets it manages. To solve this issue, the vault uses a rebasing mechanism. Lobster manually update the `valueOutsideVault` value with the new TVL (in eth) locked there. 

> The vault's TVL can be updated at anytime through a rebase by calling `function rebase(bytes calldata rebaseData) external`. 
> A rebase also happens when a user requires a deposit or a withdraw.
> Note: a rebase has an expiration date. If the last rebase expired, no one will be able to deposit or withdraw without the rebase data from Lobster


## Protocol Flow

1. **Initial Deposit**
   - User deposits assets into the vault. Based on the last rebases (if it did not expire), the vault compute the amount of shares the user will receive. The amount of shares the user will receive is calculated as follows: $shares = (ethDeposited * totalShares) / totalEthManaged$

> - If the last rebase expired, the vault will not accept any deposit and withdrawals without a rebase


1. **Asset Management**
   - Deposited assets become immediately available to Lobster's algorithm
   - Algorithm periodically rebalance/update its positions to optimize yield based on market conditions
   - Each operation from the algorithm is verified by the Validator contract before being executed

2. **Withdrawal / Redeem Process**
   - On withdrawal request, the vault calculates the amount of shares the user will burn. The amount of shares the user will burn is calculated as follows: $ethAmount = (sharesToBurn * totalEthManaged) / totalShares$ (the user can chose to redeem a certain amount of shares or withdraw a certain amount of eth)

> To determine how many tokens is worth one share, the vault compute the eth value deposited by itself in each one of the supported protocols + the value in the L3 (from the last rebase). 
> If the rebase is too old, see  `Initial Deposit` note [above](#protocol-flow)
   
## Fee Structure

### Performance Fees
- Fixed percentage that can be updated by Lobster
- Collected during each rebase event

### Management Fees
- Fixed annual percentage that can be updated by Lobster
- Collected during each rebase event

### Deposit Fees
- Fixed value that can be updated by Lobster
- Deducted from shares before conversion to underlying assets
- Took into account when computing the new shares for the user
- Set to 0% by default
 
### Withdrawal Fees
- Fixed value that can be updated by Lobster
- Deducted from shares before conversion to underlying assets

### Insurance Fees
A part (which needs to be determined) of the fees collected by the vault will be used to insure the vault. The insurance will be used to cover the losses of the vault in case of a hack or any other exceptional circumstances. The insurance will be provided by a third party.

## Technical Implementation Notes

All fee parameters are maintained as protocol constants but can be modified by Lobster governance through update. Fee collection is automated and integrated into the rebasing process to ensure consistent protocol revenue management.


> Note: When users request a withdrawal, the offchain script which creates the operation to execute to unlock the assets MUST first use the assets from the vault first and only retrieve the missing funds if needed