// // SPDX-License-Identifier: GPL-3.0-or-later
// pragma solidity ^0.8.28;

// import "forge-std/Test.sol";
// import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
// import {UniV3LpVault, Position, MAX_SCALED_PERCENTAGE} from "../../../src/vaults/UniV3LpVault.sol";
// import {TestHelper} from "../helpers/TestHelper.sol";
// import {TestConstants} from "../helpers/Constants.sol";

// contract UniV3LpVaultFullCycleTest is Test {
//     using Math for uint256;

//     TestHelper helper;
//     TestHelper.VaultSetup setup;

//     function setUp() public {
//         helper = new TestHelper();
//         setup = helper.deployVaultWithPool(TestConstants.MEDIUM_TVL_FEE);
//     }

//     function test_fullCycle_DepositMintCollectBurnWithdraw() public {
//         address user = setup.owner;
//         address recipient = makeAddr("recipient");

//         // === PHASE 1: Initial Setup and Deposit ===
//         uint256 initialDeposit0 = TestConstants.LARGE_AMOUNT;
//         uint256 initialDeposit1 = TestConstants.LARGE_AMOUNT;

//         uint256 userInitialBalance0 = setup.token0.balanceOf(user);
//         uint256 userInitialBalance1 = setup.token1.balanceOf(user);

//         helper.depositToVault(setup, initialDeposit0, initialDeposit1);

//         (uint256 total0, uint256 total1) = setup.vault.netAssetsValue();

//         // Verify deposit
//         assertEq(setup.token0.balanceOf(address(setup.vault)), initialDeposit0);
//         assertEq(setup.token1.balanceOf(address(setup.vault)), initialDeposit1);
//         (uint256 netAfterDeposit0, uint256 netAfterDeposit1) = setup
//             .vault
//             .netAssetsValue();
//         assertEq(netAfterDeposit0, initialDeposit0);
//         assertEq(netAfterDeposit1, initialDeposit1);

//         // === PHASE 2: Create Multiple Positions ===
//         (, int24 currentTick, , , , , ) = setup.pool.slot0();

//         // Position 1: Narrow range around current price
//         int24 narrow_lower = currentTick - TestConstants.TICK_RANGE_NARROW;
//         int24 narrow_upper = currentTick + TestConstants.TICK_RANGE_NARROW;
//         uint256 narrow_amount0 = TestConstants.MEDIUM_AMOUNT;
//         uint256 narrow_amount1 = TestConstants.MEDIUM_AMOUNT;

//         (uint256 actual_narrow_0, uint256 actual_narrow_1) = helper
//             .createPosition(
//                 setup.vault,
//                 setup.executor,
//                 narrow_lower,
//                 narrow_upper,
//                 narrow_amount0,
//                 narrow_amount1
//             );

//         // Position 2: Wide range for base liquidity
//         int24 wide_lower = currentTick - TestConstants.TICK_RANGE_WIDE;
//         int24 wide_upper = currentTick + TestConstants.TICK_RANGE_WIDE;
//         uint256 wide_amount0 = TestConstants.MEDIUM_AMOUNT;
//         uint256 wide_amount1 = TestConstants.MEDIUM_AMOUNT;

//         (uint256 actual_wide_0, uint256 actual_wide_1) = helper.createPosition(
//             setup.vault,
//             setup.executor,
//             wide_lower,
//             wide_upper,
//             wide_amount0,
//             wide_amount1
//         );

//         // Verify positions created
//         Position memory pos1 = setup.vault.getPosition(0);
//         Position memory pos2 = setup.vault.getPosition(1);
//         assertTrue(pos1.liquidity > 0);
//         assertTrue(pos2.liquidity > 0);

//         // Verify LP value reflects positions
//         (uint256 totalLp0, uint256 totalLp1) = setup.vault.totalLpValue();
//         helper.assertApproxEqual(
//             totalLp0,
//             actual_narrow_0 + actual_wide_0,
//             TestConstants.TOLERANCE_LOW,
//             "Total LP value0 mismatch"
//         );

//         // === PHASE 3: Time Passes - Accumulate Fees ===
//         uint256 delay = TestConstants.ONE_MONTH;
//         helper.simulateTimePass(delay);

//         // Check that TVL fees are pending
//         (uint256 netWithPendingFees0, uint256 netWithPendingFees1) = setup
//             .vault
//             .netAssetsValue();
//         assertTrue(netWithPendingFees0 < netAfterDeposit0); // Should be reduced by pending fees
//         assertTrue(netWithPendingFees1 < netAfterDeposit1);

//         // === PHASE 4: Collect Fees from Positions ===
//         uint256 vaultBalanceBeforeCollect0 = setup.token0.balanceOf(
//             address(setup.vault)
//         );
//         uint256 vaultBalanceBeforeCollect1 = setup.token1.balanceOf(
//             address(setup.vault)
//         );

//         vm.startPrank(setup.executor);
//         // Collect from both positions
//         setup.vault.collect(
//             narrow_lower,
//             narrow_upper,
//             type(uint128).max,
//             type(uint128).max
//         );
//         setup.vault.collect(
//             wide_lower,
//             wide_upper,
//             type(uint128).max,
//             type(uint128).max
//         );
//         vm.stopPrank();

//         // Vault balance should be >= before (collected fees)
//         assertTrue(
//             setup.token0.balanceOf(address(setup.vault)) >=
//                 vaultBalanceBeforeCollect0
//         );
//         assertTrue(
//             setup.token1.balanceOf(address(setup.vault)) >=
//                 vaultBalanceBeforeCollect1
//         );

//         // === PHASE 5: Partial Position Management ===
//         // Burn half of the narrow position
//         uint128 burnAmount = pos1.liquidity / 2;

//         vm.prank(setup.executor);
//         (uint256 burned0, uint256 burned1) = setup.vault.burn(
//             narrow_lower,
//             narrow_upper,
//             burnAmount
//         );

//         assertTrue(burned0 > 0 || burned1 > 0);

//         // Position should still exist but with reduced liquidity
//         Position memory pos1_after_burn = setup.vault.getPosition(0);
//         assertTrue(pos1_after_burn.liquidity < pos1.liquidity);
//         helper.assertApproxEqual(
//             uint256(pos1_after_burn.liquidity),
//             uint256(pos1.liquidity - burnAmount),
//             1,
//             "Position liquidity after burn"
//         );

//         // === PHASE 6: Add More Liquidity to Existing Position ===
//         uint256 additionalAmount0 = TestConstants.SMALL_AMOUNT;
//         uint256 additionalAmount1 = TestConstants.SMALL_AMOUNT;

//         (uint256 additional0, uint256 additional1) = helper.createPosition(
//             setup.vault,
//             setup.executor,
//             wide_lower,
//             wide_upper,
//             additionalAmount0,
//             additionalAmount1
//         );

//         // Should still have 2 positions, but wide position should have more liquidity
//         Position memory pos2_after_addition = setup.vault.getPosition(1);
//         assertTrue(pos2_after_addition.liquidity > pos2.liquidity);

//         // === PHASE 7: Partial Withdrawal ===
//         uint256 feeCollectorBalanceBefore0 = setup.token0.balanceOf(
//             setup.feeCollector
//         );
//         uint256 feeCollectorBalanceBefore1 = setup.token1.balanceOf(
//             setup.feeCollector
//         );
//         uint256 recipientBalanceBefore0 = setup.token0.balanceOf(recipient);
//         uint256 recipientBalanceBefore1 = setup.token1.balanceOf(recipient);

//         uint256 withdrawPercentage = TestConstants.HALF_SCALED_PERCENTAGE; // 50%

//         (uint256 withdrawn0, uint256 withdrawn1) = helper.withdrawFromVault(
//             setup,
//             withdrawPercentage,
//             recipient
//         );

//         uint256 tvlFeePercent = setup.vault.tvlFeeScaled().mulDiv(
//             delay,
//             365 days
//         );

//         uint256 expectedFee0 = total0.mulDiv(
//             tvlFeePercent,
//             MAX_SCALED_PERCENTAGE
//         );
//         uint256 expectedFee1 = total1.mulDiv(
//             tvlFeePercent,
//             MAX_SCALED_PERCENTAGE
//         );
//         // Verify recipient received tokens
//         assertEq(
//             setup.token0.balanceOf(recipient),
//             recipientBalanceBefore0 + withdrawn0
//         );
//         console.log("avant");

//         assertEq(
//             setup.token1.balanceOf(recipient),
//             recipientBalanceBefore1 + withdrawn1
//         );
//         console.log("avant1");

//         assertTrue(withdrawn0 > 0);
//         assertTrue(withdrawn1 > 0);
//         console.log("avant2");

//         // Verify fee collector received TVL fees
//         assertApproxEqAbs(
//             setup.token0.balanceOf(setup.feeCollector),
//             feeCollectorBalanceBefore0 + expectedFee0,
//             1
//         );
//         console.log("avant3");

//         assertApproxEqAbs(
//             setup.token1.balanceOf(setup.feeCollector),
//             feeCollectorBalanceBefore1 + expectedFee1,
//             1
//         );
//         console.log("avant4");

//         // === PHASE 8: More Time Passes ===
//         helper.simulateTimePass(TestConstants.ONE_WEEK);

//         // === PHASE 9: Final Full Withdrawal ===
//         uint256 recipientBalanceBeforeFinal0 = setup.token0.balanceOf(
//             recipient
//         );
//         uint256 recipientBalanceBeforeFinal1 = setup.token1.balanceOf(
//             recipient
//         );
//         uint256 feeCollectorBalanceBeforeFinal0 = setup.token0.balanceOf(
//             setup.feeCollector
//         );
//         uint256 feeCollectorBalanceBeforeFinal1 = setup.token1.balanceOf(
//             setup.feeCollector
//         );

//         (uint256 finalWithdrawn0, uint256 finalWithdrawn1) = helper
//             .withdrawFromVault(
//                 setup,
//                 TestConstants.MAX_SCALED_PERCENTAGE, // 100%
//                 recipient
//             );

//         (uint256 total00, uint256 total01) = setup.vault.netAssetsValue();
//         console.log("total00", total00);
//         console.log("total01", total01);

//         // Verify final withdrawal
//         assertTrue(finalWithdrawn0 > 0 || finalWithdrawn1 > 0);
//         assertTrue(
//             setup.token0.balanceOf(recipient) > recipientBalanceBeforeFinal0
//         );
//         assertTrue(
//             setup.token1.balanceOf(recipient) > recipientBalanceBeforeFinal1
//         );

//         // Verify additional TVL fees collected
//         assertTrue(
//             setup.token0.balanceOf(setup.feeCollector) >=
//                 feeCollectorBalanceBeforeFinal0
//         );
//         assertTrue(
//             setup.token1.balanceOf(setup.feeCollector) >=
//                 feeCollectorBalanceBeforeFinal1
//         );

//         // === PHASE 10: Final State Verification ===
//         (uint256 finalNet0, uint256 finalNet1) = setup.vault.netAssetsValue();
//         (uint256 finalLp0, uint256 finalLp1) = setup.vault.totalLpValue();

//         console.log("finalNet0", finalNet0);
//         console.log("finalNet1", finalNet1);
//         console.log("finalLp0", finalLp0);
//         console.log("finalLp1", finalLp1);
//         console.log("dddd", setup.vault.positionsLength());

//         // Vault should be nearly empty
//         assertEq(finalNet0, 0);
//         assertEq(finalNet1, 0);
//         assertEq(finalLp0, 0);
//         assertEq(finalLp1, 0);

//         console.log("ssk");

//         // No positions should remain
//         vm.expectRevert();
//         setup.vault.getPosition(0);

//         // === PHASE 11: Token Conservation Check ===
//         uint256 userFinalBalance0 = setup.token0.balanceOf(user);
//         uint256 userFinalBalance1 = setup.token1.balanceOf(user);
//         uint256 totalRecipientReceived0 = setup.token0.balanceOf(recipient);
//         uint256 totalRecipientReceived1 = setup.token1.balanceOf(recipient);
//         uint256 totalFeesCollected0 = setup.token0.balanceOf(
//             setup.feeCollector
//         );
//         uint256 totalFeesCollected1 = setup.token1.balanceOf(
//             setup.feeCollector
//         );
//         uint256 vaultRemainder0 = setup.token0.balanceOf(address(setup.vault));
//         uint256 vaultRemainder1 = setup.token1.balanceOf(address(setup.vault));

//         // Total tokens should be conserved (allowing for small rounding errors)
//         uint256 totalAccountedFor0 = userFinalBalance0 +
//             totalRecipientReceived0 +
//             totalFeesCollected0 +
//             vaultRemainder0;
//         uint256 totalAccountedFor1 = userFinalBalance1 +
//             totalRecipientReceived1 +
//             totalFeesCollected1 +
//             vaultRemainder1;

//         helper.assertApproxEqual(
//             totalAccountedFor0,
//             userInitialBalance0,
//             TestConstants.TOLERANCE_MEDIUM,
//             "Token0 conservation check failed"
//         );
//         helper.assertApproxEqual(
//             totalAccountedFor1,
//             userInitialBalance1,
//             TestConstants.TOLERANCE_MEDIUM,
//             "Token1 conservation check failed"
//         );

//         // === PHASE 12: Verify Reasonable Fee Collection ===
//         // TVL fees should be reasonable (less than 10% of initial deposit for ~5 weeks)
//         assertTrue(
//             totalFeesCollected0 < initialDeposit0 / 10,
//             "TVL fees seem too high for token0"
//         );
//         assertTrue(
//             totalFeesCollected1 < initialDeposit1 / 10,
//             "TVL fees seem too high for token1"
//         );
//         assertTrue(
//             totalFeesCollected0 > 0,
//             "Should have collected some TVL fees for token0"
//         );
//         assertTrue(
//             totalFeesCollected1 > 0,
//             "Should have collected some TVL fees for token1"
//         );
//     }

//     // function test_fullCycle_NoPositionsOnlyCash() public {
//     //     // Test full cycle with deposits and withdrawals but no LP positions
//     //     uint256 depositAmount0 = TestConstants.MEDIUM_AMOUNT;
//     //     uint256 depositAmount1 = TestConstants.MEDIUM_AMOUNT;

//     //     address recipient = makeAddr("recipient");

//     //     // Deposit
//     //     helper.depositToVault(setup, depositAmount0, depositAmount1);

//     //     // Wait for TVL fees to accumulate
//     //     helper.simulateTimePass(TestConstants.ONE_MONTH);

//     //     uint256 feeCollectorBefore0 = setup.token0.balanceOf(
//     //         setup.feeCollector
//     //     );
//     //     uint256 feeCollectorBefore1 = setup.token1.balanceOf(
//     //         setup.feeCollector
//     //     );

//     //     // Withdraw 25%
//     //     helper.withdrawFromVault(
//     //         setup,
//     //         TestConstants.QUARTER_SCALED_PERCENTAGE,
//     //         recipient
//     //     );

//     //     // TVL fees should be collected
//     //     assertTrue(
//     //         setup.token0.balanceOf(setup.feeCollector) > feeCollectorBefore0
//     //     );
//     //     assertTrue(
//     //         setup.token1.balanceOf(setup.feeCollector) > feeCollectorBefore1
//     //     );

//     //     // Wait more time
//     //     helper.simulateTimePass(TestConstants.ONE_WEEK);

//     //     // Final withdrawal
//     //     helper.withdrawFromVault(
//     //         setup,
//     //         TestConstants.MAX_SCALED_PERCENTAGE,
//     //         recipient
//     //     );

//     //     // Vault should be empty
//     //     (uint256 finalNet0, uint256 finalNet1) = setup.vault.netAssetsValue();
//     //     helper.assertApproxEqual(
//     //         finalNet0,
//     //         0,
//     //         TestConstants.TOLERANCE_HIGH,
//     //         "Should be empty"
//     //     );
//     //     helper.assertApproxEqual(
//     //         finalNet1,
//     //         0,
//     //         TestConstants.TOLERANCE_HIGH,
//     //         "Should be empty"
//     //     );
//     // }

//     // function test_fullCycle_WithRebalancing() public {
//     //     // Test a more complex scenario with position rebalancing
//     //     uint256 depositAmount0 = TestConstants.LARGE_AMOUNT;
//     //     uint256 depositAmount1 = TestConstants.LARGE_AMOUNT;

//     //     helper.depositToVault(setup, depositAmount0, depositAmount1);

//     //     (, int24 currentTick, , , , , ) = setup.pool.slot0();
//     //     address recipient = makeAddr("recipient");

//     //     // === Initial Position ===
//     //     int24 initialLower = currentTick - TestConstants.TICK_RANGE_MEDIUM;
//     //     int24 initialUpper = currentTick + TestConstants.TICK_RANGE_MEDIUM;

//     //     helper.createPosition(
//     //         setup.vault,
//     //         setup.executor,
//     //         initialLower,
//     //         initialUpper,
//     //         TestConstants.MEDIUM_AMOUNT,
//     //         TestConstants.MEDIUM_AMOUNT
//     //     );

//     //     Position memory initialPos = setup.vault.getPosition(0);

//     //     // === Simulate Price Movement (Mock) ===
//     //     // In real scenario, price would move due to swaps
//     //     helper.movePoolPriceUp(setup.pool, 10); // Mock 10% price increase

//     //     // === Rebalance: Close old position, open new ===
//     //     vm.prank(setup.executor);
//     //     setup.vault.burn(initialLower, initialUpper, initialPos.liquidity);

//     //     // No positions should exist now
//     //     vm.expectRevert();
//     //     setup.vault.getPosition(0);

//     //     // Create new position at different range
//     //     int24 newLower = currentTick - TestConstants.TICK_RANGE_NARROW;
//     //     int24 newUpper = currentTick + TestConstants.TICK_RANGE_WIDE; // Asymmetric

//     //     helper.createPosition(
//     //         setup.vault,
//     //         setup.executor,
//     //         newLower,
//     //         newUpper,
//     //         TestConstants.MEDIUM_AMOUNT,
//     //         TestConstants.MEDIUM_AMOUNT
//     //     );

//     //     // Should have one position again
//     //     Position memory newPos = setup.vault.getPosition(0);
//     //     assertTrue(newPos.liquidity > 0);
//     //     assertTrue(
//     //         newPos.lowerTick != initialPos.lowerTick ||
//     //             newPos.upperTick != initialPos.upperTick
//     //     );

//     //     // === Time passes ===
//     //     helper.simulateTimePass(TestConstants.ONE_MONTH);

//     //     // === Final withdrawal ===
//     //     uint256 feeCollectorBefore0 = setup.token0.balanceOf(
//     //         setup.feeCollector
//     //     );

//     //     helper.withdrawFromVault(
//     //         setup,
//     //         TestConstants.MAX_SCALED_PERCENTAGE,
//     //         recipient
//     //     );

//     //     // Should have collected TVL fees
//     //     assertTrue(
//     //         setup.token0.balanceOf(setup.feeCollector) > feeCollectorBefore0
//     //     );

//     //     // Vault should be empty
//     //     (uint256 finalNet0, uint256 finalNet1) = setup.vault.netAssetsValue();
//     //     helper.assertApproxEqual(
//     //         finalNet0,
//     //         0,
//     //         TestConstants.TOLERANCE_HIGH,
//     //         "Should be empty after rebalancing"
//     //     );
//     //     helper.assertApproxEqual(
//     //         finalNet1,
//     //         0,
//     //         TestConstants.TOLERANCE_HIGH,
//     //         "Should be empty after rebalancing"
//     //     );
//     // }

//     // function test_fullCycle_MultipleUsersDepositsAndWithdrawals() public {
//     //     // Simulate multiple deposit/withdrawal cycles
//     //     address recipient1 = makeAddr("recipient1");
//     //     address recipient2 = makeAddr("recipient2");

//     //     // === Cycle 1 ===
//     //     helper.depositToVault(
//     //         setup,
//     //         TestConstants.MEDIUM_AMOUNT,
//     //         TestConstants.MEDIUM_AMOUNT
//     //     );
//     //     helper.createPositionAroundCurrentTick(
//     //         setup.vault,
//     //         setup.executor,
//     //         TestConstants.TICK_RANGE_NARROW,
//     //         TestConstants.SMALL_AMOUNT,
//     //         TestConstants.SMALL_AMOUNT
//     //     );

//     //     helper.simulateTimePass(TestConstants.ONE_WEEK);
//     //     helper.withdrawFromVault(
//     //         setup,
//     //         TestConstants.HALF_SCALED_PERCENTAGE,
//     //         recipient1
//     //     );

//     //     // === Cycle 2 ===
//     //     helper.depositToVault(
//     //         setup,
//     //         TestConstants.LARGE_AMOUNT,
//     //         TestConstants.LARGE_AMOUNT
//     //     );
//     //     helper.createPositionAroundCurrentTick(
//     //         setup.vault,
//     //         setup.executor,
//     //         TestConstants.TICK_RANGE_WIDE,
//     //         TestConstants.MEDIUM_AMOUNT,
//     //         TestConstants.MEDIUM_AMOUNT
//     //     );

//     //     helper.simulateTimePass(TestConstants.ONE_WEEK);
//     //     helper.withdrawFromVault(
//     //         setup,
//     //         TestConstants.QUARTER_SCALED_PERCENTAGE,
//     //         recipient2
//     //     );

//     //     // === Final cycle ===
//     //     helper.simulateTimePass(TestConstants.ONE_WEEK);
//     //     helper.withdrawFromVault(
//     //         setup,
//     //         TestConstants.MAX_SCALED_PERCENTAGE,
//     //         recipient1
//     //     );

//     //     // Vault should be empty
//     //     (uint256 finalNet0, uint256 finalNet1) = setup.vault.netAssetsValue();
//     //     helper.assertApproxEqual(
//     //         finalNet0,
//     //         0,
//     //         TestConstants.TOLERANCE_HIGH,
//     //         "Multi-cycle final check"
//     //     );
//     //     helper.assertApproxEqual(
//     //         finalNet1,
//     //         0,
//     //         TestConstants.TOLERANCE_HIGH,
//     //         "Multi-cycle final check"
//     //     );

//     //     // Both recipients should have received tokens
//     //     assertTrue(setup.token0.balanceOf(recipient1) > 0);
//     //     assertTrue(setup.token0.balanceOf(recipient2) > 0);
//     //     assertTrue(setup.token1.balanceOf(recipient1) > 0);
//     //     assertTrue(setup.token1.balanceOf(recipient2) > 0);

//     //     // Fee collector should have received fees
//     //     assertTrue(setup.token0.balanceOf(setup.feeCollector) > 0);
//     //     assertTrue(setup.token1.balanceOf(setup.feeCollector) > 0);
//     // }
// }
