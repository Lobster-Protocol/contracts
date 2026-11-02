// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.28;

import {IUniswapV3PoolMinimal} from "../interfaces/uniswapV3/IUniswapV3PoolMinimal.sol";
import {IUniswapV3PoolTuples, PoolTick} from "../interfaces/uniswapV3/IUniswapV3PoolTuples.sol";
import {LiquidityAmounts} from "../libraries/uniswapV3/LiquidityAmounts.sol";
import {TickMath} from "../libraries/uniswapV3/TickMath.sol";
import {FeeParams} from "../libraries/uniswapV3/PositionValue.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @dev Q128 constant for fixed-point arithmetic in Uniswap V3 fee calculations
uint256 constant Q128 = 0x100000000000000000000000000000000;

int24 constant MIN_TICK = -887272;
int24 constant MAX_TICK = 887272;

/**
 * @notice A pool's global fee growth, read once and shared by the fee calculation of every position
 * @param feeGrowthGlobal0X128 The pool's feeGrowthGlobal0X128()
 * @param feeGrowthGlobal1X128 The pool's feeGrowthGlobal1X128()
 */
struct FeeGrowthGlobal {
    uint256 feeGrowthGlobal0X128;
    uint256 feeGrowthGlobal1X128;
}

/**
 * @title UniswapV3Calculator
 * @author Elli <nathan@lobster-protocol.com>
 * @notice Library contract for Uniswap V3 position calculations
 */
contract UniswapV3Calculator {
    using Math for uint256;

    error UnexpectedTickValue(int56 tickValue);

    /**
     * @dev Calculate the principal token amounts for a position at the current price
     * @param sqrtRatioX96 The current sqrt price of the pool
     * @param tickLower The lower tick boundary of the position
     * @param tickUpper The upper tick boundary of the position
     * @param liquidity The liquidity amount of the position
     * @return amount0 The amount of token0 in the position
     * @return amount1 The amount of token1 in the position
     */
    function _principalPosition(
        uint160 sqrtRatioX96,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity
    )
        internal
        pure
        returns (uint256 amount0, uint256 amount1)
    {
        return LiquidityAmounts.getAmountsForLiquidity(
            sqrtRatioX96, TickMath.getSqrtRatioAtTick(tickLower), TickMath.getSqrtRatioAtTick(tickUpper), liquidity
        );
    }

    /**
     * @dev Calculate the uncollected fees for a position
     * @param pool The Uniswap V3 pool contract
     * @param feeParams Struct containing all fee calculation parameters
     * @param tickCurrent The current tick of the pool
     * @param feeGrowthGlobal The pool's global fee growth (only used if the position is in range)
     * @return fee0 The uncollected fees in token0
     * @return fee1 The uncollected fees in token1
     */
    function _feePosition(
        IUniswapV3PoolMinimal pool,
        FeeParams memory feeParams,
        int24 tickCurrent,
        FeeGrowthGlobal memory feeGrowthGlobal
    )
        internal
        view
        returns (uint256 fee0, uint256 fee1)
    {
        (uint256 poolFeeGrowthInside0LastX128, uint256 poolFeeGrowthInside1LastX128) =
            _getFeeGrowthInside(pool, tickCurrent, feeParams.tickLower, feeParams.tickUpper, feeGrowthGlobal);

        fee0 = (poolFeeGrowthInside0LastX128 - feeParams.positionFeeGrowthInside0LastX128)
        .mulDiv(feeParams.liquidity, Q128) + feeParams.tokensOwed0;

        fee1 = (poolFeeGrowthInside1LastX128 - feeParams.positionFeeGrowthInside1LastX128)
        .mulDiv(feeParams.liquidity, Q128) + feeParams.tokensOwed1;
    }

    /**
     * @dev Calculate the fee growth inside a position's tick range
     * This is a core Uniswap V3 calculation that determines how much fees have
     * accrued within the position's active range
     * @param pool The Uniswap V3 pool contract
     * @param tickCurrent The current tick of the pool
     * @param tickLower The lower tick boundary of the position
     * @param tickUpper The upper tick boundary of the position
     * @param feeGrowthGlobal The pool's global fee growth (only used if the position is in range)
     * @return feeGrowthInside0X128 Fee growth inside the range for token0
     * @return feeGrowthInside1X128 Fee growth inside the range for token1
     */
    function _getFeeGrowthInside(
        IUniswapV3PoolMinimal pool,
        int24 tickCurrent,
        int24 tickLower,
        int24 tickUpper,
        FeeGrowthGlobal memory feeGrowthGlobal
    )
        internal
        view
        returns (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128)
    {
        // Get fee growth data from the pool's tick boundaries
        (uint256 lowerFeeGrowthOutside0X128, uint256 lowerFeeGrowthOutside1X128) = _feeGrowthOutside(pool, tickLower);
        (uint256 upperFeeGrowthOutside0X128, uint256 upperFeeGrowthOutside1X128) = _feeGrowthOutside(pool, tickUpper);

        // Calculate fee growth inside based on current tick position
        if (tickCurrent < tickLower) {
            // Current price is below the position range
            feeGrowthInside0X128 = lowerFeeGrowthOutside0X128 - upperFeeGrowthOutside0X128;
            feeGrowthInside1X128 = lowerFeeGrowthOutside1X128 - upperFeeGrowthOutside1X128;
        } else if (tickCurrent < tickUpper) {
            // Current price is within the position range (position is active)
            feeGrowthInside0X128 =
                feeGrowthGlobal.feeGrowthGlobal0X128 - lowerFeeGrowthOutside0X128 - upperFeeGrowthOutside0X128;
            feeGrowthInside1X128 =
                feeGrowthGlobal.feeGrowthGlobal1X128 - lowerFeeGrowthOutside1X128 - upperFeeGrowthOutside1X128;
        } else {
            // Current price is above the position range
            feeGrowthInside0X128 = upperFeeGrowthOutside0X128 - lowerFeeGrowthOutside0X128;
            feeGrowthInside1X128 = upperFeeGrowthOutside1X128 - lowerFeeGrowthOutside1X128;
        }
    }

    /**
     * @dev Read the fee growth outside a tick: the pool's whole `ticks(tick)` entry, of which two fields are used
     * @param pool The Uniswap V3 pool contract
     * @param tick The tick to read
     * @return feeGrowthOutside0X128 Fee growth on the other side of the tick for token0
     * @return feeGrowthOutside1X128 Fee growth on the other side of the tick for token1
     */
    function _feeGrowthOutside(
        IUniswapV3PoolMinimal pool,
        int24 tick
    )
        private
        view
        returns (uint256 feeGrowthOutside0X128, uint256 feeGrowthOutside1X128)
    {
        // Two reads per position of the vault (see UniV3LpVault._totalLpState), on its own pool
        // forge-lint: disable-next-line(calls-loop)
        PoolTick memory info = IUniswapV3PoolTuples(address(pool)).ticks(tick);
        return (info.feeGrowthOutside0X128, info.feeGrowthOutside1X128);
    }
}
