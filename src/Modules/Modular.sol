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
 * @notice Base contract containing the modules related events, errors, and state variables for the Vault contract
 * @dev This contract provides the foundation for the modular vault operation mechanism
 */
abstract contract Modular is ERC4626 {
    /**
     * @notice Module responsible for validating vault operations
     * @dev If not set, the vault cannot execute any operations
     */
    IOpValidatorModule public immutable opValidator;

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
     * @notice Thrown when an operation is not approved by the opValidator
     */
    error OpNotApproved();

    /* ------------------FUNCTIONS FOR CUSTOM CALLS------------------ */

    /**
     * @notice Executes a single operation after validation
     * @param op The operation to execute
     * @dev Requires an operation validator to be set
     */
    function executeOp(Op calldata op) external {
        // Always revert if validator is not set
        address validator = address(opValidator);
        if (validator == address(0)) {
            revert OpNotApproved();
        }

        if (!opValidator.validateOp(op)) {
            revert OpNotApproved();
        }

        _call(op.base);
    }

    /**
     * @notice Executes a batch of operations after validation
     * @param batch The batch operation containing multiple operations
     * @dev Requires an operation validator to be set
     */
    function executeOpBatch(BatchOp calldata batch) external {
        // Always revert if validator is not set
        address validator = address(opValidator);
        if (validator == address(0)) {
            revert OpNotApproved();
        }

        // Validate batch operation
        if (!opValidator.validateBatchedOp(batch)) {
            revert OpNotApproved();
        }

        // Process all operations in batch
        uint256 length = batch.ops.length;
        for (uint256 i = 0; i < length;) {
            _call(batch.ops[i]);

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
}
