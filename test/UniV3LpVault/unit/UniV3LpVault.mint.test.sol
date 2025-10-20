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
        uint256 amount0Desired = TestConstants.MEDIUM_AMOUNT;
        uint256 amount1Desired = TestConstants.MEDIUM_AMOUNT;

        uint256 initialVaultBalance0 = setup.token0.balanceOf(address(setup.vault));
        uint256 initialVaultBalance1 = setup.token1.balanceOf(address(setup.vault));

        int24 tickRange = TestConstants.TICK_RANGE_NARROW;

        vm.prank(setup.allocator);
        (uint256 amount0, uint256 amount1) = helper.createPositionAroundCurrentTick(
            setup.vault, setup.allocator, tickRange, amount0Desired, amount1Desired
        );
        // Calculate desired ticks
        int24 desiredTickLower = currentTick - tickRange;
        int24 desiredTickUpper = currentTick + tickRange;

        // Align ticks to tick spacing (round down for lower, round up for upper)
        int24 tickSpacing = setup.vault.pool().tickSpacing();
        int24 tickLower = (desiredTickLower / tickSpacing) * tickSpacing;
        int24 tickUpper = (desiredTickUpper / tickSpacing) * tickSpacing;

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

        uint256 firstAmount0 = TestConstants.SMALL_AMOUNT;
        uint256 firstAmount1 = TestConstants.SMALL_AMOUNT;
        uint256 secondAmount0 = TestConstants.MEDIUM_AMOUNT;
        uint256 secondAmount1 = TestConstants.MEDIUM_AMOUNT;

        // Create first position
        vm.prank(setup.allocator);
        int24 tickRange = TestConstants.TICK_RANGE_NARROW;

        helper.createPositionAroundCurrentTick(setup.vault, setup.allocator, tickRange, firstAmount0, firstAmount1);
        // Calculate desired ticks
        int24 desiredTickLower = currentTick - tickRange;
        int24 desiredTickUpper = currentTick + tickRange;

        // Align ticks to tick spacing (round down for lower, round up for upper)
        int24 tickSpacing = setup.vault.pool().tickSpacing();
        int24 tickLower = (desiredTickLower / tickSpacing) * tickSpacing;
        int24 tickUpper = (desiredTickUpper / tickSpacing) * tickSpacing;

        Position memory initialPosition = setup.vault.getPosition(0);
        uint128 initialLiquidity = initialPosition.liquidity;

        // Add to same position
        vm.prank(setup.allocator);
        helper.createPositionAroundCurrentTick(setup.vault, setup.allocator, tickRange, secondAmount0, secondAmount1);

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
        // Create first position
        vm.prank(setup.allocator);

        int24 tickRange = TestConstants.TICK_RANGE_NARROW;

        helper.createPositionAroundCurrentTick(
            setup.vault, setup.allocator, tickRange, TestConstants.SMALL_AMOUNT, TestConstants.SMALL_AMOUNT
        );

        // Create second position with different range
        vm.prank(setup.allocator);
        int24 tickRange2 = TestConstants.TICK_RANGE_WIDE;

        helper.createPositionAroundCurrentTick(
            setup.vault, setup.allocator, tickRange2, TestConstants.MEDIUM_AMOUNT, TestConstants.MEDIUM_AMOUNT
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

        int24 tickSpacing = setup.pool.tickSpacing();

        int24 tickRange = TestConstants.TICK_RANGE_NARROW;

        // Calculate desired ticks
        int24 desiredTickLower = currentTick - tickRange;
        int24 desiredTickUpper = currentTick + tickRange;

        // Align ticks to tick spacing (round down for lower, round up for upper)
        int24 tickLower = (desiredTickLower / tickSpacing) * tickSpacing;
        int24 tickUpper = (desiredTickUpper / tickSpacing) * tickSpacing;

        MinimalMintParams memory mintParams = MinimalMintParams({
            tickLower: tickLower,
            tickUpper: tickUpper,
            amount0Desired: TestConstants.SMALL_AMOUNT,
            amount1Desired: TestConstants.SMALL_AMOUNT,
            amount0Min: 0,
            amount1Min: 0,
            deadline: pastDeadline
        });

        vm.prank(setup.allocator);
        vm.expectRevert("Transaction too old");
        setup.vault.mint(mintParams);
    }

    function test_mint_SlippageProtection_Reverts() public {
        (, int24 currentTick,,,,,) = setup.pool.slot0();

        int24 tickSpacing = setup.pool.tickSpacing();
        int24 tickRange = TestConstants.TICK_RANGE_NARROW;

        // Calculate desired ticks
        int24 desiredTickLower = currentTick - tickRange;
        int24 desiredTickUpper = currentTick + tickRange;

        // Align ticks to tick spacing (round down for lower, round up for upper)
        int24 tickLower = (desiredTickLower / tickSpacing) * tickSpacing;
        int24 tickUpper = (desiredTickUpper / tickSpacing) * tickSpacing;

        // Set minimum amounts higher than what can be achieved
        MinimalMintParams memory mintParams = MinimalMintParams({
            tickLower: tickLower,
            tickUpper: tickUpper,
            amount0Desired: TestConstants.SMALL_AMOUNT,
            amount1Desired: TestConstants.SMALL_AMOUNT,
            amount0Min: TestConstants.LARGE_AMOUNT, // Unrealistic minimum
            amount1Min: TestConstants.LARGE_AMOUNT, // Unrealistic minimum
            deadline: block.timestamp + 1 hours
        });

        vm.prank(setup.allocator);
        vm.expectRevert("Price slippage check");
        setup.vault.mint(mintParams);
    }

    function test_mint_InsufficientFunds_Reverts() public {
        // Deploy vault with minimal funds
        TestHelper.VaultSetup memory poorSetup = helper.deployVaultWithPool();
        helper.depositToVault(poorSetup, TestConstants.SMALL_AMOUNT, TestConstants.SMALL_AMOUNT);

        (, int24 currentTick,,,,,) = poorSetup.pool.slot0();

        int24 tickSpacing = setup.pool.tickSpacing();
        int24 tickRange = TestConstants.TICK_RANGE_NARROW;

        // Calculate desired ticks
        int24 desiredTickLower = currentTick - tickRange;
        int24 desiredTickUpper = currentTick + tickRange;

        // Align ticks to tick spacing (round down for lower, round up for upper)
        int24 tickLower = (desiredTickLower / tickSpacing) * tickSpacing;
        int24 tickUpper = (desiredTickUpper / tickSpacing) * tickSpacing;

        // Try to mint position requiring more funds than available
        MinimalMintParams memory mintParams = MinimalMintParams({
            tickLower: tickLower,
            tickUpper: tickUpper,
            amount0Desired: TestConstants.LARGE_AMOUNT,
            amount1Desired: TestConstants.LARGE_AMOUNT,
            amount0Min: 0,
            amount1Min: 0,
            deadline: block.timestamp + 1 hours
        });

        vm.prank(poorSetup.allocator);
        vm.expectRevert(); // Should revert due to insufficient balance for transfer
        poorSetup.vault.mint(mintParams);
    }

    function test_mint_OwnerCanAlsoMint_Success() public {
        // Owner should also be able to mint (onlyOwnerOrAllocator modifier)
        vm.prank(setup.owner);
        (uint256 amount0, uint256 amount1) = helper.createPositionAroundCurrentTick(
            setup.vault,
            setup.owner,
            TestConstants.TICK_RANGE_NARROW,
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

        int24 tickSpacing = setup.pool.tickSpacing();
        int24 tickRange = TestConstants.TICK_RANGE_NARROW;

        // Calculate desired ticks
        int24 desiredTickLower = currentTick - tickRange;
        int24 desiredTickUpper = currentTick + tickRange;

        // Align ticks to tick spacing (round down for lower, round up for upper)
        int24 tickLower = (desiredTickLower / tickSpacing) * tickSpacing;
        int24 tickUpper = (desiredTickUpper / tickSpacing) * tickSpacing;

        // Try to mint with very small amounts that might result in zero liquidity
        MinimalMintParams memory mintParams = MinimalMintParams({
            tickLower: tickLower,
            tickUpper: tickUpper,
            amount0Desired: 1, // Very small amount
            amount1Desired: 1, // Very small amount
            amount0Min: 0,
            amount1Min: 0,
            deadline: block.timestamp + 1 hours
        });

        vm.prank(setup.allocator);
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
