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
import {UniswapV3ProxyBase} from "./base/UniswapV3ProxyBase.sol";
import {Multicall} from "./base/Multicall.sol";

/// @title Uniswap V3 + V4 proxy
/// @notice The deployable contract. Combines V3 liquidity provision, V3 swaps and V4 swaps behind a
/// single address, so integrators approve one contract rather than three. Swaps on either version
/// can be batched into one atomic transaction through `multicall`.
/// @dev Composition only — every function lives in a mixin:
/// - {UniswapV3MintProxy}  mint + uniswapV3MintCallback
/// - {UniswapV3SwapProxy}  exactInputSingle / exactOutputSingle + uniswapV3SwapCallback
/// - {UniswapV4SwapProxy}  exactInputSingleV4 / exactOutputSingleV4 + unlockCallback
/// - {Multicall}           multicall
///
/// The one thing decided here rather than in a mixin is which entry points `multicall` accepts
/// (`_isBatchable`), because this is the only contract that sees all of them.
///
/// The mixins are abstract and declare no constructors so that the two V3 mixins can share
/// {UniswapV3ProxyBase} without its constructor arguments being supplied twice. That makes this
/// contract the only place base constructors are called.
///
/// Every path settles with `transferFrom(payer, ...)` where `payer` is always `msg.sender`, so an
/// approval granted to this address is usable by all five entry points. Keep that in mind when
/// adding another one. `multicall` preserves `msg.sender` into each batched call, so batching does
/// not change who pays.
contract UniswapProxy is Multicall, UniswapV3MintProxy, UniswapV3SwapProxy, UniswapV4SwapProxy {
    constructor(
        address _uniV3Factory,
        address _poolManager
    )
        UniswapV3ProxyBase(_uniV3Factory)
        UniswapV4SwapProxy(_poolManager)
    {}

    /// @dev Swaps only, V3 and V4. Everything else is refused:
    /// - `mint` is out of scope for now. Batching it would be safe; it is excluded to keep the
    ///   batchable surface to swaps until LP batching is needed. Add its selector here to enable it.
    /// - The three pool callbacks would revert in a batch anyway, since `msg.sender` there is the
    ///   caller rather than a pool or the PoolManager. Listing them out makes that structural instead
    ///   of something to re-argue on every change.
    /// - `multicall` itself: nesting batches adds nothing.
    function _isBatchable(bytes4 selector) internal pure override returns (bool) {
        return selector == UniswapV3SwapProxy.exactInputSingle.selector
            || selector == UniswapV3SwapProxy.exactOutputSingle.selector
            || selector == UniswapV4SwapProxy.exactInputSingleV4.selector
            || selector == UniswapV4SwapProxy.exactOutputSingleV4.selector;
    }
}
