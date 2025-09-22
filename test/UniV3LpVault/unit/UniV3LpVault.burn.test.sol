// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import {UniV3LpVault, Position} from "../../../src/vaults/UniV3LpVault.sol";
import {SingleVault} from "../../../src/vaults/SingleVault.sol";
import {TestHelper} from "../helpers/TestHelper.sol";
import {TestConstants} from "../helpers/Constants.sol";

contract UniV3LpVaultBurnTest is Test {
    TestHelper helper;
    TestHelper.VaultSetup setup;

    function setUp() public {
        helper = new TestHelper();
        setup = helper.deployVaultWithPool();

        // Setup with funds and initial position
        helper.depositToVault(setup, TestConstants.LARGE_AMOUNT, TestConstants.LARGE_AMOUNT);
    }

    function test_burn_PartialPosition_Success() public {
        // Create position first
        (, int24 currentTick,,,,,) = setup.pool.slot0();
        int24 tickLower = currentTick - TestConstants.TICK_RANGE_NARROW;
        int24 tickUpper = currentTick + TestConstants.TICK_RANGE_NARROW;

        helper.createPosition(
            setup.vault, setup.executor, tickLower, tickUpper, TestConstants.MEDIUM_AMOUNT, TestConstants.MEDIUM_AMOUNT
        );

        Position memory initialPosition = setup.vault.getPosition(0);
        uint128 initialLiquidity = initialPosition.liquidity;
        uint128 burnAmount = initialLiquidity / 2; // Burn half

        uint256 initialVaultBalance0 = setup.token0.balanceOf(address(setup.vault));
        uint256 initialVaultBalance1 = setup.token1.balanceOf(address(setup.vault));

        vm.prank(setup.executor);
        (uint256 amount0, uint256 amount1) = setup.vault.burn(tickLower, tickUpper, burnAmount);

        // Should receive tokens back to vault
        assertTrue(setup.token0.balanceOf(address(setup.vault)) > initialVaultBalance0);
        assertTrue(setup.token1.balanceOf(address(setup.vault)) > initialVaultBalance1);
        assertTrue(amount0 > 0);
        assertTrue(amount1 > 0);

        // Position should still exist but with reduced liquidity
        Position memory finalPosition = setup.vault.getPosition(0);
        assertEq(finalPosition.lowerTick, tickLower);
        assertEq(finalPosition.upperTick, tickUpper);
        assertEq(finalPosition.liquidity, initialLiquidity - burnAmount);
    }

    function test_burn_FullPosition_RemovesFromArray() public {
        (, int24 currentTick,,,,,) = setup.pool.slot0();
        int24 tickLower = currentTick - TestConstants.TICK_RANGE_NARROW;
        int24 tickUpper = currentTick + TestConstants.TICK_RANGE_NARROW;

        helper.createPosition(
            setup.vault, setup.executor, tickLower, tickUpper, TestConstants.MEDIUM_AMOUNT, TestConstants.MEDIUM_AMOUNT
        );

        Position memory position = setup.vault.getPosition(0);
        uint128 fullLiquidity = position.liquidity;

        vm.prank(setup.executor);
        setup.vault.burn(tickLower, tickUpper, fullLiquidity);

        // Position should be removed from array
        vm.expectRevert();
        setup.vault.getPosition(0);
    }

    function test_burn_MultiplePositions_RemovesCorrectOne() public {
        (, int24 currentTick,,,,,) = setup.pool.slot0();

        // Create two different positions
        int24 tickLower1 = currentTick - TestConstants.TICK_RANGE_NARROW;
        int24 tickUpper1 = currentTick + TestConstants.TICK_RANGE_NARROW;
        int24 tickLower2 = currentTick - TestConstants.TICK_RANGE_WIDE;
        int24 tickUpper2 = currentTick + TestConstants.TICK_RANGE_WIDE;

        helper.createPosition(
            setup.vault, setup.executor, tickLower1, tickUpper1, TestConstants.SMALL_AMOUNT, TestConstants.SMALL_AMOUNT
        );
        helper.createPosition(
            setup.vault,
            setup.executor,
            tickLower2,
            tickUpper2,
            TestConstants.MEDIUM_AMOUNT,
            TestConstants.MEDIUM_AMOUNT
        );

        // Get second position liquidity
        Position memory position2 = setup.vault.getPosition(1);
        uint128 liquidity2 = position2.liquidity;

        // Burn second position completely
        vm.prank(setup.executor);
        setup.vault.burn(tickLower2, tickUpper2, liquidity2);

        // First position should still exist
        Position memory remainingPosition = setup.vault.getPosition(0);
        assertTrue(remainingPosition.liquidity > 0);

        // Should only have one position now
        vm.expectRevert();
        setup.vault.getPosition(1);
    }

    function test_burn_NotAuthorized_Reverts() public {
        helper.createPosition(
            setup.vault,
            setup.executor,
            -TestConstants.TICK_RANGE_NARROW,
            TestConstants.TICK_RANGE_NARROW,
            TestConstants.MEDIUM_AMOUNT,
            TestConstants.MEDIUM_AMOUNT
        );

        address unauthorized = makeAddr("unauthorized");

        vm.prank(unauthorized);
        vm.expectRevert(SingleVault.Unauthorized.selector);
        setup.vault.burn(-TestConstants.TICK_RANGE_NARROW, TestConstants.TICK_RANGE_NARROW, 100);
    }

    function test_burn_NonExistentPosition_HandlesGracefully() public {
        // Try to burn from non-existent position
        (, int24 currentTick,,,,,) = setup.pool.slot0();
        int24 tickLower = currentTick - TestConstants.TICK_RANGE_NARROW;
        int24 tickUpper = currentTick + TestConstants.TICK_RANGE_NARROW;

        vm.prank(setup.executor);
        // This should either revert or return (0, 0) - both are acceptable
        try setup.vault.burn(tickLower, tickUpper, 1000) returns (uint256 amount0, uint256 amount1) {
            // If it succeeds, amounts should be zero
            assertEq(amount0, 0);
            assertEq(amount1, 0);
        } catch {
            // If it reverts, that's also acceptable
        }
    }

    function test_burn_ExcessiveLiquidity_HandlesGracefully() public {
        (, int24 currentTick,,,,,) = setup.pool.slot0();
        int24 tickLower = currentTick - TestConstants.TICK_RANGE_NARROW;
        int24 tickUpper = currentTick + TestConstants.TICK_RANGE_NARROW;

        helper.createPosition(
            setup.vault, setup.executor, tickLower, tickUpper, TestConstants.SMALL_AMOUNT, TestConstants.SMALL_AMOUNT
        );

        Position memory position = setup.vault.getPosition(0);
        uint128 excessiveAmount = position.liquidity * 2; // More than available

        vm.prank(setup.executor);
        // Should revert or handle gracefully
        vm.expectRevert();
        setup.vault.burn(tickLower, tickUpper, excessiveAmount);
    }

    function test_burn_AutoCollect_TransfersTokens() public {
        (, int24 currentTick,,,,,) = setup.pool.slot0();
        int24 tickLower = currentTick - TestConstants.TICK_RANGE_NARROW;
        int24 tickUpper = currentTick + TestConstants.TICK_RANGE_NARROW;

        helper.createPosition(
            setup.vault, setup.executor, tickLower, tickUpper, TestConstants.MEDIUM_AMOUNT, TestConstants.MEDIUM_AMOUNT
        );

        // todo:
        // Simulate some trading to generate fees (in real scenario). Then use > and < instead of <= and >=

        Position memory position = setup.vault.getPosition(0);
        uint256 initialBalance0 = setup.token0.balanceOf(address(setup.vault));
        uint256 initialBalance1 = setup.token1.balanceOf(address(setup.vault));

        vm.prank(setup.executor);
        (uint256 amount0, uint256 amount1) = setup.vault.burn(tickLower, tickUpper, position.liquidity / 4);

        // Vault balance should increase (tokens returned from pool)
        assertTrue(setup.token0.balanceOf(address(setup.vault)) >= initialBalance0 + amount0);
        assertTrue(setup.token1.balanceOf(address(setup.vault)) >= initialBalance1 + amount1);
    }

    function test_burn_UpdatesLpValue() public {
        (, int24 currentTick,,,,,) = setup.pool.slot0();
        int24 tickLower = currentTick - TestConstants.TICK_RANGE_NARROW;
        int24 tickUpper = currentTick + TestConstants.TICK_RANGE_NARROW;

        helper.createPosition(
            setup.vault, setup.executor, tickLower, tickUpper, TestConstants.MEDIUM_AMOUNT, TestConstants.MEDIUM_AMOUNT
        );

        (uint256 initialLp0, uint256 initialLp1) = setup.vault.totalLpValue();

        Position memory position = setup.vault.getPosition(0);

        vm.prank(setup.executor);
        setup.vault.burn(tickLower, tickUpper, position.liquidity / 2);

        (uint256 finalLp0, uint256 finalLp1) = setup.vault.totalLpValue();

        // LP value should decrease after burning
        assertTrue(finalLp0 < initialLp0);
        assertTrue(finalLp1 < initialLp1);
    }

    function test_burn_ZeroAmount_Success() public {
        (, int24 currentTick,,,,,) = setup.pool.slot0();
        int24 tickLower = currentTick - TestConstants.TICK_RANGE_NARROW;
        int24 tickUpper = currentTick + TestConstants.TICK_RANGE_NARROW;

        helper.createPosition(
            setup.vault, setup.executor, tickLower, tickUpper, TestConstants.MEDIUM_AMOUNT, TestConstants.MEDIUM_AMOUNT
        );

        vm.prank(setup.executor);
        (uint256 amount0, uint256 amount1) = setup.vault.burn(tickLower, tickUpper, 0);

        // Should return zero amounts
        assertEq(amount0, 0);
        assertEq(amount1, 0);

        // Position should remain unchanged
        Position memory position = setup.vault.getPosition(0);
        assertTrue(position.liquidity > 0);
    }

    function test_burn_OwnerCanAlsoBurn_Success() public {
        (, int24 currentTick,,,,,) = setup.pool.slot0();
        int24 tickLower = currentTick - TestConstants.TICK_RANGE_NARROW;
        int24 tickUpper = currentTick + TestConstants.TICK_RANGE_NARROW;

        helper.createPosition(
            setup.vault, setup.executor, tickLower, tickUpper, TestConstants.MEDIUM_AMOUNT, TestConstants.MEDIUM_AMOUNT
        );

        Position memory position = setup.vault.getPosition(0);

        // Owner should be able to burn (onlyOwnerOrExecutor modifier)
        vm.prank(setup.owner);
        (uint256 amount0, uint256 amount1) = setup.vault.burn(tickLower, tickUpper, position.liquidity / 4);

        assertTrue(amount0 > 0 || amount1 > 0);
    }
}
