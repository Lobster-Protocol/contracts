// SPDX-License-Identifier: GNU AGPL v3.0
pragma solidity ^0.8.28;

import {IOpValidatorModule, BatchOp, Op} from "../../../src/interfaces/modules/IOpValidatorModule.sol";

bytes4 constant UNAUTHORIZED = bytes4(0x0B00BEE5);
bytes4 constant AUTHORIZED = bytes4(0x00000001);

contract DummyValidator is IOpValidatorModule {
    // Dummy validator that always returns true unless the op validation data is UNAUTHORIZED
    function validateOp(Op calldata op) external pure returns (bool) {
        if (op.validationData.length >= 4 && bytes4(op.validationData[:4]) == UNAUTHORIZED) {
            // Dummy logic to simulate validation failure
            return false;
        }
        return true;
    }

    function validateBatchedOp(BatchOp calldata batch) external pure returns (bool) {
        if (batch.validationData.length >= 4 && bytes4(batch.validationData[:4]) == UNAUTHORIZED) {
            // Dummy logic to simulate validation failure
            return false;
        }
        // Dummy logic to simulate validation success
        // In a real implementation, you would have your own validation logic here
        return true;
    }
}
