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

/// @title Uniswap V3 + V4 proxy
/// @notice The deployable contract. Combines V3 liquidity provision, V3 swaps and V4 swaps behind a
/// single address, so integrators approve one contract rather than three.
/// @dev Composition only — every function lives in a mixin:
/// - {UniswapV3MintProxy}  mint + uniswapV3MintCallback
/// - {UniswapV3SwapProxy}  exactInputSingle / exactOutputSingle + uniswapV3SwapCallback
/// - {UniswapV4SwapProxy}  exactInputSingleV4 / exactOutputSingleV4 + unlockCallback
///
/// The mixins are abstract and declare no constructors so that the two V3 mixins can share
/// {UniswapV3ProxyBase} without its constructor arguments being supplied twice. That makes this
/// contract the only place base constructors are called.
///
/// Every path settles with `transferFrom(payer, ...)` where `payer` is always `msg.sender`, so an
/// approval granted to this address is usable by all five entry points. Keep that in mind when
/// adding another one.
contract UniswapProxy is UniswapV3MintProxy, UniswapV3SwapProxy, UniswapV4SwapProxy {
    constructor(
        address _uniV3Factory,
        address _poolManager
    )
        UniswapV3ProxyBase(_uniV3Factory)
        UniswapV4SwapProxy(_poolManager)
    {}
}
