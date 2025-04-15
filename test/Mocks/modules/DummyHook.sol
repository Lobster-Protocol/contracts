// SPDX-License-Identifier: GNU AGPL v3.0
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import {IHook} from "../../../src/interfaces/IHook.sol";
import {Op} from "../../../src/interfaces/modules/IOpValidatorModule.sol";

bytes4 constant UNAUTHORIZED_PREHOOK = bytes4(0x12345678);
bytes4 constant UNAUTHORIZED_POSTHOOK = bytes4(0x01234567);

contract DummyHook is IHook {
    bytes32 private constant CONTEXT = keccak256("DummyHook");

    // used to ensure the hook is called with delegatecall
    mapping(address => uint256) public preCheckCalls;
    mapping(address => uint256) public postCheckCalls;

    error InvalidContext();

    modifier onlyDelegateCall() {
        require(_amIDelegated(), "Not a delegate call");
        _;
    }

    function preCheck(Op calldata op, address caller) external view onlyDelegateCall returns (bytes memory context) {
        // fail if selector is UNAUTHORIZED
        if (op.validationData.length == 4 && bytes4(op.validationData[:4]) == UNAUTHORIZED_PREHOOK) revert();

        return abi.encode(CONTEXT, op, caller);
    }

    function postCheck(bytes calldata ctx) external onlyDelegateCall returns (bool success) {
        (bytes32 context, Op memory op,) = abi.decode(ctx, (bytes32, Op, address));

        if (context != CONTEXT) {
            revert InvalidContext();
        }

        if (
            op.validationData.length == 4
                && keccak256(op.validationData) == keccak256(abi.encodePacked(UNAUTHORIZED_POSTHOOK))
        ) revert();

        // Increment the postCheckCalls counter for the caller
        postCheckCalls[msg.sender]++; // msg.sender must be the vault

        // Dummy logic to simulate post-check
        success = true;
    }

    // check if we are in a delegate call
    function _amIDelegated() public view returns (bool) {
        // Get the address where the code is actually stored
        address codeAddress;
        assembly {
            codeAddress := extcodesize(address())
        }

        // If the code address is different from address(this), we're in a delegatecall
        return codeAddress != address(this);
    }
}
