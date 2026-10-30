// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.27;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Deadline} from "./Deadline.sol";
import {Chaining} from "../libraries/Chaining.sol";

/// @title Checks shared by every entry point
/// @notice Deadline, recipient validation and a reentrancy lock.
/// @dev The lock matters because of chaining: inside a `batchSwap`, the proxy holds the output of
/// one swap until a later swap spends it. Any call that re-entered the proxy at that moment (say
/// from a token's transfer hook) could spend those funds as its own. Every external entry point is
/// therefore `nonReentrant`; only the pool callbacks and `receive` stay open, since the pools must
/// call them mid-swap. The lock lives in transient storage, so it adds no persistent state of its
/// own and costs a few hundred gas per call. ({LobsterProxy}'s persistent state is its
/// per-vault pool registry, permissions and price bands, see {PoolRegistry}, and each vault's V4
/// Roles configuration.)
abstract contract Guards is Deadline, ReentrancyGuardTransient {
    /// @dev For recipients supplied by the caller. The proxy itself is refused because nothing can
    /// move tokens or positions out of it again; `Chaining.ADDRESS_THIS` because it only means
    /// something to `batchSwap`, which resolves it before any swap runs.
    function _checkRecipient(address recipient) internal view {
        require(recipient != address(0), InvalidRecipient());
        require(recipient != address(this) && recipient != Chaining.ADDRESS_THIS, InvalidRecipient());
    }

    /// @dev What the proxy holds of `token`; address(0) is native ETH, as in V4
    function _heldBalance(address token) internal view returns (uint256) {
        return token == address(0) ? address(this).balance : IERC20(token).balanceOf(address(this));
    }
}
