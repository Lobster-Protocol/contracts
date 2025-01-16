# Lobster Protocol - Smart Contracts

## Core Concepts

### Rebasing
Since some tokens can be in another blockchain (Derive chain for instance), the vault cannot know the exact value of the assets it manages. To solve this issue, the vault uses a rebasing mechanism. Lobster manually update the other vault (Derive chain) with the new TVL (in eth) locked there. 
The vault's TVL is updated at least every hour: the vault compute its tvl for the protocols on the same chain and Lobster add the TVL of the other vaults. The vault's TVL is computed as follows: $tvl = ethManaged + ethLockedInDeriveChain$

> Note: Up to 10% of the TVL can be locked in the Derive chain

## Protocol Flow

1. **Initial Deposit**
   - User deposits assets into the vault. Based on the last 24h rebases, the vault predicts the amount of shares the user will receive. The amount of shares the user will receive is calculated as follows: $shares = (ethDeposited * totalShares) / totalEthManaged$

> - A rebase is expected to happen at most every hour. 
> - If the last rebase is older than 3h, the vault will not accept any deposit
> - If the last rebase is older than 5h, withdraws are accepted but the user's will suffer a penalty of 10% on their shares (We take the worst case in the calculation of the shares: the derive chain vault has a TVL of 0 eth)

2. **Asset Management**
   - Deposited assets become immediately available to Lobster's algorithm
   - Algorithm periodically rebalance/update its positions to optimize yield based on market conditions
   - Each operation from the algorithm is verified by the Validator contract before being executed

3. **Withdrawal / Redeem Process**
   - User initiates a withdrawal request
   - The vault calculates the amount of shares the user will burn. The amount of shares the user will burn is calculated as follows: $ethAmount = (sharesToBurn * totalEthManaged) / totalShares$ (the user can chose to redeem a certain amount of shares or withdraw a certain amount of eth)

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