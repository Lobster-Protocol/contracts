// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import {Position, MAX_SCALED_PERCENTAGE} from "../../../src/vaults/uniV3LpVault/UniV3LpVault.sol";
import {TestHelper} from "../helpers/TestHelper.sol";
import {TestConstants} from "../helpers/Constants.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract UniV3LpVaultViewsTest is Test {
    using Math for uint256;

    TestHelper helper;
    TestHelper.VaultSetup setup;
    TestHelper.VaultSetup feeSetup;

    function setUp() public {
        helper = new TestHelper();
        setup = helper.deployVaultWithPool();
        feeSetup = helper.deployVaultWithPool(
            TestConstants.HIGH_TVL_FEE, // 5% annual
            TestConstants.HIGH_PERF_FEE
        );
    }

    function test_totalLpValue_EmptyVault_ReturnsZero() public view {
        (uint256 totalAssets0, uint256 totalAssets1) = setup.vault.totalLpValue();
        assertEq(totalAssets0, 0);
        assertEq(totalAssets1, 0);
    }

    function test_netAssetsValue_EmptyVault_ReturnsZero() public view {
        (uint256 totalAssets0, uint256 totalAssets1) = setup.vault.netAssetsValue();
        assertEq(totalAssets0, 0);
        assertEq(totalAssets1, 0);
    }

    function test_totalLpValue_OnlyCashNoPositions_ReturnsZero() public {
        helper.depositToVault(setup, TestConstants.MEDIUM_AMOUNT, TestConstants.MEDIUM_AMOUNT);

        (uint256 totalAssets0, uint256 totalAssets1) = setup.vault.totalLpValue();
        assertEq(totalAssets0, 0);
        assertEq(totalAssets1, 0);
    }

    function test_netAssetsValue_OnlyCashNoPositions_ReturnsCashBalance() public {
        uint256 depositAmount0 = TestConstants.MEDIUM_AMOUNT;
        uint256 depositAmount1 = TestConstants.LARGE_AMOUNT;

        helper.depositToVault(setup, depositAmount0, depositAmount1);

        (uint256 totalAssets0, uint256 totalAssets1) = setup.vault.netAssetsValue();
        assertEq(totalAssets0, depositAmount0);
        assertEq(totalAssets1, depositAmount1);
    }

    function test_totalLpValue_WithSinglePosition_ReturnsPositionValue() public {
        helper.depositToVault(setup, TestConstants.LARGE_AMOUNT, TestConstants.LARGE_AMOUNT);

        uint256 amount0Desired = TestConstants.MEDIUM_AMOUNT;
        uint256 amount1Desired = TestConstants.MEDIUM_AMOUNT;

        (uint256 amount0, uint256 amount1) = helper.createPositionAroundCurrentTick(
            setup.vault, setup.allocator, TestConstants.TICK_RANGE_NARROW, amount0Desired, amount1Desired
        );

        (uint256 totalLp0, uint256 totalLp1) = setup.vault.totalLpValue();

        assertTrue(totalLp0 > 0);
        assertTrue(totalLp1 > 0);
        helper.assertApproxEqual(totalLp0, amount0, TestConstants.TOLERANCE_LOW, "LP value0 mismatch");
        helper.assertApproxEqual(totalLp1, amount1, TestConstants.TOLERANCE_LOW, "LP value1 mismatch");
    }

    function test_netAssetsValue_WithPositionAndCash_ReturnsCombined() public {
        uint256 totalDeposit0 = TestConstants.LARGE_AMOUNT;
        uint256 totalDeposit1 = TestConstants.LARGE_AMOUNT;
        uint256 positionAmount0 = TestConstants.MEDIUM_AMOUNT;
        uint256 positionAmount1 = TestConstants.MEDIUM_AMOUNT;

        helper.depositToVault(setup, totalDeposit0, totalDeposit1);
        helper.createPositionAroundCurrentTick(
            setup.vault, setup.allocator, TestConstants.TICK_RANGE_NARROW, positionAmount0, positionAmount1
        );

        (uint256 netAssets0, uint256 netAssets1) = setup.vault.netAssetsValue();

        // Net assets should be approximately equal to total deposit
        // (position value + remaining cash)
        helper.assertApproxEqual(
            netAssets0, totalDeposit0, TestConstants.TOLERANCE_LOW, "Net assets0 should equal total deposit"
        );
        helper.assertApproxEqual(
            netAssets1, totalDeposit1, TestConstants.TOLERANCE_LOW, "Net assets1 should equal total deposit"
        );
    }

    function test_totalLpValue_WithMultiplePositions_ReturnsSum() public {
        helper.depositToVault(setup, TestConstants.LARGE_AMOUNT, TestConstants.LARGE_AMOUNT);

        (, int24 currentTick,,,,,) = setup.pool.slot0();

        // Create two positions
        uint256 amount1_0 = TestConstants.SMALL_AMOUNT;
        uint256 amount1_1 = TestConstants.SMALL_AMOUNT;
        uint256 amount2_0 = TestConstants.MEDIUM_AMOUNT;
        uint256 amount2_1 = TestConstants.MEDIUM_AMOUNT;

        int24 tickSpacing = setup.pool.tickSpacing();
        int24 tickRange1 = TestConstants.TICK_RANGE_NARROW;

        // Calculate desired ticks
        int24 desiredTickLower1 = currentTick - tickRange1;
        int24 desiredTickUpper1 = currentTick + tickRange1;

        // Align ticks to tick spacing (round down for lower, round up for upper)
        int24 tickLower1 = (desiredTickLower1 / tickSpacing) * tickSpacing;
        int24 tickUpper1 = (desiredTickUpper1 / tickSpacing) * tickSpacing;

        helper.createPosition(setup.vault, setup.allocator, tickLower1, tickUpper1, amount1_0, amount1_1);

        int24 tickRange2 = TestConstants.TICK_RANGE_WIDE;

        // Calculate desired ticks
        int24 desiredTickLower2 = currentTick - tickRange2;
        int24 desiredTickUpper2 = currentTick + tickRange2;

        // Align ticks to tick spacing (round down for lower, round up for upper)
        int24 tickLower2 = (desiredTickLower2 / tickSpacing) * tickSpacing;
        int24 tickUpper2 = (desiredTickUpper2 / tickSpacing) * tickSpacing;

        helper.createPosition(setup.vault, setup.allocator, tickLower2, tickUpper2, amount2_0, amount2_1);

        (uint256 totalLp0, uint256 totalLp1) = setup.vault.totalLpValue();

        // Should be approximately sum of both positions
        helper.assertApproxEqual(
            totalLp0, amount1_0 + amount2_0, TestConstants.TOLERANCE_MEDIUM, "Total LP value0 should sum positions"
        );
        helper.assertApproxEqual(
            totalLp1, amount1_1 + amount2_1, TestConstants.TOLERANCE_MEDIUM, "Total LP value1 should sum positions"
        );
    }

    function test_getPosition_ValidIndex_ReturnsCorrectPosition() public {
        helper.depositToVault(setup, TestConstants.LARGE_AMOUNT, TestConstants.LARGE_AMOUNT);

        (, int24 currentTick,,,,,) = setup.pool.slot0();

        int24 tickSpacing = setup.pool.tickSpacing();
        int24 tickRange = TestConstants.TICK_RANGE_NARROW;

        // Calculate desired ticks
        int24 desiredTickLower = currentTick - tickRange;
        int24 desiredTickUpper = currentTick + tickRange;

        // Align ticks to tick spacing (round down for lower, round up for upper)
        int24 expectedLowerTick = (desiredTickLower / tickSpacing) * tickSpacing;
        int24 expectedUpperTick = (desiredTickUpper / tickSpacing) * tickSpacing;

        helper.createPosition(
            setup.vault,
            setup.allocator,
            expectedLowerTick,
            expectedUpperTick,
            TestConstants.MEDIUM_AMOUNT,
            TestConstants.MEDIUM_AMOUNT
        );

        Position memory position = setup.vault.getPosition(0);

        assertEq(position.lowerTick, expectedLowerTick);
        assertEq(position.upperTick, expectedUpperTick);
        assertTrue(position.liquidity > 0);
    }

    function test_getPosition_InvalidIndex_Reverts() public {
        // Try to get position that doesn't exist
        vm.expectRevert();
        setup.vault.getPosition(0);

        // Create one position, try to get second
        helper.depositToVault(setup, TestConstants.LARGE_AMOUNT, TestConstants.LARGE_AMOUNT);
        helper.createPositionAroundCurrentTick(
            setup.vault,
            setup.allocator,
            TestConstants.TICK_RANGE_NARROW,
            TestConstants.MEDIUM_AMOUNT,
            TestConstants.MEDIUM_AMOUNT
        );

        vm.expectRevert();
        setup.vault.getPosition(1);
    }

    function test_views_AfterPartialBurn_UpdatesCorrectly() public {
        helper.depositToVault(setup, TestConstants.LARGE_AMOUNT, TestConstants.LARGE_AMOUNT);

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

        (uint256 initialLp0, uint256 initialLp1) = setup.vault.totalLpValue();
        Position memory initialPosition = setup.vault.getPosition(0);

        // Burn half the position
        vm.prank(setup.allocator);
        setup.vault.burn(tickLower, tickUpper, initialPosition.liquidity / 2);

        (uint256 finalLp0, uint256 finalLp1) = setup.vault.totalLpValue();
        Position memory finalPosition = setup.vault.getPosition(0);

        // LP value should decrease
        assertTrue(finalLp0 < initialLp0);
        assertTrue(finalLp1 < initialLp1);

        // Position liquidity should be halved
        assertApproxEqAbs(finalPosition.liquidity, initialPosition.liquidity / 2, 1);
    }

    function test_views_WithTvlFees_ReflectsFeesReduction() public {
        helper.depositToVault(feeSetup, TestConstants.LARGE_AMOUNT, TestConstants.LARGE_AMOUNT);
        helper.createPositionAroundCurrentTick(
            feeSetup.vault,
            feeSetup.allocator,
            TestConstants.TICK_RANGE_NARROW,
            TestConstants.MEDIUM_AMOUNT,
            TestConstants.MEDIUM_AMOUNT
        );

        // Get values immediately after creation
        (uint256 initialNet0, uint256 initialNet1) = feeSetup.vault.netAssetsValue();

        // Let time pass to accumulate fees
        helper.simulateTimePass(TestConstants.ONE_MONTH);

        // Get values after time passes (before fee collection)
        (uint256 finalNet0, uint256 finalNet1) = feeSetup.vault.netAssetsValue();

        // Net assets should be reduced due to pending TVL fees
        assertTrue(finalNet0 < initialNet0);
        assertTrue(finalNet1 < initialNet1);

        // The reduction should be reasonable (less than the monthly fee rate)
        uint256 maxExpectedReduction = initialNet0 / 20; // Less than 5% (annual rate is 5%)
        assertTrue(initialNet0 - finalNet0 < maxExpectedReduction);
    }

    function test_views_ConsistencyBetweenCalls() public {
        helper.depositToVault(setup, TestConstants.MEDIUM_AMOUNT, TestConstants.MEDIUM_AMOUNT);
        helper.createPositionAroundCurrentTick(
            setup.vault,
            setup.allocator,
            TestConstants.TICK_RANGE_NARROW,
            TestConstants.SMALL_AMOUNT,
            TestConstants.SMALL_AMOUNT
        );

        // Multiple calls should return consistent values
        (uint256 lp0x1, uint256 lp1x1) = setup.vault.totalLpValue();
        (uint256 lp0x2, uint256 lp1x2) = setup.vault.totalLpValue();
        (uint256 net0x1, uint256 net1x1) = setup.vault.netAssetsValue();
        (uint256 net0x2, uint256 net1x2) = setup.vault.netAssetsValue();

        assertEq(lp0x1, lp0x2);
        assertEq(lp1x1, lp1x2);
        assertEq(net0x1, net0x2);
        assertEq(net1x1, net1x2);
    }

    function test_views_AfterFullWithdrawal_ReturnsZero() public {
        helper.depositToVault(setup, TestConstants.MEDIUM_AMOUNT, TestConstants.MEDIUM_AMOUNT);
        helper.createPositionAroundCurrentTick(
            setup.vault,
            setup.allocator,
            TestConstants.TICK_RANGE_NARROW,
            TestConstants.SMALL_AMOUNT,
            TestConstants.SMALL_AMOUNT
        );

        // Withdraw everything
        address recipient = makeAddr("recipient");
        helper.withdrawFromVault(setup, TestConstants.MAX_SCALED_PERCENTAGE, recipient);

        (uint256 finalLp0, uint256 finalLp1) = setup.vault.totalLpValue();
        (uint256 finalNet0, uint256 finalNet1) = setup.vault.netAssetsValue();

        // Should be zero or very close to zero
        helper.assertApproxEqual(finalLp0, 0, TestConstants.TOLERANCE_HIGH, "LP value should be zero");
        helper.assertApproxEqual(finalLp1, 0, TestConstants.TOLERANCE_HIGH, "LP value should be zero");
        helper.assertApproxEqual(finalNet0, 0, TestConstants.TOLERANCE_HIGH, "Net assets should be zero");
        helper.assertApproxEqual(finalNet1, 0, TestConstants.TOLERANCE_HIGH, "Net assets should be zero");
    }

    function test_views_rawAssetsValue() public {
        helper.depositToVault(setup, TestConstants.MEDIUM_AMOUNT, TestConstants.MEDIUM_AMOUNT);

        (uint256 raw0, uint256 raw1) = setup.vault.rawAssetsValue();
        assertEq(setup.token0.balanceOf(address(setup.vault)), raw0);
        assertEq(setup.token1.balanceOf(address(setup.vault)), raw1);
    }

    function test_views_pendingTvlFee() public {
        uint256 depositAmount0 = 100 ether;
        uint256 depositAmount1 = 3 ether;

        helper.depositToVault(feeSetup, depositAmount0, depositAmount1);

        uint256 delay = TestConstants.ONE_YEAR;
        helper.simulateTimePass(delay);

        (uint256 pending0, uint256 pending1) = feeSetup.vault.pendingTvlFee();

        uint256 pendingFeePercent = feeSetup.vault.tvlFeeScaled().mulDiv(delay, 365 days);

        uint256 pending0Computed = depositAmount0.mulDiv(pendingFeePercent, MAX_SCALED_PERCENTAGE);
        uint256 pending1Computed = depositAmount1.mulDiv(pendingFeePercent, MAX_SCALED_PERCENTAGE);

        assertEq(pending0, pending0Computed);
        assertEq(pending1, pending1Computed);
    }

    function test_pendingPerformanceFee_noPerfFee() public view {
        assertEq(0, setup.vault.performanceFeeScaled());
    }

    function test_pendingPerformanceFee() public {
        uint256 deposit0 = TestConstants.LARGE_AMOUNT;
        uint256 deposit1 = TestConstants.LARGE_AMOUNT;

        helper.depositToVault(setup, deposit0, deposit1);
        helper.createPositionAroundCurrentTick(
            setup.vault,
            setup.allocator,
            TestConstants.TICK_RANGE_NARROW,
            TestConstants.MEDIUM_AMOUNT,
            TestConstants.MEDIUM_AMOUNT
        );

        // Mint tokens to the vault to simulate +100% performance
        (uint256 tvl0, uint256 tvl1) = setup.vault.rawAssetsValue();
        setup.token0.mint(address(setup.vault), tvl0 / 2);
        setup.token1.mint(address(setup.vault), tvl1 / 2);

        // actual_performance = +50% so perf fee will be vault.performanceFeeScaled() / 2
        uint256 feeScaledPercent = setup.vault.performanceFeeScaled() / 2;

        uint256 expectedFee0 = deposit0.mulDiv(feeScaledPercent, MAX_SCALED_PERCENTAGE);
        uint256 expectedFee1 = deposit1.mulDiv(feeScaledPercent, MAX_SCALED_PERCENTAGE);

        (uint256 fee0, uint256 fee1) = setup.vault.pendingPerformanceFee();
        assertEq(expectedFee0, fee0);
        assertEq(expectedFee1, fee1);
    }

    function test_previewWithdraw_ReturnsZero_WhenMinAmount0IsZero() public {
        uint256 scaledPercent = setup.vault.previewWithdraw(0, 1000e6);
        assertEq(scaledPercent, 0, "Should return 0 when minAmount0 is 0");
    }

    function test_previewWithdraw_ReturnsZero_WhenMinAmount1IsZero() public {
        uint256 scaledPercent = setup.vault.previewWithdraw(1000e18, 0);
        assertEq(scaledPercent, 0, "Should return 0 when minAmount1 is 0");
    }

    function test_previewWithdraw_ReturnsZero_WhenBothAmountsAreZero() public {
        uint256 scaledPercent = setup.vault.previewWithdraw(0, 0);
        assertEq(scaledPercent, 0, "Should return 0 when both amounts are 0");
    }

    function test_previewWithdraw_BasicCase_Token0IsConstraint() public {
        // Deposit liquidity first
        helper.depositToVault(setup, 10_000e18, 10_000e6);

        uint256 scaledPercent = setup.vault.previewWithdraw(5000e18, 1000e6);

        // The scaled percent should be based on token0's ratio
        assertGt(scaledPercent, 0, "Should return non-zero value");
        assertLe(scaledPercent, MAX_SCALED_PERCENTAGE, "Should not exceed 100%");
    }

    function test_previewWithdraw_BasicCase_Token1IsConstraint() public {
        // Deposit liquidity first
        helper.depositToVault(setup, 10_000e18, 10_000e6);

        // Request withdrawal where token1 is the limiting factor
        // Want 1000 token0 and 5000 token1
        // If vault has ~10k of each, token0 requires 10% withdrawal
        // but token1 requires 50% withdrawal
        // Should return the smaller ratio (token0's 10% = 0.1e18)
        uint256 scaledPercent = setup.vault.previewWithdraw(1000e18, 5000e6);

        // The scaled percent should be based on token1's ratio
        assertGt(scaledPercent, 0, "Should return non-zero value");
        assertLe(scaledPercent, MAX_SCALED_PERCENTAGE, "Should not exceed 100%");
    }

    function test_previewWithdraw_ExactWithdrawal() public {
        // Deposit known amounts
        helper.depositToVault(setup, 10_000e18, 10_000e6);

        (uint256 netAssets0, uint256 netAssets1) = setup.vault.netAssetsValue();

        // Request to withdraw exactly what's available
        uint256 scaledPercent = setup.vault.previewWithdraw(netAssets0, netAssets1);

        // Should return 100% (MAX_SCALED_PERCENTAGE)
        assertEq(scaledPercent, MAX_SCALED_PERCENTAGE, "Should return 100% for exact withdrawal");
    }

    function test_previewWithdraw_ReturnsZero_WhenBothAmountsExceedTVL() public {
        helper.depositToVault(setup, 10_000e18, 10_000e6);

        (uint256 netAssets0, uint256 netAssets1) = setup.vault.netAssetsValue();

        // Request more than available for both tokens
        uint256 scaledPercent = setup.vault.previewWithdraw(netAssets0 + 1000e18, netAssets1 + 1000e6);

        // When both exceed, ratio calculation will underflow or return 0
        assertEq(scaledPercent, 0, "Should return 0 when both amounts exceed TVL");
    }

    function test_previewWithdraw_Token0ExceedsTVL() public {
        helper.depositToVault(setup, 10_000e18, 10_000e6);

        (uint256 netAssets0, uint256 netAssets1) = setup.vault.netAssetsValue();

        // Request more token0 than available, but reasonable token1
        uint256 scaledPercent = setup.vault.previewWithdraw(netAssets0 + 1000e18, netAssets1 / 2);

        assertEq(scaledPercent, 0, "Should return zero for unfeasible partial withdrawal");
    }

    function test_previewWithdraw_Token1ExceedsTVL() public {
        helper.depositToVault(setup, 10_000e18, 10_000e6);

        (uint256 netAssets0, uint256 netAssets1) = setup.vault.netAssetsValue();

        // Request reasonable token0, but more token1 than available
        uint256 scaledPercent = setup.vault.previewWithdraw(netAssets0 / 2, netAssets1 + 1000e6);

        assertEq(scaledPercent, 0, "Should return zero for unfeasible partial withdrawal");
    }

    function test_previewWithdraw_50PercentWithdrawal() public {
        helper.depositToVault(setup, 10_000e18, 10_000e6);

        (uint256 netAssets0, uint256 netAssets1) = setup.vault.netAssetsValue();

        // Request exactly 50% of each
        uint256 scaledPercent = setup.vault.previewWithdraw(netAssets0 / 2, netAssets1 / 2);

        // Should return approximately 50% (accounting for rounding)
        assertApproxEqRel(
            scaledPercent,
            MAX_SCALED_PERCENTAGE / 2,
            0.01e18, // 1% tolerance
            "Should return ~50% for half withdrawal"
        );
    }

    function test_previewWithdraw_SmallWithdrawal() public {
        helper.depositToVault(setup, 10_000e18, 10_000e6);

        (uint256 netAssets0, uint256 netAssets1) = setup.vault.netAssetsValue();

        // Request 1% of each
        uint256 scaledPercent = setup.vault.previewWithdraw(netAssets0 / 100, netAssets1 / 100);

        // Should return approximately 1%
        assertApproxEqRel(
            scaledPercent,
            MAX_SCALED_PERCENTAGE / 100,
            0.01e18, // 1% tolerance
            "Should return ~1% for small withdrawal"
        );
    }

    function test_previewWithdraw_AsymmetricRatios() public {
        helper.depositToVault(setup, 10_000e18, 10_000e6);

        (uint256 netAssets0, uint256 netAssets1) = setup.vault.netAssetsValue();

        // Request 10% of token0 but 90% of token1
        uint256 scaledPercent = setup.vault.previewWithdraw(netAssets0 / 10, (netAssets1 * 9) / 10);

        assertEq(scaledPercent, (MAX_SCALED_PERCENTAGE * 9) / 10, "Should return the higher ratio");
    }

    function test_previewWithdraw_InvertedAsymmetricRatios() public {
        helper.depositToVault(setup, 10_000e18, 10_000e6);

        (uint256 netAssets0, uint256 netAssets1) = setup.vault.netAssetsValue();

        // Request 90% of token0 but 10% of token1
        uint256 scaledPercent = setup.vault.previewWithdraw((netAssets0 * 9) / 10, netAssets1 / 10);

        assertEq(scaledPercent, (MAX_SCALED_PERCENTAGE * 9) / 10, "Should return the higher ratio");
    }

    function test_previewWithdraw_WithAccruedFees() public {
        // Use vault with fees
        helper.depositToVault(feeSetup, 10_000e18, 10_000e6);

        // Warp time to accrue fees
        vm.warp(block.timestamp + 365 days);

        (uint256 netAssets0, uint256 netAssets1) = feeSetup.vault.netAssetsValue();

        // Net assets should be less than gross due to fees
        // Preview withdraw should account for this
        uint256 scaledPercent = feeSetup.vault.previewWithdraw(netAssets0 / 2, netAssets1 / 2);

        assertGt(scaledPercent, 0, "Should handle fee accrual");
        assertLe(scaledPercent, MAX_SCALED_PERCENTAGE, "Should not exceed 100%");
    }

    function test_previewWithdraw_VeryLargeAmounts() public {
        // Deposit large amounts
        helper.depositToVault(setup, 1_000_000e18, 1_000_000e6);

        (uint256 netAssets0, uint256 netAssets1) = setup.vault.netAssetsValue();

        uint256 scaledPercent = setup.vault.previewWithdraw(netAssets0 / 2, netAssets1 / 2);

        assertGt(scaledPercent, 0, "Should handle large amounts");
        assertLe(scaledPercent, MAX_SCALED_PERCENTAGE, "Should not exceed 100%");
    }

    function testFuzz_previewWithdraw_NeverExceedsScalingFactor(uint256 minAmount0, uint256 minAmount1) public {
        // Bound inputs to reasonable ranges
        minAmount0 = bound(minAmount0, 1, 1_000_000e18);
        minAmount1 = bound(minAmount1, 1, 1_000_000e6);

        // Ensure vault has liquidity
        helper.depositToVault(setup, 100_000e18, 100_000e6);

        uint256 scaledPercent = setup.vault.previewWithdraw(minAmount0, minAmount1);

        assertLe(scaledPercent, MAX_SCALED_PERCENTAGE, "Should never exceed 100%");
    }

    function testFuzz_previewWithdraw_ReturnsMaxRatio(uint256 minAmount0, uint256 minAmount1) public {
        // Bound inputs
        minAmount0 = bound(minAmount0, 1e18, 10_000e18);
        minAmount1 = bound(minAmount1, 1e6, 10_000e6);

        helper.depositToVault(setup, 100_000e18, 100_000e6);

        (uint256 netAssets0, uint256 netAssets1) = setup.vault.netAssetsValue();

        // Calculate expected ratios
        uint256 ratio0 = minAmount0.mulDiv(MAX_SCALED_PERCENTAGE, netAssets0);
        uint256 ratio1 = minAmount1.mulDiv(MAX_SCALED_PERCENTAGE, netAssets1);
        uint256 expectedMax = ratio0 > ratio1 ? ratio0 : ratio1;

        uint256 scaledPercent = setup.vault.previewWithdraw(minAmount0, minAmount1);

        assertEq(scaledPercent, expectedMax, "Should return maximum of the two ratios");
        assertTrue(scaledPercent <= MAX_SCALED_PERCENTAGE);
    }

    // todo: test positionsLength()
    // todo: test netAssetsValue with perf and tvl fees (add perf and delay before calling the fct. setup already has fees)
    // todo: test pendingFeeUpdate()
}
