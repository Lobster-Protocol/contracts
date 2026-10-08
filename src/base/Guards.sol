// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.24;

import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Deadline} from "./Deadline.sol";
import {Chaining} from "../libraries/Chaining.sol";

/// @title Checks shared by every entry point
/// @notice Deadline, recipient validation and a reentrancy lock.
/// @dev The lock matters because of chaining: inside a `batchSwap`, the proxy holds the output of
/// one swap until a later swap spends it. Any call that re-entered the proxy at that moment (say
/// from a token's transfer hook) could spend those funds as its own. Every external entry point is
/// therefore `nonReentrant`; only the pool callbacks and `receive` stay open, since the pools must
/// call them mid-swap. The lock lives in transient storage, so the proxy still has no persistent
/// state, and it costs a few hundred gas per call.
abstract contract Guards is Deadline, ReentrancyGuardTransient {
    /// @dev For recipients supplied by the caller. The proxy itself is refused because nothing can
    /// move tokens or positions out of it again; `Chaining.ADDRESS_THIS` because it only means
    /// something to `batchSwap`, which resolves it before any swap runs.
    function _checkRecipient(address recipient) internal view {
        require(recipient != address(0));
        require(recipient != address(this) && recipient != Chaining.ADDRESS_THIS, "Invalid recipient");
    }
}
