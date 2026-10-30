// SPDX-License-Identifier: GPL-3.0
// Exact pin, deliberately: the tests and the deploy must build the same bytecode, and with
// `via_ir = true` builds from different compilers are not interchangeable. 0.8.28, not 0.8.26: solc
// 0.8.26 crashes on this contract ("Assembly exception for bytecode"), fixed in 0.8.28, which the vault
// contracts use too. v4-core's PoolManager pins `=0.8.26`, so no file may import both it and this one;
// the tests deploy the PoolManager from its own artifact instead (test/Mocks/uniswapV4/PoolManagerBuild.sol).
pragma solidity =0.8.28;

import {UniswapV3MintProxy} from "./UniswapV3MintProxy.sol";
import {UniswapV3SwapProxy} from "./UniswapV3SwapProxy.sol";
import {UniswapV4SwapProxy} from "./UniswapV4SwapProxy.sol";
import {UniswapBatchSwapProxy, SwapType} from "./UniswapBatchSwapProxy.sol";
import {UniswapV3ProxyBase} from "./base/UniswapV3ProxyBase.sol";
import {PoolRegistry} from "./base/PoolRegistry.sol";
import {UniswapV4LiquidityProxy} from "./UniswapV4LiquidityProxy.sol";
import {Chaining} from "./libraries/Chaining.sol";
import {MintParams} from "./interfaces/uniswapV3/IUniswapV3MintCallback.sol";
import {ExactInputSingleParams, ExactOutputSingleParams} from "./interfaces/uniswapV3/IUniswapV3SwapCallback.sol";
import {V4ExactInputSingleParams, V4ExactOutputSingleParams} from "./interfaces/uniswapV4/IUnlockCallback.sol";
import {PoolAddress} from "./libraries/uniswapV3/PoolAddress.sol";
import {PoolKey} from "./interfaces/uniswapV4/IPoolManagerMinimal.sol";
import {IUniswapV3PoolMinimal} from "./interfaces/uniswapV3/IUniswapV3PoolMinimal.sol";

/// @title Lobster proxy
/// @notice A Uniswap V3 + V4 proxy for Lobster vaults only. A vault (a Safe) may mint and swap only on
/// the pools it has registered for itself in {PoolRegistry}, and only with itself as recipient. A
/// caller with no registration can do nothing.
/// @dev The deployable contract. Composition plus checks: every function lives in a mixin.
/// - {UniswapV3MintProxy}     mint + uniswapV3MintCallback
/// - {UniswapV3SwapProxy}     exactInputSingle / exactOutputSingle + uniswapV3SwapCallback
/// - {UniswapV4SwapProxy}     exactInputSingleV4 / exactOutputSingleV4 + unlockCallback + receive
/// - {UniswapBatchSwapProxy}  batchSwap, with chaining and chained V4 swaps sharing one unlock
/// - {PoolRegistry}           setPools, permissionsOf, poolsOf, setPriceBand, priceBandOf, v3Key, v4Key
/// - {UniswapV4LiquidityProxy} modifyLiquidityV4, setV4Roles, v4RolesOf, check (Roles condition), and
///                            the liquidity branch of unlockCallback (unlock data tagged 0x02)
/// The mixins are abstract and declare no constructors, so the two V3 mixins can share
/// {UniswapV3ProxyBase} without its arguments being supplied twice; this contract is the only place
/// base constructors are called. Every fund-moving entry point is overridden here to run the
/// registry checks before anything else, then the mixin's internal body unchanged. There is no
/// unchecked fund-moving entry point: the callbacks are only reachable by a genuine pool or the PoolManager during a call one of the checked
/// entry points made, and `receive` admits ETH from the PoolManager only.
///
/// THE CHECKS (deny by default):
/// - single swaps and `mint`: `recipient == msg.sender`, and the pool's key is registered for
///   `msg.sender` with the right bit (`PERMISSION_MINT` for `mint`, `PERMISSION_SWAP` for swaps);
///   `mint` also needs the pool's current tick inside the caller's price band for that key, and
///   every swap needs it both before and after the swap;
/// - `batchSwap`: one validation pass over the whole batch before anything executes. Every leg's pool
///   must be registered with `PERMISSION_SWAP`, and every leg's recipient must be `msg.sender` or
///   `Chaining.ADDRESS_THIS`. Each leg's pool price is then checked against the band like a single
///   swap's, before and after that leg. The batch then runs on the unchanged {UniswapBatchSwapProxy} code, whose
///   `FundsLeftInProxy` rule makes sure parked outputs are spent within the batch. Together, the
///   recipient rule and that rule mean a batch's outputs can only end up in the vault;
/// - `modifyLiquidityV4`: the caller's own Roles modifier must be configured; adding needs
///   `PERMISSION_MINT` on the pool's V4 key and the pool's current tick inside the caller's price
///   band for it; removing and collecting need nothing, so a vault can always exit. Positions are the vault's own, proceeds go to the vault only.
/// Reverts are custom errors, all declared in {IProxyErrors}.
///
/// WHO PAYS. Every swap or mint is paid by `msg.sender` (an internal call inside `batchSwap` does not
/// change it), so an approval granted to this address is usable only by the account that granted it.
/// The single exception is a chained swap inside `batchSwap` (`amountIn = Chaining.HELD_BALANCE`),
/// which the proxy pays from what earlier swaps of the same batch parked here. Keep both in mind when
/// adding an entry point.
///
/// STATE AND FUNDS. Persistent storage: the pool registry (permissions and price bands) and each
/// vault's V4 Roles configuration.
/// Funds: none between transactions. Mid-batch it may hold parked outputs, which the batch must spend
/// before returning, and during `modifyLiquidityV4` the vault's msg.value; every entry point is
/// `nonReentrant`, so nothing can reach either meanwhile. Tokens transferred to
/// it directly, outside the entry points, belong to no one and are spent by the next `HELD_BALANCE`
/// leg in that token (see KNOWN BEHAVIOURS).
///
/// HOW A VAULT USES IT.
/// - The vault's owners register its pools with `setPools` and, for pools it adds liquidity to, set
///   their price bands with `setPriceBand`. For V4 liquidity they also configure its Roles
///   modifier and this contract's role on it with `setV4Roles`, from the Safe itself.
/// - The executor operates the vault through Zodiac Roles. Roles must allow the executor ONLY `mint`,
///   `exactInputSingle`, `exactOutputSingle`, `exactInputSingleV4`, `exactOutputSingleV4`,
///   `batchSwap` and `modifyLiquidityV4` on this contract. NEVER `setPools`, `setPriceBand` or
///   `setV4Roles`: an executor allowed to call them could register any pool for the vault, or widen
///   a band until it protects nothing. The V4 single swaps and
///   `modifyLiquidityV4` are payable; Roles must allow `value` on them only if the vault should pay
///   native ETH.
/// - This contract itself holds a dedicated role on each vault's modifier, for V4 liquidity only; see
///   {UniswapV4LiquidityProxy} for exactly what that role must allow.
/// - LP positions belong to the vault. V3: the recipient, always the vault, owns the position inside
///   the pool; `burn`/`collect` are made by the vault directly on the pool. V4: the vault itself is
///   the position's owner in the PoolManager, and exits through `modifyLiquidityV4`.
///
/// SWAPS. Exact input and exact output, on V3 and V4, singly or in a batch (types 0x01-0x04). An
/// exact-output swap without a price limit must deliver the full `amountOut` or it reverts, so a
/// pool running dry cannot spend `amountInMaximum` on a partial fill.
///
/// KNOWN BEHAVIOURS, inherited from {UniswapBatchSwapProxy}:
/// - a `HELD_BALANCE` leg spends everything the proxy holds of its input, including tokens or ETH that
///   reached the proxy outside the entry points (a direct transfer, a selfdestruct);
/// - `batchSwap` is not payable: in a batch, native ETH can only be input as a parked V4 output.
///
/// PRICES. Adding liquidity and swapping are refused outside the vault's price band for the pool (see
/// {PoolRegistry}): no band, no mint and no swap. A swap is checked before and after it runs, and a
/// swap moves the price one way only, so every part of it executes at a price inside the band. A
/// vault cannot be made to deposit or trade at a price outside the range its owners chose; within the
/// band, the caller's own slippage bounds still apply. Removing liquidity and collecting fees ignore
/// bands, so a vault can always exit.
contract LobsterProxy is
    UniswapV3MintProxy,
    UniswapV3SwapProxy,
    UniswapV4SwapProxy,
    UniswapBatchSwapProxy,
    PoolRegistry,
    UniswapV4LiquidityProxy
{
    constructor(
        address _uniV3Factory,
        address _poolManager
    )
        UniswapV3ProxyBase(_uniV3Factory)
        UniswapV4SwapProxy(_poolManager)
    {}

    // ---------------------------------------------------------------------------------------------
    // V3
    // ---------------------------------------------------------------------------------------------

    /// @notice Mints liquidity on a V3 pool the caller registered with `PERMISSION_MINT`, to the caller
    /// @dev See {UniswapV3MintProxy-mint} for how the position is owned and withdrawn
    function mint(MintParams calldata params)
        external
        override
        nonReentrant
        returns (uint256 amount0, uint256 amount1)
    {
        _requireRecipientIsCaller(params.recipient);
        address pool = PoolAddress.computeAddress(
            UNI_V3_FACTORY, PoolAddress.PoolKey({token0: params.token0, token1: params.token1, fee: params.fee})
        );
        bytes32 key = v3Key(pool);
        _requirePermission(key, PERMISSION_MINT);
        (, int24 tick,,,,,) = IUniswapV3PoolMinimal(pool).slot0();
        _requireInPriceBand(msg.sender, key, tick);
        _checkDeadline(params.deadline);
        return _mint(params);
    }

    /// @notice Exact-input swap on a V3 pool the caller registered with `PERMISSION_SWAP`, to the caller
    function exactInputSingle(ExactInputSingleParams calldata params)
        external
        override
        nonReentrant
        returns (uint256 amountOut)
    {
        _requireRecipientIsCaller(params.recipient);
        _requirePermission(_v3PoolKey(params.tokenIn, params.tokenOut, params.fee), PERMISSION_SWAP);
        return _exactInputSingle(params, msg.sender);
    }

    /// @notice Exact-output swap on a V3 pool the caller registered with `PERMISSION_SWAP`, to the caller
    function exactOutputSingle(ExactOutputSingleParams calldata params)
        external
        override
        nonReentrant
        returns (uint256 amountIn)
    {
        _requireRecipientIsCaller(params.recipient);
        _requirePermission(_v3PoolKey(params.tokenIn, params.tokenOut, params.fee), PERMISSION_SWAP);
        return _exactOutputSingle(params, msg.sender);
    }

    // ---------------------------------------------------------------------------------------------
    // V4
    // ---------------------------------------------------------------------------------------------

    /// @notice Exact-input swap on a V4 pool the caller registered with `PERMISSION_SWAP`, to the caller
    /// @dev Payable for native-ETH pools; unspent ETH is refunded to the caller. Hooked pools are
    /// refused even if registered.
    function exactInputSingleV4(V4ExactInputSingleParams calldata params)
        external
        payable
        override
        nonReentrant
        returns (uint256 amountOut)
    {
        _requireRecipientIsCaller(params.recipient);
        _requirePermission(_v4Key(params.poolKey), PERMISSION_SWAP);
        amountOut = _exactInputSingleV4(params, msg.sender);
        _refundExcessNative();
    }

    /// @notice Exact-output swap on a V4 pool the caller registered with `PERMISSION_SWAP`, to the caller
    /// @dev Payable for native-ETH pools; unspent ETH is refunded to the caller. Hooked pools are
    /// refused even if registered.
    function exactOutputSingleV4(V4ExactOutputSingleParams calldata params)
        external
        payable
        override
        nonReentrant
        returns (uint256 amountIn)
    {
        _requireRecipientIsCaller(params.recipient);
        _requirePermission(_v4Key(params.poolKey), PERMISSION_SWAP);
        amountIn = _exactOutputSingleV4(params, msg.sender);
        _refundExcessNative();
    }

    // ---------------------------------------------------------------------------------------------
    // Batches
    // ---------------------------------------------------------------------------------------------

    /// @notice Runs a batch of V3 and V4 swaps, optionally chained, after checking every leg
    /// @dev Validates the whole batch first, then runs the unchanged {UniswapBatchSwapProxy} logic.
    /// Nothing executes, no swap and no PoolManager unlock, unless every leg passes.
    function batchSwap(bytes[] calldata swaps) external override nonReentrant returns (uint256[] memory amounts) {
        _validateBatch(swaps);
        return _batchSwap(swaps);
    }

    /// @dev For every leg: the pool must be registered for the caller with `PERMISSION_SWAP`, and the
    /// recipient must be the caller or `Chaining.ADDRESS_THIS`. Items are decoded with the same
    /// functions execution uses, so validation and execution cannot read a leg differently. Malformed
    /// items revert here exactly as they would during execution.
    function _validateBatch(bytes[] calldata swaps) private view {
        for (uint256 i = 0; i < swaps.length; i++) {
            bytes calldata item = swaps[i];
            uint8 swapType = _swapType(item);
            bytes32 key;
            address recipient;
            if (swapType == SwapType.V3_EXACT_INPUT) {
                ExactInputSingleParams memory p = _decodeV3ExactInput(item);
                (key, recipient) = (_v3PoolKey(p.tokenIn, p.tokenOut, p.fee), p.recipient);
            } else if (swapType == SwapType.V3_EXACT_OUTPUT) {
                ExactOutputSingleParams memory p = _decodeV3ExactOutput(item);
                (key, recipient) = (_v3PoolKey(p.tokenIn, p.tokenOut, p.fee), p.recipient);
            } else if (swapType == SwapType.V4_EXACT_INPUT) {
                V4ExactInputSingleParams memory p = _decodeV4ExactInput(item);
                (key, recipient) = (_v4Key(p.poolKey), p.recipient);
            } else if (swapType == SwapType.V4_EXACT_OUTPUT) {
                V4ExactOutputSingleParams memory p = _decodeV4ExactOutput(item);
                (key, recipient) = (_v4Key(p.poolKey), p.recipient);
            } else {
                revert InvalidSwapType();
            }
            _requirePermission(key, PERMISSION_SWAP);
            require(recipient == msg.sender || recipient == Chaining.ADDRESS_THIS, RecipientMustBeCaller());
        }
    }

    /// @dev Every V3 swap, single or batch leg: the pool's price must be inside the caller's band.
    /// Runs in the caller's frame, so msg.sender is the vault.
    function _checkV3SwapPrice(IUniswapV3PoolMinimal pool) internal view override {
        (, int24 tick,,,,,) = pool.slot0();
        _requireInPriceBand(msg.sender, v3Key(address(pool)), tick);
    }

    /// @dev Every V4 swap, single or chain leg: the pool's price must be inside `account`'s band
    function _checkV4SwapPrice(address account, PoolKey memory poolKey) internal view override {
        bytes32 poolId = _v4Key(poolKey);
        _requireInPriceBand(account, poolId, _currentTick(poolId));
    }

    /// @dev The registry key of the V3 pool a swap uses: the address the swap derives from
    /// (factory, sorted tokens, fee), exactly as {UniswapV3ProxyBase-_getPool} does for execution
    function _v3PoolKey(address tokenIn, address tokenOut, uint24 fee) private view returns (bytes32) {
        return v3Key(address(_getPool(tokenIn, tokenOut, fee)));
    }
}
