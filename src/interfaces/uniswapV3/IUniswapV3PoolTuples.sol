// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

/**
 * @notice The whole `slot0()` tuple of a Uniswap V3 pool, as one value (same fields, same order)
 * @param sqrtPriceX96 The current price of the pool as a sqrt(token1/token0) Q64.96 value
 * @param tick The current tick of the pool
 * @param observationIndex The index of the last oracle observation that was written
 * @param observationCardinality The current maximum number of observations stored in the pool
 * @param observationCardinalityNext The next maximum number of observations
 * @param feeProtocol The protocol fee for both tokens of the pool
 * @param unlocked Whether the pool is currently unlocked (not in the middle of a swap, mint or burn)
 */
struct PoolSlot0 {
    uint160 sqrtPriceX96;
    int24 tick;
    uint16 observationIndex;
    uint16 observationCardinality;
    uint16 observationCardinalityNext;
    uint8 feeProtocol;
    bool unlocked;
}

/**
 * @notice The whole `ticks(int24)` tuple of a Uniswap V3 pool, as one value (same fields, same order)
 * @param liquidityGross The total position liquidity that references this tick
 * @param liquidityNet The liquidity change when the price crosses this tick
 * @param feeGrowthOutside0X128 The token0 fee growth on the other side of this tick from the current tick
 * @param feeGrowthOutside1X128 The token1 fee growth on the other side of this tick from the current tick
 * @param tickCumulativeOutside The cumulative tick value on the other side of this tick
 * @param secondsPerLiquidityOutsideX128 The seconds per liquidity on the other side of this tick
 * @param secondsOutside The seconds spent on the other side of this tick
 * @param initialized Whether the tick is initialized
 */
struct PoolTick {
    uint128 liquidityGross;
    int128 liquidityNet;
    uint256 feeGrowthOutside0X128;
    uint256 feeGrowthOutside1X128;
    int56 tickCumulativeOutside;
    uint160 secondsPerLiquidityOutsideX128;
    uint32 secondsOutside;
    bool initialized;
}

/**
 * @title IUniswapV3PoolTuples
 * @notice A Uniswap V3 pool's `slot0()` and `ticks(int24)` getters, declared to return their tuple as one struct
 * @dev Same selectors and same ABI encoding as the tuples of IUniswapV3PoolMinimal (a tuple of static values is
 *      encoded like a static struct of the same fields): a call decodes and validates every field exactly as
 *      destructuring the tuple does, and fails the same way. The caller keeps the whole tuple and reads the fields
 *      it needs, so no return value of the call is dropped.
 */
interface IUniswapV3PoolTuples {
    function slot0() external view returns (PoolSlot0 memory);

    function ticks(int24 tick) external view returns (PoolTick memory);
}
