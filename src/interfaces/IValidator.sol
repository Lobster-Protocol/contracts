// SPDX-License-Identifier: GNU AGPL v3.0
pragma solidity ^0.8.28;

struct Op {
    address target;
    bytes data;
    uint256 value;
}

interface IValidator {
    /**
     * The value owned by the vault on another chain / application
     */
    function valueOutsideChain() external view returns (uint256);

    function rebaseExpiresAt() external view returns (uint256);

    function validateOp(Op calldata op) external view returns (bool);

    function validateBatchedOp(Op[] calldata ops) external view returns (bool);
}
