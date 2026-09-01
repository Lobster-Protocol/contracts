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

/// @title Uniswap V3 single-pool swaps
/// @notice Swaps directly against a V3 pool rather than routing through SwapRouter, paying for the
/// swap out of the caller's balance in the pool's callback.
/// @dev Abstract on purpose: this is a mixin combined into {UniswapProxy}, which owns the
/// constructor. Deploy {UniswapProxy} rather than this.
abstract contract UniswapV3SwapProxy is UniswapV3ProxyBase, IUniswapV3SwapCallback {
    /// @notice Swaps `amountIn` of one token for as much as possible of another token (single pool)
    function exactInputSingle(ExactInputSingleParams calldata params)
        external
        checkDeadline(params.deadline)
        returns (uint256 amountOut)
    {
        require(params.recipient != address(0));

        bool zeroForOne = params.tokenIn < params.tokenOut;

        (int256 amount0, int256 amount1) = _getPool(params.tokenIn, params.tokenOut, params.fee)
            .swap(
                params.recipient,
                zeroForOne,
                int256(params.amountIn),
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

    /// @notice Swaps as little as possible of one token for `amountOut` of another token (single pool)
    function exactOutputSingle(ExactOutputSingleParams calldata params)
        external
        checkDeadline(params.deadline)
        returns (uint256 amountIn)
    {
        require(params.recipient != address(0));

        bool zeroForOne = params.tokenIn < params.tokenOut;

        (int256 amount0, int256 amount1) = _getPool(params.tokenIn, params.tokenOut, params.fee)
            .swap(
                params.recipient,
                zeroForOne,
                -int256(params.amountOut),
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
