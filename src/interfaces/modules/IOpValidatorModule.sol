// SPDX-License-Identifier: GNUv3
pragma solidity ^0.8.28;

// For individual operations
struct Op {
    address target;
    uint256 value;
    bytes data;
    bytes validationData;
}

// For batch operations with shared validation data
struct BatchOp {
    Op[] ops; // ops with validationData = 0x
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
