// SPDX-License-Identifier: GNUv3
pragma solidity ^0.8.28;

import {Op} from "./IOpValidatorModule.sol";

interface IHook {
    /**
     * Function to be called before the main operation is executed by the Vault.
     * This function is called by the vault using delegatecall.
     *
     * @param op - The operation to be executed.
     * @param caller - vault.msg.sender
     */
    function preCheck(Op memory op, address caller) external returns (bytes memory context);

    /**
     * Function to be called after the main operation is executed by the Vault.
     * This function is called by the vault using delegatecall.
     *
     * @param ctx - The context returned by preCheck.
     */
    function postCheck(bytes memory ctx) external returns (bool success);
}
