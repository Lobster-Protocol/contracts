// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.27;

import {
    IUniswapV3SwapCallback,
    SwapCallbackData,
    ExactInputSingleParams,
    ExactOutputSingleParams
} from "./interfaces/uniswapV3/IUniswapV3SwapCallback.sol";
import {IUniswapV3PoolMinimal} from "./interfaces/uniswapV3/IUniswapV3PoolMinimal.sol";
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
/// Abstract on purpose: this is a mixin combined into {LobsterProxy}, which owns the
/// constructor. Deploy {LobsterProxy} rather than this.
abstract contract UniswapV3SwapProxy is UniswapV3ProxyBase, IUniswapV3SwapCallback {
    /// @notice Swaps `amountIn` of one token for as much as possible of another token (single pool)
    function exactInputSingle(ExactInputSingleParams calldata params)
        external
        virtual
        nonReentrant
        returns (uint256 amountOut)
    {
        _checkRecipient(params.recipient);
        return _exactInputSingle(params, msg.sender);
    }

    /// @notice Swaps as little as possible of one token for `amountOut` of another token (single pool)
    function exactOutputSingle(ExactOutputSingleParams calldata params)
        external
        virtual
        nonReentrant
        returns (uint256 amountIn)
    {
        _checkRecipient(params.recipient);
        return _exactOutputSingle(params, msg.sender);
    }

    /// @dev Body of {exactInputSingle}, shared with {UniswapBatchSwapProxy-batchSwap}. The caller of
    /// this body has already validated or resolved `params.recipient`. `payer` is the account the
    /// pool is paid from: `msg.sender`, or the proxy itself when a chained swap spends what an
    /// earlier swap in the batch produced.
    function _exactInputSingle(
        ExactInputSingleParams memory params,
        address payer
    )
        internal
        returns (uint256 amountOut)
    {
        _checkDeadline(params.deadline);

        bool zeroForOne = params.tokenIn < params.tokenOut;
        IUniswapV3PoolMinimal pool = _getPool(params.tokenIn, params.tokenOut, params.fee);

        _checkV3SwapPrice(pool);
        (int256 amount0, int256 amount1) = pool.swap(
            params.recipient,
            zeroForOne,
            SafeCast.toInt256(params.amountIn),
            params.sqrtPriceLimitX96 == 0
                ? (zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1)
                : params.sqrtPriceLimitX96,
            abi.encode(
                SwapCallbackData({tokenIn: params.tokenIn, tokenOut: params.tokenOut, fee: params.fee, payer: payer})
            )
        );
        _checkV3SwapPrice(pool);

        amountOut = uint256(-(zeroForOne ? amount1 : amount0));
        require(amountOut >= params.amountOutMinimum, TooLittleReceived());
    }

    /// @dev Body of {exactOutputSingle}, shared with {UniswapBatchSwapProxy-batchSwap}. Same contract
    /// for `params.recipient` and `payer` as {_exactInputSingle}.
    function _exactOutputSingle(
        ExactOutputSingleParams memory params,
        address payer
    )
        internal
        returns (uint256 amountIn)
    {
        _checkDeadline(params.deadline);

        bool zeroForOne = params.tokenIn < params.tokenOut;
        IUniswapV3PoolMinimal pool = _getPool(params.tokenIn, params.tokenOut, params.fee);

        _checkV3SwapPrice(pool);
        (int256 amount0, int256 amount1) = pool.swap(
            params.recipient,
            zeroForOne,
            -SafeCast.toInt256(params.amountOut),
            params.sqrtPriceLimitX96 == 0
                ? (zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1)
                : params.sqrtPriceLimitX96,
            abi.encode(
                SwapCallbackData({tokenIn: params.tokenIn, tokenOut: params.tokenOut, fee: params.fee, payer: payer})
            )
        );
        _checkV3SwapPrice(pool);

        amountIn = uint256(zeroForOne ? amount0 : amount1);
        require(amountIn <= params.amountInMaximum, TooMuchRequested());
        // A swap can stop early, on the price limit or when the pool runs out of liquidity, and
        // deliver less than requested. When the caller did not ask for a limit, that outcome is
        // never intended, so reject it. Same rule as SwapRouter and as the V4 path.
        if (params.sqrtPriceLimitX96 == 0) {
            require(uint256(-(zeroForOne ? amount1 : amount0)) == params.amountOut, TooLittleReceived());
        }
    }

    /// @dev Called with the pool right before and right after every swap, in the caller's frame
    /// (msg.sender is the account swapping). No check here; {LobsterProxy} enforces the caller's
    /// price band. A swap moves the price one way only, so a price inside the band at both ends means
    /// the whole trade executed inside it.
    function _checkV3SwapPrice(IUniswapV3PoolMinimal pool) internal view virtual {}

    /// @inheritdoc IUniswapV3SwapCallback
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata _data) external override {
        require(amount0Delta > 0 || amount1Delta > 0); // swaps entirely within 0-liquidity regions are not supported
        SwapCallbackData memory data = abi.decode(_data, (SwapCallbackData));
        CallbackValidation.verifyCallback(UNI_V3_FACTORY, data.tokenIn, data.tokenOut, data.fee);

        // casting to uint256 is safe because the require above guarantees at least one delta is positive,
        // and the ternary only casts the positive value
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 amountToPay = amount0Delta > 0 ? uint256(amount0Delta) : uint256(amount1Delta);
        // `payer` is the proxy only for a chained swap inside a batch, spending what an earlier swap
        // left here. The data is the proxy's own: `verifyCallback` proves a genuine pool is calling,
        // and a pool only calls back whoever called its `swap`, so this cannot be forged.
        if (data.payer == address(this)) TransferHelper.safeTransfer(data.tokenIn, msg.sender, amountToPay);
        else TransferHelper.safeTransferFrom(data.tokenIn, data.payer, msg.sender, amountToPay);
    }
}
