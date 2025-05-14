// SPDX-License-Identifier: GNUv3
pragma solidity ^0.8.28;

import {PositionValue} from "../../../src/libraries/uniswapV3/PositionValue.sol";
import "forge-std/Test.sol";

import {UniswapV3VaultFlowSetup} from "../../Vault/VaultSetups/WithRealModules/UniswapV3VaultFlowSetup.sol";
import {INonFungiblePositionManager} from "../../../src/interfaces/uniswapV3/INonFungiblePositionManager.sol";
import {IUniswapV3FactoryMinimal} from "../../../src/interfaces/uniswapV3/IUniswapV3FactoryMinimal.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IVaultFlowModule} from "../../../src/interfaces/modules/IVaultFlowModule.sol";
import {UniswapV3VaultFlow} from "../../../src/Modules/VaultFlow/UniswapV3VaultFlow.sol";
import {MockERC20} from "../../Mocks/MockERC20.sol";
import {BatchOp, BaseOp, Op} from "../../../src/interfaces/modules/IOpValidatorModule.sol";
import {IUniswapV3PoolMinimal} from "../../../src/interfaces/uniswapV3/IUniswapV3PoolMinimal.sol";
import {IUniswapV3RouterMinimal} from "../../../src/interfaces/uniswapV3/IUniswapV3RouterMinimal.sol";

contract UniswapV3VaultFlowTest is UniswapV3VaultFlowSetup {
    function testDeposit() public {
        vm.startPrank(alice);
        uint256 initialAliceAssetBalance = IERC20(vault.asset()).balanceOf(alice);
        uint256 initialVaultAssetBalance = IERC20(vault.asset()).balanceOf(address(vault));

        // alice deposit
        uint256 depositedAmount = 1 ether;
        uint256 expectedShares = vault.convertToShares(depositedAmount);
        // ensure the deposit event is emitted
        vm.expectEmit(true, true, true, true);
        emit IERC4626.Deposit(alice, alice, depositedAmount, expectedShares);
        uint256 shares = vault.deposit(depositedAmount, alice);

        vm.stopPrank();

        // ensure the transfer happened
        vm.assertEq(IERC20(vault.asset()).balanceOf(alice), initialAliceAssetBalance - depositedAmount);
        vm.assertEq(IERC20(vault.asset()).balanceOf(address(vault)), initialVaultAssetBalance + depositedAmount);
        vm.assertEq(vault.balanceOf(alice), shares);
    }

    function testWithdrawNoPositions() public {
        // set timestamp to january 1st 2025 GMT
        vm.warp(1735689600); // we need this, otherwise when we call pool.observe(1 hour), it will revert. (only needs to be > 1 hour)

        vm.startPrank(alice);
        // Alice deposits 1 ether into the vault
        uint256 aliceDeposit = 1 ether;
        uint256 mintedShares = vault.deposit(aliceDeposit, alice);

        // Alice withdraws all her shares
        uint256 sharesToWithdraw = mintedShares;
        uint256 expectedAssets = vault.convertToAssets(sharesToWithdraw);
        uint256 initialAliceAssetBalance = IERC20(vault.asset()).balanceOf(alice);
        uint256 initialVaultAssetBalance = IERC20(vault.asset()).balanceOf(address(vault));
        // ensure the withdraw event is emitted
        vm.expectEmit(true, true, true, true);
        emit IERC4626.Withdraw(alice, alice, alice, sharesToWithdraw, expectedAssets);
        vault.withdraw(sharesToWithdraw, alice, alice);

        // ensure the transfer happened
        vm.assertEq(IERC20(vault.asset()).balanceOf(alice), initialAliceAssetBalance + expectedAssets);
        vm.assertEq(IERC20(vault.asset()).balanceOf(address(vault)), initialVaultAssetBalance - expectedAssets);

        vm.stopPrank();
    }

    // Should withdraw the necessary funds from the uniswap positions
    function testWithdrawWithPosition() public {
        // set timestamp to january 1st 2025 GMT
        uint256 initialTimestamp = 1735689600;
        vm.warp(initialTimestamp); // we need this, otherwise when we call pool.observe(1 hour), it will revert. (only needs to be > 1 hour)

        // random dude deposits 1000 ether into the pool
        vm.startPrank(bob);
        uint256 amountA = 10_000 ether;
        uint256 amountB = 10_000 ether;
        // mint some tokens for the test
        MockERC20(uniswapV3Data.tokenA).mint(bob, amountA); // 1000 tokens with 18 decimals
        MockERC20(uniswapV3Data.tokenB).mint(bob, amountB); // 1000 tokens with 18 decimals

        createPosition(
            uniswapV3Data.positionManager,
            uniswapV3Data.tokenA,
            uniswapV3Data.tokenB,
            amountA,
            amountB,
            uniswapV3Data.poolFee,
            bob
        );

        vm.stopPrank();

        vm.startPrank(alice);
        console.log("vault asset balance 0: ", IERC20(vault.asset()).balanceOf(address(vault)));
        uint256 initialToken0Alice = IERC20(uniswapV3Data.tokenA).balanceOf(alice);
        uint256 initialToken1Alice = IERC20(uniswapV3Data.tokenB).balanceOf(alice);
        // Alice deposits 1 ether into the vault
        uint256 aliceDeposit = 1 ether;
        uint256 expectedMintedShares = vault.previewDeposit(aliceDeposit);
        uint256 mintedShares = vault.deposit(aliceDeposit, alice);

        // Ensure the expected shares were minted
        assertEq(expectedMintedShares, mintedShares);

        vm.stopPrank();
        console.log("vault asset balance 1: ", IERC20(vault.asset()).balanceOf(address(vault)));

        // approve tokenA
        BaseOp memory op0 = BaseOp({
            target: address(uniswapV3Data.tokenA),
            value: 0,
            data: abi.encodeCall(IERC20.approve, (address(uniswapV3Data.router), type(uint256).max))
        });
        vault.executeOp(Op(op0, ""));

        // approve tokenB
        BaseOp memory op1 = BaseOp({
            target: address(uniswapV3Data.tokenB),
            value: 0,
            data: abi.encodeCall(IERC20.approve, (address(uniswapV3Data.router), type(uint256).max))
        });
        vault.executeOp(Op(op1, ""));

        // swap 50% of the deposit to tokenB
        BaseOp memory op2 = BaseOp({
            target: address(uniswapV3Data.router),
            value: 0,
            data: abi.encodeCall(
                IUniswapV3RouterMinimal.exactInputSingle,
                (
                    IUniswapV3RouterMinimal.ExactInputSingleParams({
                        tokenIn: vault.asset(),
                        tokenOut: vault.asset() == uniswapV3Data.tokenA ? uniswapV3Data.tokenB : uniswapV3Data.tokenA,
                        fee: uniswapV3Data.poolFee,
                        recipient: address(vault),
                        deadline: block.timestamp + 1 hours,
                        amountIn: aliceDeposit / 2,
                        amountOutMinimum: ((aliceDeposit / 2) * 99) / 100, // 1% slippage
                        sqrtPriceLimitX96: 0
                    })
                )
            )
        });

        vault.executeOp(Op(op2, ""));
        console.log("vault asset balance 2: ", IERC20(vault.asset()).balanceOf(address(vault)));

        // get both token amounts
        uint256 tokenAInVaultAfterSwap = IERC20(uniswapV3Data.tokenA).balanceOf(address(vault));
        uint256 tokenBInVaultAfterSwap = IERC20(uniswapV3Data.tokenB).balanceOf(address(vault)); // expected to be <= aliceDeposit/2 because of the slippage

        console.log("vault balances after swap: ", tokenAInVaultAfterSwap, tokenBInVaultAfterSwap);

        // allow the position manager to spend the tokens
        BaseOp memory op3 = BaseOp({
            target: address(uniswapV3Data.tokenA),
            value: 0,
            data: abi.encodeCall(IERC20.approve, (address(uniswapV3Data.positionManager), type(uint256).max))
        });
        vault.executeOp(Op(op3, ""));
        BaseOp memory op4 = BaseOp({
            target: address(uniswapV3Data.tokenB),
            value: 0,
            data: abi.encodeCall(IERC20.approve, (address(uniswapV3Data.positionManager), type(uint256).max))
        });
        vault.executeOp(Op(op4, ""));

        // Create a new position with the swapped tokens
        BaseOp memory op5 = BaseOp({
            target: address(uniswapV3Data.positionManager),
            value: 0,
            data: abi.encodeCall(
                INonFungiblePositionManager.mint,
                (
                    INonFungiblePositionManager.MintParams({
                        token0: uniswapV3Data.tokenA > uniswapV3Data.tokenB ? uniswapV3Data.tokenB : uniswapV3Data.tokenA,
                        token1: uniswapV3Data.tokenA > uniswapV3Data.tokenB ? uniswapV3Data.tokenA : uniswapV3Data.tokenB,
                        fee: uniswapV3Data.poolFee,
                        tickLower: -6000,
                        tickUpper: 6000,
                        amount0Desired: uniswapV3Data.tokenA > uniswapV3Data.tokenB
                            ? tokenAInVaultAfterSwap
                            : tokenBInVaultAfterSwap,
                        amount1Desired: uniswapV3Data.tokenA > uniswapV3Data.tokenB
                            ? tokenBInVaultAfterSwap
                            : tokenAInVaultAfterSwap,
                        // todo: adapt the sqrt price depending on the old one with the new swap from (op2) (or use the output amount to estimate sqrt price ??)
                        amount0Min: (
                            (uniswapV3Data.tokenA > uniswapV3Data.tokenB ? tokenAInVaultAfterSwap : tokenBInVaultAfterSwap) * 99
                        ) / 100,
                        amount1Min: (
                            (uniswapV3Data.tokenA > uniswapV3Data.tokenB ? tokenBInVaultAfterSwap : tokenAInVaultAfterSwap) * 99
                        ) / 100,
                        recipient: address(vault),
                        deadline: block.timestamp + 1 hours
                    })
                )
            )
        });

        vault.executeOp(Op(op5, ""));

        // Alice withdraws all her shares
        vm.startPrank(alice);
        uint256 assetsToWithdraw = vault.maxWithdraw(alice);

        // // ensure the withdraw event is emitted
        // vm.expectEmit(true, true, true, true);
        // emit IERC4626.Withdraw(
        //     alice,
        //     alice,
        //     alice,
        //     sharesToWithdraw,
        //     expectedAssets
        // );
        vault.withdraw(assetsToWithdraw, alice, alice);
        console.log(
            "final vault balances: ",
            IERC20(uniswapV3Data.tokenA).balanceOf(address(vault)),
            IERC20(uniswapV3Data.tokenB).balanceOf(address(vault))
        );
        console.log(
            "final alice balances delta0: ",
            int256(IERC20(uniswapV3Data.tokenA).balanceOf(alice)) - int256(initialToken0Alice)
        );
        console.log(
            "final alice balances delta1: ",
            int256(IERC20(uniswapV3Data.tokenB).balanceOf(alice)) - int256(initialToken1Alice)
        );

        // // ensure the transfer happened
        // vm.assertEq(
        //     IERC20(vault.asset()).balanceOf(alice),
        //     initialAliceAssetBalance + expectedAssets
        // );
        // vm.assertEq(
        //     IERC20(vault.asset()).balanceOf(address(vault)),
        //     initialVaultAssetBalance - expectedAssets
        // );

        vm.stopPrank();
    }

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
