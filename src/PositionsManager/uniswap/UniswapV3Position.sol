// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {TickMath} from "./lib/TickMath.sol";
import {PoolAddress} from "./lib/PoolAddress.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {INonfungiblePositionManager} from "../../interfaces/uniswapV3/INonfungiblePositionManager.sol";
import {IUniswapV3Pool} from "../../interfaces/uniswapV3/IUniswapV3Pool.sol";
import {UniswapV3MathLib} from "./lib/UniswapV3MathLib.sol";
import {Constants} from "../Constants.sol";
import {TransferHelper} from "./lib/TransferHelper.sol";

/**
 * @title UniswapV3PositionManager
 * @author Elli610
 * @notice This contract is used to retrieve the total value (in ETH) held by a specific address in Uniswap V3. It also allows to update a user's position.
 */
contract UniswapV3Position is Constants {
    using Math for uint256;

    // uniswap v3 position manager
    INonfungiblePositionManager public immutable positionManager;
    address public immutable uniswapV3Factory;

    constructor(
        address uniswapPositionManagerAddress,
        address factory,
        address weth
    ) {
        positionManager = INonfungiblePositionManager(
            uniswapPositionManagerAddress
        );
        uniswapV3Factory = factory;
        wethAddress = weth;
    }

    // Get total value locked in Uniswap V3 for a specific address. returns the total value in ETH
    function getUniswapV3PositionValueInETH(
        address user
    ) public view returns (uint256 totalValueInETH) {
        uint256 balance = positionManager.balanceOf(user);

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
                ,

            ) = positionManager.positions(tokenId);

            // Get the pool address
            PoolAddress.PoolKey memory key = PoolAddress.getPoolKey(
                token0,
                token1,
                fee
            );
            address poolAddress = PoolAddress.computeAddress(
                uniswapV3Factory,
                key
            );

            // Calculate position value
            uint256 positionValueInETH = calculatePositionValue(
                poolAddress,
                token0,
                token1,
                liquidity,
                tickLower,
                tickUpper
            );

            totalValueInETH += positionValueInETH;
        }

        return totalValueInETH;
    }

    // Calculate the value of a specific Uniswap V3 position
    // todo: prevent from flash loan attacks (for now we only get the price from the uniswapV3 pools)
    function calculatePositionValue(
        address poolAddress,
        address token0,
        address token1,
        uint128 liquidity,
        int24 tickLower,
        int24 tickUpper
    ) public view returns (uint256 valueInETH) {
        IUniswapV3Pool pool = IUniswapV3Pool(poolAddress);

        // Get current price
        (, int24 currentTick, , , , , ) = pool.slot0();

        uint160 sqrtPriceA = TickMath.getSqrtRatioAtTick(tickLower);
        uint160 sqrtPriceB = TickMath.getSqrtRatioAtTick(tickUpper);
        uint160 sqrtPriceCurrent = TickMath.getSqrtRatioAtTick(currentTick);

        // extract position value
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

        // Convert to ETH
        uint256 token0ToETH = getTokenInETH(token0, amount0, uniswapV3Factory);
        uint256 token1ToETH = getTokenInETH(token1, amount1, uniswapV3Factory);

        return token0ToETH + token1ToETH;
    }

    /**
     * @notice Get the token value in ETH from the token/weth Uniswap V3 pools
     * @param token The token address
     * @param amount The amount of token to get the value for
     * @param factory The Uniswap V3 factory address to use
     */
    function getTokenInETH(
        address token,
        uint256 amount,
        address factory
    ) internal view returns (uint256) {
        // if token is weth, return the amount (1:1 ratio)
        if (token == wethAddress) return amount;

        // Common Uniswap V3 fees to try
        uint24[] memory fees = new uint24[](3);
        fees[0] = 3000; // 0.3% fee tier
        fees[1] = 10000; // 1% fee tier
        fees[2] = 500; // 0.05% fee tier

        // Try different fee tiers to get a price quote
        for (uint i = 0; i < fees.length; i++) {
            PoolAddress.PoolKey memory key = PoolAddress.getPoolKey(
                token,
                wethAddress,
                fees[i]
            );
            address poolAddress = PoolAddress.computeAddress(factory, key);

            // check code length at address
            uint codeSize;
            assembly {
                codeSize := extcodesize(poolAddress)
            }

            if (codeSize == 0) {
                continue;
            }

            // get the quote
            uint256 quote = UniswapV3MathLib.getQuote(
                poolAddress,
                amount,
                wethAddress
            );

            // return the quote
            return quote;
        }

        // If all quotes fail, return 0
        return 0;
    }

    /* ------------------WITHDRAW POSITION------------------ */

    /// @notice Withdraws a specific amount of liquidity from a position
    /// @param tokenId The ID of the NFT position
    /// @param liquidityToWithdraw The amount of liquidity to withdraw
    /// @param amount0Min The minimum amount of token0 to receive
    /// @param amount1Min The minimum amount of token1 to receive
    function withdrawPartialPosition(
        uint256 tokenId,
        uint128 liquidityToWithdraw,
        uint256 amount0Min,
        uint256 amount1Min
    ) external {
        // Get position information
        (
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            uint128 currentLiquidity,
            ,
            ,
            ,

        ) = positionManager.positions(tokenId);

        // Ensure we're not trying to withdraw more than available
        require(
            liquidityToWithdraw <= currentLiquidity,
            "Insufficient liquidity"
        );

        // Call main withdrawal function
        _withdrawPosition(
            tokenId,
            liquidityToWithdraw,
            amount0Min,
            amount1Min
            // token0,
            // token1
        );
    }

    function _withdrawPosition(
        uint256 tokenId,
        uint128 liquidityToWithdraw,
        uint256 amount0Min,
        uint256 amount1Min
    ) private returns (uint256 amount0, uint256 amount1) {
        // Decrease specified amount of liquidity
        INonfungiblePositionManager.DecreaseLiquidityParams
            memory params = INonfungiblePositionManager
                .DecreaseLiquidityParams({
                    tokenId: tokenId,
                    liquidity: liquidityToWithdraw,
                    amount0Min: amount0Min,
                    amount1Min: amount1Min,
                    deadline: block.timestamp
                });

        positionManager.decreaseLiquidity(params);

        // Collect the withdrawn liquidity
        INonfungiblePositionManager.CollectParams
            memory collectParams = INonfungiblePositionManager.CollectParams({
                tokenId: tokenId,
                recipient: address(this),
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            });

        (amount0, amount1) = positionManager.collect(collectParams);
    }
}
