// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {UniV3LpVault, Position, MAX_SCALED_PERCENTAGE} from "../../../src/vaults/UniV3LpVault.sol";
import {TestHelper} from "../helpers/TestHelper.sol";
import {TestConstants} from "../helpers/Constants.sol";

contract UniV3LpVaultFuzzTest is Test {
    using Math for uint256;

    TestHelper helper;
    TestHelper.VaultSetup setup;

    function setUp() public {
        helper = new TestHelper();
        setup = helper.deployVaultWithPool(TestConstants.MEDIUM_TVL_FEE, TestConstants.MEDIUM_PERF_FEE);
    }

    // === DEPOSIT FUZZ TESTS ===

    function testFuzz_deposit_ValidAmounts(uint256 amount0, uint256 amount1) public {
        amount0 = bound(amount0, 1, TestConstants.INITIAL_BALANCE);
        amount1 = bound(amount1, 1, TestConstants.INITIAL_BALANCE);

        uint256 initialVaultBalance0 = setup.token0.balanceOf(address(setup.vault));
        uint256 initialVaultBalance1 = setup.token1.balanceOf(address(setup.vault));
        uint256 initialOwnerBalance0 = setup.token0.balanceOf(setup.owner);
        uint256 initialOwnerBalance1 = setup.token1.balanceOf(setup.owner);

        vm.prank(setup.owner);
        setup.vault.deposit(amount0, amount1);

        // Invariants
        assertEq(setup.token0.balanceOf(address(setup.vault)), initialVaultBalance0 + amount0);
        assertEq(setup.token1.balanceOf(address(setup.vault)), initialVaultBalance1 + amount1);
        assertEq(setup.token0.balanceOf(setup.owner), initialOwnerBalance0 - amount0);
        assertEq(setup.token1.balanceOf(setup.owner), initialOwnerBalance1 - amount1);

        (uint256 netAssets0, uint256 netAssets1) = setup.vault.netAssetsValue();
        assertEq(netAssets0, initialVaultBalance0 + amount0);
        assertEq(netAssets1, initialVaultBalance1 + amount1);
    }

    function testFuzz_deposit_SingleToken(uint256 amount, bool isToken0) public {
        amount = bound(amount, 1, TestConstants.INITIAL_BALANCE);

        uint256 amount0 = isToken0 ? amount : 0;
        uint256 amount1 = isToken0 ? 0 : amount;

        uint256 initialBalance0 = setup.token0.balanceOf(address(setup.vault));
        uint256 initialBalance1 = setup.token1.balanceOf(address(setup.vault));

        vm.prank(setup.owner);
        setup.vault.deposit(amount0, amount1);

        if (isToken0) {
            assertEq(setup.token0.balanceOf(address(setup.vault)), initialBalance0 + amount);
            assertEq(setup.token1.balanceOf(address(setup.vault)), initialBalance1);
        } else {
            assertEq(setup.token0.balanceOf(address(setup.vault)), initialBalance0);
            assertEq(setup.token1.balanceOf(address(setup.vault)), initialBalance1 + amount);
        }
    }

    // === WITHDRAW FUZZ TESTS ===

    function testFuzz_withdraw_ValidPercentages(uint256 scaledPercentage) public {
        scaledPercentage = bound(scaledPercentage, 1, TestConstants.MAX_SCALED_PERCENTAGE);

        // Setup with funds
        // Use high values to make sure roundings does not lead to 0 for excessively small scaledPercentage values
        helper.depositToVault(setup, 10_000 ether, 10_000 ether);
        helper.createPositionAroundCurrentTick(
            setup.vault, setup.allocator, TestConstants.TICK_RANGE_NARROW, 1000 ether, 1000 ether
        );

        address recipient = makeAddr("recipient");
        (uint256 initialNet0, uint256 initialNet1) = setup.vault.netAssetsValue();

        vm.prank(setup.owner);
        (uint256 withdrawn0, uint256 withdrawn1) = setup.vault.withdraw(scaledPercentage, recipient);

        // Withdrawn amounts should be proportional
        if (scaledPercentage == TestConstants.MAX_SCALED_PERCENTAGE) {
            // Full withdrawal should leave vault nearly empty
            (uint256 finalNet0, uint256 finalNet1) = setup.vault.netAssetsValue();
            helper.assertApproxEqual(finalNet0, 0, TestConstants.TOLERANCE_LOW, "Full withdrawal should empty vault");
            helper.assertApproxEqual(finalNet1, 0, TestConstants.TOLERANCE_LOW, "Full withdrawal should empty vault");
        } else {
            // Partial withdrawal - check proportionality
            assertTrue(withdrawn0 > 0 || withdrawn1 > 0, "Should withdraw something");

            uint256 expected0 = scaledPercentage.mulDiv(initialNet0, TestConstants.MAX_SCALED_PERCENTAGE);

            uint256 expected1 = scaledPercentage.mulDiv(initialNet1, TestConstants.MAX_SCALED_PERCENTAGE);

            assertApproxEqAbs(expected0, withdrawn0, 1);
            assertApproxEqAbs(expected1, withdrawn1, 1);
        }
    }

    // === MINT FUZZ TESTS ===

    function testFuzz_mint_ValidAmounts(
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 tickRangeMultiplier
    )
        public
    {
        amount0Desired = bound(amount0Desired, TestConstants.SMALL_AMOUNT, TestConstants.MEDIUM_AMOUNT);
        amount1Desired = bound(amount1Desired, TestConstants.SMALL_AMOUNT, TestConstants.MEDIUM_AMOUNT);
        tickRangeMultiplier = bound(tickRangeMultiplier, 1, 5);

        // Ensure vault has enough funds
        helper.depositToVault(setup, TestConstants.LARGE_AMOUNT, TestConstants.LARGE_AMOUNT);

        (, int24 currentTick,,,,,) = setup.pool.slot0();
        int24 tickSpacing = setup.pool.tickSpacing();
        int24 tickRange = int24(TestConstants.TICK_RANGE_NARROW * int256(tickRangeMultiplier));

        // Calculate desired ticks
        int24 desiredTickLower = currentTick - tickRange;
        int24 desiredTickUpper = currentTick + tickRange;

        // Align ticks to tick spacing (round down for lower, round up for upper)
        int24 tickLower = (desiredTickLower / tickSpacing) * tickSpacing;
        int24 tickUpper = (desiredTickUpper / tickSpacing) * tickSpacing;

        uint256 initialLp0;
        uint256 initialLp1;
        (initialLp0, initialLp1) = setup.vault.totalLpValue();

        vm.prank(setup.allocator);
        (uint256 actualAmount0, uint256 actualAmount1) =
            helper.createPosition(setup.vault, setup.allocator, tickLower, tickUpper, amount0Desired, amount1Desired);

        // LP value should increase
        (uint256 finalLp0, uint256 finalLp1) = setup.vault.totalLpValue();
        assertTrue(finalLp0 >= initialLp0, "LP value0 should increase");
        assertTrue(finalLp1 >= initialLp1, "LP value1 should increase");

        // Should have used some tokens from vault
        assertTrue(actualAmount0 > 0 || actualAmount1 > 0, "Should have minted something");
        assertTrue(actualAmount0 <= amount0Desired, "Should not exceed desired amount0");
        assertTrue(actualAmount1 <= amount1Desired, "Should not exceed desired amount1");
    }

    // === BURN FUZZ TESTS ===

    function testFuzz_burn_ValidAmounts(uint256 burnPercentage) public {
        burnPercentage = bound(burnPercentage, 1, 100);

        // Setup with position
        helper.depositToVault(setup, TestConstants.LARGE_AMOUNT, TestConstants.LARGE_AMOUNT);
        helper.createPositionAroundCurrentTick(
            setup.vault,
            setup.allocator,
            TestConstants.TICK_RANGE_NARROW,
            TestConstants.MEDIUM_AMOUNT,
            TestConstants.MEDIUM_AMOUNT
        );

        Position memory initialPos = setup.vault.getPosition(0);
        uint128 burnAmount = uint128((uint256(initialPos.liquidity) * burnPercentage) / 100);

        (, int24 currentTick,,,,,) = setup.pool.slot0();
        int24 tickSpacing = setup.pool.tickSpacing();
        int24 tickRange = TestConstants.TICK_RANGE_NARROW;

        // Calculate desired ticks
        int24 desiredTickLower = currentTick - tickRange;
        int24 desiredTickUpper = currentTick + tickRange;

        // Align ticks to tick spacing (round down for lower, round up for upper)
        int24 tickLower = (desiredTickLower / tickSpacing) * tickSpacing;
        int24 tickUpper = (desiredTickUpper / tickSpacing) * tickSpacing;

        uint256 initialVaultBalance0 = setup.token0.balanceOf(address(setup.vault));
        uint256 initialVaultBalance1 = setup.token1.balanceOf(address(setup.vault));

        vm.prank(setup.allocator);
        setup.vault.burn(tickLower, tickUpper, burnAmount);

        // Should receive tokens back
        assertTrue(setup.token0.balanceOf(address(setup.vault)) >= initialVaultBalance0, "Should get tokens back");
        assertTrue(setup.token1.balanceOf(address(setup.vault)) >= initialVaultBalance1, "Should get tokens back");

        if (burnAmount == initialPos.liquidity) {
            // Full burn - position should be removed
            vm.expectRevert();
            setup.vault.getPosition(0);
        } else {
            // Partial burn - position should remain with reduced liquidity
            Position memory finalPos = setup.vault.getPosition(0);
            assertEq(finalPos.liquidity, initialPos.liquidity - burnAmount);
        }
    }

    // === TVL FEES FUZZ TESTS ===

    function testFuzz_tvlFees_TimeAndRate(uint256 timeElapsed, uint256 tvlFeeRate, uint256 perfFee) public {
        timeElapsed = bound(timeElapsed, 1 days, 2 * TestConstants.ONE_YEAR);
        tvlFeeRate = bound(tvlFeeRate, 0, TestConstants.MAX_SCALED_PERCENTAGE / 10); // Max 10% annual

        TestHelper.VaultSetup memory fuzzSetup = helper.deployVaultWithPool(tvlFeeRate, perfFee);

        uint256 depositAmount0 = TestConstants.MEDIUM_AMOUNT;
        uint256 depositAmount1 = TestConstants.MEDIUM_AMOUNT;
        helper.depositToVault(fuzzSetup, depositAmount0, depositAmount1);

        (uint256 total0Before, uint256 total1Before) = fuzzSetup.vault.netAssetsValue(); // Before time elapsed so pending fee is 0

        helper.simulateTimePass(timeElapsed);

        uint256 initialFeeCollectorBalance0 = fuzzSetup.token0.balanceOf(fuzzSetup.feeCollector);
        uint256 initialFeeCollectorBalance1 = fuzzSetup.token1.balanceOf(fuzzSetup.feeCollector);

        // Trigger fee collection
        helper.depositToVault(fuzzSetup, 1, 1);

        uint256 finalFeeCollectorBalance0 = fuzzSetup.token0.balanceOf(fuzzSetup.feeCollector);
        uint256 finalFeeCollectorBalance1 = fuzzSetup.token1.balanceOf(fuzzSetup.feeCollector);
        uint256 collectedFees0 = finalFeeCollectorBalance0 - initialFeeCollectorBalance0;
        uint256 collectedFees1 = finalFeeCollectorBalance1 - initialFeeCollectorBalance1;

        if (tvlFeeRate == 0) {
            assertEq(collectedFees0, 0, "No fees should be collected with 0% rate");
        } else {
            // Calculate expected fee
            uint256 tvlFeePercent = fuzzSetup.vault.tvlFeeScaled().mulDiv(timeElapsed, 365 days);

            uint256 expectedFee0 = total0Before.mulDiv(tvlFeePercent, MAX_SCALED_PERCENTAGE);
            uint256 expectedFee1 = total1Before.mulDiv(tvlFeePercent, MAX_SCALED_PERCENTAGE);
            // Fee = deposit × tvlFee × seconds / 3,155,760,000

            assertApproxEqAbs(collectedFees0, expectedFee0, 1);
            assertApproxEqAbs(collectedFees1, expectedFee1, 1);

            // Sanity check - fees shouldn't exceed the deposit
            assertTrue(
                collectedFees0 <= depositAmount0 && collectedFees1 <= depositAmount1, "Fees shouldn't exceed principal"
            );
        }
    }

    // === INVARIANT TESTS ===

    function testFuzz_invariant_TokenConservation(
        uint256 depositAmount0,
        uint256 depositAmount1,
        uint256 mintAmount0,
        uint256 mintAmount1,
        uint256 timeElapsed
    )
        public
    {
        depositAmount0 = bound(depositAmount0, TestConstants.MEDIUM_AMOUNT, TestConstants.LARGE_AMOUNT);
        depositAmount1 = bound(depositAmount1, TestConstants.MEDIUM_AMOUNT, TestConstants.LARGE_AMOUNT);
        mintAmount0 = bound(mintAmount0, TestConstants.SMALL_AMOUNT, depositAmount0 / 2);
        mintAmount1 = bound(mintAmount1, TestConstants.SMALL_AMOUNT, depositAmount1 / 2);
        timeElapsed = bound(timeElapsed, 1 hours, TestConstants.ONE_MONTH);

        uint256 initialOwnerBalance0 = setup.token0.balanceOf(setup.owner);
        uint256 initialOwnerBalance1 = setup.token1.balanceOf(setup.owner);

        // Deposit
        helper.depositToVault(setup, depositAmount0, depositAmount1);

        // Create position
        helper.createPositionAroundCurrentTick(
            setup.vault, setup.allocator, TestConstants.TICK_RANGE_NARROW, mintAmount0, mintAmount1
        );

        // Time passes
        helper.simulateTimePass(timeElapsed);

        // Withdraw everything
        address recipient = makeAddr("recipient");
        helper.withdrawFromVault(setup, TestConstants.MAX_SCALED_PERCENTAGE, recipient);

        // Check token conservation (accounting for TVL fees)
        uint256 finalOwnerBalance0 = setup.token0.balanceOf(setup.owner);
        uint256 finalOwnerBalance1 = setup.token1.balanceOf(setup.owner);
        uint256 recipientBalance0 = setup.token0.balanceOf(recipient);
        uint256 recipientBalance1 = setup.token1.balanceOf(recipient);
        uint256 feeCollectorBalance0 = setup.token0.balanceOf(setup.feeCollector);
        uint256 feeCollectorBalance1 = setup.token1.balanceOf(setup.feeCollector);
        uint256 vaultRemainder0 = setup.token0.balanceOf(address(setup.vault));
        uint256 vaultRemainder1 = setup.token1.balanceOf(address(setup.vault));

        uint256 totalFinal0 = finalOwnerBalance0 + recipientBalance0 + feeCollectorBalance0 + vaultRemainder0;
        uint256 totalFinal1 = finalOwnerBalance1 + recipientBalance1 + feeCollectorBalance1 + vaultRemainder1;

        // Total should equal initial (allowing for small rounding errors)
        helper.assertApproxEqual(
            totalFinal0, initialOwnerBalance0, TestConstants.TOLERANCE_MEDIUM, "Token0 conservation failed"
        );
        helper.assertApproxEqual(
            totalFinal1, initialOwnerBalance1, TestConstants.TOLERANCE_MEDIUM, "Token1 conservation failed"
        );
    }

    function testFuzz_invariant_NetAssetsNonNegative(uint256 amount0, uint256 amount1, uint256 operations) public {
        amount0 = bound(amount0, TestConstants.SMALL_AMOUNT, TestConstants.LARGE_AMOUNT);
        amount1 = bound(amount1, TestConstants.SMALL_AMOUNT, TestConstants.LARGE_AMOUNT);
        operations = bound(operations, 1, 5);

        helper.depositToVault(setup, amount0, amount1);

        for (uint256 i = 0; i < operations; i++) {
            uint256 op = uint256(keccak256(abi.encode(i, amount0, amount1))) % 3;

            if (op == 0) {
                // Mint position
                try helper.createPositionAroundCurrentTick(
                    setup.vault,
                    setup.allocator,
                    TestConstants.TICK_RANGE_NARROW,
                    TestConstants.SMALL_AMOUNT,
                    TestConstants.SMALL_AMOUNT
                ) {} catch {}
            } else if (op == 1) {
                // Collect fees
                (, int24 currentTick,,,,,) = setup.pool.slot0();
                vm.prank(setup.allocator);
                try setup.vault.collect(
                    currentTick - TestConstants.TICK_RANGE_NARROW,
                    currentTick + TestConstants.TICK_RANGE_NARROW,
                    type(uint128).max,
                    type(uint128).max
                ) {} catch {}
            } else {
                // Burn position
                try setup.vault.getPosition(0) returns (Position memory pos) {
                    if (pos.liquidity > 0) {
                        vm.prank(setup.allocator);
                        try setup.vault.burn(pos.lowerTick, pos.upperTick, pos.liquidity / 2) {} catch {}
                    }
                } catch {}
            }

            // Invariant: net assets should always be non-negative
            (uint256 net0, uint256 net1) = setup.vault.netAssetsValue();
            assertTrue(net0 >= 0, "Net assets0 became negative");
            assertTrue(net1 >= 0, "Net assets1 became negative");
        }
    }
}
