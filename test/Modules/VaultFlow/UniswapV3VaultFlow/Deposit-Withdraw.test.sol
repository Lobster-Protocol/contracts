// SPDX-License-Identifier: GNUv3
pragma solidity ^0.8.28;

import {PositionValue} from "../../../../src/libraries/uniswapV3/PositionValue.sol";
import "forge-std/Test.sol";

import {UniswapV3VaultFlowSetup} from "../../../Vault/VaultSetups/WithRealModules/UniswapV3VaultFlowSetup.sol";
import {INonFungiblePositionManager} from "../../../../src/interfaces/uniswapV3/INonFungiblePositionManager.sol";
import {IUniswapV3FactoryMinimal} from "../../../../src/interfaces/uniswapV3/IUniswapV3FactoryMinimal.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IVaultFlowModule} from "../../../../src/interfaces/modules/IVaultFlowModule.sol";
import {UniswapV3VaultFlow} from "../../../../src/Modules/VaultFlow/UniswapV3VaultFlow.sol";
import {MockERC20} from "../../../Mocks/MockERC20.sol";
import {BatchOp, BaseOp, Op} from "../../../../src/interfaces/modules/IOpValidatorModule.sol";
import {IUniswapV3PoolMinimal} from "../../../../src/interfaces/uniswapV3/IUniswapV3PoolMinimal.sol";
import {IUniswapV3RouterMinimal} from "../../../../src/interfaces/uniswapV3/IUniswapV3RouterMinimal.sol";

contract UniswapV3VaultFlowTest is UniswapV3VaultFlowSetup {
    function testDepositNoFees() public {
        // alice deposit
        uint256 depositedAmount0 = 1 ether;
        uint256 depositedAmount1 = 3 ether;

        depositToVault(alice, depositedAmount0, depositedAmount1);

        // tests are done in 'depositToVault' fct
    }

    function testWithdrawNoPositionsNoFees() public {
        uint256 aliceDeposit0 = 1 ether;
        uint256 aliceDeposit1 = 3 ether;

        uint256 mintedShares = depositToVault(alice, aliceDeposit0, aliceDeposit1);

        // Alice withdraws all her shares
        uint256 expectedAssets = packUint128(uint128(aliceDeposit0), uint128(aliceDeposit1));

        uint256 redeemedShares = withdrawFromVault(alice, expectedAssets);

        vm.assertEq(mintedShares, redeemedShares);
    }

    // Should withdraw the necessary funds from the uniswap positions
    function testWithdrawWithPositionNoFees() public {
        // Alice deposits into the vault
        uint256 aliceDeposit0 = 1 ether;
        uint256 aliceDeposit1 = 3 ether;

        uint256 mintedShares = depositToVault(alice, aliceDeposit0, aliceDeposit1);

        // get both token amounts
        uint256 tokenAInVault = IERC20(uniswapV3Data.tokenA).balanceOf(address(vault));
        uint256 tokenBInVault = IERC20(uniswapV3Data.tokenB).balanceOf(address(vault));

        // allow the position manager to spend the tokens
        vaultOpApproveToken(uniswapV3Data.tokenA, address(uniswapV3Data.positionManager));

        // Create a new position with the swapped tokens
        vaultOpMintUniswapPosition(
            uniswapV3Data.tokenA > uniswapV3Data.tokenB ? tokenAInVault : tokenBInVault / 3, // todo: get the expected amount using sqrt prices
            uniswapV3Data.tokenA > uniswapV3Data.tokenB
                ? tokenBInVault / 3 // todo: get the expected amount using sqrt prices
                : tokenAInVault,
            -6000,
            6000,
            100
        );

        // Alice withdraws all her shares
        uint256 expectedAssets = vault.maxWithdraw(alice);

        uint256 burntShares = withdrawFromVault(alice, expectedAssets);

        // Ensure all the assets have been withdrawn
        vm.assertEq(vault.totalAssets(), 0);
        vm.assertEq(mintedShares, burntShares);
        vm.assertEq(vault.balanceOf(alice), mintedShares - burntShares);
    }

    function testMintNoFees() public {
        // alice shares to mint
        uint256 sharesToMint = 1 ether;

        mintVaultShares(alice, sharesToMint);

        // tests are done in 'mintVaultShares' fct
    }

    function testRedeemNoPositionNoFees() public {
        uint256 sharesToMint = 1 ether;

        uint256 depositedAssetsPacked = mintVaultShares(alice, sharesToMint);

        uint256 vaultBalance0AfterMint = IERC20(uniswapV3Data.tokenA).balanceOf(address(vault));
        uint256 vaultBalance1AfterMint = IERC20(uniswapV3Data.tokenB).balanceOf(address(vault));
        uint256 aliceBalance0AfterMint = IERC20(uniswapV3Data.tokenA).balanceOf(alice);
        uint256 aliceBalance1AfterMint = IERC20(uniswapV3Data.tokenB).balanceOf(alice);

        uint256 expectedAssetsToRedeem = vault.previewRedeem(sharesToMint);

        uint256 withdrawnAssets = redeemVaultShares(alice, sharesToMint);

        uint256 vaultFinalBalance0 = IERC20(uniswapV3Data.tokenA).balanceOf(address(vault));
        uint256 vaultFinalBalance1 = IERC20(uniswapV3Data.tokenB).balanceOf(address(vault));
        uint256 aliceFinalBalance0 = IERC20(uniswapV3Data.tokenA).balanceOf(alice);
        uint256 aliceFinalBalance1 = IERC20(uniswapV3Data.tokenB).balanceOf(alice);

        (uint256 token0Withdrawn, uint256 token1Withdrawn) = decodePackedUint128(depositedAssetsPacked);

        // Ensure value matching
        vm.assertEq(expectedAssetsToRedeem, depositedAssetsPacked);
        vm.assertEq(expectedAssetsToRedeem, withdrawnAssets);

        // Ensure asset transfers
        vm.assertEq(vaultBalance0AfterMint, vaultFinalBalance0 + token0Withdrawn);
        vm.assertEq(vaultBalance1AfterMint, vaultFinalBalance1 + token1Withdrawn);
        vm.assertEq(aliceBalance0AfterMint + token0Withdrawn, aliceFinalBalance0);
        vm.assertEq(aliceBalance1AfterMint + token1Withdrawn, aliceFinalBalance1);
    }

    function testRedeemWithPositionNoFees() public {
        uint256 mintedShares = 3 ether;

        mintVaultShares(alice, mintedShares);

        // get both token amounts
        uint256 tokenAInVault = IERC20(uniswapV3Data.tokenA).balanceOf(address(vault));
        uint256 tokenBInVault = IERC20(uniswapV3Data.tokenB).balanceOf(address(vault));

        // allow the position manager to spend the tokens
        vaultOpApproveToken(uniswapV3Data.tokenA, address(uniswapV3Data.positionManager));

        // Create a new position with the swapped tokens
        vaultOpMintUniswapPosition(
            uniswapV3Data.tokenA > uniswapV3Data.tokenB ? tokenAInVault : tokenBInVault, // todo: get the expected amount using sqrt prices
            uniswapV3Data.tokenA > uniswapV3Data.tokenB
                ? tokenBInVault // todo: get the expected amount using sqrt prices
                : tokenAInVault,
            -6000,
            6000,
            100
        );

        redeemVaultShares(alice, mintedShares);

        // Ensure all the assets have been withdrawn
        vm.assertEq(vault.totalAssets(), 0);
        vm.assertEq(0, vault.balanceOf(alice));

        // other necessary checks are done in 'redeemVaultShares'
    }

    // function testTotalAssets()

    //     function testTotalAssetsForWithNoPositions() public view {
    //         /* ------ test total assets for ------ */
    //         uint256 expectedTotalAssets = 0;
    //         uint256 totalAsset = UniswapV3VaultFlow(address(vault.vaultFlow()))
    //             .totalAssetsFor(vault);

    //         assertEq(totalAsset, expectedTotalAssets);
    //     }

    //     function testTotalAssetsForWithPositions() public {
    //         vm.startPrank(alice);
    //         // mint tokens
    //         uint256 mintedAmount = 10000 ether;
    //         MockERC20(uniswapV3Data.tokenA).mint(alice, mintedAmount);
    //         MockERC20(uniswapV3Data.tokenB).mint(alice, mintedAmount);

    //         // approve tokens for the pool
    //         IERC20(uniswapV3Data.tokenA).approve(
    //             address(uniswapV3Data.positionManager),
    //             type(uint256).max
    //         );
    //         IERC20(uniswapV3Data.tokenB).approve(
    //             address(uniswapV3Data.positionManager),
    //             type(uint256).max
    //         );

    //         // deposit some assets as lp
    //         uint256 depositedAmount = 1 ether;

    //         (
    //             ,
    //             ,
    //             // tokenId
    //             // liquidity
    //             uint256 amount0,
    //             uint256 amount1
    //         ) = createPosition(
    //                 uniswapV3Data.positionManager,
    //                 uniswapV3Data.tokenA,
    //                 uniswapV3Data.tokenB,
    //                 depositedAmount,
    //                 depositedAmount,
    //                 uniswapV3Data.poolFee,
    //                 address(vault) // vault will be the position owner
    //             );

    //         /* ------ test total assets for ------ */
    //         // test with 1 position
    //         uint256 expectedTotalAssets = amount0 + amount1; // 2 assets in the pool with a quote of 1:1
    //         uint256 totalAsset = UniswapV3VaultFlow(address(vault.vaultFlow()))
    //             .totalAssetsFor(vault);

    //         assert(
    //             totalAsset >= expectedTotalAssets - 2 &&
    //                 totalAsset <= expectedTotalAssets
    //         ); // uniswap rounds down the amount of tokens in the pool so we accept 1 token difference for each deposited token (2 tokens in total with a quote of 1:1)

    //         // test with a new position
    //         // create a new position
    //         (
    //             ,
    //             ,
    //             // tokenId
    //             // liquidity
    //             uint256 amount0New,
    //             uint256 amount1New
    //         ) = createPosition(
    //                 uniswapV3Data.positionManager,
    //                 uniswapV3Data.tokenA,
    //                 uniswapV3Data.tokenB,
    //                 depositedAmount,
    //                 depositedAmount,
    //                 uniswapV3Data.poolFee,
    //                 address(vault) // vault will be the position owner
    //             );

    //         // test with 2 positions
    //         expectedTotalAssets = amount0 + amount1 + amount0New + amount1New; // 2 assets in the pool with a quote of 1:1
    //         totalAsset = UniswapV3VaultFlow(address(vault.vaultFlow()))
    //             .totalAssetsFor(vault);

    //         assert(
    //             totalAsset >= expectedTotalAssets - 4 &&
    //                 totalAsset <= expectedTotalAssets
    //         ); // uniswap rounds down the amount of tokens in the pool so we accept 1 token difference for each deposited token: 2*(2 tokens in total with a quote of 1:1) = 4

    //         vm.stopPrank();
    //     }
}
