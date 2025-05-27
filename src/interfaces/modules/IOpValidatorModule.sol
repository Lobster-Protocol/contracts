// SPDX-License-Identifier: GPLv3
pragma solidity ^0.8.28;

/**
 * @title Operation Validator Structures and Interface
 * @author Lobster
 * @notice Defines core data structures and interface for validating operations in the vault system
 */

/// @notice Base operation data shared across all operation types
struct BaseOp {
    address target; // Target contract to call
    uint256 value; // Native tokens to send
    bytes data; // Calldata for the operation
}

/// @notice Complete operation with validation data
struct Op {
    BaseOp base; // Core operation data
    bytes validationData; // Data for validation, may include signatures, nonces, or other verification info
}

/// @notice For batch operations with shared validation data
struct BatchOp {
    BaseOp[] ops; // Array of operations to execute in sequence
    bytes validationData; // Shared validation data for the entire batch
}

/// @notice Pairs a function selector with its parameter validator
struct SelectorAndChecker {
    bytes4 selector; // Function selector (first 4 bytes of function signature)
    address paramsValidator; // Address of the contract that validates parameters for this function
}

/// @notice Defines permissions for calls to specific contract functions
struct WhitelistedCall {
    address target; // Target contract address
    uint256 maxAllowance; // Maximum ETH value allowed for calls
    bytes1 permissions; // Bitmap of permissions
    SelectorAndChecker[] selectorAndChecker; // Allowed function selectors with their validators
}

/// @notice ECDSA signature components
struct EcdsaSignature {
    bytes32 r; // r component of signature
    bytes32 s; // s component of signature
    uint8 v; // v component of signature (recovery id)
}

/// @notice Defines a signer with associated weight for multi-signature schemes
struct Signer {
    address signer; // Signer address
    uint256 weight; // Weight of this signer's signature
}

/// @notice Interface for OpValidator modules
/// @dev This interface defines the functions that must be implemented by any OpValidator module.
/// The validateOp & validateBatchedOp MUST protect against replay attacks (by implementing a nonce check for instance).
/// @notice IOpValidatorModule is the module in charge of approving or denying vault operations.
/// If no opValidatorModule is set in the vault, then the vault cannot execute any operations.
interface IOpValidatorModule {
    /**
     * @notice Validates a single operation
     * @param op The operation to validate
     * @return True if the operation is valid and can be executed
     */
    function validateOp(Op calldata op) external returns (bool);

    /**
     * @notice Validates a batch of operations
     * @param batch The batch operation to validate
     * @return True if the batch operation is valid and can be executed
     */
    function validateBatchedOp(BatchOp calldata batch) external returns (bool);
}
