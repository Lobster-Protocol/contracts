// SPDX-License-Identifier: GNUv3
pragma solidity ^0.8.28;

import {IVaultOperations} from "../../../src/interfaces/modules/IVaultOperations.sol";

address constant ACCEPTED_CALLER = address(888);
address constant PANIC_CALLER = address(12);

contract DummyVaultOperations is IVaultOperations {
    event DepositHasBeenCalled(address caller, address receiver, uint256 assets, uint256 shares);
    event WithdrawHasBeenCalled(address caller, address receiver, address owner, uint256 assets, uint256 shares);

    modifier onlyDelegateCall() {
        require(_amIDelegated(), "DummyVaultOperations: Not a delegate call");
        _;
    }

    function _deposit(
        address caller,
        address receiver,
        uint256 assets,
        uint256 shares
    )
        external
        onlyDelegateCall
        returns (bool success)
    {
        emit DepositHasBeenCalled(caller, receiver, assets, shares);

        // revert if caller is PANIC_CALLER
        if (caller == PANIC_CALLER) revert();

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
        onlyDelegateCall
        returns (bool success)
    {
        emit WithdrawHasBeenCalled(caller, receiver, owner, assets, shares);
        // revert if caller is PANIC_CALLER
        if (caller == PANIC_CALLER) revert();

        return true;
    }

    // check if we are in a delegate call
    function _amIDelegated() public view returns (bool) {
        // Get the address where the code is actually stored
        address codeAddress;
        assembly {
            codeAddress := extcodesize(address())
        }

        // If the code address is different from address(this), we're in a delegatecall
        return codeAddress != address(this);
    }
}
