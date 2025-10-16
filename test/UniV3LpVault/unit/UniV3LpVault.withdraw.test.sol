// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {UniV3LpVault} from "../../../src/vaults/UniV3LpVault.sol";
import {SingleVault} from "../../../src/vaults/SingleVault.sol";
import {TestHelper} from "../helpers/TestHelper.sol";
import {TestConstants} from "../helpers/Constants.sol";

contract UniV3LpVaultWithdrawTest is Test {
    using Math for uint256;

    TestHelper helper;
    TestHelper.VaultSetup setup;

    function setUp() public {
        helper = new TestHelper();
        setup = helper.deployVaultWithPool();
    }

    function test_withdraw_PartialWithdraw_Success() public {
        uint256 depositAmount0 = TestConstants.LARGE_AMOUNT;
        uint256 depositAmount1 = TestConstants.LARGE_AMOUNT;

        // Setup: deposit and create position
        helper.depositToVault(setup, depositAmount0, depositAmount1);
        helper.createPositionAroundCurrentTick(
            setup.vault,
            setup.executor,
            TestConstants.TICK_RANGE_NARROW,
            TestConstants.MEDIUM_AMOUNT,
            TestConstants.MEDIUM_AMOUNT
        );

        address recipient = makeAddr("recipient");
        uint256 withdrawPercentage = TestConstants.HALF_SCALED_PERCENTAGE; // 50%

        uint256 initialRecipientBalance0 = setup.token0.balanceOf(recipient);
        uint256 initialRecipientBalance1 = setup.token1.balanceOf(recipient);

        vm.expectEmit(false, false, true, true); // We don't check indexed parameters due to complexity
        emit UniV3LpVault.Withdraw(0, 0, recipient); // Amounts will be calculated dynamically

        vm.prank(setup.owner);
        (uint256 withdrawn0, uint256 withdrawn1) = setup.vault.withdraw(withdrawPercentage, recipient);

        // Check recipient received tokens
        assertTrue(setup.token0.balanceOf(recipient) > initialRecipientBalance0);
        assertTrue(setup.token1.balanceOf(recipient) > initialRecipientBalance1);
        assertTrue(withdrawn0 > 0);
        assertTrue(withdrawn1 > 0);

        // Check vault still has remaining assets
        (uint256 remainingNet0, uint256 remainingNet1) = setup.vault.netAssetsValue();
        assertTrue(remainingNet0 > 0);
        assertTrue(remainingNet1 > 0);
    }

    function test_withdraw_FullWithdraw_Success() public {
        uint256 depositAmount0 = TestConstants.MEDIUM_AMOUNT;
        uint256 depositAmount1 = TestConstants.MEDIUM_AMOUNT;

        helper.depositToVault(setup, depositAmount0, depositAmount1);
        helper.createPositionAroundCurrentTick(
            setup.vault,
            setup.executor,
            TestConstants.TICK_RANGE_NARROW,
            TestConstants.SMALL_AMOUNT,
            TestConstants.SMALL_AMOUNT
        );

        address recipient = makeAddr("recipient");

        vm.prank(setup.owner);
        setup.vault.withdraw(TestConstants.MAX_SCALED_PERCENTAGE, recipient);

        // Vault should be nearly empty (allowing for small rounding errors)
        (uint256 finalNet0, uint256 finalNet1) = setup.vault.netAssetsValue();
        helper.assertApproxEqual(finalNet0, 0, TestConstants.TOLERANCE_HIGH, "Final net assets0 should be zero");
        helper.assertApproxEqual(finalNet1, 0, TestConstants.TOLERANCE_HIGH, "Final net assets1 should be zero");
    }

    function test_withdraw_ZeroPercentage_Reverts() public {
        helper.depositToVault(setup, TestConstants.MEDIUM_AMOUNT, TestConstants.MEDIUM_AMOUNT);

        address recipient = makeAddr("recipient");

        vm.prank(setup.owner);
        vm.expectRevert(SingleVault.ZeroValue.selector);
        setup.vault.withdraw(0, recipient);
    }

    function test_withdraw_PercentageOverMax_Reverts() public {
        helper.depositToVault(setup, TestConstants.MEDIUM_AMOUNT, TestConstants.MEDIUM_AMOUNT);

        address recipient = makeAddr("recipient");
        uint256 excessivePercentage = TestConstants.MAX_SCALED_PERCENTAGE + 1;

        vm.prank(setup.owner);
        vm.expectRevert(UniV3LpVault.InvalidScalingFactor.selector);
        setup.vault.withdraw(excessivePercentage, recipient);
    }

    function test_withdraw_ZeroRecipient_Reverts() public {
        helper.depositToVault(setup, TestConstants.MEDIUM_AMOUNT, TestConstants.MEDIUM_AMOUNT);

        vm.prank(setup.owner);
        vm.expectRevert(SingleVault.ZeroAddress.selector);
        setup.vault.withdraw(TestConstants.HALF_SCALED_PERCENTAGE, address(0));
    }

    function test_withdraw_NotOwner_Reverts() public {
        helper.depositToVault(setup, TestConstants.MEDIUM_AMOUNT, TestConstants.MEDIUM_AMOUNT);

        address notOwner = makeAddr("notOwner");
        address recipient = makeAddr("recipient");

        vm.prank(notOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, notOwner));
        setup.vault.withdraw(TestConstants.HALF_SCALED_PERCENTAGE, recipient);
    }

    function test_withdraw_WithMultiplePositions_Success() public {
        uint256 depositAmount0 = TestConstants.LARGE_AMOUNT;
        uint256 depositAmount1 = TestConstants.LARGE_AMOUNT;

        helper.depositToVault(setup, depositAmount0, depositAmount1);

        // Create multiple positions

        helper.createPositionAroundCurrentTick(
            setup.vault,
            setup.executor,
            TestConstants.TICK_RANGE_NARROW,
            TestConstants.SMALL_AMOUNT,
            TestConstants.SMALL_AMOUNT
        );

        helper.createPositionAroundCurrentTick(
            setup.vault,
            setup.executor,
            TestConstants.TICK_RANGE_NARROW,
            TestConstants.MEDIUM_AMOUNT,
            TestConstants.MEDIUM_AMOUNT
        );

        address recipient = makeAddr("recipient");

        vm.prank(setup.owner);
        (uint256 withdrawn0, uint256 withdrawn1) =
            setup.vault.withdraw(TestConstants.QUARTER_SCALED_PERCENTAGE, recipient);

        assertTrue(withdrawn0 > 0);
        assertTrue(withdrawn1 > 0);
        assertTrue(setup.token0.balanceOf(recipient) == withdrawn0);
        assertTrue(setup.token1.balanceOf(recipient) == withdrawn1);
    }

    function test_withdraw_WithTvlFees_CollectsFees() public {
        TestHelper.VaultSetup memory feeSetup =
            helper.deployVaultWithPool(TestConstants.HIGH_TVL_FEE, TestConstants.HIGH_PERF_FEE);

        helper.depositToVault(feeSetup, TestConstants.LARGE_AMOUNT, TestConstants.LARGE_AMOUNT);
        helper.createPositionAroundCurrentTick(
            feeSetup.vault,
            feeSetup.executor,
            TestConstants.TICK_RANGE_NARROW,
            TestConstants.MEDIUM_AMOUNT,
            TestConstants.MEDIUM_AMOUNT
        );

        // Let time pass to accumulate TVL fees
        helper.simulateTimePass(TestConstants.ONE_MONTH);

        address recipient = makeAddr("recipient");
        uint256 initialFeeCollectorBalance0 = feeSetup.token0.balanceOf(feeSetup.feeCollector);
        uint256 initialFeeCollectorBalance1 = feeSetup.token1.balanceOf(feeSetup.feeCollector);

        vm.expectEmit(false, false, true, true);
        emit UniV3LpVault.TvlFeeCollected(0, 0, feeSetup.feeCollector);

        vm.prank(feeSetup.owner);
        feeSetup.vault.withdraw(TestConstants.HALF_SCALED_PERCENTAGE, recipient);

        // Fee collector should have received fees
        // todo: improve the assertiosn to assertEq(balance delta, expected tvl fees + expected perf fee)
        assertTrue(feeSetup.token0.balanceOf(feeSetup.feeCollector) > initialFeeCollectorBalance0);
        assertTrue(feeSetup.token1.balanceOf(feeSetup.feeCollector) > initialFeeCollectorBalance1);
    }

    function test_withdraw_EmptyVault_Success() public {
        address recipient = makeAddr("recipient");

        vm.prank(setup.owner);
        (uint256 withdrawn0, uint256 withdrawn1) = setup.vault.withdraw(TestConstants.MAX_SCALED_PERCENTAGE, recipient);

        assertEq(withdrawn0, 0);
        assertEq(withdrawn1, 0);
        assertEq(setup.token0.balanceOf(recipient), 0);
        assertEq(setup.token1.balanceOf(recipient), 0);
    }

    function test_withdraw_OnlyCashNoPositions_Success() public {
        uint256 depositAmount0 = TestConstants.MEDIUM_AMOUNT;
        uint256 depositAmount1 = TestConstants.MEDIUM_AMOUNT;

        helper.depositToVault(setup, depositAmount0, depositAmount1);
        // Don't create any positions - all funds remain as cash

        address recipient = makeAddr("recipient");
        uint256 withdrawPercentage = TestConstants.HALF_SCALED_PERCENTAGE;

        vm.prank(setup.owner);
        (uint256 withdrawn0, uint256 withdrawn1) = setup.vault.withdraw(withdrawPercentage, recipient);

        uint256 expectedWithdraw0 = depositAmount0.mulDiv(withdrawPercentage, TestConstants.MAX_SCALED_PERCENTAGE);
        uint256 expectedWithdraw1 = depositAmount1.mulDiv(withdrawPercentage, TestConstants.MAX_SCALED_PERCENTAGE);

        assertEq(withdrawn0, expectedWithdraw0);
        assertEq(withdrawn1, expectedWithdraw1);
        assertEq(setup.token0.balanceOf(recipient), expectedWithdraw0);
        assertEq(setup.token1.balanceOf(recipient), expectedWithdraw1);
    }

    function test_withdraw_QuarterPercentage_Success() public {
        uint256 depositAmount0 = TestConstants.LARGE_AMOUNT;
        uint256 depositAmount1 = TestConstants.LARGE_AMOUNT;

        helper.depositToVault(setup, depositAmount0, depositAmount1);
        helper.createPositionAroundCurrentTick(
            setup.vault,
            setup.executor,
            TestConstants.TICK_RANGE_MEDIUM,
            TestConstants.MEDIUM_AMOUNT,
            TestConstants.MEDIUM_AMOUNT
        );

        address recipient = makeAddr("recipient");

        vm.prank(setup.owner);
        setup.vault.withdraw(TestConstants.QUARTER_SCALED_PERCENTAGE, recipient);

        // Vault should have approximately 75% left
        (uint256 finalNet0, uint256 finalNet1) = setup.vault.netAssetsValue();

        // Allow for some tolerance due to position management and rounding
        uint256 expectedRemaining0 = (depositAmount0 * 75) / 100;
        uint256 expectedRemaining1 = (depositAmount1 * 75) / 100;

        helper.assertApproxEqual(
            finalNet0, expectedRemaining0, TestConstants.TOLERANCE_MEDIUM, "Remaining assets0 should be ~75%"
        );
        helper.assertApproxEqual(
            finalNet1, expectedRemaining1, TestConstants.TOLERANCE_MEDIUM, "Remaining assets1 should be ~75%"
        );
    }
}
