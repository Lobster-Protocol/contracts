// SPDX-License-Identifier: GPL-3.0
// Exact pin, deliberately. v4-core's PoolManager pins `=0.8.26`, so any test exercising a real
// PoolManager compiles this contract at 0.8.26. A floating pragma here let the deploy build resolve
// to 0.8.28 instead, meaning the tests validated bytecode that would never ship. With `via_ir = true`
// those two builds are not interchangeable. Pinning makes the tested and deployed artifact identical.
// Consequence: a file importing this one cannot require a different exact version. The vault
// contracts pin `=0.8.28`, which is fine only because nothing imports both them and this — the two
// dependency graphs are disjoint, so they never share a compilation unit. Anything that needs both
// would have to bring the vaults down to `=0.8.26`, since v4-core's pin is not negotiable.
pragma solidity =0.8.26;

import {UniswapV3MintProxy} from "./UniswapV3MintProxy.sol";
import {UniswapV3SwapProxy} from "./UniswapV3SwapProxy.sol";
import {UniswapV4SwapProxy} from "./UniswapV4SwapProxy.sol";
import {UniswapBatchSwapProxy} from "./UniswapBatchSwapProxy.sol";
import {UniswapV3ProxyBase} from "./base/UniswapV3ProxyBase.sol";

/// @title Uniswap V3 + V4 proxy
/// @notice The deployable contract. Combines V3 liquidity provision, V3 swaps and V4 swaps behind a
/// single address, so integrators approve one contract rather than three. Any mix of V3 and V4 swaps
/// can also be run as one atomic batch, chained so that a swap spends what the previous one produced.
/// @dev Composition only — every function lives in a mixin:
/// - {UniswapV3MintProxy}     mint + uniswapV3MintCallback
/// - {UniswapV3SwapProxy}     exactInputSingle / exactOutputSingle + uniswapV3SwapCallback
/// - {UniswapV4SwapProxy}     exactInputSingleV4 / exactOutputSingleV4 + unlockCallback + receive
/// - {UniswapBatchSwapProxy}  batchSwap: any sequence of the four swaps above, optionally chained
/// Shared checks (deadline, recipient, reentrancy lock) live in {Guards}.
///
/// The mixins are abstract and declare no constructors so that the two V3 mixins can share
/// {UniswapV3ProxyBase} without its constructor arguments being supplied twice. That makes this
/// contract the only place base constructors are called.
///
/// WHO PAYS. Every swap or mint is paid by `msg.sender` (an internal call inside `batchSwap` does not
/// change it), so an approval granted to this address is usable by all six entry points, and only by
/// the account that granted it. The single exception is a chained swap inside `batchSwap`
/// (`amountIn = Chaining.HELD_BALANCE`), which the proxy pays from what earlier swaps of the same
/// batch parked here. Keep both in mind when adding an entry point.
///
/// WHAT THE PROXY HOLDS. Nothing, between transactions. Mid-batch it may hold parked outputs, which
/// the batch must spend before returning, and every entry point is `nonReentrant` so nothing can
/// reach them meanwhile. Caller-supplied recipients may not be the proxy itself (nothing could move
/// the funds out again) or `Chaining.ADDRESS_THIS` outside a batch. Tokens transferred to it
/// directly, outside these entry points, belong to no one and are spent by the next swap that uses
/// `HELD_BALANCE` for that token.
///
/// LP positions from `mint` are owned by their recipient directly in the pool, with no NFT, and only
/// that recipient can ever withdraw them. A recipient that cannot call the pool's `burn` and
/// `collect` locks the liquidity forever; see {UniswapV3MintProxy-mint}.
contract UniswapProxy is UniswapV3MintProxy, UniswapV3SwapProxy, UniswapV4SwapProxy, UniswapBatchSwapProxy {
    constructor(
        address _uniV3Factory,
        address _poolManager
    )
        UniswapV3ProxyBase(_uniV3Factory)
        UniswapV4SwapProxy(_poolManager)
    {}
}
