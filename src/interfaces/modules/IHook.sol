// SPDX-License-Identifier: GPLv3
pragma solidity ^0.8.28;

import {BaseOp} from "./IOpValidatorModule.sol";

/**
 * @title IHook Interface
 * @author Lobster
 * @notice Interface defining the hook contract that can execute logic before and after vault operations.
 * The hook contains pieces of code to be executed before and after any vault operation execution.
 * This allows for additional validation, state modification, or other actions to be performed
 * in conjunction with the primary vault operation.
 * 
 * @dev A Hook execute operations through the vault without triggering itself.
 */
interface IHook {
    /**
     * Function to be called before the main operation is executed by the Vault.
     *
     * @param op - The operation to be executed.
     * @param caller - vault.msg.sender
     * @return context - Data to be passed to the postCheck function after operation execution
     */
    function preCheck(BaseOp memory op, address caller) external returns (bytes memory context);

    /**
     * Function to be called after the main operation is executed by the Vault.
     *
     * @param ctx - The context returned by preCheck.
     * @return success - Boolean indicating whether the post-operation check was successful
     */
    function postCheck(bytes memory ctx) external returns (bool success);
}
