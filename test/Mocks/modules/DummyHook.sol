// SPDX-License-Identifier: GNU AGPL v3.0
pragma solidity ^0.8.28;

import {IHook} from "../../../src/interfaces/modules/IHook.sol";
import {Op} from "../../../src/interfaces/modules/IOpValidatorModule.sol";
import {LobsterVault} from "../../../src/Vault/Vault.sol";

bytes4 constant UNAUTHORIZED_PREHOOK = bytes4(0x12345678);
bytes4 constant UNAUTHORIZED_POSTHOOK = bytes4(0x01234567);

contract DummyHook is IHook {
    bytes32 private constant CONTEXT = keccak256("DummyHook");

    mapping(address => uint256) public preCheckCalls;
    mapping(address => uint256) public postCheckCalls;

    error InvalidContext();

    event Ping();

    function preCheck(Op calldata op, address caller) external pure returns (bytes memory context) {
        // fail if selector is UNAUTHORIZED
        if (op.validationData.length == 4 && bytes4(op.validationData[:4]) == UNAUTHORIZED_PREHOOK) revert();

        return abi.encode(CONTEXT, op, caller);
    }

    function postCheck(bytes calldata ctx) external returns (bool success) {
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

    /**
     * Calls the Vault without having been called by it first
     */
    function callVault(LobsterVault vault) external {
        // dummy op
        Op memory op = Op(
            address(this),
            0,
            abi.encodeWithSelector(DummyHook.ping.selector),
            "" // no need for validationData, caller is the hook
        );

        vault.executeOp(op);
    }

    function ping() external {
        emit Ping();
    }
}
