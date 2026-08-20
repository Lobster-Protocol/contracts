// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.20;

import {IUniswapV3MintCallback, MintParams, MintCallbackData} from "./interfaces/uniswapV3/IUniswapV3MintCallback.sol";
import {IUniswapV3PoolMinimal} from "./interfaces/uniswapV3/IUniswapV3PoolMinimal.sol";
import {TransferHelper} from "./libraries/uniswapV3/TransferHelper.sol";
import {PoolAddress} from "./libraries/uniswapV3/PoolAddress.sol";
import {TickMath} from "./libraries/uniswapV3/TickMath.sol";
import {LiquidityAmounts} from "./libraries/uniswapV3/LiquidityAmounts.sol";
import {CallbackValidation} from "./libraries/uniswapV3/CallbackValidation.sol";
import {UniswapV3ProxyBase} from "./base/UniswapV3ProxyBase.sol";

/// @title Uniswap V3 liquidity provision
/// @notice Mints a position directly on a V3 pool and pays for it from the caller's balance.
/// @dev Abstract on purpose: this is a mixin combined into {UniswapProxy}, which owns the
/// constructor. Deploy {UniswapProxy} rather than this.
abstract contract UniswapV3MintProxy is UniswapV3ProxyBase, IUniswapV3MintCallback {
    /// @notice Mints liquidity to a Uniswap V3 pool
    function mint(MintParams calldata params)
        external
        checkDeadline(params.deadline)
        returns (uint256 amount0, uint256 amount1)
    {
        require(params.recipient != address(0));

        PoolAddress.PoolKey memory poolKey =
            PoolAddress.PoolKey({token0: params.token0, token1: params.token1, fee: params.fee});

        // Get the pool address
        IUniswapV3PoolMinimal pool = IUniswapV3PoolMinimal(PoolAddress.computeAddress(UNI_V3_FACTORY, poolKey));

        // compute the liquidity amount
        uint128 liquidity;
        {
            (uint160 sqrtPriceX96,,,,,,) = pool.slot0();
            uint160 sqrtRatioAX96 = TickMath.getSqrtRatioAtTick(params.tickLower);
            uint160 sqrtRatioBX96 = TickMath.getSqrtRatioAtTick(params.tickUpper);

            liquidity = LiquidityAmounts.getLiquidityForAmounts(
                sqrtPriceX96, sqrtRatioAX96, sqrtRatioBX96, params.amount0Desired, params.amount1Desired
            );
        }

        (amount0, amount1) = pool.mint(
            params.recipient,
            params.tickLower,
            params.tickUpper,
            liquidity,
            abi.encode(MintCallbackData({poolKey: poolKey, payer: msg.sender}))
        );

        require(amount0 >= params.amount0Min && amount1 >= params.amount1Min, "Price slippage check");
    }

    function uniswapV3MintCallback(uint256 amount0Owed, uint256 amount1Owed, bytes calldata data) external override {
        MintCallbackData memory decoded = abi.decode(data, (MintCallbackData));

        // Make sure caller is a contract deployed by the Uniswap V3 factory
        CallbackValidation.verifyCallback(UNI_V3_FACTORY, decoded.poolKey);

        if (amount0Owed > 0) {
            TransferHelper.safeTransferFrom(decoded.poolKey.token0, decoded.payer, msg.sender, amount0Owed);
        }
        if (amount1Owed > 0) {
            TransferHelper.safeTransferFrom(decoded.poolKey.token1, decoded.payer, msg.sender, amount1Owed);
        }
    }
}
