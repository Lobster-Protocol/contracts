// SPDX-License-Identifier: GNUv3
pragma solidity ^0.8.28;

import {IUniswapV3PoolMinimal} from "../interfaces/uniswapV3/IUniswapV3PoolMinimal.sol";
import {INonfungiblePositionManager} from "../interfaces/uniswapV3/INonfungiblePositionManager.sol";
import {PoolAddress} from "../utils/uniswapV3Lib/PoolAddress.sol";
import {TickMath} from "../utils/uniswapV3Lib/TickMath.sol";
import {UniswapV3MathLib} from "../utils/uniswapV3Lib/UniswapV3MathLib.sol";

struct Position {
    address token;
    uint256 value;
}

library UniswapUtils {
    // Constant for 2^96
    uint256 private constant Q96 = 2 ** 96;
    int24 private constant MIN_TICK = -887272;
    int24 private constant MAX_TICK = 887272;

    /**
     * @notice Converts sqrtPriceX96 to price
     * @param sqrtPriceX96 The sqrt price in X96 format from Uniswap V3
     * @return price The price of token1 in terms of token0
     */
    function sqrtPriceX96ToPrice(
        uint160 sqrtPriceX96
    ) public pure returns (uint256 price) {
        // Calculate price = (sqrtPriceX96)^2 / 2^192
        return (uint256(sqrtPriceX96) * uint256(sqrtPriceX96)) / (Q96 * Q96);
    }

    /**
     * @notice Fetches and calculates the time-weighted average price (TWAP) from a Uniswap V3 pool
     * @param pool The Uniswap V3 pool
     * @param secondsAgo The number of seconds in the past to start calculating the TWAP
     * @return twapPrice The time-weighted average price of token1 in terms of token0
     */
    function getTwap(
        IUniswapV3PoolMinimal pool,
        uint32 secondsAgo
    ) public view returns (uint256 twapPrice) {
        // Ensure secondsAgo is not zero to prevent division by zero
        require(secondsAgo > 0, "Period must be greater than 0");

        // Create array with two time points: now and secondsAgo seconds ago
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = secondsAgo;
        secondsAgos[1] = 0; // now

        // Get cumulative ticks at both time points
        (int56[] memory tickCumulatives, ) = pool.observe(secondsAgos);

        // const diffTickCumulative = observations[0].tickCumulative - observations[1].tickCumulative
        // const secondsBetween = 108

        // const averageTick = diffTickCumulative / secondsBetween

        int56 diffTickCumulative = tickCumulatives[0] - tickCumulatives[1];

        require(
            uint56(secondsAgo) <= uint56(type(int56).max),
            "secondsAgo out of range for int56"
        );

        int56 averageTick = diffTickCumulative / int56(int32(secondsAgo));

        twapPrice = tickToPrice(averageTick);
    }

    /**
     * @notice Converts a tick to a price
     * @param tick The tick to convert
     * @return price The price as a Q96 fixed-point number
     */
    function tickToPrice(int56 tick) public pure returns (uint256 price) {
        // Ensure the tick is within the valid range
        require(tick >= MIN_TICK && tick <= MAX_TICK, "Tick out of range");

        // Need to convert to a valid int24 for actual implementation
        int24 adjustedTick = int24(tick);

        // If tick is negative, we need to calculate 1 / (1.0001^abs(tick))
        if (tick < 0) {
            // We use the formula 1 / (1.0001^abs(tick))
            return
                sqrtPriceX96ToPrice(TickMath.getSqrtRatioAtTick(-adjustedTick));
        } else {
            // If tick is positive or zero, we calculate 1.0001^tick directly
            return
                sqrtPriceX96ToPrice(TickMath.getSqrtRatioAtTick(adjustedTick));
        }
    }

    // Get total value locked in Uniswap V3 for a specific address in a specific pool
    function getUniswapV3Positions(
        IUniswapV3PoolMinimal pool,
        INonfungiblePositionManager positionManager,
        address user,
        address poolToken0,
        address poolToken1
    )
        public
        view
        returns (Position memory position0, Position memory position1)
    {
        uint256 balance = positionManager.balanceOf(user);
        (, int24 currentTick, , , , , ) = pool.slot0();

        position0 = Position({token: poolToken0, value: 0});
        position1 = Position({token: poolToken1, value: 0});

        // todo: if possible, use the pool instead of the positionManager
        for (uint256 i = 0; i < balance; i++) {
            // Get the tokenId for each of the user's positions
            uint256 tokenId = positionManager.tokenOfOwnerByIndex(user, i);

            // Retrieve position details
            (
                ,
                ,
                address token0,
                address token1,
                uint24 fee,
                int24 tickLower,
                int24 tickUpper,
                uint128 liquidity,
                ,
                ,
                uint256 tokensOwed0, // fees token 0
                uint256 tokensOwed1 // fees token 1
            ) = positionManager.positions(tokenId);

            // Get the pool address
            PoolAddress.PoolKey memory key = PoolAddress.getPoolKey(
                token0,
                token1,
                fee
            );

            address computedPoolAddress = PoolAddress.computeAddress(
                pool.factory(),
                key
            );

            if (computedPoolAddress == address(pool)) {
                uint160 sqrtPriceA = TickMath.getSqrtRatioAtTick(tickLower);
                uint160 sqrtPriceB = TickMath.getSqrtRatioAtTick(tickUpper);
                uint160 sqrtPriceCurrent = TickMath.getSqrtRatioAtTick(
                    currentTick
                );

                uint256 amount0 = UniswapV3MathLib.getToken0FromLiquidity(
                    liquidity,
                    sqrtPriceCurrent,
                    sqrtPriceB
                );

                uint256 amount1 = UniswapV3MathLib.getToken1FromLiquidity(
                    liquidity,
                    sqrtPriceA,
                    sqrtPriceCurrent
                );

                position0.value += amount0 + tokensOwed0;
                position0.value += amount1 + tokensOwed1;
            }
        }

        return (position0, position1);
    }
}
