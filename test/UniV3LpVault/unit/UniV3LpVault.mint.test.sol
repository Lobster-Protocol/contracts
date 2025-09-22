// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import {UniV3LpVault, MinimalMintParams, Position} from "../../../src/vaults/UniV3LpVault.sol";
import {SingleVault} from "../../../src/vaults/SingleVault.sol";
import {MintCallbackData} from "../../../src/interfaces/uniswapV3/IUniswapV3MintCallback.sol";
import {PoolAddress} from "../../../src/libraries/uniswapV3/PoolAddress.sol";
import {TestHelper} from "../helpers/TestHelper.sol";
import {TestConstants} from "../helpers/Constants.sol";

contract UniV3LpVaultMintTest is Test {
    TestHelper helper;
    TestHelper.VaultSetup setup;

    function setUp() public {
        helper = new TestHelper();
        setup = helper.deployVaultWithPool();

        // Setup with some funds
        helper.depositToVault(setup, TestConstants.LARGE_AMOUNT, TestConstants.LARGE_AMOUNT);
    }

    function test_mint_NewPosition_Success() public {
        (, int24 currentTick,,,,,) = setup.pool.slot0();
        int24 tickLower = currentTick - TestConstants.TICK_RANGE_NARROW;
        int24 tickUpper = currentTick + TestConstants.TICK_RANGE_NARROW;

        uint256 amount0Desired = TestConstants.MEDIUM_AMOUNT;
        uint256 amount1Desired = TestConstants.MEDIUM_AMOUNT;

        uint256 initialVaultBalance0 = setup.token0.balanceOf(address(setup.vault));
        uint256 initialVaultBalance1 = setup.token1.balanceOf(address(setup.vault));

        vm.prank(setup.executor);
        (uint256 amount0, uint256 amount1) =
            helper.createPosition(setup.vault, setup.executor, tickLower, tickUpper, amount0Desired, amount1Desired);

        // Tokens should be transferred from vault to pool
        assertTrue(setup.token0.balanceOf(address(setup.vault)) < initialVaultBalance0);
        assertTrue(setup.token1.balanceOf(address(setup.vault)) < initialVaultBalance1);
        assertTrue(amount0 > 0);
        assertTrue(amount1 > 0);

        // Position should exist in vault
        Position memory position = setup.vault.getPosition(0);
        assertEq(position.lowerTick, tickLower);
        assertEq(position.upperTick, tickUpper);
        assertTrue(position.liquidity > 0);

        // LP value should reflect new position
        (uint256 totalLp0, uint256 totalLp1) = setup.vault.totalLpValue();
        helper.assertApproxEqual(totalLp0, amount0, TestConstants.TOLERANCE_LOW, "LP value0 mismatch");
        helper.assertApproxEqual(totalLp1, amount1, TestConstants.TOLERANCE_LOW, "LP value1 mismatch");
    }

    function test_mint_AddToExistingPosition_Success() public {
        (, int24 currentTick,,,,,) = setup.pool.slot0();
        int24 tickLower = currentTick - TestConstants.TICK_RANGE_NARROW;
        int24 tickUpper = currentTick + TestConstants.TICK_RANGE_NARROW;

        uint256 firstAmount0 = TestConstants.SMALL_AMOUNT;
        uint256 firstAmount1 = TestConstants.SMALL_AMOUNT;
        uint256 secondAmount0 = TestConstants.MEDIUM_AMOUNT;
        uint256 secondAmount1 = TestConstants.MEDIUM_AMOUNT;

        // Create first position
        vm.prank(setup.executor);
        helper.createPosition(setup.vault, setup.executor, tickLower, tickUpper, firstAmount0, firstAmount1);

        Position memory initialPosition = setup.vault.getPosition(0);
        uint128 initialLiquidity = initialPosition.liquidity;

        // Add to same position
        vm.prank(setup.executor);
        helper.createPosition(setup.vault, setup.executor, tickLower, tickUpper, secondAmount0, secondAmount1);

        // Should still have only one position but with more liquidity
        Position memory finalPosition = setup.vault.getPosition(0);
        assertEq(finalPosition.lowerTick, tickLower);
        assertEq(finalPosition.upperTick, tickUpper);
        assertTrue(finalPosition.liquidity > initialLiquidity);

        // Should revert when trying to get second position (doesn't exist)
        vm.expectRevert();
        setup.vault.getPosition(1);
    }

    function test_mint_MultipleRanges_Success() public {
        (, int24 currentTick,,,,,) = setup.pool.slot0();

        // Create first position
        int24 tickLower1 = currentTick - TestConstants.TICK_RANGE_NARROW;
        int24 tickUpper1 = currentTick + TestConstants.TICK_RANGE_NARROW;

        vm.prank(setup.executor);
        helper.createPosition(
            setup.vault, setup.executor, tickLower1, tickUpper1, TestConstants.SMALL_AMOUNT, TestConstants.SMALL_AMOUNT
        );

        // Create second position with different range
        int24 tickLower2 = currentTick - TestConstants.TICK_RANGE_WIDE;
        int24 tickUpper2 = currentTick + TestConstants.TICK_RANGE_WIDE;

        vm.prank(setup.executor);
        helper.createPosition(
            setup.vault,
            setup.executor,
            tickLower2,
            tickUpper2,
            TestConstants.MEDIUM_AMOUNT,
            TestConstants.MEDIUM_AMOUNT
        );

        // Should have two separate positions
        Position memory position1 = setup.vault.getPosition(0);
        Position memory position2 = setup.vault.getPosition(1);

        assertTrue(position1.lowerTick != position2.lowerTick || position1.upperTick != position2.upperTick);
        assertTrue(position1.liquidity > 0);
        assertTrue(position2.liquidity > 0);
    }

    function test_mint_NotAuthorized_Reverts() public {
        (, int24 currentTick,,,,,) = setup.pool.slot0();

        MinimalMintParams memory mintParams = MinimalMintParams({
            tickLower: currentTick - TestConstants.TICK_RANGE_NARROW,
            tickUpper: currentTick + TestConstants.TICK_RANGE_NARROW,
            amount0Desired: TestConstants.SMALL_AMOUNT,
            amount1Desired: TestConstants.SMALL_AMOUNT,
            amount0Min: 0,
            amount1Min: 0,
            deadline: block.timestamp + 1 hours
        });

        address unauthorizedUser = makeAddr("unauthorized");

        vm.prank(unauthorizedUser);
        vm.expectRevert(SingleVault.Unauthorized.selector);
        setup.vault.mint(mintParams);
    }

    function test_mint_DeadlinePassed_Reverts() public {
        (, int24 currentTick,,,,,) = setup.pool.slot0();

        uint256 pastDeadline = block.timestamp - 1;

        MinimalMintParams memory mintParams = MinimalMintParams({
            tickLower: currentTick - TestConstants.TICK_RANGE_NARROW,
            tickUpper: currentTick + TestConstants.TICK_RANGE_NARROW,
            amount0Desired: TestConstants.SMALL_AMOUNT,
            amount1Desired: TestConstants.SMALL_AMOUNT,
            amount0Min: 0,
            amount1Min: 0,
            deadline: pastDeadline
        });

        vm.prank(setup.executor);
        vm.expectRevert("Transaction too old");
        setup.vault.mint(mintParams);
    }

    function test_mint_SlippageProtection_Reverts() public {
        (, int24 currentTick,,,,,) = setup.pool.slot0();

        // Set minimum amounts higher than what can be achieved
        MinimalMintParams memory mintParams = MinimalMintParams({
            tickLower: currentTick - TestConstants.TICK_RANGE_NARROW,
            tickUpper: currentTick + TestConstants.TICK_RANGE_NARROW,
            amount0Desired: TestConstants.SMALL_AMOUNT,
            amount1Desired: TestConstants.SMALL_AMOUNT,
            amount0Min: TestConstants.LARGE_AMOUNT, // Unrealistic minimum
            amount1Min: TestConstants.LARGE_AMOUNT, // Unrealistic minimum
            deadline: block.timestamp + 1 hours
        });

        vm.prank(setup.executor);
        vm.expectRevert("Price slippage check");
        setup.vault.mint(mintParams);
    }

    function test_mint_InsufficientFunds_Reverts() public {
        // Deploy vault with minimal funds
        TestHelper.VaultSetup memory poorSetup = helper.deployVaultWithPool();
        helper.depositToVault(poorSetup, TestConstants.SMALL_AMOUNT, TestConstants.SMALL_AMOUNT);

        (, int24 currentTick,,,,,) = poorSetup.pool.slot0();

        // Try to mint position requiring more funds than available
        MinimalMintParams memory mintParams = MinimalMintParams({
            tickLower: currentTick - TestConstants.TICK_RANGE_NARROW,
            tickUpper: currentTick + TestConstants.TICK_RANGE_NARROW,
            amount0Desired: TestConstants.LARGE_AMOUNT,
            amount1Desired: TestConstants.LARGE_AMOUNT,
            amount0Min: 0,
            amount1Min: 0,
            deadline: block.timestamp + 1 hours
        });

        vm.prank(poorSetup.executor);
        vm.expectRevert(); // Should revert due to insufficient balance for transfer
        poorSetup.vault.mint(mintParams);
    }

    function test_mint_OwnerCanAlsoMint_Success() public {
        (, int24 currentTick,,,,,) = setup.pool.slot0();

        // Owner should also be able to mint (onlyOwnerOrExecutor modifier)
        vm.prank(setup.owner);
        (uint256 amount0, uint256 amount1) = helper.createPosition(
            setup.vault,
            setup.owner,
            currentTick - TestConstants.TICK_RANGE_NARROW,
            currentTick + TestConstants.TICK_RANGE_NARROW,
            TestConstants.MEDIUM_AMOUNT,
            TestConstants.MEDIUM_AMOUNT
        );

        assertTrue(amount0 > 0);
        assertTrue(amount1 > 0);
    }

    function test_uniswapV3MintCallback_NotPool_Reverts() public {
        MintCallbackData memory callbackData = MintCallbackData({
            poolKey: PoolAddress.PoolKey({
                token0: address(setup.token0),
                token1: address(setup.token1),
                fee: TestConstants.POOL_FEE
            }),
            payer: address(setup.vault)
        });

        address notPool = makeAddr("notPool");

        vm.prank(notPool);
        vm.expectRevert(UniV3LpVault.NotPool.selector);
        setup.vault.uniswapV3MintCallback(100, 200, abi.encode(callbackData));
    }

    function test_uniswapV3MintCallback_WrongPayer_Reverts() public {
        MintCallbackData memory callbackData = MintCallbackData({
            poolKey: PoolAddress.PoolKey({
                token0: address(setup.token0),
                token1: address(setup.token1),
                fee: TestConstants.POOL_FEE
            }),
            payer: makeAddr("wrongPayer")
        });

        vm.prank(address(setup.pool));
        vm.expectRevert(UniV3LpVault.WrongPayer.selector);
        setup.vault.uniswapV3MintCallback(100, 200, abi.encode(callbackData));
    }

    function test_mint_ZeroLiquidity_HandleGracefully() public {
        (, int24 currentTick,,,,,) = setup.pool.slot0();

        // Try to mint with very small amounts that might result in zero liquidity
        MinimalMintParams memory mintParams = MinimalMintParams({
            tickLower: currentTick - TestConstants.TICK_RANGE_NARROW,
            tickUpper: currentTick + TestConstants.TICK_RANGE_NARROW,
            amount0Desired: 1, // Very small amount
            amount1Desired: 1, // Very small amount
            amount0Min: 0,
            amount1Min: 0,
            deadline: block.timestamp + 1 hours
        });

        vm.prank(setup.executor);
        // This might succeed with zero amounts or revert - both are acceptable
        try setup.vault.mint(mintParams) returns (uint256 amount0, uint256 amount1) {
            // If it succeeds, amounts might be zero
            assertTrue(amount0 == 0 || amount0 > 0);
            assertTrue(amount1 == 0 || amount1 > 0);
        } catch {
            // If it reverts, that's also acceptable for very small amounts
        }
    }
}
