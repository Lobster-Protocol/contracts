// SPDX-License-Identifier: GNUv3
pragma solidity ^0.8.28;

address constant NO_PARAMS_CHECKS_ADDRESS = address(1);

// Permission types in whitelistedTargets mapping
// Bit 0: Can send ETH to address
// Bit 1: Can call functions on address
// Bit 2: Can delegateCall functions on address (not implemented yet)
// Bits 3-7: Reserved for future use
uint8 constant SEND_ETH = 0x01; // 0000 0001
uint8 constant CALL_FUNCTIONS = 0x02; // 0000 0010
uint8 constant DELEGATE_CALL_FUNCTIONS = 0x04; // 0000 0100
