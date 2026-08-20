// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.20;

import {
    IPoolManagerMinimal,
    Currency,
    BalanceDelta,
    PoolKey,
    SwapParams
} from "./interfaces/uniswapV4/IPoolManagerMinimal.sol";
import {
    IUnlockCallback,
    V4SwapCallbackData,
    V4ExactInputSingleParams,
    V4ExactOutputSingleParams
} from "./interfaces/uniswapV4/IUnlockCallback.sol";
import {BalanceDeltaLibrary} from "./libraries/uniswapV4/BalanceDeltaLibrary.sol";
import {CurrencySettler} from "./libraries/uniswapV4/CurrencySettler.sol";
import {TransferHelper} from "./libraries/uniswapV3/TransferHelper.sol";
import {Deadline} from "./base/Deadline.sol";

/// @title Uniswap V4 single-pool swaps
/// @notice Exact input/output swaps against the Uniswap V4 PoolManager singleton.
/// @dev V4 differs from V3 in three ways that matter here:
/// - V3 pools are individual contracts derived by CREATE2, so callbacks are authenticated by
///   recomputing the pool address. V4 has one PoolManager singleton, so `msg.sender == POOL_MANAGER`
///   is the whole check.
/// - V3 calls back per-swap. V4 calls back once per `unlock`, and everything happens inside it.
/// - `amountSpecified` is positive for exact input in V3, but negative for exact input in V4.
///
/// HOOKED POOLS ARE NOT SUPPORTED. Only `poolKey.hooks == address(0)` is accepted. A hook executes
/// third-party code during the swap and may adjust the caller's balance delta
/// (`swapDelta = swapDelta - hookDelta`, see v4-core Hooks.sol). Restricting to hookless pools keeps
/// the swap paths as predictable as their v3 equivalents.
///
/// Abstract on purpose: this is a mixin combined into {UniswapProxy}. Deploy that rather than this.
abstract contract UniswapV4SwapProxy is Deadline, IUnlockCallback {
    using BalanceDeltaLibrary for BalanceDelta;
    using CurrencySettler for Currency;

    /// @dev v4-core renamed TickMath.MIN_SQRT_RATIO / MAX_SQRT_RATIO to MIN_SQRT_PRICE / MAX_SQRT_PRICE.
    /// Values are unchanged, so these match `TickMath` in libraries/uniswapV3.
    uint160 internal constant MIN_SQRT_PRICE = 4295128739;
    uint160 internal constant MAX_SQRT_PRICE = 1461446703485210103287273052203988822378723970342;

    IPoolManagerMinimal public immutable POOL_MANAGER;

    constructor(address _poolManager) {
        POOL_MANAGER = IPoolManagerMinimal(_poolManager);
    }

    /// @notice Swaps `amountIn` of one currency for as much as possible of another (single V4 pool)
    /// @dev Payable so that native-currency pools can be used directly, without wrapping to WETH.
    /// Any unspent ETH is refunded to msg.sender.
    function exactInputSingleV4(V4ExactInputSingleParams calldata params)
        external
        payable
        checkDeadline(params.deadline)
        returns (uint256 amountOut)
    {
        require(params.recipient != address(0));

        uint256 amountIn;
        // negative amountSpecified == exact input in v4
        (amountIn, amountOut) = _unlockAndSwap(
            params.poolKey,
            params.zeroForOne,
            -int256(uint256(params.amountIn)),
            params.sqrtPriceLimitX96,
            params.recipient
        );

        // Hookless pools consume at most the specified input, so this holds by construction. Kept as
        // a cheap assertion of the function's contract rather than as load-bearing protection.
        require(amountIn <= params.amountIn, "Too much requested");
        require(amountOut >= params.amountOutMinimum, "Too little received");

        _refundExcessNative();
    }

    /// @notice Swaps as little as possible of one currency for `amountOut` of another (single V4 pool)
    function exactOutputSingleV4(V4ExactOutputSingleParams calldata params)
        external
        payable
        checkDeadline(params.deadline)
        returns (uint256 amountIn)
    {
        require(params.recipient != address(0));

        uint256 amountOut;
        // positive amountSpecified == exact output in v4
        (amountIn, amountOut) = _unlockAndSwap(
            params.poolKey,
            params.zeroForOne,
            int256(uint256(params.amountOut)),
            params.sqrtPriceLimitX96,
            params.recipient
        );

        require(amountIn <= params.amountInMaximum, "Too much requested");
        // A swap can stop early on the price limit and deliver less than requested. When the caller
        // did not ask for a limit, that outcome is never intended, so reject it.
        if (params.sqrtPriceLimitX96 == 0) require(amountOut == params.amountOut, "Too little received");

        _refundExcessNative();
    }

    /// @inheritdoc IUnlockCallback
    /// @dev The only entry point the PoolManager uses. Runs the swap and nets both currency deltas
    /// back to zero, otherwise the manager reverts the whole unlock with `CurrencyNotSettled`.
    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        require(msg.sender == address(POOL_MANAGER), "Not pool manager");

        V4SwapCallbackData memory decoded = abi.decode(data, (V4SwapCallbackData));

        // Empty hookData: _unlockAndSwap only lets hookless pools through, so there is nothing to
        // pass it to.
        BalanceDelta delta = POOL_MANAGER.swap(decoded.poolKey, decoded.swapParams, "");

        (Currency inputCurrency, Currency outputCurrency) = decoded.swapParams.zeroForOne
            ? (decoded.poolKey.currency0, decoded.poolKey.currency1)
            : (decoded.poolKey.currency1, decoded.poolKey.currency0);

        (int128 inputDelta, int128 outputDelta) =
            decoded.swapParams.zeroForOne ? (delta.amount0(), delta.amount1()) : (delta.amount1(), delta.amount0());

        // A hookless pool always leaves us owing the input and owed the output. The casts below rely
        // on it, so assert rather than assume.
        require(inputDelta <= 0 && outputDelta >= 0, "Unexpected delta");

        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 amountIn = uint256(uint128(-inputDelta));
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 amountOut = uint256(uint128(outputDelta));

        if (amountIn > 0) inputCurrency.settle(POOL_MANAGER, decoded.payer, amountIn);
        if (amountOut > 0) outputCurrency.take(POOL_MANAGER, decoded.recipient, amountOut);

        return abi.encode(amountIn, amountOut);
    }

    /// @dev Shared body of the two V4 swap entry points: opens the unlock window and unpacks the
    /// result. Also the single choke point where hooked pools are rejected.
    function _unlockAndSwap(
        PoolKey calldata poolKey,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        address recipient
    )
        private
        returns (uint256 amountIn, uint256 amountOut)
    {
        // Everything downstream assumes a plain constant-product pool, so hooked pools are refused
        // here — the single choke point both entry points route through.
        require(address(poolKey.hooks) == address(0), "Hooks not supported");

        bytes memory result = POOL_MANAGER.unlock(
            abi.encode(
                V4SwapCallbackData({
                    poolKey: poolKey,
                    swapParams: SwapParams({
                        zeroForOne: zeroForOne,
                        amountSpecified: amountSpecified,
                        sqrtPriceLimitX96: sqrtPriceLimitX96 == 0
                            ? (zeroForOne ? MIN_SQRT_PRICE + 1 : MAX_SQRT_PRICE - 1)
                            : sqrtPriceLimitX96
                    }),
                    payer: msg.sender,
                    recipient: recipient
                })
            )
        );

        (amountIn, amountOut) = abi.decode(result, (uint256, uint256));
    }

    /// @dev Returns ETH that was sent in but not consumed by the swap.
    /// The proxy is not meant to hold a balance between calls (there is no `receive`), so anything
    /// left here at the end of a call is this caller's change.
    /// INVARIANT: this holds only while the contract has no `receive`, no `multicall`, and exactly
    /// one payable call path per transaction. Do not add any of those without revisiting this.
    function _refundExcessNative() private {
        uint256 balance = address(this).balance;
        if (balance > 0) TransferHelper.safeTransferETH(msg.sender, balance);
    }
}
