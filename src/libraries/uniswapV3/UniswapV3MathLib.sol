// SPDX-License-Identifier: GPLv3
pragma solidity ^0.8.0;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

library UniswapV3MathLib {
    // Constants from Uniswap V3 for fixed-point arithmetic
    int24 internal constant MIN_TICK = -887272;
    int24 internal constant MAX_TICK = 887272;
    uint256 constant Q96 = 2 ** 96;
    uint256 constant Q192 = 2 ** 192;

    // Token0Amount = liquidity * (2^96/sqrtRatioCurrent - 2^96/sqrtRatioA)
    function getToken0FromLiquidity(
        uint128 liquidity,
        uint160 sqrtPriceA,
        uint160 sqrtPriceB
    )
        internal
        pure
        returns (uint256 amount0)
    {
        require(sqrtPriceA <= sqrtPriceB, "Price A must be <= Price B");

        uint256 liq = uint256(liquidity);

        // Formula: Token0Amount = liquidity * (2^96/sqrtRatioCurrent - 2^96/sqrtRatioA)
        // Token0Amount = liquidity * 2^96 * (sqrtRatioB - sqrtRatioA) / (sqrtRatioA * sqrtRatioB)

        // Calculate the numerator
        uint256 numerator = Math.mulDiv(Q96, uint256(sqrtPriceB) - uint256(sqrtPriceA), Q192);

        // Calculate the denominator
        uint256 denominator = Math.mulDiv(uint256(sqrtPriceA), uint256(sqrtPriceB), Q192);

        // Calculate the final amount
        amount0 = Math.mulDiv(liq, numerator, denominator);
    }

    // Token1Amount = liquidity * (sqrtRatioCurrent/2^96 - sqrtRatioA/2^96)
    function getToken1FromLiquidity(
        uint128 liquidity,
        uint160 sqrtPriceA,
        uint160 sqrtPriceCurrent
    )
        internal
        pure
        returns (uint256 amount1)
    {
        require(sqrtPriceA <= sqrtPriceCurrent, "Price A must be <= Price current");

        uint256 liq = uint256(liquidity);

        uint256 diff = uint256(sqrtPriceCurrent) - uint256(sqrtPriceA);
        amount1 = Math.mulDiv(liq, diff, Q96);

        return amount1;
    }
}
