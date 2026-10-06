// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.20;

import {
    IUniswapV3SwapCallback,
    SwapCallbackData,
    ExactInputSingleParams,
    ExactOutputSingleParams
} from "./interfaces/uniswapV3/IUniswapV3SwapCallback.sol";
import {TransferHelper} from "./libraries/uniswapV3/TransferHelper.sol";
import {TickMath} from "./libraries/uniswapV3/TickMath.sol";
import {CallbackValidation} from "./libraries/uniswapV3/CallbackValidation.sol";
import {UniswapV3ProxyBase} from "./base/UniswapV3ProxyBase.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @title Uniswap V3 single-pool swaps
/// @notice Swaps directly against a V3 pool rather than routing through SwapRouter, paying for the
/// swap out of the caller's balance in the pool's callback.
/// @dev Calling pools directly means taking on SwapRouter's job of turning the pool's low-level
/// `swap` into the guarantees the entry point names promise. Two of those live here:
/// - Amounts are converted to `int256` with a checked cast. A plain `int256(x)` wraps at 2**255,
///   and in V3 the sign of `amountSpecified` selects exact-input vs exact-output, so a wrapped
///   amount silently turns one into the other.
/// - An exact-output swap without a price limit must deliver the full `amountOut`. A pool stops
///   early when it runs out of liquidity; accepting that partial fill would let `amountInMaximum`
///   be spent on a fraction of the order.
///
/// Abstract on purpose: this is a mixin combined into {UniswapProxy}, which owns the
/// constructor. Deploy {UniswapProxy} rather than this.
abstract contract UniswapV3SwapProxy is UniswapV3ProxyBase, IUniswapV3SwapCallback {
    /// @notice Swaps `amountIn` of one token for as much as possible of another token (single pool)
    function exactInputSingle(ExactInputSingleParams calldata params) external returns (uint256 amountOut) {
        return _exactInputSingle(params);
    }

    /// @notice Swaps as little as possible of one token for `amountOut` of another token (single pool)
    function exactOutputSingle(ExactOutputSingleParams calldata params) external returns (uint256 amountIn) {
        return _exactOutputSingle(params);
    }

    /// @dev Body of {exactInputSingle}, shared with {UniswapBatchSwapProxy-batchSwap}. Pays from
    /// `msg.sender`, which an internal call leaves unchanged, so both paths charge their own caller.
    function _exactInputSingle(ExactInputSingleParams memory params) internal returns (uint256 amountOut) {
        _checkDeadline(params.deadline);
        require(params.recipient != address(0));
        // Nothing can move tokens or positions out of the proxy again, so sending them here loses them
        require(params.recipient != address(this), "Invalid recipient");

        bool zeroForOne = params.tokenIn < params.tokenOut;

        (int256 amount0, int256 amount1) = _getPool(params.tokenIn, params.tokenOut, params.fee)
            .swap(
                params.recipient,
                zeroForOne,
                SafeCast.toInt256(params.amountIn),
                params.sqrtPriceLimitX96 == 0
                    ? (zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1)
                    : params.sqrtPriceLimitX96,
                abi.encode(
                    SwapCallbackData({
                        tokenIn: params.tokenIn, tokenOut: params.tokenOut, fee: params.fee, payer: msg.sender
                    })
                )
            );

        amountOut = uint256(-(zeroForOne ? amount1 : amount0));
        require(amountOut >= params.amountOutMinimum, "Too little received");
    }

    /// @dev Body of {exactOutputSingle}, shared with {UniswapBatchSwapProxy-batchSwap}
    function _exactOutputSingle(ExactOutputSingleParams memory params) internal returns (uint256 amountIn) {
        _checkDeadline(params.deadline);
        require(params.recipient != address(0));
        // Nothing can move tokens or positions out of the proxy again, so sending them here loses them
        require(params.recipient != address(this), "Invalid recipient");

        bool zeroForOne = params.tokenIn < params.tokenOut;

        (int256 amount0, int256 amount1) = _getPool(params.tokenIn, params.tokenOut, params.fee)
            .swap(
                params.recipient,
                zeroForOne,
                -SafeCast.toInt256(params.amountOut),
                params.sqrtPriceLimitX96 == 0
                    ? (zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1)
                    : params.sqrtPriceLimitX96,
                abi.encode(
                    SwapCallbackData({
                        tokenIn: params.tokenIn, tokenOut: params.tokenOut, fee: params.fee, payer: msg.sender
                    })
                )
            );

        amountIn = uint256(zeroForOne ? amount0 : amount1);
        require(amountIn <= params.amountInMaximum, "Too much requested");
        // A swap can stop early, on the price limit or when the pool runs out of liquidity, and
        // deliver less than requested. When the caller did not ask for a limit, that outcome is
        // never intended, so reject it. Same rule as SwapRouter and as the V4 path.
        if (params.sqrtPriceLimitX96 == 0) {
            require(uint256(-(zeroForOne ? amount1 : amount0)) == params.amountOut, "Too little received");
        }
    }

    /// @inheritdoc IUniswapV3SwapCallback
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata _data) external override {
        require(amount0Delta > 0 || amount1Delta > 0); // swaps entirely within 0-liquidity regions are not supported
        SwapCallbackData memory data = abi.decode(_data, (SwapCallbackData));
        CallbackValidation.verifyCallback(UNI_V3_FACTORY, data.tokenIn, data.tokenOut, data.fee);

        // casting to uint256 is safe because the require above guarantees at least one delta is positive,
        // and the ternary only casts the positive value
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 amountToPay = amount0Delta > 0 ? uint256(amount0Delta) : uint256(amount1Delta);
        TransferHelper.safeTransferFrom(data.tokenIn, data.payer, msg.sender, amountToPay);
    }
}
