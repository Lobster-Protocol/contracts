// SPDX-License-Identifier: GPLv3
pragma solidity ^0.8.28;

// Special address indicating that no parameter validation is needed
// for the operation validation done by the GenericMusigOpValidator.
// When a SelectorAndChecker references this address as the paramsValidator,
// the system will skip parameter validation for that function.
address constant NO_PARAMS_CHECKS_ADDRESS = address(1);

/* -------------------------------------------------------------------------------- */
// Permission flags for operation target validation.
// These bit flags are used in the whitelistedTargets mapping to define
// what types of interactions are allowed with specific addresses.

// Permission flag to allow sending ETH to an address (bit 0)
// Binary: 0000 0001
uint8 constant SEND_ETH = 0x01;

// Permission flag to allow calling functions on an address (bit 1)
// Binary: 0000 0010
uint8 constant CALL_FUNCTIONS = 0x02;

// Permission flag to allow delegateCall to functions on an address (bit 2)
// Binary: 0000 0100
// Not implemented yet in the current version
uint8 constant DELEGATE_CALL_FUNCTIONS = 0x04; // 0000 0100
/* -------------------------------------------------------------------------------- */
