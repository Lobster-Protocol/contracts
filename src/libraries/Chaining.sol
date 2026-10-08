// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.20;

/// @title The two magic values that chain swaps inside a `batchSwap`
/// @notice Chaining lets a later swap in a batch spend exactly what an earlier one produced:
///   [ V3 exactIn  USDC -> WETH   amountIn = 1000e6        recipient = ADDRESS_THIS ]
///   [ V4 exactIn  WETH -> ETH    amountIn = HELD_BALANCE  recipient = <user>       ]
/// Outside `batchSwap` neither value means anything: direct swaps reject `ADDRESS_THIS` as a
/// recipient, and an `amountIn` of zero is rejected by the pools.
library Chaining {
    /// @notice As a swap's `recipient`: keep the output in the proxy for a later swap of the same
    /// batch. Whatever a batch parks this way must be spent by the end of it, or the batch reverts.
    /// @dev The same value Uniswap's UniversalRouter uses for this purpose.
    address internal constant ADDRESS_THIS = address(2);

    /// @notice As an exact-input swap's `amountIn`: spend everything the proxy holds of the input
    /// token, i.e. what earlier swaps of the batch parked there. The proxy pays, not the caller.
    uint256 internal constant HELD_BALANCE = 0;
}
