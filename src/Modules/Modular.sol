// SPDX-License-Identifier: GPLv3
pragma solidity ^0.8.28;

import {IOpValidatorModule} from "../interfaces/modules/IOpValidatorModule.sol";
import {IVaultFlowModule} from "../interfaces/modules/IVaultFlowModule.sol";
import {IHook} from "../interfaces/modules/IHook.sol";
import {INav} from "../interfaces/modules/INav.sol";
import {BaseOp, Op, BatchOp} from "../interfaces/modules/IOpValidatorModule.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title Modular Base Contract
 * @author Lobster
 * @notice Base contract containing the modules related events, errors, and state variables for the Vault contract
 * @dev This contract provides the foundation for modular functionality in the vault system
 *      by defining core modules, error conditions, and events
 */
abstract contract Modular is ERC4626 {
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
     * @dev Used to protect the vault from hooks calls when the vault did not call it first
     * @notice Flag to track if the vault is currently executing operations
     */
    bool private _executingOps;

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
     * @notice Ensures only the vaultFlow module can call the function
     * @dev Restricts access to certain functions that should only be accessed by the vaultFlow module
     */
    modifier OnlyVaultFlow() {
        require(msg.sender == address(vaultFlow), "Not allowed vaultFlow call");
        _;
    }

    /**
     * @notice Ensures hook calls to the vault are properly authorized
     * @dev Used to protect the vault from hooks calls when the vault did not call it first
     */
    modifier inExecutionContext() {
        if (msg.sender == address(hook)) {
            // if the caller is the hook, only check if the call is allowed
            require(_executingOps, "Not allowed Hook call");
            _;
        } else {
            _executingOps = true;
            _;
            _executingOps = false;
        }
    }

    /* ------------------FUNCTIONS FOR CUSTOM CALLS------------------ */

    /**
     * @notice Executes a single operation after validation
     * @param op The operation to execute
     * @dev Requires an operation validator to be set
     * @dev If called by a hook, validation is skipped but operations are still executed
     */
    function executeOp(Op calldata op) external inExecutionContext {
        // Always revert if validator is not set
        address validator = address(opValidator);
        if (validator == address(0)) {
            revert OpNotApproved();
        }

        // Skip validation if caller is the hook or vaultFlow module
        bool isFromHookOrFlow = msg.sender == address(hook) || msg.sender == address(vaultFlow);

        // Validate operation if not from hook or vaultFlow
        if (!isFromHookOrFlow && !opValidator.validateOp(op)) {
            revert OpNotApproved();
        }

        // Execute operation with hook calls only if not from hook or vaultFlow
        bytes memory ctx;
        if (!isFromHookOrFlow) {
            ctx = _preCallHook(op.base, msg.sender);
        }

        _call(op.base);

        if (!isFromHookOrFlow) {
            _postCallHook(ctx);
        }
    }

    /**
     * @notice Executes a batch of operations after validation
     * @param batch The batch operation containing multiple operations
     * @dev Requires an operation validator to be set
     * @dev If called by a hook, hook validation is skipped but operations are still executed
     */
    function executeOpBatch(BatchOp calldata batch) external inExecutionContext {
        // Always revert if validator is not set
        address validator = address(opValidator);
        if (validator == address(0)) {
            revert OpNotApproved();
        }

        // Skip validation if caller is the hook or vaultFlow module
        bool isFromHookOrFlow = msg.sender == address(hook) || msg.sender == address(vaultFlow);

        // Validate batch operation
        if (!isFromHookOrFlow && !opValidator.validateBatchedOp(batch)) {
            revert OpNotApproved();
        }

        // Process all operations in batch
        uint256 length = batch.ops.length;
        for (uint256 i = 0; i < length;) {
            // Execute operation with hook calls only if not from hook
            bytes memory ctx;
            if (!isFromHookOrFlow) {
                // todo: would it be better to call the hook once ? (but les granularity)
                ctx = _preCallHook(batch.ops[i], msg.sender);
            }

            _call(batch.ops[i]);

            if (!isFromHookOrFlow) {
                _postCallHook(ctx);
            }

            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice Internal function to perform the actual call in an operation
     * @param op The base operation containing target, value, and data
     * @return result The raw bytes data returned from the call
     * @dev Emits an Executed event after successful execution
     * @dev Reverts with the error message if the call fails
     */
    function _call(BaseOp calldata op) private returns (bytes memory result) {
        (bool success, bytes memory returnData) = op.target.call{value: op.value}(op.data);

        assembly {
            if iszero(success) { revert(add(returnData, 32), mload(returnData)) }
        }

        bytes4 selector = bytes4(0);
        if (op.data.length > 4) {
            selector = bytes4(op.data[:4]);
        }

        emit Executed(op.target, op.value, selector);

        return returnData;
    }

    /* ------------------HOOKS------------------- */
    /**
     * @notice Calls the preCheck function from the Hook contract (if set)
     * @param op The operation to execute
     * @param caller The address of the caller
     * @return context Data to be passed to the postCheck function
     * @dev Reverts with PreHookFailed if the hook's preCheck fails
     */
    function _preCallHook(BaseOp memory op, address caller) private returns (bytes memory context) {
        if (address(hook) != address(0)) {
            // Prepare the call data for preCheck function
            bytes memory callData = abi.encodeWithSelector(hook.preCheck.selector, op, caller);

            // Perform low-level static call
            (bool success, bytes memory returnData) = address(hook).call(callData);

            // Revert with PreHookFailed error if the call fails
            if (!success) {
                revert PreHookFailed();
            }

            return abi.decode(returnData, (bytes)); // decode the output
        }

        return "";
    }

    /**
     * @notice Calls the postCheck function from the Hook contract (if set)
     * @param ctx The context returned by _preCallHook
     * @return success True if the post hook was successful or not needed
     * @dev Reverts with PostHookFailed if the hook's postCheck fails
     */
    function _postCallHook(bytes memory ctx) private returns (bool success) {
        if (ctx.length > 0) {
            // Prepare the call data for preCheck function
            bytes memory callData = abi.encodeWithSelector(hook.postCheck.selector, ctx);

            // Perform low-level static call
            (bool callSuccess,) = address(hook).call(callData);

            // Revert with PreHookFailed error if the call fails
            if (!callSuccess) {
                revert PostHookFailed();
            }

            return true;
        }

        return true;
    }

    /**
     * @notice Safely transfers tokens to an address
     * @param token The ERC20 token to transfer
     * @param to The recipient address
     * @param amount The amount to transfer
     * @dev Can only be called by the vaultFlow module
     */
    function safeTransfer(IERC20 token, address to, uint256 amount) external OnlyVaultFlow {
        // Use SafeERC20 to transfer tokens safely
        SafeERC20.safeTransfer(token, to, amount);
    }

    /**
     * @notice Safely transfers tokens from one address to another
     * @param token The ERC20 token to transfer
     * @param from The source address
     * @param to The recipient address
     * @param amount The amount to transfer
     * @dev Can only be called by the vaultFlow module
     */
    function safeTransferFrom(IERC20 token, address from, address to, uint256 amount) external OnlyVaultFlow {
        // Use SafeERC20 to transfer tokens safely
        SafeERC20.safeTransferFrom(token, from, to, amount);
    }
}
