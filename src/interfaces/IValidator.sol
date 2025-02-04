// SPDX-License-Identifier: GNU AGPL v3.0
pragma solidity ^0.8.28;

struct Op {
    address target;
    bytes data;
    uint256 value;
}

// interface IValidator {
//     /* The value owned by the vault on another chain / application ie: value set when rebasing */
//     function valueOutsideVault() external view returns (uint256);

//     /* The Block number when the rebase expire */
//     function rebaseExpiresAt() external view returns (uint256);

//     /* wrapper for the erc4626 deposit function: update rebase value and call deposit */
//     function deposit(uint256 assets, address receiver, bytes calldata rebaseData) external returns (uint256);

//     /* wrapper for the erc4626 mint function: update rebase value and call mint */
//     function mint(uint256 shares, address receiver, bytes calldata rebaseData) external returns (uint256);

//     /* wrapper for the erc4626 withdraw function: update rebase value and call withdraw */
//     function withdraw(uint256 assets, address receiver, address owner, bytes calldata rebaseData) external returns (uint256);

//     /* wrapper for the erc4626 redeem function: update rebase value and call redeem */
//     function redeem(uint256 shares, address receiver, address owner, bytes calldata rebaseData) external returns (uint256);

//     /* Approve custom operation */
//     function validateOp(Op calldata op) external view returns (bool);

//     /* Approve custom operations */
//     function validateBatchedOp(Op[] calldata ops) external view returns (bool);
// }
