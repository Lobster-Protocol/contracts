// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.6.8;

// import '@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol';
// import '@uniswap/v3-core/contracts/libraries/FixedPoint128.sol';
// import '@uniswap/v3-core/contracts/libraries/TickMath.sol';
// import '@uniswap/v3-core/contracts/libraries/Tick.sol';
import {IUniswapV3PoolMinimal} from "../../interfaces/uniswapV3/IUniswapV3PoolMinimal.sol";
import {TickMath} from "./TickMath.sol";
import "../../interfaces/uniswapV3/INonFungiblePositionManager.sol";
import "./LiquidityAmounts.sol";
import "./PoolAddress.sol";
import "./PositionKey.sol";

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

/// @title Returns information about the token value held in a Uniswap V3 NFT
library PositionValue {
    using Math for uint256;

    uint256 internal constant Q128 = 0x100000000000000000000000000000000;

    /// @notice Returns the total amounts of token0 and token1, i.e. the sum of fees and principal
    /// that a given nonFungible position manager token is worth
    /// @param positionManager The Uniswap V3 NonFungiblePositionManager
    /// @param tokenId The tokenId of the token for which to get the total value
    /// @param sqrtRatioX96 The square root price X96 for which to calculate the principal amounts
    /// @return amount0 The total amount of token0
    /// @return fee0 The total amount of fees owed in token0
    /// @return amount1 The total amount of token1
    /// @return fee1 The total amount of fees owed in token1
    function total(
        INonFungiblePositionManager positionManager,
        uint256 tokenId,
        uint160 sqrtRatioX96
    )
        internal
        view
        returns (uint256 amount0, uint256 fee0, uint256 amount1, uint256 fee1)
    {
        (uint256 amount0Principal, uint256 amount1Principal) = principal(positionManager, tokenId, sqrtRatioX96);
        (uint256 amount0Fee, uint256 amount1Fee) = fees(positionManager, tokenId);
        return (amount0Principal, amount0Fee, amount1Principal, amount1Fee);
    }

    /// @notice Calculates the principal (currently acting as liquidity) owed to the token owner in the event
    /// that the position is burned
    /// @param positionManager The Uniswap V3 NonFungiblePositionManager
    /// @param tokenId The tokenId of the token for which to get the total principal owed
    /// @param sqrtRatioX96 The square root price X96 for which to calculate the principal amounts
    /// @return amount0 The principal amount of token0
    /// @return amount1 The principal amount of token1
    function principal(
        INonFungiblePositionManager positionManager,
        uint256 tokenId,
        uint160 sqrtRatioX96
    )
        internal
        view
        returns (uint256 amount0, uint256 amount1)
    {
        (,,,,, int24 tickLower, int24 tickUpper, uint128 liquidity,,,,) = positionManager.positions(tokenId);

        return LiquidityAmounts.getAmountsForLiquidity(
            sqrtRatioX96, TickMath.getSqrtRatioAtTick(tickLower), TickMath.getSqrtRatioAtTick(tickUpper), liquidity
        );
    }

    /// @notice Calculates the total fees owed to the token owner
    /// @param positionManager The Uniswap V3 NonfungiblePositionManager
    /// @param tokenId The tokenId of the token for which to get the total fees owed
    /// @return amount0 The amount of fees owed in token0
    /// @return amount1 The amount of fees owed in token1
    function fees(
        INonFungiblePositionManager positionManager,
        uint256 tokenId
    )
        internal
        view
        returns (uint256 amount0, uint256 amount1)
    {
        (
            ,
            ,
            address token0,
            address token1,
            uint24 fee,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            uint256 positionFeeGrowthInside0LastX128,
            uint256 positionFeeGrowthInside1LastX128,
            uint256 tokensOwed0,
            uint256 tokensOwed1
        ) = positionManager.positions(tokenId);

        return _fees(
            positionManager,
            FeeParams({
                token0: token0,
                token1: token1,
                fee: fee,
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidity: liquidity,
                positionFeeGrowthInside0LastX128: positionFeeGrowthInside0LastX128,
                positionFeeGrowthInside1LastX128: positionFeeGrowthInside1LastX128,
                tokensOwed0: tokensOwed0,
                tokensOwed1: tokensOwed1
            })
        );
    }

    function _fees(
        INonFungiblePositionManager positionManager,
        FeeParams memory feeParams
    )
        private
        view
        returns (uint256 amount0, uint256 amount1)
    {
        (uint256 poolFeeGrowthInside0LastX128, uint256 poolFeeGrowthInside1LastX128) = _getFeeGrowthInside(
            IUniswapV3PoolMinimal(
                PoolAddress.computeAddress(
                    positionManager.factory(),
                    PoolAddress.PoolKey({token0: feeParams.token0, token1: feeParams.token1, fee: feeParams.fee})
                )
            ),
            feeParams.tickLower,
            feeParams.tickUpper
        );

        amount0 = uint256(poolFeeGrowthInside0LastX128 - feeParams.positionFeeGrowthInside0LastX128).mulDiv(
            feeParams.liquidity, Q128
        ) + feeParams.tokensOwed0;

        amount1 = (poolFeeGrowthInside1LastX128 - feeParams.positionFeeGrowthInside1LastX128).mulDiv(
            feeParams.liquidity, Q128
        ) + feeParams.tokensOwed1;
    }

    function _getFeeGrowthInside(
        IUniswapV3PoolMinimal pool,
        int24 tickLower,
        int24 tickUpper
    )
        private
        view
        returns (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128)
    {
        (, int24 tickCurrent,,,,,) = pool.slot0();
        (,, uint256 lowerFeeGrowthOutside0X128, uint256 lowerFeeGrowthOutside1X128,,,,) = pool.ticks(tickLower);
        (,, uint256 upperFeeGrowthOutside0X128, uint256 upperFeeGrowthOutside1X128,,,,) = pool.ticks(tickUpper);

        if (tickCurrent < tickLower) {
            feeGrowthInside0X128 = lowerFeeGrowthOutside0X128 - upperFeeGrowthOutside0X128;
            feeGrowthInside1X128 = lowerFeeGrowthOutside1X128 - upperFeeGrowthOutside1X128;
        } else if (tickCurrent < tickUpper) {
            uint256 feeGrowthGlobal0X128 = pool.feeGrowthGlobal0X128();
            uint256 feeGrowthGlobal1X128 = pool.feeGrowthGlobal1X128();
            feeGrowthInside0X128 = feeGrowthGlobal0X128 - lowerFeeGrowthOutside0X128 - upperFeeGrowthOutside0X128;
            feeGrowthInside1X128 = feeGrowthGlobal1X128 - lowerFeeGrowthOutside1X128 - upperFeeGrowthOutside1X128;
        } else {
            feeGrowthInside0X128 = upperFeeGrowthOutside0X128 - lowerFeeGrowthOutside0X128;
            feeGrowthInside1X128 = upperFeeGrowthOutside1X128 - lowerFeeGrowthOutside1X128;
        }
    }
}
