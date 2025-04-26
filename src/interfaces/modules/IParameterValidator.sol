// SPDX-License-Identifier: GPLv3
pragma solidity ^0.8.28;

/**
 * @title IParameterValidator Interface
 * @author Lobster
 * @notice Interface for validating operation calldata parameters
 * @dev When validating an operation, we might need to check the operation calldata
 *      to verify the parameters sent to the targeted contract/function.
 *      This interface allows for specific validation logic for different function parameters.
 */

// Interface for parameter validators
interface IParameterValidator {
    /**
     * @notice Validates the parameters within a function call
     * @param parameters The encoded function parameters to validate
     * @return True if the parameters are valid according to the validator's rules
     * @dev The parameters are expected to be ABI-encoded calldata excluding the function selector
     */
    function validateParameters(bytes calldata parameters) external view returns (bool);
}
