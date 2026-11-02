// SPDX-License-Identifier: GPL-3.0
// Exact pin, deliberately: the tests and the deploy must build the same bytecode, and with
// `via_ir = true` builds from different compilers are not interchangeable. 0.8.28, not 0.8.26: solc
// 0.8.26 crashes on this contract ("Assembly exception for bytecode"), fixed in 0.8.28, which the vault
// contracts use too. v4-core's PoolManager pins `=0.8.26`, so no file may import both it and this one;
// the tests deploy the PoolManager from its own artifact instead (test/Mocks/uniswapV4/PoolManagerBuild.sol).
pragma solidity =0.8.28;

import {UniswapV3MintProxy} from "./UniswapV3MintProxy.sol";
import {UniswapSwapProxy} from "./UniswapSwapProxy.sol";
import {UniswapV4LiquidityProxy} from "./UniswapV4LiquidityProxy.sol";
import {UniswapV3ProxyBase} from "./base/UniswapV3ProxyBase.sol";
import {PoolManagerBase} from "./base/PoolManagerBase.sol";
import {MintParams} from "./interfaces/uniswapV3/IUniswapV3MintCallback.sol";
import {PoolAddress} from "./libraries/uniswapV3/PoolAddress.sol";

/// @title Lobster proxy
/// @notice A Uniswap V3 + V4 proxy for Lobster vaults only. A vault (a Safe) may mint and swap only on
/// the pools it has registered for itself in {PoolRegistry}, and only for itself. A caller with no
/// registration can do nothing.
/// @dev The deployable contract. Composition plus the V3 mint entry point:
/// - {UniswapSwapProxy}        swap (V3 and V4, single or chained, packed calldata) + uniswapV3SwapCallback
/// - {UniswapV3MintProxy}      the body of mint + uniswapV3MintCallback
/// - {UniswapV4LiquidityProxy} modifyLiquidityV4, setV4Roles, v4RolesOf, check (Roles condition)
/// - {PoolRegistry}            setPools, permissionsOf, poolsOf, setPriceBand, priceBandOf, v3Key, v4Key
/// - {PoolManagerBase}         unlockCallback, dispatching swap and liquidity unlocks
/// The mixins are abstract; this contract is the only place base constructors are called. Every
/// fund-moving entry point checks the registry before it moves anything: the callbacks are only
/// reachable by a genuine pool or the PoolManager during a call one of the checked entry points made.
///
/// THE CHECKS (deny by default):
/// - `swap`: every leg's pool must be registered for `msg.sender` with `PERMISSION_SWAP`, and the
///   pool's current tick must be inside the caller's price band for it both before and after the
///   leg. Outputs go to `msg.sender` or stay parked for a later leg of the same call, and whatever is
///   parked must be spent by its end (`FundsLeftInProxy`): a call's outputs can only end up in the
///   vault;
/// - `mint`: `recipient == msg.sender`, the pool registered with `PERMISSION_MINT` and its current
///   tick inside the caller's price band;
/// - `modifyLiquidityV4`: the caller's own Roles modifier must be configured; adding needs
///   `PERMISSION_MINT` on the pool's V4 key and the pool's current tick inside the caller's price
///   band for it; removing and collecting need nothing, so a vault can always exit. Positions are the
///   vault's own, proceeds go to the vault only.
/// Reverts are custom errors, all declared in {IProxyErrors}.
///
/// WHO PAYS. Every swap or mint is paid by `msg.sender` of the entry point, at any call depth (the
/// callbacks read it from the reentrancy lock), so an approval granted to this address is usable only
/// by the account that granted it. The single exception is a HELD leg of a `swap` call, which the
/// proxy pays from what earlier legs of the same call parked, and only that. Keep both in mind when
/// adding an entry point.
///
/// STATE AND FUNDS. Persistent storage: the pool registry (permissions and price bands) and each
/// vault's V4 Roles configuration. Funds: none between transactions. During a `swap` call it may hold,
/// or be owed by the PoolManager, parked outputs, which the call must spend before returning, and the
/// caller's msg.value; during `modifyLiquidityV4` the vault's msg.value; every entry point is
/// `nonReentrant`, so nothing can reach either meanwhile. Native input is paid from the caller's
/// msg.value only, and only what is left of it is refunded: ETH force-fed to the proxy between calls
/// belongs to no one and is neither spent nor refunded. Tokens transferred to it directly belong to no
/// one either; see {UniswapSwapProxy} KNOWN BEHAVIOURS for the one-sided fee token that can spend them.
///
/// HOW A VAULT USES IT.
/// - The vault's owners register its pools with `setPools` and set their price bands with
///   `setPriceBand`. For V4 liquidity they also configure its Roles modifier and this contract's role
///   on it with `setV4Roles`, from the Safe itself.
/// - The executor operates the vault through Zodiac Roles. Roles must allow the executor ONLY `swap`,
///   `mint` and `modifyLiquidityV4` on this contract. NEVER `setPools`, `setPriceBand` or
///   `setV4Roles`: an executor allowed to call them could register any pool for the vault, or widen
///   a band until it protects nothing. `swap` and `modifyLiquidityV4` are payable; Roles must allow
///   `value` on them only if the vault should pay native ETH.
/// - This contract itself holds a dedicated role on each vault's modifier, for V4 liquidity only; see
///   {UniswapV4LiquidityProxy} for exactly what that role must allow.
/// - Register only pools whose tokens run no outside code in their transfers: such a token could
///   trade against the vault's other legs from inside its own `swap` call ({UniswapSwapProxy}, KNOWN
///   BEHAVIOURS); every leg's bound still applies.
/// - LP positions belong to the vault. V3: the recipient, always the vault, owns the position inside
///   the pool; `burn`/`collect` are made by the vault directly on the pool. V4: the vault itself is
///   the position's owner in the PoolManager, and exits through `modifyLiquidityV4`.
///
/// PRICES. Adding liquidity and swapping are refused outside the vault's price band for the pool (see
/// {PoolRegistry}): no band, no mint and no swap. A swap leg is checked before and after it runs, and
/// a swap moves the price one way only, so every part of it executes at a price inside the band. A
/// vault cannot be made to deposit or trade at a price outside the range its owners chose; within the
/// band, the caller's own slippage bounds still apply. Removing liquidity and collecting fees ignore
/// bands, so a vault can always exit.
contract LobsterProxy is UniswapV3MintProxy, UniswapSwapProxy, UniswapV4LiquidityProxy {
    constructor(
        address _uniV3Factory,
        address _poolManager
    )
        UniswapV3ProxyBase(_uniV3Factory)
        PoolManagerBase(_poolManager)
    {}

    /// @notice Mints liquidity on a V3 pool the caller registered with `PERMISSION_MINT`, to the caller
    /// @dev See {UniswapV3MintProxy-_mint} for how the position is owned and withdrawn
    function mint(MintParams calldata params) external nonReentrant returns (uint256 amount0, uint256 amount1) {
        require(params.recipient == msg.sender, RecipientMustBeCaller());
        address pool = PoolAddress.computeAddress(
            UNI_V3_FACTORY, PoolAddress.PoolKey({token0: params.token0, token1: params.token1, fee: params.fee})
        );
        (int24 minTick, int24 maxTick) = _requireAllowed(msg.sender, v3Key(pool), PERMISSION_MINT);
        (, int24 tick) = _slot0(pool);
        _requireInBand(tick, minTick, maxTick);
        _checkDeadline(params.deadline);
        return _mint(params);
    }
}
