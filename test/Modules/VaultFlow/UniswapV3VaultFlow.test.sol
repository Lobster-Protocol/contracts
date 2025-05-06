// SPDX-License-Identifier: GNUv3
pragma solidity ^0.8.28;

import "forge-std/Test.sol";

import {UniswapV3VaultOperationsSetup} from "../../Vault/VaultSetups/WithRealModules/UniswapV3VaultOperationsSetup.sol";
import {INonFungiblePositionManager} from "../../../src/interfaces/uniswapV3/INonFungiblePositionManager.sol";
import {IUniswapV3FactoryMinimal} from "../../../src/interfaces/uniswapV3/IUniswapV3FactoryMinimal.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IVaultFlowModule} from "../../../src/interfaces/modules/IVaultFlowModule.sol";
import {UniswapV3VaultFlow} from "../../../src/Modules/VaultFlow/UniswapV3WithTwap.sol";
import {MockERC20} from "../../Mocks/MockERC20.sol";

contract UniswapV3VaultOperations is UniswapV3VaultOperationsSetup {
    function testDeposit() public {
        // set timestamp to january 1st 2025 GMT
        vm.warp(1735689600); // we need this, otherwise when we call pool.observe(1 hour), it will revert. (only needs to be > 1 hour)

        vm.startPrank(alice);
        uint256 initialAliceAssetBalance = IERC20(vault.asset()).balanceOf(alice);
        uint256 initialVaultAssetBalance = IERC20(vault.asset()).balanceOf(address(vault));

        // alice deposit
        uint256 depositedAmount = 1 ether;
        uint256 expectedShares = vault.convertToShares(depositedAmount);
        // ensure the deposit event is emitted
        vm.expectEmit(true, true, true, true);
        emit IERC4626.Deposit(alice, alice, depositedAmount, expectedShares);
        vault.deposit(depositedAmount, alice);

        vm.stopPrank();

        // ensure the transfer happened
        vm.assertEq(IERC20(vault.asset()).balanceOf(alice), initialAliceAssetBalance - depositedAmount);
        vm.assertEq(IERC20(vault.asset()).balanceOf(address(vault)), initialVaultAssetBalance + depositedAmount);
    }

    // function testDepositHighVolatility() public {
    //     // todo
    // }

    // function testWithdraw() public {
    //     IVaultFlowModule vaultOps = IVaultFlowModule(address(vault.vaultFlow()));
    //     vaultOps._withdraw(address(vault), alice, alice, 1 ether, 1 ether);
    //     revert("voluntary revert");
    // }

    // function testWithdrawWithHighVolatilityAndNoWithdrawerAdvantage() public {
    //     // IVaultFlowModule vaultOps = IVaultFlowModule(address(vault.vaultOperations()));
    //     // vaultOps._withdraw(address(vault), alice, alice, 1 ether, 1 ether);
    //     // revert("voluntary revert");
    // }

    // function testWithdrawWithHighVolatilityAndWithdrawerAdvantage() public {
    //     // IVaultFlowModule vaultOps = IVaultFlowModule(address(vault.vaultOperations()));
    //     // vaultOps._withdraw(address(vault), alice, alice, 1 ether, 1 ether);
    //     // revert("voluntary revert");
    // }

    // function testTotalAssets()

    function testTotalAssetsForWithNoPositions() public view {
        /* ------ test total assets for ------ */
        uint256 expectedTotalAssets = 0;
        uint256 totalAsset = UniswapV3VaultFlow(address(vault.vaultFlow())).totalAssetsFor(vault);

        assertEq(totalAsset, expectedTotalAssets);
    }

    function testTotalAssetsForWithPositions() public {
        vm.startPrank(alice);
        // mint tokens
        uint256 mintedAmount = 10000 ether;
        MockERC20(uniswapV3Data.tokenA).mint(alice, mintedAmount);
        MockERC20(uniswapV3Data.tokenB).mint(alice, mintedAmount);

        // approve tokens for the pool
        IERC20(uniswapV3Data.tokenA).approve(address(uniswapV3Data.positionManager), type(uint256).max);
        IERC20(uniswapV3Data.tokenB).approve(address(uniswapV3Data.positionManager), type(uint256).max);

        // deposit some assets as lp
        uint256 depositedAmount = 1 ether;

        (
            ,
            ,
            // tokenId
            // liquidity
            uint256 amount0,
            uint256 amount1
        ) = createPosition(
            uniswapV3Data.positionManager,
            uniswapV3Data.tokenA,
            uniswapV3Data.tokenB,
            depositedAmount,
            depositedAmount,
            uniswapV3Data.poolFee,
            address(vault) // vault will be the position owner
        );

        /* ------ test total assets for ------ */
        // test with 1 position
        uint256 expectedTotalAssets = amount0 + amount1; // 2 assets in the pool with a quote of 1:1
        uint256 totalAsset = UniswapV3VaultFlow(address(vault.vaultFlow())).totalAssetsFor(vault);

        assert(totalAsset >= expectedTotalAssets - 2 && totalAsset <= expectedTotalAssets); // uniswap rounds down the amount of tokens in the pool so we accept 1 token difference for each deposited token (2 tokens in total with a quote of 1:1)

        // test with a new position
        // create a new position
        (
            ,
            ,
            // tokenId
            // liquidity
            uint256 amount0New,
            uint256 amount1New
        ) = createPosition(
            uniswapV3Data.positionManager,
            uniswapV3Data.tokenA,
            uniswapV3Data.tokenB,
            depositedAmount,
            depositedAmount,
            uniswapV3Data.poolFee,
            address(vault) // vault will be the position owner
        );

        // test with 2 positions
        expectedTotalAssets = amount0 + amount1 + amount0New + amount1New; // 2 assets in the pool with a quote of 1:1
        totalAsset = UniswapV3VaultFlow(address(vault.vaultFlow())).totalAssetsFor(vault);

        assert(totalAsset >= expectedTotalAssets - 4 && totalAsset <= expectedTotalAssets); // uniswap rounds down the amount of tokens in the pool so we accept 1 token difference for each deposited token: 2*(2 tokens in total with a quote of 1:1) = 4

        vm.stopPrank();
    }
}
