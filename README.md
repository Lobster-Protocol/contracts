# Lobster Protocol - Smart Contracts

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