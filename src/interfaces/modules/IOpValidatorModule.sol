// SPDX-License-Identifier: GNUv3
pragma solidity ^0.8.28;

/// @notice Base operation data shared across all operation types
struct BaseOp {
    address target; // Target contract to call
    uint256 value; // ETH value to send
    bytes data; // Calldata for the operation
}

/// @notice Complete operation with validation data and nonce
struct Op {
    BaseOp base; // Core operation data
    bytes validationData; // Data for validation
}

/// @notice For batch operations with shared validation data
struct BatchOp {
    BaseOp[] ops;
    bytes validationData;
}

struct SelectorAndChecker {
    bytes4 selector;
    address paramsValidator;
}

struct WhitelistedCall {
    address target;
    uint256 maxAllowance;
    bytes1 permissions;
    SelectorAndChecker[] selectorAndChecker;
}

struct EcdsaSignature {
    bytes32 r;
    bytes32 s;
    uint8 v;
}

struct Signers {
    address signer;
    uint256 weight;
}

interface IOpValidatorModule {
    function validateOp(Op calldata op) external returns (bool);

    function validateBatchedOp(BatchOp calldata batch) external returns (bool);
}
