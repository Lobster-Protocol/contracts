// SPDX-License-Identifier: GPLv3
pragma solidity ^0.8.28;

import {IOpValidatorModule} from "../interfaces/modules/IOpValidatorModule.sol";
import {BaseOp, Op, BatchOp} from "../interfaces/modules/IOpValidatorModule.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title Modular Base Contract
 * @author Lobster
 * @notice Base contract providing secure operation execution capabilities for ERC4626 vaults.
 * Implements a validation system where all external operations must be approved by a validator module
 * before execution. This enables controlled access to vault operations while maintaining security.
 * @dev This contract extends ERC4626 and provides the foundation for modular vault systems that need
 * to execute arbitrary operations (like DeFi interactions) in a controlled manner.
 */
abstract contract Modular is ERC4626 {
    /**
     * @notice Module responsible for validating vault operations before execution
     * @dev This validator determines which operations are allowed to be executed by the vault.
     * Operations include function calls to external contracts, ETH transfers, and complex batched operations.
     * If this is not set (address(0)), all operations will be rejected for security.
     */
    IOpValidatorModule public immutable opValidator;

    /**
     * @notice Emitted when a vault operation is successfully executed
     * @param target The address of the contract that was called
     * @param value The amount of ETH (in wei) sent with the call
     * @param selector The 4-byte function selector that was called (or 0x00000000 for calls with <4 bytes data)
     */
    event Executed(address indexed target, uint256 value, bytes4 selector);

    /**
     * @notice Emitted when an operation validator module is set during construction
     * @param opValidator The address of the operation validator module
     */
    event OpValidatorSet(IOpValidatorModule opValidator);

    /**
     * @notice Thrown when an operation is rejected by the validator or no validator is set
     * @dev This error is thrown in the following cases:
     * - No operation validator is configured (opValidator is address(0))
     * - The validator explicitly rejects the operation
     * - The operation fails validation checks
     */
    error OpNotApproved();

    /* ------------------OPERATION EXECUTION FUNCTIONS------------------ */

    /**
     * @notice Executes a single validated operation
     * @param op The operation to execute, containing target contract, ETH value, and calldata
     * @dev Security flow:
     * 1. Checks that an operation validator is configured
     * 2. Validates the operation through the validator module
     * 3. Executes the operation if approved
     * 4. Emits an Executed event with operation details
     * @dev Reverts with OpNotApproved if no validator is set or validation fails
     * @dev Reverts with the underlying error if the operation call itself fails
     */
    function executeOp(Op calldata op) external {
        // Security check: Always revert if no validator is configured
        address validator = address(opValidator);
        if (validator == address(0)) {
            revert OpNotApproved();
        }

        // Validate the operation through the configured validator
        if (!opValidator.validateOp(op)) {
            revert OpNotApproved();
        }

        // Execute the validated operation
        _call(op.base);
    }

    /**
     * @notice Executes a batch of validated operations atomically
     * @param batch The batch operation containing an array of operations to execute
     * @dev Security flow:
     * 1. Checks that an operation validator is configured
     * 2. Validates the entire batch through the validator module
     * 3. Executes all operations in sequence if the batch is approved
     * 4. Emits an Executed event for each individual operation
     * @dev All operations in the batch are executed atomically - if any operation fails,
     * the entire transaction reverts and no operations are executed
     * @dev Reverts with OpNotApproved if no validator is set or batch validation fails
     * @dev Reverts with the underlying error if any operation call fails
     */
    function executeOpBatch(BatchOp calldata batch) external {
        // Security check: Always revert if no validator is configured
        address validator = address(opValidator);
        if (validator == address(0)) {
            revert OpNotApproved();
        }

        // Validate the entire batch operation
        if (!opValidator.validateBatchedOp(batch)) {
            revert OpNotApproved();
        }

        // Execute all operations in the batch sequentially
        uint256 length = batch.ops.length;
        for (uint256 i = 0; i < length;) {
            _call(batch.ops[i]);

            unchecked {
                ++i;
            }
        }
    }

    /**
     * @dev Internal function to perform the actual contract call for an operation
     * @param op The base operation containing target address, ETH value, and calldata
     * @return result The raw bytes data returned from the successful call
     * @dev This function:
     * 1. Executes the low-level call with the specified parameters
     * 2. Uses inline assembly for efficient error handling and revert forwarding
     * 3. Extracts the function selector from calldata for event emission
     * 4. Emits an Executed event with operation details
     * @dev The function selector extraction handles edge cases:
     * - Returns 0x00000000 for calls with less than 4 bytes of data
     * - Extracts the first 4 bytes as the selector for normal function calls
     * @dev Reverts with the original error message if the underlying call fails
     */
    function _call(BaseOp calldata op) private returns (bytes memory result) {
        // Execute the low-level call
        (bool success, bytes memory returnData) = op.target.call{value: op.value}(op.data);

        // Efficient error handling using inline assembly
        // If call failed, revert with the original error message
        assembly {
            if iszero(success) { revert(add(returnData, 32), mload(returnData)) }
        }

        // Extract function selector for event emission
        bytes4 selector = bytes4(0);
        if (op.data.length >= 4) {
            selector = bytes4(op.data[:4]);
        }

        // Emit event for successful operation execution
        emit Executed(op.target, op.value, selector);

        return returnData;
    }
}
