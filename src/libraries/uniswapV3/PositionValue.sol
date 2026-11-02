// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.6.8;

/// @notice What the uncollected fees of a Uniswap V3 position are computed from: the pool it is in (`token0`,
/// `token1`, `fee`), its tick range, its liquidity, the fee growth inside that range as of the position's last
/// update, and the tokens already owed to it
/// @dev `FeeParams` of Uniswap v3-periphery's `PositionValue` library. The fees themselves are computed by
/// `UniswapV3Calculator._feePosition`.
struct FeeParams {
    address token0;
    address token1;
    uint24 fee;
    int24 tickLower;
    int24 tickUpper;
    uint128 liquidity;
    uint256 positionFeeGrowthInside0LastX128;
    uint256 positionFeeGrowthInside1LastX128;
    uint256 tokensOwed0;
    uint256 tokensOwed1;
}
