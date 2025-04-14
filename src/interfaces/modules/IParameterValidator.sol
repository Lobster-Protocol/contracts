// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// Interface for parameter validators
interface IParameterValidator {
    function validateParameters(
        bytes calldata parameters
    ) external view returns (bool);
}
