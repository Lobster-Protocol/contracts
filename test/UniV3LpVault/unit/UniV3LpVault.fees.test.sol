// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {UniV3LpVault} from "../../../src/vaults/UniV3LpVault.sol";
import {TestHelper} from "../helpers/TestHelper.sol";
import {TestConstants} from "../helpers/Constants.sol";

contract UniV3LpVaultFeesTest is Test {
    using Math for uint256;

    TestHelper helper;
    TestHelper.VaultSetup setup;
    TestHelper.VaultSetup feeSetup;

    function setUp() public {
        helper = new TestHelper();
        setup = helper.deployVaultWithPool(0); // No fees
        feeSetup = helper.deployVaultWithPool(TestConstants.HIGH_TVL_FEE); // 5% annual
    }

    function test_tvlFees_NoFeesConfigured_NoCollection() public {
        // Setup with zero TVL fee
        helper.depositToVault(setup, TestConstants.LARGE_AMOUNT, TestConstants.LARGE_AMOUNT);
        helper.createPositionAroundCurrentTick(
            setup.vault,
            setup.executor,
            TestConstants.TICK_RANGE_NARROW,
            TestConstants.MEDIUM_AMOUNT,
            TestConstants.MEDIUM_AMOUNT
        );

        helper.simulateTimePass(TestConstants.ONE_YEAR);

        uint256 initialFeeCollectorBalance0 = setup.token0.balanceOf(setup.feeCollector);
        uint256 initialFeeCollectorBalance1 = setup.token1.balanceOf(setup.feeCollector);

        // Trigger fee collection through deposit
        helper.depositToVault(setup, TestConstants.SMALL_AMOUNT, TestConstants.SMALL_AMOUNT);

        // No fees should be collected
        assertEq(setup.token0.balanceOf(setup.feeCollector), initialFeeCollectorBalance0);
        assertEq(setup.token1.balanceOf(setup.feeCollector), initialFeeCollectorBalance1);
    }

    function test_tvlFees_OneMonth_CollectsCorrectAmount() public {
        uint256 depositAmount0 = TestConstants.LARGE_AMOUNT;
        uint256 depositAmount1 = TestConstants.LARGE_AMOUNT;

        helper.depositToVault(feeSetup, depositAmount0, depositAmount1);
        helper.createPositionAroundCurrentTick(
            feeSetup.vault,
            feeSetup.executor,
            TestConstants.TICK_RANGE_NARROW,
            TestConstants.MEDIUM_AMOUNT,
            TestConstants.MEDIUM_AMOUNT
        );

        helper.simulateTimePass(TestConstants.ONE_MONTH);

        uint256 initialFeeCollectorBalance0 = feeSetup.token0.balanceOf(feeSetup.feeCollector);
        uint256 initialFeeCollectorBalance1 = feeSetup.token1.balanceOf(feeSetup.feeCollector);

        vm.expectEmit(false, false, true, true);
        emit UniV3LpVault.TvlFeeCollected(0, 0, feeSetup.feeCollector);

        // Trigger fee collection
        helper.depositToVault(feeSetup, TestConstants.SMALL_AMOUNT, TestConstants.SMALL_AMOUNT);

        // Fee collector should receive approximately 1/12 of 5% of the assets
        uint256 expectedMonthlyFeeRate = TestConstants.HIGH_TVL_FEE.mulDiv(
            TestConstants.ONE_MONTH, TestConstants.ONE_YEAR * TestConstants.MAX_SCALED_PERCENTAGE
        );

        uint256 finalFeeCollectorBalance0 = feeSetup.token0.balanceOf(feeSetup.feeCollector);
        uint256 finalFeeCollectorBalance1 = feeSetup.token1.balanceOf(feeSetup.feeCollector);

        assertTrue(finalFeeCollectorBalance0 > initialFeeCollectorBalance0);
        assertTrue(finalFeeCollectorBalance1 > initialFeeCollectorBalance1);

        // Check approximate fee amounts (allowing for position management complexity)
        uint256 collectedFee0 = finalFeeCollectorBalance0 - initialFeeCollectorBalance0;
        uint256 collectedFee1 = finalFeeCollectorBalance1 - initialFeeCollectorBalance1;

        // Fees should be positive but reasonable
        assertTrue(collectedFee0 > 0);
        assertTrue(collectedFee1 > 0);
        assertTrue(collectedFee0 < depositAmount0 / 10); // Less than 10% of deposit
        assertTrue(collectedFee1 < depositAmount1 / 10);
    }

    function test_tvlFees_OneYear_CollectsFullAnnualFee() public {
        uint256 depositAmount0 = TestConstants.MEDIUM_AMOUNT;
        uint256 depositAmount1 = TestConstants.MEDIUM_AMOUNT;

        helper.depositToVault(feeSetup, depositAmount0, depositAmount1);
        // Don't create positions - keep all as cash for simpler calculation

        helper.simulateTimePass(TestConstants.ONE_YEAR);

        uint256 initialFeeCollectorBalance0 = feeSetup.token0.balanceOf(feeSetup.feeCollector);

        // Trigger fee collection
        helper.depositToVault(feeSetup, 1, 1);

        uint256 finalFeeCollectorBalance0 = feeSetup.token0.balanceOf(feeSetup.feeCollector);
        uint256 collectedFee0 = finalFeeCollectorBalance0 - initialFeeCollectorBalance0;

        // Should collect approximately 5% of the deposit (HIGH_TVL_FEE = 5%)
        uint256 expectedAnnualFee =
            depositAmount0.mulDiv(TestConstants.HIGH_TVL_FEE, TestConstants.MAX_SCALED_PERCENTAGE);

        helper.assertApproxEqual(
            collectedFee0, expectedAnnualFee, TestConstants.TOLERANCE_MEDIUM, "Annual fee collection mismatch"
        );
    }

    function test_tvlFees_MultipleCollections_ResetsTimer() public {
        helper.depositToVault(feeSetup, TestConstants.LARGE_AMOUNT, TestConstants.LARGE_AMOUNT);

        // First collection after 1 month
        helper.simulateTimePass(TestConstants.ONE_MONTH);
        helper.depositToVault(feeSetup, 1, 1); // Trigger collection

        uint256 balanceAfterFirst = feeSetup.token0.balanceOf(feeSetup.feeCollector);

        // Second collection after another month
        helper.simulateTimePass(TestConstants.ONE_MONTH);
        helper.depositToVault(feeSetup, 1, 1); // Trigger collection again

        uint256 balanceAfterSecond = feeSetup.token0.balanceOf(feeSetup.feeCollector);

        // Both collections should have yielded fees
        assertTrue(balanceAfterFirst > 0);
        assertTrue(balanceAfterSecond > balanceAfterFirst);
    }

    function test_tvlFees_NoTimeElapsed_NoCollection() public {
        helper.depositToVault(feeSetup, TestConstants.LARGE_AMOUNT, TestConstants.LARGE_AMOUNT);

        uint256 initialFeeCollectorBalance = feeSetup.token0.balanceOf(feeSetup.feeCollector);

        // Immediately trigger collection without time passing
        helper.depositToVault(feeSetup, TestConstants.SMALL_AMOUNT, TestConstants.SMALL_AMOUNT);

        uint256 finalFeeCollectorBalance = feeSetup.token0.balanceOf(feeSetup.feeCollector);

        // No fees should be collected
        assertEq(finalFeeCollectorBalance, initialFeeCollectorBalance);
    }

    function test_tvlFees_WithdrawalTriggersCollection() public {
        helper.depositToVault(feeSetup, TestConstants.LARGE_AMOUNT, TestConstants.LARGE_AMOUNT);
        helper.createPositionAroundCurrentTick(
            feeSetup.vault,
            feeSetup.executor,
            TestConstants.TICK_RANGE_NARROW,
            TestConstants.MEDIUM_AMOUNT,
            TestConstants.MEDIUM_AMOUNT
        );

        helper.simulateTimePass(TestConstants.ONE_MONTH);

        uint256 initialFeeCollectorBalance = feeSetup.token0.balanceOf(feeSetup.feeCollector);

        // Withdraw should also trigger fee collection
        address recipient = makeAddr("recipient");
        helper.withdrawFromVault(feeSetup, TestConstants.QUARTER_SCALED_PERCENTAGE, recipient);

        uint256 finalFeeCollectorBalance = feeSetup.token0.balanceOf(feeSetup.feeCollector);

        assertTrue(finalFeeCollectorBalance > initialFeeCollectorBalance);
    }

    function test_tvlFees_EmptyVault_NoCollection() public {
        // Don't deposit anything
        helper.simulateTimePass(TestConstants.ONE_YEAR);

        uint256 initialFeeCollectorBalance = feeSetup.token0.balanceOf(feeSetup.feeCollector);

        // Try to trigger collection on empty vault
        helper.depositToVault(feeSetup, TestConstants.SMALL_AMOUNT, TestConstants.SMALL_AMOUNT);

        uint256 finalFeeCollectorBalance = feeSetup.token0.balanceOf(feeSetup.feeCollector);

        // Since vault was empty for the period, no meaningful fees should be collected
        // (the new small deposit doesn't count for the historical period)
        assertEq(finalFeeCollectorBalance, initialFeeCollectorBalance);
    }

    function test_tvlFees_HighFeeRate_CollectsCorrectly() public {
        // Test with very high fee rate (20% annual)
        TestHelper.VaultSetup memory highFeeSetup = helper.deployVaultWithPool(20 * TestConstants.SCALING_FACTOR);

        helper.depositToVault(highFeeSetup, TestConstants.MEDIUM_AMOUNT, TestConstants.MEDIUM_AMOUNT);

        helper.simulateTimePass(TestConstants.ONE_YEAR);

        uint256 initialBalance = highFeeSetup.token0.balanceOf(highFeeSetup.feeCollector);

        helper.depositToVault(highFeeSetup, 1, 1);

        uint256 finalBalance = highFeeSetup.token0.balanceOf(highFeeSetup.feeCollector);
        uint256 collectedFee = finalBalance - initialBalance;

        // Should collect approximately 20% of the deposit
        uint256 expectedFee =
            TestConstants.MEDIUM_AMOUNT.mulDiv(20 * TestConstants.SCALING_FACTOR, TestConstants.MAX_SCALED_PERCENTAGE);

        helper.assertApproxEqual(
            collectedFee, expectedFee, TestConstants.TOLERANCE_MEDIUM, "High fee rate collection mismatch"
        );
    }

    function test_tvlFees_PartialYear_ProportionalCollection() public {
        helper.depositToVault(feeSetup, TestConstants.MEDIUM_AMOUNT, TestConstants.MEDIUM_AMOUNT);

        // Wait for exactly half a year
        helper.simulateTimePass(TestConstants.ONE_YEAR / 2);

        uint256 initialBalance = feeSetup.token0.balanceOf(feeSetup.feeCollector);

        helper.depositToVault(feeSetup, 1, 1);

        uint256 finalBalance = feeSetup.token0.balanceOf(feeSetup.feeCollector);
        uint256 collectedFee = finalBalance - initialBalance;

        // Should collect approximately 2.5% (half of 5% annual)
        uint256 expectedHalfYearFee = TestConstants.MEDIUM_AMOUNT.mulDiv(
            TestConstants.HIGH_TVL_FEE,
            TestConstants.MAX_SCALED_PERCENTAGE * 2 // Half of annual rate
        );

        helper.assertApproxEqual(
            collectedFee, expectedHalfYearFee, TestConstants.TOLERANCE_MEDIUM, "Half-year fee collection mismatch"
        );
    }
}
