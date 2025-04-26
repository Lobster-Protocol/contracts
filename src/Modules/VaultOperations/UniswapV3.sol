// Maxime / Thomas ignore
// SPDX-License-Identifier: GPLv3
pragma solidity ^0.8.28;

import "forge-std/Test.sol";

import {IVaultFlowModule} from "../../interfaces/modules/IVaultFlowModule.sol";
import {INav} from "../../interfaces/modules/INav.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IUniswapV3PoolMinimal} from "../../interfaces/uniswapV3/IUniswapV3PoolMinimal.sol";
import {BaseOp, Op} from "../../interfaces/modules/IOpValidatorModule.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {LobsterVault} from "../../../src/Vault/Vault.sol";
import {UniswapUtils, Position} from "../../utils/UniswapUtils.sol";
import {INonFungiblePositionManager} from "../../interfaces/uniswapV3/INonFungiblePositionManager.sol";

uint16 constant BASIS_POINT_SCALE = 10_000;
uint256 constant SCALING_FACTOR = 1e24;

// Hook used to take a fee when the vault collect its fees from a uniswap pool
contract UniswapV3VaultOperations is IVaultFlowModule, INav {
    using Math for uint256;

    uint32 constant TWAP_PERIOD = 3600; // 1 hour

    IUniswapV3PoolMinimal public pool;
    INonFungiblePositionManager public positionManager;
    uint8 decimals0;
    uint8 decimals1;

    // The maximum acceptable price difference between the spot price and the TWAP price
    uint256 public constant MAX_ACCEPTABLE_PRICE_DIFF_BASIS_POINT = 150; // 1.5%

    constructor(IUniswapV3PoolMinimal _pool, INonFungiblePositionManager positionManager_) {
        pool = _pool;
        decimals0 = IERC20Metadata(pool.token0()).decimals();
        decimals1 = IERC20Metadata(pool.token1()).decimals();
        positionManager = positionManager_;
    }

    function _deposit(
        address caller,
        address receiver,
        uint256 assets,
        uint256 shares
    )
        external
        returns (bool success)
    {
        // /////
        // (uint256 twPrice, uint256 spotPrice_) = getPrices(decimals0);
        // console.log("btc spot price:", spotPrice_);
        // // uint256 priceToken1 = UniswapUtils.sqrtPriceX96ToPrice(
        // //     sqrtPriceX96,
        // //     decimals0
        // // );
        //         (uint256 twPriceETH, uint256 spotPrice_ETH) = getPrices(decimals1);
        // console.log(
        //     "eth spot price with scale:",twPriceETH
        //     // (10 ** decimals1).mulDiv(SCALING_FACTOR, spotPrice_)
        // );
        // /////
        (uint256 twapPrice, uint256 spotPrice) = getPrices(decimals0);
        console.log("azerty spot: ", spotPrice);
        console.log("azerty twap: ", twapPrice);
        (uint256 twapPrice1, uint256 spotPrice1) = getPrices(decimals1);
        console.log("azerty spot: ", spotPrice1);
        console.log("azerty twap: ", twapPrice1);
        // (uint256 twapPrice, uint256 spotPrice) = getPrices(decimals0);

        // refuse to deposit if the price is too volatile (i.e. the spot price is too far from the TWAP price)
        // security measure to protect the depositor or the vault for a potential arbitrage attack
        requireLowVolatility(twapPrice, spotPrice);

        LobsterVault vault = LobsterVault(msg.sender);

        vault.safeTransferFrom(IERC20(vault.asset()), caller, address(vault), assets);
        vault.mintShares(receiver, shares);

        emit IERC4626.Deposit(caller, receiver, assets, shares);

        return true;
    }

    function _withdraw(
        address caller,
        address receiver,
        address owner,
        uint256 assets,
        uint256 shares
    )
        external
        returns (bool success)
    {
        revert("use PositionValue");
        // (uint256 twPrice, uint256 spotPrice) = getPrices();

        // // if the volatility is too high and the withdrawer is advantaged (arbitrage), create a slippage to protect the vault
        // if (
        //     tooMuchVolatility(twPrice, spotPrice) == true && spotPrice < twPrice
        // ) {
        //     /*
        //         If spotPrice < twPrice, the vault tvl will be over evaluated and during withdrawal,
        //         the vault will transfer more eth than necessary.
        //         This snippets aims to fix this
        //     */

        //     // Estimate the slippage
        //     uint256 slippageDiffBasisPoint = spotPrice.mulDiv(
        //         BASIS_POINT_SCALE,
        //         twPrice
        //     ); // < 10_000 since

        //     // reduce the withdrawn asset amount accordingly
        //     assets = assets.mulDiv(slippageDiffBasisPoint, BASIS_POINT_SCALE);
        // }

        // LobsterVault vault = LobsterVault(msg.sender);

        // // todo: if needed, withdraw the tokens we need from uniswap

        // // Execute withdrawal
        // vault.burnShares(owner, shares);
        // vault.safeTransfer(IERC20(vault.asset()), receiver, assets);

        // emit IERC4626.Withdraw(caller, receiver, owner, assets, shares);

        // return true;
    }

    function totalAssets() external pure returns (uint256) {
        revert("use PositionValue");

        // IERC20 poolToken0 = IERC20(pool.token0());
        // IERC20 poolToken1 = IERC20(pool.token1());

        // bool isVaultAssetToken0 = address(poolToken1) ==
        //     LobsterVault(msg.sender).asset()
        //     ? true
        //     : false;

        // require(
        //     isVaultAssetToken0 ||
        //         address(poolToken1) == LobsterVault(msg.sender).asset(),
        //     "None of the pool assets is in the pool"
        // );

        // // Get the pool assets owned by the vault
        // uint256 amount0 = poolToken0.balanceOf(msg.sender);
        // uint256 amount1 = poolToken1.balanceOf(msg.sender);

        // // Get all the positions in the pool (+ non collected fees)
        // (Position memory position0, Position memory position1) = UniswapUtils
        //     .getUniswapV3Positions(
        //         pool,
        //         positionManager,
        //         msg.sender,
        //         address(poolToken0),
        //         address(poolToken1)
        //     );

        // amount0 += position0.value;
        // amount1 += position1.value;

        // (uint256 twPrice, ) = getPrices();

        // // use the time weighted price to estimate the vault total assets
        // // here we accept a lag with the current spot price
        // if (isVaultAssetToken0) {
        //     //             uint256 decimals0 = poolToken0.decimals();
        //     // uint256 decimals1 = poolToken1.decimals();
        //     // uint256 decimalMultiplier = 10**(token1.de);
        //     // tvl = amount0 + amount1 *
        // } else {
        //     // console.log("1/twPrice=", (10**10)*10_000_000 ether/twPrice);

        //     tvl = amount1 + amount0 * twPrice;
        // }
    }

    function vaultAssets(address token0, address token1) public view returns (uint256 amount0, uint256 amount1) {}

    function requireLowVolatility(uint256 twapPrice, uint256 spotPrice) internal pure {
        // check if the spot price is within the acceptable range
        require(
            tooMuchVolatility(twapPrice, spotPrice) == false,
            "UniswapV3VaultOperations: Spot price is not within the acceptable range"
        );
    }

    function tooMuchVolatility(
        uint256 twPrice, // amount of token1 needed for 1 token0
        uint256 spotPrice // amount of token1 needed for 1 token0
    )
        internal
        pure
        returns (bool)
    {
        // calculate the acceptable price difference
        uint256 acceptablePriceDiff = twPrice.mulDiv(MAX_ACCEPTABLE_PRICE_DIFF_BASIS_POINT, BASIS_POINT_SCALE);
        /////
        // display the abs value between (spot +- acceptablePriceDiff) - twPrice
        console.log("acceptablePriceDiff:", acceptablePriceDiff);
        console.log("spotPrice:", spotPrice);
        console.log("twPrice:", twPrice);
        console.log("abs(spotPrice - twPrice):", spotPrice > twPrice ? spotPrice - twPrice : twPrice - spotPrice);
        console.log("acceptablePriceDiff:", acceptablePriceDiff);
        /////
        // check if the spot price is within the acceptable range
        return !(spotPrice >= twPrice - acceptablePriceDiff && spotPrice <= twPrice + acceptablePriceDiff);
    }

    // decimals is the decimals for the tokens which serves as unit price
    function getPrices(uint8 decimals) internal view returns (uint256 twPrice, uint256 spotPrice) {
        // // get the spot price of the pool
        // (uint160 sqrtPriceX96, , , , , , ) = pool.slot0();
        // spotPrice = UniswapUtils.sqrtPriceX96ToPrice(sqrtPriceX96, decimals0, decimals1);

        // // get the TWAP price
        // twPrice = UniswapUtils.getTwap(pool, TWAP_PERIOD, decimals0, decimals1);

        // // detect which token we want the price of based on the decimals
        // if (decimals == decimals0) {
        //     // If we need token0 price, return prices
        //     return (twPrice, spotPrice);
        // } else if (decimals == decimals1) {
        //     console.log("decimals1:", decimals1);
        //     // If we need token1, invert the token price and use the SCALING_FACTOR
        //     return (
        //         (10 ** decimals).mulDiv(SCALING_FACTOR, twPrice),
        //         (10 ** decimals).mulDiv(SCALING_FACTOR, spotPrice)
        //     );
        // } else {
        //     revert("Unknown decimal value");
        // }
    }
}
