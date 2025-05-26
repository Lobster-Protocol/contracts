// SPDX-License-Identifier: GNUv3
pragma solidity ^0.8.28;

import {UniswapV3VaultFlowSetup} from "../../../Vault/VaultSetups/WithRealModules/UniswapV3VaultFlowSetup.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {UniswapV3VaultFlow} from "../../../../src/Modules/VaultFlow/UniswapV3VaultFlow.sol";
import {MockERC20} from "../../../Mocks/MockERC20.sol";

contract UniswapV3VaultFlowTotalAssetsTest is UniswapV3VaultFlowSetup {
    function testTotalAssetsForNoPositionsNoFees() public {
        // alice deposit
        uint256 depositedAmountA = 1 ether;
        uint256 depositedAmountB = 3 ether;

        depositToVault(alice, depositedAmountA, depositedAmountB);

        // get both token amounts
        uint256 tokenAInVault = IERC20(uniswapV3Data.tokenA).balanceOf(address(vault));
        uint256 tokenBInVault = IERC20(uniswapV3Data.tokenB).balanceOf(address(vault));

        vm.assertEq(tokenAInVault, depositedAmountA);
        vm.assertEq(tokenBInVault, depositedAmountB);
    }

    function testTotalAssetsForWithPositionsNoFees() public {
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

        (uint256 totalAssets0, uint256 totalAssets1,,) = getVaultTVL(vault);

        /* ------ test total assets for ------ */
        // test with 1 position
        (uint256 actualTotalAsset0, uint256 actualTotalAsset1) =
            UniswapV3VaultFlow(address(vault.vaultFlow())).totalAssetsFor(vault);

        vm.assertEq(actualTotalAsset0, totalAssets0);
        vm.assertEq(actualTotalAsset1, totalAssets1);

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
        (uint256 newTotalAssets0, uint256 newTotalAssets1,,) = getVaultTVL(vault);
        (uint256 newActualTotalAsset0, uint256 newActualTotalAsset1) =
            UniswapV3VaultFlow(address(vault.vaultFlow())).totalAssetsFor(vault);

        vm.assertEq(newActualTotalAsset0, newTotalAssets0);
        vm.assertEq(newActualTotalAsset1, newTotalAssets1);
        // Assert that actual is within 2 wei of expected
        assertApproxEqAbs(newActualTotalAsset0, amount0 + amount0New, 2, "Values should be within 2 wei");
        assertApproxEqAbs(newActualTotalAsset1, amount1 + amount1New, 2, "Values should be within 2 wei");

        vm.stopPrank();
    }
}
