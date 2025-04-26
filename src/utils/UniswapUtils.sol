// Maxime / Thomas ignore
// SPDX-License-Identifier: GPLv3
pragma solidity ^0.8.28;

import "forge-std/Test.sol";

import {IUniswapV3PoolMinimal} from "../interfaces/uniswapV3/IUniswapV3PoolMinimal.sol";
import {INonFungiblePositionManager} from "../interfaces/uniswapV3/INonFungiblePositionManager.sol";
import {PoolAddress} from "../utils/uniswapV3Lib/PoolAddress.sol";
import {TickMath} from "../utils/uniswapV3Lib/TickMath.sol";
import {UniswapV3MathLib} from "../utils/uniswapV3Lib/UniswapV3MathLib.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

struct Position {
    address token;
    uint256 value;
}

library UniswapUtils {
    using Math for uint256;
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
        uint160 sqrtPriceX96,
        uint8 token0Decimals, // decimal for the token used as price unit
        uint8 token1Decimals // decimal for the token used as price unit
    )
        public
        pure
        returns (uint256 price, uint256 scalingFactor)
    {
        if (token0Decimals > token1Decimals) {
            price = uint256(sqrtPriceX96).mulDiv(uint256(sqrtPriceX96) * 10 ** (token1Decimals), (Q96 * Q96));
        } else {
            console.log("sqrtPriceX96", sqrtPriceX96);
            price = uint256(sqrtPriceX96).mulDiv(uint256(sqrtPriceX96) * 10 ** (token0Decimals), (Q96 * Q96));
        }
    }
    // /**
    //  * @notice Converts sqrtPriceX96 to price
    //  * @param sqrtPriceX96 The sqrt price in X96 format from Uniswap V3
    //  * @param token0Decimals Decimals for token0
    //  * @param token1Decimals Decimals for token1
    //  * @return price The price of token1 in terms of token0
    //  */
    // function sqrtPriceX96ToPrice(
    //     uint160 sqrtPriceX96,
    //     uint8 token0Decimals,
    //     uint8 token1Decimals
    // ) public pure returns (uint256 price, uint256 scalingFactor) {
    //     // Calculate the adjustment for decimal differences
    //     uint256 decimalAdjustment;
    //     if (token0Decimals >= token1Decimals) {
    //         decimalAdjustment = 10 ** (token0Decimals - token1Decimals);
    //     } else {
    //         decimalAdjustment = 10 ** (token1Decimals - token0Decimals);
    //     }

    //     // Calculate price = (sqrtPriceX96 ^ 2) / (2^192)
    //     // This represents the price of token1 in terms of token0
    //     uint256 priceSquared = uint256(sqrtPriceX96) * uint256(sqrtPriceX96);

    //     if (token0Decimals >= token1Decimals) {
    //         // When token0 has more decimals, multiply the price
    //         price = priceSquared.mulDiv(decimalAdjustment, Q96 * Q96);
    //     } else {
    //         // When token1 has more decimals, divide the price
    //         price = priceSquared.mulDiv(1, Q96 * Q96 * decimalAdjustment);
    //     }
    // }

    // /**
    //  * @notice Fetches and calculates the time-weighted average price (TWAP) from a Uniswap V3 pool
    //  * @param pool The Uniswap V3 pool
    //  * @param secondsAgo The number of seconds in the past to start calculating the TWAP
    //  * @return twapPrice The time-weighted average price of token0 in terms of token1
    //  */
    // function getTwap(
    //     IUniswapV3PoolMinimal pool,
    //     uint32 secondsAgo,
    //     uint8 token0Decimals, // the decimals for the token used as price units
    //     uint8 token1Decimals // the decimals for the token used as price units
    // ) public view returns (uint256 twapPrice) {
    //     // Ensure secondsAgo is not zero to prevent division by zero
    //     require(secondsAgo > 0, "Period must be greater than 0");

    //     // Create array with two time points: now and secondsAgo seconds ago
    //     uint32[] memory secondsAgos = new uint32[](2);
    //     secondsAgos[0] = secondsAgo;
    //     secondsAgos[1] = 0; // now

    //     // Get cumulative ticks at both time points
    //     (int56[] memory tickCumulatives, ) = pool.observe(secondsAgos);

    //     // const diffTickCumulative = observations[0].tickCumulative - observations[1].tickCumulative
    //     // const secondsBetween = 108

    //     // const averageTick = diffTickCumulative / secondsBetween

    //     int56 diffTickCumulative = tickCumulatives[0] - tickCumulatives[1];

    //     require(
    //         uint56(secondsAgo) <= uint56(type(int56).max),
    //         "secondsAgo out of range for int56"
    //     );

    //     int56 averageTick = diffTickCumulative / int56(int32(secondsAgo));

    //     twapPrice = tickToPrice(averageTick, token0Decimals, token1Decimals);
    // }

    // /**
    //  * @notice Converts a tick to a price
    //  * @param tick The tick to convert
    //  * @return price The price as a Q96 fixed-point number
    //  */
    // function tickToPrice(
    //     int56 tick,
    //     uint8 token0Decimals,
    //     uint8 token1Decimals
    // ) public pure returns (uint256 price) {
    //     // Ensure the tick is within the valid range
    //     require(tick >= MIN_TICK && tick <= MAX_TICK, "Tick out of range");

    //     // Need to convert to a valid int24 for actual implementation
    //     int24 adjustedTick = int24(tick);

    //     // If tick is negative, we need to calculate 1 / (1.0001^abs(tick))
    //     if (tick < 0) {
    //         // We use the formula 1 / (1.0001^abs(tick))
    //         return
    //             sqrtPriceX96ToPrice(
    //                 TickMath.getSqrtRatioAtTick(-adjustedTick),
    //                 token0Decimals,
    //                 token1Decimals
    //             );
    //     } else {
    //         // If tick is positive or zero, we calculate 1.0001^tick directly
    //         return
    //             sqrtPriceX96ToPrice(
    //                 TickMath.getSqrtRatioAtTick(adjustedTick),
    //                 token0Decimals,
    //                 token1Decimals
    //             );
    //     }
    // }

    // Get total value locked in Uniswap V3 for a specific address in a specific pool
    function getUniswapV3Positions(
        IUniswapV3PoolMinimal pool,
        INonFungiblePositionManager positionManager,
        address user,
        address poolToken0,
        address poolToken1
    )
        public
        view
        returns (Position memory position0, Position memory position1)
    {
        uint256 balance = positionManager.balanceOf(user);
        (, int24 currentTick,,,,,) = pool.slot0();

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
            PoolAddress.PoolKey memory key = PoolAddress.getPoolKey(token0, token1, fee);

            address computedPoolAddress = PoolAddress.computeAddress(pool.factory(), key);

            if (computedPoolAddress == address(pool)) {
                uint160 sqrtPriceA = TickMath.getSqrtRatioAtTick(tickLower);
                uint160 sqrtPriceB = TickMath.getSqrtRatioAtTick(tickUpper);
                uint160 sqrtPriceCurrent = TickMath.getSqrtRatioAtTick(currentTick);

                uint256 amount0 = UniswapV3MathLib.getToken0FromLiquidity(liquidity, sqrtPriceCurrent, sqrtPriceB);

                uint256 amount1 = UniswapV3MathLib.getToken1FromLiquidity(liquidity, sqrtPriceA, sqrtPriceCurrent);

                position0.value += amount0 + tokensOwed0;
                position0.value += amount1 + tokensOwed1;
            }
        }

        return (position0, position1);
    }
}
