// SPDX-License-Identifier: GNUv3
pragma solidity ^0.8.28;

import {IVaultOperations} from "../../../src/interfaces/modules/IVaultOperations.sol";
import {LobsterVault} from "../../../src/Vault/Vault.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";

address constant ACCEPTED_CALLER = address(118_712);
address constant PANIC_CALLER = address(12);
address constant CALL_MINT_SHARES = address(13);
address constant CALL_BURN_SHARES = address(14);
address constant CALL_SAFE_TRANSFER = address(15);
address constant CALL_SAFE_TRANSFER_FROM = address(16);

contract DummyVaultOperations is IVaultOperations {
    LobsterVault public vault;
    IERC20 token;

    event DepositHasBeenCalled(address caller, address receiver, uint256 assets, uint256 shares);
    event WithdrawHasBeenCalled(address caller, address receiver, address owner, uint256 assets, uint256 shares);

    function _deposit(
        address caller,
        address receiver,
        uint256 assets,
        uint256 shares
    )
        external
        returns (bool success)
    {
        emit DepositHasBeenCalled(caller, receiver, assets, shares);
        // revert if caller is PANIC_CALLER
        if (caller == PANIC_CALLER) {
            revert();
        } else if (caller == CALL_MINT_SHARES) {
            // mint shares
            vault.mintShares(receiver, shares);
        } else if (caller == CALL_BURN_SHARES) {
            // burn shares
            vault.burnShares(receiver, shares);
        } else if (caller == CALL_SAFE_TRANSFER) {
            // transfer assets
            vault.safeTransfer(token, receiver, assets);
        } else if (caller == CALL_SAFE_TRANSFER_FROM) {
            // transfer assets from caller to receiver
            vault.safeTransferFrom(token, caller, receiver, assets);
        }

        return true;
    }

    function _withdraw(
        address caller,
        address receiver,
        address owner,
        uint256 assets,
        uint256 shares
    )
        external
        returns (bool success)
    {
        emit WithdrawHasBeenCalled(caller, receiver, owner, assets, shares);
        // revert if caller is PANIC_CALLER
        if (caller == PANIC_CALLER) revert();

        return true;
    }

    function setVault(address _vault) external {
        vault = LobsterVault(_vault);
    }

    function setToken(address _token) external {
        token = IERC20(_token);
    }
}
