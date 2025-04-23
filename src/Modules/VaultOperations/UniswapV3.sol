// SPDX-License-Identifier: GNUv3
pragma solidity ^0.8.28;

import {IVaultOperations} from "../../interfaces/modules/IVaultOperations.sol";
import {INav} from "../../interfaces/modules/INav.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IUniswapV3PoolMinimal} from "../../interfaces/uniswapV3/IUniswapV3PoolMinimal.sol";
import {BaseOp, Op} from "../../interfaces/modules/IOpValidatorModule.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {LobsterVault} from "../../../src/Vault/Vault.sol";
import {UniswapUtils, Position} from "../../utils/UniswapUtils.sol";
import {INonfungiblePositionManager} from "../../interfaces/uniswapV3/INonfungiblePositionManager.sol";

uint256 constant BASIS_POINT_SCALE = 10_000;

// Hook used to take a fee when the vault collect its fees from a uniswap pool
contract UniswapV3VaultOperations is IVaultOperations, INav {
    using Math for uint256;

    uint32 constant TWAP_PERIOD = 3600; // 1 hour

    IUniswapV3PoolMinimal public pool;
    INonfungiblePositionManager public positionManager;

    // The maximum acceptable price difference between the spot price and the TWAP price
    uint256 public constant MAX_ACCEPTABLE_PRICE_DIFF_BASIS_POINT = 150; // 1.5%

    constructor(
        IUniswapV3PoolMinimal _pool,
        INonfungiblePositionManager positionManager_
    ) {
        pool = _pool;
        positionManager = positionManager_;
    }

    function _deposit(
        address caller,
        address receiver,
        uint256 assets,
        uint256 shares
    ) external returns (bool success) {
        (uint256 twapPrice, uint256 spotPrice) = getPrices();
        // refuse to deposit if the price is too volatile (i.e. the spot price is too far from the TWAP price)
        // security measure to protect the depositor or the vault for a potential arbitrage attack
        requireLowVolatility(twapPrice, spotPrice);

        LobsterVault vault = LobsterVault(msg.sender);

        // transfer before minting to avoid reentrancy
        vault.safeTransferFrom(
            IERC20(vault.asset()),
            caller,
            address(vault),
            assets
        );
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
    ) external returns (bool success) {
        (uint256 twapPrice, uint256 spotPrice) = getPrices();

        // if the volatility is too high and the withdrawer is advantaged (arbitrage), create a slippage to protect the vault
        if (
            tooMuchVolatility(twapPrice, spotPrice) == true &&
            spotPrice < twapPrice
        ) {
            /* 
                If spotPrice < twapPrice, the vault tvl will be over evaluated and during withdrawal, 
                the vault will transfer more eth than necessary.
                This snippets aims to fix this
            */

            // Estimate the slippage
            uint256 slippageDiffBasisPoint = spotPrice.mulDiv(
                BASIS_POINT_SCALE,
                twapPrice
            );

            // reduce the withdrawn asset amount accordingly
            assets = assets.mulDiv(slippageDiffBasisPoint, BASIS_POINT_SCALE);
        }

        LobsterVault vault = LobsterVault(msg.sender);

        // todo: withdraw the tokens we need from uniswap

        // Burn shares
        vault.burnShares(owner, shares);
        // Transfer the assets
        vault.safeTransfer(IERC20(vault.asset()), receiver, assets);

        emit IERC4626.Withdraw(caller, receiver, owner, assets, shares);

        return true;
    }

    // only takes the vault asset into account
    function totalAssets() external view returns (uint256 tvl) {
        IERC20 poolToken0 = IERC20(pool.token0());
        IERC20 poolToken1 = IERC20(pool.token1());

        bool isVaultAssetToken0 = address(poolToken1) ==
            LobsterVault(msg.sender).asset()
            ? true
            : false;

        require(
            isVaultAssetToken0 ||
                address(poolToken1) == LobsterVault(msg.sender).asset(),
            "None of the pool assets is in the pool"
        );

        // Get the pool assets owned by the vault
        tvl = 0;

        if (isVaultAssetToken0) {
            tvl += poolToken0.balanceOf(msg.sender);
        } else {
            tvl += poolToken1.balanceOf(msg.sender);
        }

        // Get all the positions in the pool (+ non collected fees)
        (Position memory position0, Position memory position1) = UniswapUtils
            .getUniswapV3Positions(
                pool,
                positionManager,
                msg.sender,
                address(poolToken0),
                address(poolToken1)
            );

        if (isVaultAssetToken0) {
            tvl += position0.value;
        } else {
            tvl += position1.value;
        }
    }

    function requireLowVolatility(
        uint256 twapPrice,
        uint256 spotPrice
    ) internal pure {
        // check if the spot price is within the acceptable range
        require(
            tooMuchVolatility(twapPrice, spotPrice) == false,
            "UniswapV3VaultOperations: Spot price is not within the acceptable range"
        );
    }

    function tooMuchVolatility(
        uint256 twPrice,
        uint256 spotPrice
    ) internal pure returns (bool) {
        // calculate the acceptable price difference
        uint256 acceptablePriceDiff = twPrice.mulDiv(
            MAX_ACCEPTABLE_PRICE_DIFF_BASIS_POINT,
            BASIS_POINT_SCALE
        );

        // check if the spot price is within the acceptable range
        return
            !(spotPrice >= twPrice - acceptablePriceDiff &&
                spotPrice <= twPrice + acceptablePriceDiff);
    }

    function getPrices()
        internal
        view
        returns (uint256 twPrice, uint256 spotPrice)
    {
        // get the spot price of the pool
        (uint160 sqrtPriceX96, , , , , , ) = pool.slot0();
        spotPrice = UniswapUtils.sqrtPriceX96ToPrice(sqrtPriceX96);

        // get the TWAP price
        twPrice = UniswapUtils.getTwap(pool, TWAP_PERIOD);
    }
}
