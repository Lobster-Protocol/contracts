// SPDX-License-Identifier: GPLv3
pragma solidity ^0.8.28;

import {IOpValidatorModule} from "../interfaces/modules/IOpValidatorModule.sol";
import {IVaultFlowModule} from "../interfaces/modules/IVaultFlowModule.sol";
import {IHook} from "../interfaces/modules/IHook.sol";
import {INav} from "../interfaces/modules/INav.sol";

/**
 * @title Modular Base Contract
 * @author Lobster
 * @notice Base contract containing the modules related events, errors, and state variables for the Vault contract
 * @dev This contract provides the foundation for modular functionality in the vault system
 *      by defining core modules, error conditions, and events
 */
contract Modular {
    /**
     * @notice Module responsible for validating vault operations
     * @dev If not set, the vault cannot execute any operations
     */
    IOpValidatorModule public immutable opValidator;

    /**
     * @notice Module responsible for custom deposit and withdrawal logic
     * @dev Replaces the default _deposit and _withdraw functions
     */
    IVaultFlowModule public immutable vaultFlow;

    /**
     * @notice Hook for executing code before and after vault operations
     * @dev Allows for additional validation, state modification, or other actions
     * @dev todo: 1 hook for all calls or 1 hook per call?
     */
    // todo: 1 hook for all calls or 1 hook per call?
    IHook public immutable hook;

    /**
     * @notice Module responsible for computing the totalAssets for the vault
     * @dev Replaces the default totalAssets function if set
     */
    INav public immutable navModule;

    /**
     * @notice Thrown when the pre-operation hook check fails
     */
    error PreHookFailed();

    /**
     * @notice Thrown when the post-operation hook check fails
     */
    error PostHookFailed();

    /**
     * @notice Thrown when an operation is not approved by the opValidator
     */
    error OpNotApproved();

    /**
     * @notice Thrown when the deposit module fails to process a deposit
     */
    error DepositModuleFailed();

    /**
     * @notice Thrown when the withdraw module fails to process a withdrawal
     */
    error WithdrawModuleFailed();

    /**
     * @notice Emitted when a vault operation is executed
     * @param target The address of the contract called
     * @param value The amount of ETH sent with the call
     * @param selector The function selector called
     */
    event Executed(address indexed target, uint256 value, bytes4 selector);

    /**
     * @notice Emitted when an operation validator module is set
     * @param opValidator The address of the new operation validator module
     */
    event OpValidatorSet(IOpValidatorModule opValidator);

    /**
     * @notice Emitted when a hook module is set
     * @param hook The address of the new hook module
     */
    event HookSet(IHook hook);

    /**
     * @notice Emitted when a NAV module is set
     * @param navModule The address of the new NAV module
     */
    event NavModuleSet(INav navModule);

    /**
     * @notice Emitted when a vault operations module is set
     * @param vaultFlow The address of the new vault flow module
     */
    event vaultFlowSet(IVaultFlowModule vaultFlow);
}
