// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.27;

import {TransientSlot} from "@openzeppelin/contracts/utils/TransientSlot.sol";
import {Deadline} from "./Deadline.sol";

/// @title Checks shared by every entry point
/// @notice Deadline, and a reentrancy lock that also records who holds it.
/// @dev The lock matters because of chaining: inside a `swap` call, the proxy, or the PoolManager on its
/// behalf, holds the output of one leg until a later leg spends it. Any call that re-entered the proxy at
/// that moment (say from a token's transfer hook) could spend those funds as its own. Every external
/// entry point that moves funds or writes state is therefore `nonReentrant`. What stays open: the pool
/// callbacks (`uniswapV3SwapCallback`, `uniswapV3MintCallback`, `unlockCallback`), which the pools must
/// call mid-swap and which only act for a call the proxy itself is making; the Roles condition `check`,
/// which a vault's Roles modifier calls in the middle of `modifyLiquidityV4`; and the views.
///
/// The lock lives in transient storage, so it adds no persistent state and costs a few hundred gas per
/// call. It holds the entry point's `msg.sender` rather than a flag (with bit 160 set, so even
/// address(0), as in some `eth_call` simulations, locks it): the callbacks, where `msg.sender` is a pool
/// or the PoolManager, read the vault from it. It is written only by {nonReentrant}, so it can never name
/// anyone but the account that called in.
abstract contract Guards is Deadline {
    using TransientSlot for *;

    /// @dev keccak256("lobster.proxy.lock") - 1
    bytes32 private constant LOCK_SLOT = 0xd2cd7363ef25f34f8b01c5be20e77b4ea09700d442a227d469d5fa29ce1f1091;
    uint256 private constant LOCKED = 1 << 160;

    modifier nonReentrant() {
        TransientSlot.Uint256Slot lock = LOCK_SLOT.asUint256();
        require(lock.tload() == 0, ReentrancyGuardReentrantCall());
        lock.tstore(uint256(uint160(msg.sender)) | LOCKED);
        _;
        lock.tstore(0);
    }

    /// @dev The account whose entry point is running; address(0) when none is
    function _lockedBy() internal view returns (address account) {
        assembly ("memory-safe") {
            account := and(tload(LOCK_SLOT), 0xffffffffffffffffffffffffffffffffffffffff)
        }
    }
}
