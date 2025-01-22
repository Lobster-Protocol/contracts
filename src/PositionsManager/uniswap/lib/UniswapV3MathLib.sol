// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IUniswapV3Pool} from "../../../interfaces/uniswapV3/IUniswapV3Pool.sol";


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
    ) internal pure returns (uint256 amount0) {
        require(sqrtPriceA <= sqrtPriceB, "Price A must be <= Price B");

        uint256 liq = uint256(liquidity);

        // Formula: Token0Amount = liquidity * (2^96/sqrtRatioCurrent - 2^96/sqrtRatioA)
        // Token0Amount = liquidity * 2^96 * (sqrtRatioB - sqrtRatioA) / (sqrtRatioA * sqrtRatioB)

        // Calculate the numerator
        uint256 numerator = Math.mulDiv(
            Q96,
            uint256(sqrtPriceB) - uint256(sqrtPriceA),
            Q192
        );

        // Calculate the denominator
        uint256 denominator = Math.mulDiv(
            uint256(sqrtPriceA),
            uint256(sqrtPriceB),
            Q192
        );

        // Calculate the final amount
        amount0 = Math.mulDiv(liq, numerator, denominator);
    }

    // Token1Amount = liquidity * (sqrtRatioCurrent/2^96 - sqrtRatioA/2^96)
    function getToken1FromLiquidity(
        uint128 liquidity,
        uint160 sqrtPriceA,
        uint160 sqrtPriceCurrent
    ) internal pure returns (uint256 amount1) {
        require(
            sqrtPriceA <= sqrtPriceCurrent,
            "Price A must be <= Price current"
        );

        uint256 liq = uint256(liquidity);

        uint256 diff = uint256(sqrtPriceCurrent) - uint256(sqrtPriceA);
        amount1 = Math.mulDiv(liq, diff, Q96);

        return amount1;
    }

    // returns the token amount equivalent value in eth
    function getQuote(
        address poolAddress,
        uint256 amount,
        address wethAddress
    ) internal view returns (uint256) {
        IUniswapV3Pool pool = IUniswapV3Pool(poolAddress);

        // Get current sqrt price and tick
        (uint160 sqrtPriceX96, , , , , , ) = pool.slot0();

        // Calculate the price from sqrtPriceX96
        // price = (sqrtPriceX96 * sqrtPriceX96) / (2^192)
        uint256 priceX96Squared = Math.mulDiv(
            uint256(sqrtPriceX96),
            uint256(sqrtPriceX96),
            Q96
        );

        // Convert the amount to ETH based on the price
        // If token is token0, then multiply by price
        // If token is token1, then divide by price
        uint256 amountInETH;
        if (pool.token0() == wethAddress) {
            // Token we're quoting is token1, divide by price
            amountInETH = Math.mulDiv(amount, Q96, priceX96Squared);
        } else {
            // Token we're quoting is token0, multiply by price
            amountInETH = Math.mulDiv(amount, priceX96Squared, Q96);
        }

        return amountInETH;
    }
}