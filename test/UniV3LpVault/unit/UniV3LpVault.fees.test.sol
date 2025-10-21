// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {UniV3LpVault, MAX_SCALED_PERCENTAGE, TWAP_SECONDS_AGO} from "../../../src/vaults/UniV3LpVault.sol";
import {TestHelper} from "../helpers/TestHelper.sol";
import {TestConstants} from "../helpers/Constants.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {UniswapUtils} from "../../../src/libraries/uniswapV3/UniswapUtils.sol";

contract UniV3LpVaultFeesTest is Test {
    using Math for uint256;

    TestHelper helper;
    TestHelper.VaultSetup setup;
    TestHelper.VaultSetup tvlFeeSetup;
    TestHelper.VaultSetup perfFeeSetup;
    TestHelper.VaultSetup bothFeeSetup;

    function setUp() public {
        helper = new TestHelper();
        setup = helper.deployVaultWithPool(0, 0); // No fees

        tvlFeeSetup = helper.deployVaultWithPool(
            TestConstants.HIGH_TVL_FEE, // 5% annual
            0
        );
        perfFeeSetup = helper.deployVaultWithPool(
            0,
            TestConstants.HIGH_PERF_FEE // 5%
        );
        bothFeeSetup = helper.deployVaultWithPool(
            TestConstants.HIGH_TVL_FEE, // 5% annual
            TestConstants.HIGH_PERF_FEE // 5%
        );
    }

    function test_tvlAndPerfFees_NoFeesConfigured_NoCollection() public {
        // Setup with zero TVL fee
        helper.depositToVault(setup, TestConstants.LARGE_AMOUNT, TestConstants.LARGE_AMOUNT);
        helper.createPositionAroundCurrentTick(
            setup.vault,
            setup.allocator,
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

        helper.depositToVault(tvlFeeSetup, depositAmount0, depositAmount1);
        helper.createPositionAroundCurrentTick(
            tvlFeeSetup.vault,
            tvlFeeSetup.allocator,
            TestConstants.TICK_RANGE_NARROW,
            TestConstants.MEDIUM_AMOUNT,
            TestConstants.MEDIUM_AMOUNT
        );

        uint256 delay = TestConstants.ONE_MONTH;
        helper.simulateTimePass(delay);

        uint256 initialFeeCollectorBalance0 = tvlFeeSetup.token0.balanceOf(tvlFeeSetup.feeCollector);
        uint256 initialFeeCollectorBalance1 = tvlFeeSetup.token1.balanceOf(tvlFeeSetup.feeCollector);

        vm.expectEmit(false, false, true, true);
        emit UniV3LpVault.TvlFeeCollected(0, 0, tvlFeeSetup.feeCollector);

        // Trigger fee collection
        helper.depositToVault(tvlFeeSetup, TestConstants.SMALL_AMOUNT, TestConstants.SMALL_AMOUNT);

        // Fee collector should receive approximately 1/12 of 5% of the assets
        uint256 tvlFeePercent = tvlFeeSetup.vault.tvlFeeScaled().mulDiv(delay, 365 days);
        uint256 expectedFee0 = depositAmount0.mulDiv(tvlFeePercent, MAX_SCALED_PERCENTAGE);
        uint256 expectedFee1 = depositAmount1.mulDiv(tvlFeePercent, MAX_SCALED_PERCENTAGE);

        uint256 finalFeeCollectorBalance0 = tvlFeeSetup.token0.balanceOf(tvlFeeSetup.feeCollector);
        uint256 finalFeeCollectorBalance1 = tvlFeeSetup.token1.balanceOf(tvlFeeSetup.feeCollector);

        assertTrue(finalFeeCollectorBalance0 > initialFeeCollectorBalance0);
        assertTrue(finalFeeCollectorBalance1 > initialFeeCollectorBalance1);

        // Check approximate fee amounts (allowing for position management complexity)
        uint256 collectedFee0 = finalFeeCollectorBalance0 - initialFeeCollectorBalance0;
        uint256 collectedFee1 = finalFeeCollectorBalance1 - initialFeeCollectorBalance1;

        // Fees should be positive but reasonable
        assertApproxEqAbs(collectedFee0, expectedFee0, 2);
        assertApproxEqAbs(collectedFee1, expectedFee1, 2);
    }

    function test_tvlFees_OneYear_CollectsFullAnnualFee() public {
        uint256 depositAmount0 = TestConstants.MEDIUM_AMOUNT;
        uint256 depositAmount1 = TestConstants.MEDIUM_AMOUNT;

        helper.depositToVault(tvlFeeSetup, depositAmount0, depositAmount1);
        // Don't create positions - keep all as cash for simpler calculation

        helper.simulateTimePass(TestConstants.ONE_YEAR);

        uint256 initialFeeCollectorBalance0 = tvlFeeSetup.token0.balanceOf(tvlFeeSetup.feeCollector);

        // Trigger fee collection
        helper.depositToVault(tvlFeeSetup, 1, 1);

        uint256 finalFeeCollectorBalance0 = tvlFeeSetup.token0.balanceOf(tvlFeeSetup.feeCollector);
        uint256 collectedFee0 = finalFeeCollectorBalance0 - initialFeeCollectorBalance0;

        // Should collect approximately 5% of the deposit (HIGH_TVL_FEE = 5%)
        uint256 expectedAnnualFee =
            depositAmount0.mulDiv(TestConstants.HIGH_TVL_FEE, TestConstants.MAX_SCALED_PERCENTAGE);

        helper.assertApproxEqual(
            collectedFee0, expectedAnnualFee, TestConstants.TOLERANCE_MEDIUM, "Annual fee collection mismatch"
        );
    }

    function test_tvlFees_MultipleCollections_ResetsTimer() public {
        helper.depositToVault(tvlFeeSetup, TestConstants.LARGE_AMOUNT, TestConstants.LARGE_AMOUNT);

        // First collection after 1 month
        helper.simulateTimePass(TestConstants.ONE_MONTH);
        helper.depositToVault(tvlFeeSetup, 1, 1); // Trigger collection

        uint256 balanceAfterFirst = tvlFeeSetup.token0.balanceOf(tvlFeeSetup.feeCollector);

        // Second collection after another month
        helper.simulateTimePass(TestConstants.ONE_MONTH);
        helper.depositToVault(tvlFeeSetup, 1, 1); // Trigger collection again

        uint256 balanceAfterSecond = tvlFeeSetup.token0.balanceOf(tvlFeeSetup.feeCollector);

        // Both collections should have yielded fees
        assertTrue(balanceAfterFirst > 0);
        assertTrue(balanceAfterSecond > balanceAfterFirst);
    }

    function test_tvlFees_NoTimeElapsed_NoCollection() public {
        helper.depositToVault(tvlFeeSetup, TestConstants.LARGE_AMOUNT, TestConstants.LARGE_AMOUNT);

        uint256 initialFeeCollectorBalance = tvlFeeSetup.token0.balanceOf(tvlFeeSetup.feeCollector);

        // Immediately trigger collection without time passing
        helper.depositToVault(tvlFeeSetup, TestConstants.SMALL_AMOUNT, TestConstants.SMALL_AMOUNT);

        uint256 finalFeeCollectorBalance = tvlFeeSetup.token0.balanceOf(tvlFeeSetup.feeCollector);

        // No fees should be collected
        assertEq(finalFeeCollectorBalance, initialFeeCollectorBalance);
    }

    function test_tvlFees_DepositTriggersCollection() public {
        uint256 deposit0 = TestConstants.LARGE_AMOUNT;
        uint256 deposit1 = TestConstants.LARGE_AMOUNT;

        helper.depositToVault(tvlFeeSetup, deposit0, deposit1);

        helper.createPositionAroundCurrentTick(
            tvlFeeSetup.vault,
            tvlFeeSetup.allocator,
            TestConstants.TICK_RANGE_NARROW,
            TestConstants.MEDIUM_AMOUNT,
            TestConstants.MEDIUM_AMOUNT
        );

        uint256 delay = TestConstants.ONE_MONTH;
        helper.simulateTimePass(delay);

        uint256 initialFeeCollectorBalance0 = tvlFeeSetup.token0.balanceOf(tvlFeeSetup.feeCollector);
        uint256 initialFeeCollectorBalance1 = tvlFeeSetup.token1.balanceOf(tvlFeeSetup.feeCollector);

        // Withdraw should also trigger fee collection
        address recipient = makeAddr("recipient");
        helper.withdrawFromVault(tvlFeeSetup, TestConstants.QUARTER_SCALED_PERCENTAGE, recipient);

        uint256 feeScaledPercent = tvlFeeSetup.vault.tvlFeeScaled().mulDiv(delay, 365 days);

        uint256 expectedFee0 = deposit0.mulDiv(feeScaledPercent, MAX_SCALED_PERCENTAGE);
        uint256 expectedFee1 = deposit1.mulDiv(feeScaledPercent, MAX_SCALED_PERCENTAGE);

        uint256 finalFeeCollectorBalance0 = tvlFeeSetup.token0.balanceOf(tvlFeeSetup.feeCollector);
        uint256 finalFeeCollectorBalance1 = tvlFeeSetup.token1.balanceOf(tvlFeeSetup.feeCollector);

        assertApproxEqAbs(finalFeeCollectorBalance0, initialFeeCollectorBalance0 + expectedFee0, 1);
        assertApproxEqAbs(finalFeeCollectorBalance1, initialFeeCollectorBalance1 + expectedFee1, 1);
    }

    function test_tvlFees_WithdrawalTriggersCollection() public {
        uint256 deposit0 = TestConstants.LARGE_AMOUNT;
        uint256 deposit1 = TestConstants.LARGE_AMOUNT;

        helper.depositToVault(tvlFeeSetup, deposit0, deposit1);
        helper.createPositionAroundCurrentTick(
            tvlFeeSetup.vault,
            tvlFeeSetup.allocator,
            TestConstants.TICK_RANGE_NARROW,
            TestConstants.MEDIUM_AMOUNT,
            TestConstants.MEDIUM_AMOUNT
        );

        uint256 delay = TestConstants.ONE_MONTH;
        helper.simulateTimePass(delay);

        uint256 initialFeeCollectorBalance0 = tvlFeeSetup.token0.balanceOf(tvlFeeSetup.feeCollector);
        uint256 initialFeeCollectorBalance1 = tvlFeeSetup.token0.balanceOf(tvlFeeSetup.feeCollector);

        // Withdraw should also trigger fee collection
        address recipient = makeAddr("recipient");
        helper.withdrawFromVault(tvlFeeSetup, TestConstants.QUARTER_SCALED_PERCENTAGE, recipient);

        uint256 feeScaledPercent = tvlFeeSetup.vault.tvlFeeScaled().mulDiv(delay, 365 days);

        uint256 expectedFee0 = deposit0.mulDiv(feeScaledPercent, MAX_SCALED_PERCENTAGE);
        uint256 expectedFee1 = deposit1.mulDiv(feeScaledPercent, MAX_SCALED_PERCENTAGE);

        uint256 finalFeeCollectorBalance0 = tvlFeeSetup.token0.balanceOf(tvlFeeSetup.feeCollector);
        uint256 finalFeeCollectorBalance1 = tvlFeeSetup.token1.balanceOf(tvlFeeSetup.feeCollector);

        assertApproxEqAbs(finalFeeCollectorBalance0, initialFeeCollectorBalance0 + expectedFee0, 1);
        assertApproxEqAbs(finalFeeCollectorBalance1, initialFeeCollectorBalance1 + expectedFee1, 1);
    }

    function test_tvlAndPerfFees_EmptyVault_NoCollection() public {
        // Don't deposit anything
        helper.simulateTimePass(TestConstants.ONE_YEAR);

        uint256 initialFeeCollectorBalance = bothFeeSetup.token0.balanceOf(bothFeeSetup.feeCollector);

        // Try to trigger collection on empty vault
        helper.depositToVault( // ---
            bothFeeSetup,
            TestConstants.SMALL_AMOUNT,
            TestConstants.SMALL_AMOUNT
        );

        uint256 finalFeeCollectorBalance = bothFeeSetup.token0.balanceOf(bothFeeSetup.feeCollector);

        // Since vault was empty for the period, no meaningful fees should be collected
        // (the new small deposit doesn't count for the historical period)
        assertEq(finalFeeCollectorBalance, initialFeeCollectorBalance);
    }

    function test_tvlFees_HighFeeRate_CollectsCorrectly() public {
        // Test with very high fee rate (20% annual)
        TestHelper.VaultSetup memory highFeeSetup =
            helper.deployVaultWithPool(20 * TestConstants.SCALING_FACTOR, 20 * TestConstants.SCALING_FACTOR);

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
        helper.depositToVault(tvlFeeSetup, TestConstants.MEDIUM_AMOUNT, TestConstants.MEDIUM_AMOUNT);

        // Wait for exactly half a year
        helper.simulateTimePass(TestConstants.ONE_YEAR / 2);

        uint256 initialBalance = tvlFeeSetup.token0.balanceOf(tvlFeeSetup.feeCollector);

        helper.depositToVault(tvlFeeSetup, 1, 1);

        uint256 finalBalance = tvlFeeSetup.token0.balanceOf(tvlFeeSetup.feeCollector);
        uint256 collectedFee = finalBalance - initialBalance;

        // Should collect approximately 2.5% (half of 5% annual)
        uint256 expectedHalfYearFee = TestConstants.MEDIUM_AMOUNT
            .mulDiv(
                TestConstants.HIGH_TVL_FEE,
                TestConstants.MAX_SCALED_PERCENTAGE * 2 // Half of annual rate
            );

        helper.assertApproxEqual(
            collectedFee, expectedHalfYearFee, TestConstants.TOLERANCE_MEDIUM, "Half-year fee collection mismatch"
        );
    }

    function test_PerfFees_DepositTriggersCollection() public {
        uint256 initialFeeCollectorBalance0 = perfFeeSetup.token0.balanceOf(perfFeeSetup.feeCollector);
        uint256 initialFeeCollectorBalance1 = perfFeeSetup.token1.balanceOf(perfFeeSetup.feeCollector);

        uint256 deposit0 = TestConstants.LARGE_AMOUNT;
        uint256 deposit1 = TestConstants.LARGE_AMOUNT;

        helper.depositToVault(perfFeeSetup, deposit0, deposit1);

        helper.createPositionAroundCurrentTick(
            perfFeeSetup.vault,
            perfFeeSetup.allocator,
            TestConstants.TICK_RANGE_NARROW,
            TestConstants.MEDIUM_AMOUNT,
            TestConstants.MEDIUM_AMOUNT
        );

        // Mint tokens to the vault to simulate +100% performance
        (uint256 tvl0, uint256 tvl1) = perfFeeSetup.vault.rawAssetsValue();
        perfFeeSetup.token0.mint(address(perfFeeSetup.vault), tvl0);
        perfFeeSetup.token1.mint(address(perfFeeSetup.vault), tvl1);

        // actual_performance = +100% so perf fee will be vault.performanceFeeScaled()
        uint256 feeScaledPercent = perfFeeSetup.vault.performanceFeeScaled();

        // Deposit must trigger fee collection
        helper.depositToVault(perfFeeSetup, 1 ether, 1 ether);

        uint256 expectedFee0 = deposit0.mulDiv(feeScaledPercent, MAX_SCALED_PERCENTAGE);
        uint256 expectedFee1 = deposit1.mulDiv(feeScaledPercent, MAX_SCALED_PERCENTAGE);

        uint256 finalFeeCollectorBalance0 = perfFeeSetup.token0.balanceOf(perfFeeSetup.feeCollector);
        uint256 finalFeeCollectorBalance1 = perfFeeSetup.token1.balanceOf(perfFeeSetup.feeCollector);

        assertApproxEqAbs(finalFeeCollectorBalance0, initialFeeCollectorBalance0 + expectedFee0, 3);
        assertApproxEqAbs(finalFeeCollectorBalance1, initialFeeCollectorBalance1 + expectedFee1, 3);

        // make sure vault.lastVaultTvl0() have been updated
        // works since no perf since last deposit & no tvl fee
        (uint256 finalTvl0, uint256 finalTvl1) = perfFeeSetup.vault.rawAssetsValue();
        // Use a reasonable base amount instead of 1 if there is an overflow
        uint128 baseAmount = uint128(1);
        if (finalTvl1 <= type(uint128).max) {
            // forge-lint: disable-next-line(unsafe-typecast)
            baseAmount = uint128(finalTvl1);
        }

        uint256 twapResult = UniswapUtils.getTwap(perfFeeSetup.pool, TWAP_SECONDS_AGO, baseAmount, true);

        // Scale the result if we used a smaller base amount
        uint256 twapValueFrom1To0;
        if (tvl1 > type(uint128).max) {
            twapValueFrom1To0 = twapResult * tvl1;
        } else {
            twapValueFrom1To0 = twapResult;
        }
        assertEq(perfFeeSetup.vault.lastVaultTvl0(), finalTvl0 + twapValueFrom1To0);
    }

    function test_PerfFees_WithdrawalTriggersCollection() public {
        uint256 deposit0 = TestConstants.LARGE_AMOUNT;
        uint256 deposit1 = TestConstants.LARGE_AMOUNT;

        helper.depositToVault(perfFeeSetup, deposit0, deposit1);
        helper.createPositionAroundCurrentTick(
            perfFeeSetup.vault,
            perfFeeSetup.allocator,
            TestConstants.TICK_RANGE_NARROW,
            TestConstants.MEDIUM_AMOUNT,
            TestConstants.MEDIUM_AMOUNT
        );

        // Mint tokens to the vault to simulate +100% performance
        (uint256 tvl0, uint256 tvl1) = perfFeeSetup.vault.rawAssetsValue();
        perfFeeSetup.token0.mint(address(perfFeeSetup.vault), tvl0 / 2);
        perfFeeSetup.token1.mint(address(perfFeeSetup.vault), tvl1 / 2);

        // actual_performance = +50% so perf fee will be vault.performanceFeeScaled() / 2
        uint256 feeScaledPercent = perfFeeSetup.vault.performanceFeeScaled() / 2;

        uint256 initialFeeCollectorBalance0 = perfFeeSetup.token0.balanceOf(perfFeeSetup.feeCollector);
        uint256 initialFeeCollectorBalance1 = perfFeeSetup.token0.balanceOf(perfFeeSetup.feeCollector);

        // Withdraw should also trigger fee collection
        address recipient = makeAddr("recipient");
        helper.withdrawFromVault(perfFeeSetup, TestConstants.QUARTER_SCALED_PERCENTAGE, recipient);

        uint256 expectedFee0 = deposit0.mulDiv(feeScaledPercent, MAX_SCALED_PERCENTAGE);
        uint256 expectedFee1 = deposit1.mulDiv(feeScaledPercent, MAX_SCALED_PERCENTAGE);

        uint256 finalFeeCollectorBalance0 = perfFeeSetup.token0.balanceOf(perfFeeSetup.feeCollector);
        uint256 finalFeeCollectorBalance1 = perfFeeSetup.token1.balanceOf(perfFeeSetup.feeCollector);

        assertApproxEqAbs(finalFeeCollectorBalance0, initialFeeCollectorBalance0 + expectedFee0, 2);
        assertApproxEqAbs(finalFeeCollectorBalance1, initialFeeCollectorBalance1 + expectedFee1, 2);

        // make sure vault.lastVaultTvl0() have been updated
        // works since no perf since last deposit & no tvl fee
        (uint256 finalTvl0, uint256 finalTvl1) = perfFeeSetup.vault.rawAssetsValue();

        // Use a reasonable base amount instead of 1 if there is an overflow
        uint128 baseAmount = uint128(1);
        if (finalTvl1 <= type(uint128).max) {
            // forge-lint: disable-next-line(unsafe-typecast)
            baseAmount = uint128(finalTvl1);
        }

        uint256 twapResult = UniswapUtils.getTwap(perfFeeSetup.pool, TWAP_SECONDS_AGO, baseAmount, true);

        // Scale the result if we used a smaller base amount
        uint256 twapValueFrom1To0;
        if (tvl1 > type(uint128).max) {
            twapValueFrom1To0 = twapResult * tvl1;
        } else {
            twapValueFrom1To0 = twapResult;
        }

        assertEq(perfFeeSetup.vault.lastVaultTvl0(), finalTvl0 + twapValueFrom1To0);
    }

    function test_perfFees_MultipleCollectionsWithFullWithdraw() public {
        uint256 deposit00 = TestConstants.LARGE_AMOUNT;
        uint256 deposit01 = TestConstants.LARGE_AMOUNT;

        helper.depositToVault(perfFeeSetup, deposit00, deposit01);
        helper.createPositionAroundCurrentTick(
            perfFeeSetup.vault,
            perfFeeSetup.allocator,
            TestConstants.TICK_RANGE_NARROW,
            TestConstants.MEDIUM_AMOUNT,
            TestConstants.MEDIUM_AMOUNT
        );

        // Mint tokens to the vault to simulate +100% performance
        (uint256 tvl00, uint256 tvl01) = perfFeeSetup.vault.rawAssetsValue();
        perfFeeSetup.token0.mint(address(perfFeeSetup.vault), tvl00 / 2);
        perfFeeSetup.token1.mint(address(perfFeeSetup.vault), tvl01 / 2);

        // actual_performance = +50% so perf fee will be vault.performanceFeeScaled() / 2
        uint256 feeScaledPercent0 = perfFeeSetup.vault.performanceFeeScaled() / 2;

        uint256 initialFeeCollectorBalance0 = perfFeeSetup.token0.balanceOf(perfFeeSetup.feeCollector);
        uint256 initialFeeCollectorBalance1 = perfFeeSetup.token0.balanceOf(perfFeeSetup.feeCollector);

        // Withdraw should also trigger fee collection
        address recipient = makeAddr("recipient");
        helper.withdrawFromVault(perfFeeSetup, TestConstants.MAX_SCALED_PERCENTAGE, recipient);

        // deposit again
        uint256 deposit10 = TestConstants.LARGE_AMOUNT;
        uint256 deposit11 = TestConstants.LARGE_AMOUNT;

        helper.depositToVault(perfFeeSetup, deposit10, deposit11);
        helper.createPositionAroundCurrentTick(
            perfFeeSetup.vault,
            perfFeeSetup.allocator,
            TestConstants.TICK_RANGE_NARROW,
            TestConstants.MEDIUM_AMOUNT,
            TestConstants.MEDIUM_AMOUNT
        );

        // Mint tokens to the vault to simulate +100% performance
        (uint256 tvl10, uint256 tvl11) = perfFeeSetup.vault.rawAssetsValue();
        perfFeeSetup.token0.mint(address(perfFeeSetup.vault), tvl10 / 10);
        perfFeeSetup.token1.mint(address(perfFeeSetup.vault), tvl11 / 10);

        helper.withdrawFromVault(perfFeeSetup, TestConstants.QUARTER_SCALED_PERCENTAGE, recipient);

        // actual_performance = +10% so perf fee will be vault.performanceFeeScaled() / 2
        uint256 feeScaledPercent1 = perfFeeSetup.vault.performanceFeeScaled() / 10;

        uint256 expectedFee00 = deposit00.mulDiv(feeScaledPercent0, MAX_SCALED_PERCENTAGE);
        uint256 expectedFee01 = deposit01.mulDiv(feeScaledPercent0, MAX_SCALED_PERCENTAGE);

        uint256 expectedFee10 = deposit10.mulDiv(feeScaledPercent1, MAX_SCALED_PERCENTAGE);
        uint256 expectedFee11 = deposit11.mulDiv(feeScaledPercent1, MAX_SCALED_PERCENTAGE);

        uint256 finalFeeCollectorBalance0 = perfFeeSetup.token0.balanceOf(perfFeeSetup.feeCollector);
        uint256 finalFeeCollectorBalance1 = perfFeeSetup.token1.balanceOf(perfFeeSetup.feeCollector);

        assertApproxEqAbs(finalFeeCollectorBalance0, initialFeeCollectorBalance0 + expectedFee00 + expectedFee10, 4);
        assertApproxEqAbs(finalFeeCollectorBalance1, initialFeeCollectorBalance1 + expectedFee01 + expectedFee11, 4);

        // make sure vault.lastVaultTvl0() have been updated
        // works since no perf since last deposit & no tvl fee
        (uint256 finalTvl0, uint256 finalTvl1) = perfFeeSetup.vault.rawAssetsValue();
        // Use a reasonable base amount instead of 1 if there is an overflow
        uint128 baseAmount = uint128(1);
        if (finalTvl1 <= type(uint128).max) {
            // forge-lint: disable-next-line(unsafe-typecast)
            baseAmount = uint128(finalTvl1);
        }

        uint256 twapResult = UniswapUtils.getTwap(perfFeeSetup.pool, TWAP_SECONDS_AGO, baseAmount, true);

        // Scale the result if we used a smaller base amount
        uint256 twapValueFrom1To0;
        if (tvl11 > type(uint128).max) {
            twapValueFrom1To0 = twapResult * tvl11;
        } else {
            twapValueFrom1To0 = twapResult;
        }
        assertEq(perfFeeSetup.vault.lastVaultTvl0(), finalTvl0 + twapValueFrom1To0);
    }

    function test_perfFees_MultipleCollections() public {
        uint256 deposit00 = TestConstants.LARGE_AMOUNT;
        uint256 deposit01 = TestConstants.LARGE_AMOUNT;

        helper.depositToVault(perfFeeSetup, deposit00, deposit01);
        helper.createPositionAroundCurrentTick(
            perfFeeSetup.vault,
            perfFeeSetup.allocator,
            TestConstants.TICK_RANGE_NARROW,
            TestConstants.MEDIUM_AMOUNT,
            TestConstants.MEDIUM_AMOUNT
        );

        // Mint tokens to the vault to simulate +100% performance
        (uint256 tvl00, uint256 tvl01) = perfFeeSetup.vault.rawAssetsValue();
        perfFeeSetup.token0.mint(address(perfFeeSetup.vault), tvl00 / 2);
        perfFeeSetup.token1.mint(address(perfFeeSetup.vault), tvl01 / 2);

        // actual_performance = +50% so perf fee will be vault.performanceFeeScaled() / 2
        uint256 feeScaledPercent0 = perfFeeSetup.vault.performanceFeeScaled() / 2;

        uint256 initialFeeCollectorBalance0 = perfFeeSetup.token0.balanceOf(perfFeeSetup.feeCollector);
        uint256 initialFeeCollectorBalance1 = perfFeeSetup.token0.balanceOf(perfFeeSetup.feeCollector);

        // Withdraw should also trigger fee collection
        address recipient = makeAddr("recipient");
        helper.withdrawFromVault(perfFeeSetup, TestConstants.QUARTER_SCALED_PERCENTAGE, recipient);

        // deposit again
        uint256 deposit10 = TestConstants.LARGE_AMOUNT;
        uint256 deposit11 = TestConstants.LARGE_AMOUNT;

        helper.depositToVault(perfFeeSetup, deposit10, deposit11);
        helper.createPositionAroundCurrentTick(
            perfFeeSetup.vault,
            perfFeeSetup.allocator,
            TestConstants.TICK_RANGE_NARROW,
            TestConstants.MEDIUM_AMOUNT,
            TestConstants.MEDIUM_AMOUNT
        );

        // Mint tokens to the vault to simulate +100% performance
        (uint256 tvl10, uint256 tvl11) = perfFeeSetup.vault.rawAssetsValue();
        perfFeeSetup.token0.mint(address(perfFeeSetup.vault), tvl10 / 10);
        perfFeeSetup.token1.mint(address(perfFeeSetup.vault), tvl11 / 10);

        helper.withdrawFromVault(perfFeeSetup, TestConstants.QUARTER_SCALED_PERCENTAGE, recipient);

        // actual_performance = +10% so perf fee will be vault.performanceFeeScaled() / 2
        uint256 feeScaledPercent1 = perfFeeSetup.vault.performanceFeeScaled() / 10;

        uint256 expectedFee00 = deposit00.mulDiv(feeScaledPercent0, MAX_SCALED_PERCENTAGE);
        uint256 expectedFee01 = deposit01.mulDiv(feeScaledPercent0, MAX_SCALED_PERCENTAGE);

        uint256 expectedFee10 = tvl10.mulDiv(feeScaledPercent1, MAX_SCALED_PERCENTAGE);
        uint256 expectedFee11 = tvl11.mulDiv(feeScaledPercent1, MAX_SCALED_PERCENTAGE);

        uint256 finalFeeCollectorBalance0 = perfFeeSetup.token0.balanceOf(perfFeeSetup.feeCollector);
        uint256 finalFeeCollectorBalance1 = perfFeeSetup.token1.balanceOf(perfFeeSetup.feeCollector);

        assertApproxEqAbs(finalFeeCollectorBalance0, initialFeeCollectorBalance0 + expectedFee00 + expectedFee10, 4);
        assertApproxEqAbs(finalFeeCollectorBalance1, initialFeeCollectorBalance1 + expectedFee01 + expectedFee11, 4);

        // make sure vault.lastVaultTvl0() have been updated
        // works since no perf since last deposit & no tvl fee
        (uint256 finalTvl0, uint256 finalTvl1) = perfFeeSetup.vault.rawAssetsValue();
        // Use a reasonable base amount instead of 1 if there is an overflow
        // casting to 'uint128' is safe because of ternary operator
        uint128 baseAmount = uint128(1);
        if (finalTvl1 <= type(uint128).max) {
            // forge-lint: disable-next-line(unsafe-typecast)
            baseAmount = uint128(finalTvl1);
        }
        uint256 twapResult = UniswapUtils.getTwap(perfFeeSetup.pool, TWAP_SECONDS_AGO, baseAmount, true);

        // Scale the result if we used a smaller base amount
        uint256 twapValueFrom1To0;
        if (tvl11 > type(uint128).max) {
            twapValueFrom1To0 = twapResult * tvl11;
        } else {
            twapValueFrom1To0 = twapResult;
        }
        assertEq(perfFeeSetup.vault.lastVaultTvl0(), finalTvl0 + twapValueFrom1To0);
    }

    function test_perfFees_NoPerf() public {
        uint256 initialFeeCollectorBalance0 = perfFeeSetup.token0.balanceOf(perfFeeSetup.feeCollector);
        uint256 initialFeeCollectorBalance1 = perfFeeSetup.token1.balanceOf(perfFeeSetup.feeCollector);

        uint256 deposit0 = TestConstants.LARGE_AMOUNT;
        uint256 deposit1 = TestConstants.LARGE_AMOUNT;

        helper.depositToVault(perfFeeSetup, deposit0, deposit1);

        helper.createPositionAroundCurrentTick(
            perfFeeSetup.vault,
            perfFeeSetup.allocator,
            TestConstants.TICK_RANGE_NARROW,
            TestConstants.MEDIUM_AMOUNT,
            TestConstants.MEDIUM_AMOUNT
        );

        // No perf made

        // Deposit must trigger fee collection
        helper.depositToVault(perfFeeSetup, 1 ether, 1 ether);

        uint256 finalFeeCollectorBalance0 = perfFeeSetup.token0.balanceOf(perfFeeSetup.feeCollector);
        uint256 finalFeeCollectorBalance1 = perfFeeSetup.token1.balanceOf(perfFeeSetup.feeCollector);

        assertEq(finalFeeCollectorBalance0, initialFeeCollectorBalance0);
        assertEq(finalFeeCollectorBalance1, initialFeeCollectorBalance1);

        // make sure vault.lastVaultTvl0() have been updated
        // works since no perf since last deposit & no tvl fee
        (uint256 finalTvl0, uint256 finalTvl1) = perfFeeSetup.vault.rawAssetsValue();
        // Use a reasonable base amount instead of 1 if there is an overflow
        // casting to 'uint128' is safe because of ternary operator
        uint128 baseAmount = finalTvl1 > type(uint128).max
            ? uint128(1)  // forge-lint: disable-next-line(unsafe-typecast)
            : uint128(finalTvl1);

        uint256 twapResult = UniswapUtils.getTwap(perfFeeSetup.pool, TWAP_SECONDS_AGO, baseAmount, true);

        // Scale the result if we used a smaller base amount
        uint256 twapValueFrom1To0;
        if (finalTvl1 > type(uint128).max) {
            twapValueFrom1To0 = twapResult * finalTvl1;
        } else {
            twapValueFrom1To0 = twapResult;
        }
        assertEq(perfFeeSetup.vault.lastVaultTvl0(), finalTvl0 + twapValueFrom1To0);
    }

    function test_perfFees_NegPerf() public {
        uint256 initialFeeCollectorBalance0 = perfFeeSetup.token0.balanceOf(perfFeeSetup.feeCollector);
        uint256 initialFeeCollectorBalance1 = perfFeeSetup.token1.balanceOf(perfFeeSetup.feeCollector);

        uint256 deposit0 = TestConstants.LARGE_AMOUNT;
        uint256 deposit1 = TestConstants.LARGE_AMOUNT;

        helper.depositToVault(perfFeeSetup, deposit0, deposit1);

        uint256 initial_lastVaultTvl0 = perfFeeSetup.vault.lastVaultTvl0();

        // Burn tokens to the vault to simulate negative performance
        perfFeeSetup.token0.burn(address(perfFeeSetup.vault), 1);
        perfFeeSetup.token1.burn(address(perfFeeSetup.vault), 1);

        // Deposit must trigger fee collection
        helper.depositToVault(perfFeeSetup, 1, 1); // negligeable impact on new lastVaultTvl0 value

        uint256 finalFeeCollectorBalance0 = perfFeeSetup.token0.balanceOf(perfFeeSetup.feeCollector);
        uint256 finalFeeCollectorBalance1 = perfFeeSetup.token1.balanceOf(perfFeeSetup.feeCollector);

        assertEq(finalFeeCollectorBalance0, initialFeeCollectorBalance0);
        assertEq(finalFeeCollectorBalance1, initialFeeCollectorBalance1);

        // make sure vault.lastVaultTvl0() have not been updated
        assertTrue(initial_lastVaultTvl0 > 0);

        // burn of -1 of each assets and deposit of 1 of each assets should cancel each other
        assertEq(perfFeeSetup.vault.lastVaultTvl0(), initial_lastVaultTvl0);
    }

    function test_perfAndFees_CollectionOnDeposit() public {
        uint256 deposit0 = TestConstants.LARGE_AMOUNT;
        uint256 deposit1 = TestConstants.LARGE_AMOUNT;

        helper.depositToVault(perfFeeSetup, deposit0, deposit1);
        helper.createPositionAroundCurrentTick(
            perfFeeSetup.vault,
            perfFeeSetup.allocator,
            TestConstants.TICK_RANGE_NARROW,
            TestConstants.MEDIUM_AMOUNT,
            TestConstants.MEDIUM_AMOUNT
        );

        // Mint tokens to the vault to simulate +100% performance
        (uint256 tvl0, uint256 tvl1) = perfFeeSetup.vault.rawAssetsValue();
        perfFeeSetup.token0.mint(address(perfFeeSetup.vault), tvl0 / 2);
        perfFeeSetup.token1.mint(address(perfFeeSetup.vault), tvl1 / 2);

        // actual_performance = +50% so perf fee will be vault.performanceFeeScaled() / 2
        uint256 feeScaledPercent = perfFeeSetup.vault.performanceFeeScaled() / 2;

        uint256 initialFeeCollectorBalance0 = perfFeeSetup.token0.balanceOf(perfFeeSetup.feeCollector);
        uint256 initialFeeCollectorBalance1 = perfFeeSetup.token0.balanceOf(perfFeeSetup.feeCollector);

        // Deposit should trigger fee collection
        helper.depositToVault(perfFeeSetup, 1, 1);

        uint256 expectedFee0 = deposit0.mulDiv(feeScaledPercent, MAX_SCALED_PERCENTAGE);
        uint256 expectedFee1 = deposit1.mulDiv(feeScaledPercent, MAX_SCALED_PERCENTAGE);

        uint256 finalFeeCollectorBalance0 = perfFeeSetup.token0.balanceOf(perfFeeSetup.feeCollector);
        uint256 finalFeeCollectorBalance1 = perfFeeSetup.token1.balanceOf(perfFeeSetup.feeCollector);

        assertApproxEqAbs(finalFeeCollectorBalance0, initialFeeCollectorBalance0 + expectedFee0, 2);
        assertApproxEqAbs(finalFeeCollectorBalance1, initialFeeCollectorBalance1 + expectedFee1, 2);

        // make sure vault.lastVaultTvl0() have been updated
        // works since no perf since last deposit & no tvl fee
        (uint256 finalTvl0, uint256 finalTvl1) = perfFeeSetup.vault.rawAssetsValue();

        // Use a reasonable base amount instead of 1 if there is an overflow
        uint128 baseAmount = uint128(1);
        if (finalTvl1 <= type(uint128).max) {
            // forge-lint: disable-next-line(unsafe-typecast)
            baseAmount = uint128(finalTvl1);
        }

        uint256 twapResult = UniswapUtils.getTwap(perfFeeSetup.pool, TWAP_SECONDS_AGO, baseAmount, true);

        // Scale the result if we used a smaller base amount
        uint256 twapValueFrom1To0;
        if (tvl1 > type(uint128).max) {
            twapValueFrom1To0 = twapResult * tvl1;
        } else {
            twapValueFrom1To0 = twapResult;
        }

        assertEq(perfFeeSetup.vault.lastVaultTvl0(), finalTvl0 + twapValueFrom1To0);
    }

    function test_perfAndFees_CollectionOnWithdraw() public {
        uint256 deposit0 = TestConstants.LARGE_AMOUNT;
        uint256 deposit1 = TestConstants.LARGE_AMOUNT;

        helper.depositToVault(perfFeeSetup, deposit0, deposit1);
        helper.createPositionAroundCurrentTick(
            perfFeeSetup.vault,
            perfFeeSetup.allocator,
            TestConstants.TICK_RANGE_NARROW,
            TestConstants.MEDIUM_AMOUNT,
            TestConstants.MEDIUM_AMOUNT
        );

        // Mint tokens to the vault to simulate +100% performance
        (uint256 tvl0, uint256 tvl1) = perfFeeSetup.vault.rawAssetsValue();
        perfFeeSetup.token0.mint(address(perfFeeSetup.vault), tvl0 / 2);
        perfFeeSetup.token1.mint(address(perfFeeSetup.vault), tvl1 / 2);

        // actual_performance = +50% so perf fee will be vault.performanceFeeScaled() / 2
        uint256 feeScaledPercent = perfFeeSetup.vault.performanceFeeScaled() / 2;

        uint256 initialFeeCollectorBalance0 = perfFeeSetup.token0.balanceOf(perfFeeSetup.feeCollector);
        uint256 initialFeeCollectorBalance1 = perfFeeSetup.token0.balanceOf(perfFeeSetup.feeCollector);

        // Withdraw should trigger fee collection
        address recipient = makeAddr("recipient");
        helper.withdrawFromVault(perfFeeSetup, TestConstants.QUARTER_SCALED_PERCENTAGE, recipient);

        uint256 expectedFee0 = deposit0.mulDiv(feeScaledPercent, MAX_SCALED_PERCENTAGE);
        uint256 expectedFee1 = deposit1.mulDiv(feeScaledPercent, MAX_SCALED_PERCENTAGE);

        uint256 finalFeeCollectorBalance0 = perfFeeSetup.token0.balanceOf(perfFeeSetup.feeCollector);
        uint256 finalFeeCollectorBalance1 = perfFeeSetup.token1.balanceOf(perfFeeSetup.feeCollector);

        assertApproxEqAbs(finalFeeCollectorBalance0, initialFeeCollectorBalance0 + expectedFee0, 2);
        assertApproxEqAbs(finalFeeCollectorBalance1, initialFeeCollectorBalance1 + expectedFee1, 2);

        // make sure vault.lastVaultTvl0() have been updated
        // works since no perf since last deposit & no tvl fee
        (uint256 finalTvl0, uint256 finalTvl1) = perfFeeSetup.vault.rawAssetsValue();

        // Use a reasonable base amount instead of 1 if there is an overflow
        uint128 baseAmount = uint128(1);
        if (finalTvl1 <= type(uint128).max) {
            // forge-lint: disable-next-line(unsafe-typecast)
            baseAmount = uint128(finalTvl1);
        }

        uint256 twapResult = UniswapUtils.getTwap(perfFeeSetup.pool, TWAP_SECONDS_AGO, baseAmount, true);

        // Scale the result if we used a smaller base amount
        uint256 twapValueFrom1To0;
        if (tvl1 > type(uint128).max) {
            twapValueFrom1To0 = twapResult * tvl1;
        } else {
            twapValueFrom1To0 = twapResult;
        }

        assertEq(perfFeeSetup.vault.lastVaultTvl0(), finalTvl0 + twapValueFrom1To0);
    }

    function test_perfAndTVLFees_manualCollect() public {
        // todo: add delay to also have tvl fees collected
        uint256 deposit0 = TestConstants.LARGE_AMOUNT;
        uint256 deposit1 = TestConstants.LARGE_AMOUNT;

        helper.depositToVault(bothFeeSetup, deposit0, deposit1);
        helper.createPositionAroundCurrentTick(
            bothFeeSetup.vault,
            bothFeeSetup.allocator,
            TestConstants.TICK_RANGE_NARROW,
            TestConstants.MEDIUM_AMOUNT,
            TestConstants.MEDIUM_AMOUNT
        );

        // Mint tokens to the vault to simulate +100% performance
        (uint256 tvl0, uint256 tvl1) = bothFeeSetup.vault.rawAssetsValue();
        bothFeeSetup.token0.mint(address(bothFeeSetup.vault), tvl0 / 2);
        bothFeeSetup.token1.mint(address(bothFeeSetup.vault), tvl1 / 2);

        // actual_performance = +50% so perf fee will be vault.performanceFeeScaled() / 2
        uint256 feeScaledPercent = bothFeeSetup.vault.performanceFeeScaled() / 2;

        uint256 initialFeeCollectorBalance0 = bothFeeSetup.token0.balanceOf(bothFeeSetup.feeCollector);
        uint256 initialFeeCollectorBalance1 = bothFeeSetup.token0.balanceOf(bothFeeSetup.feeCollector);

        // Withdraw should trigger fee collection
        vm.prank(bothFeeSetup.feeCollector);
        bothFeeSetup.vault.collectPendingFees();

        uint256 expectedFee0 = deposit0.mulDiv(feeScaledPercent, MAX_SCALED_PERCENTAGE);
        uint256 expectedFee1 = deposit1.mulDiv(feeScaledPercent, MAX_SCALED_PERCENTAGE);

        uint256 finalFeeCollectorBalance0 = bothFeeSetup.token0.balanceOf(bothFeeSetup.feeCollector);
        uint256 finalFeeCollectorBalance1 = bothFeeSetup.token1.balanceOf(bothFeeSetup.feeCollector);

        assertApproxEqAbs(finalFeeCollectorBalance0, initialFeeCollectorBalance0 + expectedFee0, 2);
        assertApproxEqAbs(finalFeeCollectorBalance1, initialFeeCollectorBalance1 + expectedFee1, 2);

        // make sure vault.lastVaultTvl0() have been updated
        // works since no perf since last deposit & no tvl fee
        (uint256 finalTvl0, uint256 finalTvl1) = bothFeeSetup.vault.rawAssetsValue();

        // Use a reasonable base amount instead of 1 if there is an overflow
        uint128 baseAmount = uint128(1);
        if (finalTvl1 <= type(uint128).max) {
            // forge-lint: disable-next-line(unsafe-typecast)
            baseAmount = uint128(finalTvl1);
        }

        uint256 twapResult = UniswapUtils.getTwap(bothFeeSetup.pool, TWAP_SECONDS_AGO, baseAmount, true);

        // Scale the result if we used a smaller base amount
        uint256 twapValueFrom1To0;
        if (tvl1 > type(uint128).max) {
            twapValueFrom1To0 = twapResult * tvl1;
        } else {
            twapValueFrom1To0 = twapResult;
        }

        assertEq(bothFeeSetup.vault.lastVaultTvl0(), finalTvl0 + twapValueFrom1To0);
    }
}
