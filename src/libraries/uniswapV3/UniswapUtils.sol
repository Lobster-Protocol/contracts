// SPDX-License-Identifier: GPLv3
pragma solidity ^0.8.28;

import {IUniswapV3PoolMinimal} from "../../interfaces/uniswapV3/IUniswapV3PoolMinimal.sol";
import {INonFungiblePositionManager} from "../../interfaces/uniswapV3/INonFungiblePositionManager.sol";
import {PoolAddress} from "./PoolAddress.sol";
import {TickMath} from "./TickMath.sol";
import {UniswapV3MathLib} from "./UniswapV3MathLib.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {PositionValue} from "./PositionValue.sol";

struct Position {
    address token;
    uint256 value;
}

library UniswapUtils {
    using Math for uint256;

    uint256 private constant Q96 = 2 ** 96;

    int24 private constant MIN_TICK = -887272;
    int24 private constant MAX_TICK = 887272;

    error UnexpectedTickValue(int56 tickValue);

    /**
     * @dev Calculates the amount of quote token received for a given amount of base token
     * based on the square root of the price ratio (sqrtRatioX96).
     * @dev to get the amount of token1 needed to buy 10**token0Decimals of token0, call this function with (sqrtPriceX96, token0Decimals, false)
     *
     * @param sqrtRatioX96 The square root of the price ratio(in terms of token1/token0) between two tokens, encoded as a Q64.96 value.
     * @param baseAmount The amount of the base token for which the quote is to be calculated. Specify 1e18 for a price(quoteAmount) with 18 decimals of precision.
     * @param inverse Specifies the direction of the price quote. If true, returns the price of token0 else, returns the amount of token1 to buy 10**token0
     *
     * @return quoteAmount The calculated amount of the quote token for the specified baseAmount
     */
    function getQuoteFromSqrtRatioX96(
        uint160 sqrtRatioX96,
        uint128 baseAmount,
        bool inverse
    )
        internal
        pure
        returns (uint256 quoteAmount)
    {
        // Calculate quoteAmount with better precision if it doesn't overflow when multiplied by itself
        if (sqrtRatioX96 <= type(uint128).max) {
            uint256 ratioX192 = uint256(sqrtRatioX96) * sqrtRatioX96;
            quoteAmount = !inverse
                ? uint256(baseAmount).mulDiv(ratioX192, 1 << 192)
                : uint256(baseAmount).mulDiv((1 << 192), ratioX192);
        } else {
            uint256 ratioX128 = uint256(sqrtRatioX96).mulDiv(sqrtRatioX96, 1 << 64);
            quoteAmount = !inverse
                ? uint256(baseAmount).mulDiv(ratioX128, 1 << 128)
                : uint256(baseAmount).mulDiv(1 << 128, ratioX128);
        }
    }

    /**
     * @notice Fetches and calculates the time-weighted average price (TWAP) from a Uniswap V3 pool
     * @param pool The Uniswap V3 pool
     * @param secondsAgo The number of seconds in the past to start calculating the TWAP
     * @param baseAmount The amount of the base token for which the TWAP is to be calculated
     * @param inverse Specifies the direction of the price quote. If true, returns the price of token0 else, returns the amount of token1 to buy 10**token0
     * @return twPrice The time-weighted average price of token0 in terms of token1
     */
    function getTwap(
        IUniswapV3PoolMinimal pool,
        uint32 secondsAgo,
        uint128 baseAmount,
        bool inverse
    )
        public
        view
        returns (uint256 twPrice)
    {
        // Ensure secondsAgo is not zero to prevent division by zero
        require(secondsAgo > 0, "Period must be greater than 0");

        // Create array with two time points: now and secondsAgo seconds ago
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = secondsAgo;
        secondsAgos[1] = 0; // now

        // Get cumulative ticks at both time points
        (int56[] memory tickCumulatives,) = pool.observe(secondsAgos);

        int56 tickCumulativesDelta = tickCumulatives[1] - tickCumulatives[0];

        int56 averageTick = int24(tickCumulativesDelta / int56(uint56(secondsAgo)));

        // Always round to negative infinity
        if (tickCumulativesDelta < 0 && (tickCumulativesDelta % int56(uint56(secondsAgo)) != 0)) averageTick--;

        if (averageTick < MIN_TICK || averageTick > MAX_TICK) {
            revert UnexpectedTickValue(averageTick);
        }

        require(averageTick >= MIN_TICK && averageTick <= MAX_TICK, "Tick out of range");

        twPrice = getQuoteFromSqrtRatioX96(TickMath.getSqrtRatioAtTick(int24(averageTick)), baseAmount, inverse);
    }
}
