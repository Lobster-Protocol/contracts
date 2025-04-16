// SPDX-License-Identifier: GNUv3
pragma solidity ^0.8.28;

// handle the _deposit and _withdraw functions for the vault
interface IVaultOperations {
    function _deposit(
        address caller,
        address receiver,
        uint256 assets,
        uint256 shares
    ) external returns (bool success);

    function _withdraw(
        address caller,
        address receiver,
        address owner,
        uint256 assets,
        uint256 shares
    ) external returns (bool success);
}
