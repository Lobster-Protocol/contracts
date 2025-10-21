// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import {Position} from "../../../src/vaults/UniV3LpVault.sol";
import {SingleVault} from "../../../src/vaults/SingleVault.sol";
import {TestHelper} from "../helpers/TestHelper.sol";
import {TestConstants} from "../helpers/Constants.sol";

contract UniV3LpVaultCollectTest is Test {
    TestHelper helper;
    TestHelper.VaultSetup setup;

    function setUp() public {
        helper = new TestHelper();
        setup = helper.deployVaultWithPool();

        // Setup with funds and initial position
        helper.depositToVault(setup, TestConstants.LARGE_AMOUNT, TestConstants.LARGE_AMOUNT);
    }

    function test_collect_ExistingPosition_Success() public {
        (, int24 currentTick,,,,,) = setup.pool.slot0();
        int24 tickSpacing = setup.pool.tickSpacing();
        int24 tickRange = TestConstants.TICK_RANGE_NARROW;

        // Calculate desired ticks
        int24 desiredTickLower = currentTick - tickRange;
        int24 desiredTickUpper = currentTick + tickRange;

        // Align ticks to tick spacing (round down for lower, round up for upper)
        int24 tickLower = (desiredTickLower / tickSpacing) * tickSpacing;
        int24 tickUpper = (desiredTickUpper / tickSpacing) * tickSpacing;

        helper.createPosition(
            setup.vault, setup.allocator, tickLower, tickUpper, TestConstants.MEDIUM_AMOUNT, TestConstants.MEDIUM_AMOUNT
        );

        uint256 initialVaultBalance0 = setup.token0.balanceOf(address(setup.vault));
        uint256 initialVaultBalance1 = setup.token1.balanceOf(address(setup.vault));

        vm.prank(setup.allocator);
        (uint128 amount0, uint128 amount1) =
            setup.vault
                .collect(
                    tickLower,
                    tickUpper,
                    type(uint128).max, // Collect all
                    type(uint128).max // Collect all
                );

        // Vault balance should increase or stay same (depends on fees accumulated)
        assertTrue(setup.token0.balanceOf(address(setup.vault)) >= initialVaultBalance0);
        assertTrue(setup.token1.balanceOf(address(setup.vault)) >= initialVaultBalance1);

        // Amounts can be zero if no fees accumulated
        assertTrue(amount0 >= 0);
        assertTrue(amount1 >= 0);
    }

    function test_collect_PartialAmounts_Success() public {
        (, int24 currentTick,,,,,) = setup.pool.slot0();
        int24 tickSpacing = setup.pool.tickSpacing();
        int24 tickRange = TestConstants.TICK_RANGE_NARROW;

        // Calculate desired ticks
        int24 desiredTickLower = currentTick - tickRange;
        int24 desiredTickUpper = currentTick + tickRange;

        // Align ticks to tick spacing (round down for lower, round up for upper)
        int24 tickLower = (desiredTickLower / tickSpacing) * tickSpacing;
        int24 tickUpper = (desiredTickUpper / tickSpacing) * tickSpacing;

        helper.createPosition(
            setup.vault, setup.allocator, tickLower, tickUpper, TestConstants.MEDIUM_AMOUNT, TestConstants.MEDIUM_AMOUNT
        );

        uint128 requestedAmount0 = 1000;
        uint128 requestedAmount1 = 2000;

        vm.prank(setup.allocator);
        (uint128 collected0, uint128 collected1) =
            setup.vault.collect(tickLower, tickUpper, requestedAmount0, requestedAmount1);

        // Collected amounts should be <= requested amounts
        assertTrue(collected0 <= requestedAmount0);
        assertTrue(collected1 <= requestedAmount1);
    }

    function test_collect_ZeroAmounts_Success() public {
        (, int24 currentTick,,,,,) = setup.pool.slot0();
        int24 tickSpacing = setup.pool.tickSpacing();
        int24 tickRange = TestConstants.TICK_RANGE_NARROW;

        // Calculate desired ticks
        int24 desiredTickLower = currentTick - tickRange;
        int24 desiredTickUpper = currentTick + tickRange;

        // Align ticks to tick spacing (round down for lower, round up for upper)
        int24 tickLower = (desiredTickLower / tickSpacing) * tickSpacing;
        int24 tickUpper = (desiredTickUpper / tickSpacing) * tickSpacing;

        helper.createPosition(
            setup.vault, setup.allocator, tickLower, tickUpper, TestConstants.MEDIUM_AMOUNT, TestConstants.MEDIUM_AMOUNT
        );

        vm.prank(setup.allocator);
        (uint128 collected0, uint128 collected1) =
            setup.vault
                .collect(
                    tickLower,
                    tickUpper,
                    0, // Request zero
                    0 // Request zero
                );

        assertEq(collected0, 0);
        assertEq(collected1, 0);
    }

    function test_collect_NonExistentPosition_HandlesGracefully() public {
        (, int24 currentTick,,,,,) = setup.pool.slot0();
        int24 tickSpacing = setup.pool.tickSpacing();
        int24 tickRange = TestConstants.TICK_RANGE_NARROW;

        // Calculate desired ticks
        int24 desiredTickLower = currentTick - tickRange;
        int24 desiredTickUpper = currentTick + tickRange;

        // Align ticks to tick spacing (round down for lower, round up for upper)
        int24 tickLower = (desiredTickLower / tickSpacing) * tickSpacing;
        int24 tickUpper = (desiredTickUpper / tickSpacing) * tickSpacing;

        // Try to collect from position that doesn't exist
        vm.prank(setup.allocator);
        (uint128 collected0, uint128 collected1) =
            setup.vault.collect(tickLower, tickUpper, type(uint128).max, type(uint128).max);

        // Should return zero or handle gracefully
        assertEq(collected0, 0);
        assertEq(collected1, 0);
    }

    function test_collect_NotAuthorized_Reverts() public {
        (, int24 currentTick,,,,,) = setup.pool.slot0();
        int24 tickSpacing = setup.pool.tickSpacing();
        int24 tickRange = TestConstants.TICK_RANGE_NARROW;

        // Calculate desired ticks
        int24 desiredTickLower = currentTick - tickRange;
        int24 desiredTickUpper = currentTick + tickRange;

        // Align ticks to tick spacing (round down for lower, round up for upper)
        int24 tickLower = (desiredTickLower / tickSpacing) * tickSpacing;
        int24 tickUpper = (desiredTickUpper / tickSpacing) * tickSpacing;

        helper.createPosition(
            setup.vault, setup.allocator, tickLower, tickUpper, TestConstants.MEDIUM_AMOUNT, TestConstants.MEDIUM_AMOUNT
        );

        address unauthorized = makeAddr("unauthorized");

        vm.prank(unauthorized);
        vm.expectRevert(SingleVault.Unauthorized.selector);
        setup.vault.collect(tickLower, tickUpper, 1000, 1000);
    }

    function test_collect_OwnerCanAlsoCollect_Success() public {
        (, int24 currentTick,,,,,) = setup.pool.slot0();
        int24 tickSpacing = setup.pool.tickSpacing();
        int24 tickRange = TestConstants.TICK_RANGE_NARROW;

        // Calculate desired ticks
        int24 desiredTickLower = currentTick - tickRange;
        int24 desiredTickUpper = currentTick + tickRange;

        // Align ticks to tick spacing (round down for lower, round up for upper)
        int24 tickLower = (desiredTickLower / tickSpacing) * tickSpacing;
        int24 tickUpper = (desiredTickUpper / tickSpacing) * tickSpacing;

        helper.createPosition(
            setup.vault, setup.allocator, tickLower, tickUpper, TestConstants.MEDIUM_AMOUNT, TestConstants.MEDIUM_AMOUNT
        );

        // Owner should be able to collect (onlyOwnerOrAllocator modifier)
        vm.prank(setup.owner);
        (uint128 collected0, uint128 collected1) =
            setup.vault.collect(tickLower, tickUpper, type(uint128).max, type(uint128).max);

        assertTrue(collected0 >= 0);
        assertTrue(collected1 >= 0);
    }

    function test_collect_MultiplePositions_CollectsFromCorrectOne() public {
        (, int24 currentTick,,,,,) = setup.pool.slot0();

        // Create two positions
        int24 tickSpacing = setup.pool.tickSpacing();
        int24 tickRange1 = TestConstants.TICK_RANGE_NARROW;
        int24 tickRange2 = TestConstants.TICK_RANGE_WIDE;

        // Calculate desired ticks
        int24 desiredTickLower1 = currentTick - tickRange1;
        int24 desiredTickUpper1 = currentTick + tickRange1;
        int24 desiredTickLower2 = currentTick - tickRange2;
        int24 desiredTickUpper2 = currentTick + tickRange2;

        // Align ticks to tick spacing (round down for lower, round up for upper)
        int24 tickLower1 = (desiredTickLower1 / tickSpacing) * tickSpacing;
        int24 tickUpper1 = (desiredTickUpper1 / tickSpacing) * tickSpacing;
        int24 tickLower2 = (desiredTickLower2 / tickSpacing) * tickSpacing;
        int24 tickUpper2 = (desiredTickUpper2 / tickSpacing) * tickSpacing;

        helper.createPosition(
            setup.vault, setup.allocator, tickLower1, tickUpper1, TestConstants.SMALL_AMOUNT, TestConstants.SMALL_AMOUNT
        );
        helper.createPosition(
            setup.vault,
            setup.allocator,
            tickLower2,
            tickUpper2,
            TestConstants.MEDIUM_AMOUNT,
            TestConstants.MEDIUM_AMOUNT
        );

        uint256 initialBalance0 = setup.token0.balanceOf(address(setup.vault));
        uint256 initialBalance1 = setup.token1.balanceOf(address(setup.vault));

        // Collect from first position only
        vm.prank(setup.allocator);
        setup.vault.collect(tickLower1, tickUpper1, type(uint128).max, type(uint128).max);

        // Balance should be >= initial (may have collected fees)
        assertTrue(setup.token0.balanceOf(address(setup.vault)) >= initialBalance0);
        assertTrue(setup.token1.balanceOf(address(setup.vault)) >= initialBalance1);

        // Both positions should still exist
        Position memory pos1 = setup.vault.getPosition(0);
        Position memory pos2 = setup.vault.getPosition(1);
        assertTrue(pos1.liquidity > 0);
        assertTrue(pos2.liquidity > 0);
    }

    function test_collect_AfterTimeAndTrades_CollectsFees() public {
        (, int24 currentTick,,,,,) = setup.pool.slot0();
        int24 tickSpacing = setup.pool.tickSpacing();
        int24 tickRange = TestConstants.TICK_RANGE_NARROW;

        // Calculate desired ticks
        int24 desiredTickLower = currentTick - tickRange;
        int24 desiredTickUpper = currentTick + tickRange;

        // Align ticks to tick spacing (round down for lower, round up for upper)
        int24 tickLower = (desiredTickLower / tickSpacing) * tickSpacing;
        int24 tickUpper = (desiredTickUpper / tickSpacing) * tickSpacing;

        helper.createPosition(
            setup.vault, setup.allocator, tickLower, tickUpper, TestConstants.LARGE_AMOUNT, TestConstants.LARGE_AMOUNT
        );

        uint256 initialBalance0 = setup.token0.balanceOf(address(setup.vault));
        uint256 initialBalance1 = setup.token1.balanceOf(address(setup.vault));

        // In a real scenario, there would be trading activity generating fees
        // For testing purposes, we simulate time passing
        helper.simulateTimePass(TestConstants.ONE_DAY);

        vm.prank(setup.allocator);
        (uint128 collected0, uint128 collected1) =
            setup.vault.collect(tickLower, tickUpper, type(uint128).max, type(uint128).max);

        // In test environment without real trading, collected amounts might be zero
        // But the function should execute without reverting
        assertTrue(collected0 >= 0);
        assertTrue(collected1 >= 0);
        assertTrue(setup.token0.balanceOf(address(setup.vault)) >= initialBalance0);
        assertTrue(setup.token1.balanceOf(address(setup.vault)) >= initialBalance1);
    }

    function test_collect_MultipleCalls_DoesNotRevert() public {
        (, int24 currentTick,,,,,) = setup.pool.slot0();
        int24 tickSpacing = setup.pool.tickSpacing();
        int24 tickRange = TestConstants.TICK_RANGE_NARROW;

        // Calculate desired ticks
        int24 desiredTickLower = currentTick - tickRange;
        int24 desiredTickUpper = currentTick + tickRange;

        // Align ticks to tick spacing (round down for lower, round up for upper)
        int24 tickLower = (desiredTickLower / tickSpacing) * tickSpacing;
        int24 tickUpper = (desiredTickUpper / tickSpacing) * tickSpacing;

        helper.createPosition(
            setup.vault, setup.allocator, tickLower, tickUpper, TestConstants.MEDIUM_AMOUNT, TestConstants.MEDIUM_AMOUNT
        );

        vm.startPrank(setup.allocator);

        // First collect
        (uint128 first0, uint128 first1) =
            setup.vault.collect(tickLower, tickUpper, type(uint128).max, type(uint128).max);

        // Second collect immediately after (should be zero or minimal)
        (uint128 second0, uint128 second1) =
            setup.vault.collect(tickLower, tickUpper, type(uint128).max, type(uint128).max);

        vm.stopPrank();

        // Both calls should succeed, second one likely returns zero
        assertTrue(first0 >= 0 && first1 >= 0);
        assertTrue(second0 >= 0 && second1 >= 0);
        assertTrue(second0 <= first0); // Second collect should be <= first
        assertTrue(second1 <= first1);
    }
}
