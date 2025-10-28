// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.28;

/**
 * @notice Represents a liquidity position in a UniswapV3 pool
 * @param lowerTick The lower price tick boundary of the position
 * @param upperTick The upper price tick boundary of the position
 * @param liquidity The amount of liquidity in the position
 */
struct Position {
    int24 lowerTick;
    int24 upperTick;
    uint128 liquidity;
}

/**
 * @notice Parameters for minting new liquidity positions
 * @param tickLower The lower tick boundary for the new position
 * @param tickUpper The upper tick boundary for the new position
 * @param amount0Desired Maximum amount of token0 to add as liquidity
 * @param amount1Desired Maximum amount of token1 to add as liquidity
 * @param amount0Min Minimum amount of token0 to add (slippage protection)
 * @param amount1Min Minimum amount of token1 to add (slippage protection)
 * @param deadline Transaction deadline timestamp
 */
struct MinimalMintParams {
    int24 tickLower;
    int24 tickUpper;
    uint256 amount0Desired;
    uint256 amount1Desired;
    uint256 amount0Min;
    uint256 amount1Min;
    uint256 deadline;
}

/**
 * @notice Parameters for withdrawal operations
 * @param userScaledPercent Percentage of assets to withdraw for the user (scaled by SCALING_FACTOR)
 * @param tvlFeeScaledPercent Percentage to collect as TVL management fee (scaled)
 * @param performanceFeeScaledPercent Percentage to collect as performance fee (scaled)
 * @param newTvlInToken0 Updated vault TVL denominated in token0 after fees
 * @param recipient Address to receive the withdrawn funds
 */
struct WithdrawParams {
    uint256 userScaledPercent;
    uint256 tvlFeeScaledPercent;
    uint256 performanceFeeScaledPercent;
    uint256 newTvlInToken0;
    address recipient;
}

/**
 * @notice Current state of vault assets across pool positions and free balances
 * @param sqrtPriceX96 Current pool price in sqrt(token1/token0) * 2^96 format
 * @param currentTick Current price tick in the pool
 * @param lpAssets0 Amount of token0 locked in LP positions
 * @param lpAssets1 Amount of token1 locked in LP positions
 * @param freeAssets0 Amount of token0 held as free balance
 * @param freeAssets1 Amount of token1 held as free balance
 */
struct AssetState {
    uint160 sqrtPriceX96;
    int24 currentTick;
    uint256 lpAssets0;
    uint256 lpAssets1;
    uint256 freeAssets0;
    uint256 freeAssets1;
}
