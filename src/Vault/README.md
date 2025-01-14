# Lobster Protocol - ERC4626 Vault

The Lobster Protocol Vault is a smart contract allowing users to deposit and withdraw ERC20 tokens. The Vault is designed so that the assets are managed by the lobster algorithm, which is an offchain script that determines the optimal allocation of assets in the vault. The lobster algorithm is not part of the smart contract and is not open source.

Any update made by the lobster algorithm must be approved by a [Validator contract](../Validator/README.md) before it can be executed. The Validator contract is a multisig contract that requires a majority of validators to approve an update before it can be executed.