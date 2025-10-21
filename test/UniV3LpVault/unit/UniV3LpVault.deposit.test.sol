// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import {UniV3LpVault, MAX_SCALED_PERCENTAGE, TWAP_SECONDS_AGO} from "../../../src/vaults/UniV3LpVault.sol";
import {SingleVault} from "../../../src/vaults/SingleVault.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {TestHelper} from "../helpers/TestHelper.sol";
import {TestConstants} from "../helpers/Constants.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {UniswapUtils} from "../../../src/libraries/uniswapV3/UniswapUtils.sol";

contract UniV3LpVaultDepositTest is Test {
    using Math for uint256;

    TestHelper helper;
    TestHelper.VaultSetup setup;

    function setUp() public {
        helper = new TestHelper();
        setup = helper.deployVaultWithPool();
    }

    function test_deposit_bothTokens_Success() public {
        uint256 amount0 = TestConstants.MEDIUM_AMOUNT;
        uint256 amount1 = TestConstants.LARGE_AMOUNT;

        uint256 initialVaultBalance0 = setup.token0.balanceOf(address(setup.vault));
        uint256 initialVaultBalance1 = setup.token1.balanceOf(address(setup.vault));
        uint256 initialOwnerBalance0 = setup.token0.balanceOf(setup.owner);
        uint256 initialOwnerBalance1 = setup.token1.balanceOf(setup.owner);

        vm.expectEmit(true, true, true, true);
        emit UniV3LpVault.Deposit(amount0, amount1);

        vm.prank(setup.owner);
        setup.vault.deposit(amount0, amount1);

        // Check vault balances increased
        assertEq(setup.token0.balanceOf(address(setup.vault)), initialVaultBalance0 + amount0);
        assertEq(setup.token1.balanceOf(address(setup.vault)), initialVaultBalance1 + amount1);

        // Check owner balances decreased
        assertEq(setup.token0.balanceOf(setup.owner), initialOwnerBalance0 - amount0);
        assertEq(setup.token1.balanceOf(setup.owner), initialOwnerBalance1 - amount1);
    }

    function test_deposit_Token0Only_Success() public {
        uint256 amount0 = TestConstants.MEDIUM_AMOUNT;
        uint256 amount1 = 0;

        uint256 initialVaultBalance0 = setup.token0.balanceOf(address(setup.vault));
        uint256 initialVaultBalance1 = setup.token1.balanceOf(address(setup.vault));

        vm.expectEmit(true, true, true, true);
        emit UniV3LpVault.Deposit(amount0, amount1);

        vm.prank(setup.owner);
        setup.vault.deposit(amount0, amount1);

        assertEq(setup.token0.balanceOf(address(setup.vault)), initialVaultBalance0 + amount0);
        assertEq(setup.token1.balanceOf(address(setup.vault)), initialVaultBalance1); // No change
    }

    function test_deposit_Token1Only_Success() public {
        uint256 amount0 = 0;
        uint256 amount1 = TestConstants.MEDIUM_AMOUNT;

        uint256 initialVaultBalance0 = setup.token0.balanceOf(address(setup.vault));
        uint256 initialVaultBalance1 = setup.token1.balanceOf(address(setup.vault));

        vm.expectEmit(true, true, true, true);
        emit UniV3LpVault.Deposit(amount0, amount1);

        vm.prank(setup.owner);
        setup.vault.deposit(amount0, amount1);

        assertEq(setup.token0.balanceOf(address(setup.vault)), initialVaultBalance0); // No change
        assertEq(setup.token1.balanceOf(address(setup.vault)), initialVaultBalance1 + amount1);
    }

    function test_deposit_ZeroAmounts_Reverts() public {
        vm.prank(setup.owner);
        vm.expectRevert(SingleVault.ZeroValue.selector);
        setup.vault.deposit(0, 0);
    }

    function test_deposit_NotOwner_Reverts() public {
        address notOwner = makeAddr("notOwner");

        vm.prank(notOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, notOwner));
        setup.vault.deposit(TestConstants.SMALL_AMOUNT, TestConstants.SMALL_AMOUNT);
    }

    function test_deposit_InsufficientAllowance_Reverts() public {
        // Deploy new vault setup without max approval
        TestHelper.VaultSetup memory restrictedSetup = helper.deployVaultWithPool();

        uint256 allowanceAmount = TestConstants.SMALL_AMOUNT;
        uint256 depositAmount = TestConstants.MEDIUM_AMOUNT; // More than allowance

        vm.startPrank(restrictedSetup.owner);
        restrictedSetup.token0.approve(address(restrictedSetup.vault), allowanceAmount);
        restrictedSetup.token1.approve(address(restrictedSetup.vault), allowanceAmount);

        // Should revert due to insufficient allowance
        vm.expectRevert();
        restrictedSetup.vault.deposit(depositAmount, depositAmount);
        vm.stopPrank();
    }

    function test_deposit_InsufficientBalance_Reverts() public {
        uint256 currentBalance = setup.token0.balanceOf(setup.owner);
        uint256 excessiveAmount = currentBalance + 1;

        vm.prank(setup.owner);
        vm.expectRevert();
        setup.vault.deposit(excessiveAmount, 0);
    }

    function test_deposit_MultipleDeposits_Success() public {
        uint256 firstDeposit0 = TestConstants.SMALL_AMOUNT;
        uint256 firstDeposit1 = TestConstants.SMALL_AMOUNT;
        uint256 secondDeposit0 = TestConstants.MEDIUM_AMOUNT;
        uint256 secondDeposit1 = TestConstants.MEDIUM_AMOUNT;

        vm.startPrank(setup.owner);

        // First deposit
        setup.vault.deposit(firstDeposit0, firstDeposit1);

        uint256 intermediateBalance0 = setup.token0.balanceOf(address(setup.vault));
        uint256 intermediateBalance1 = setup.token1.balanceOf(address(setup.vault));

        assertEq(intermediateBalance0, firstDeposit0);
        assertEq(intermediateBalance1, firstDeposit1);

        // Second deposit
        setup.vault.deposit(secondDeposit0, secondDeposit1);

        vm.stopPrank();

        // Check final balances
        assertEq(setup.token0.balanceOf(address(setup.vault)), firstDeposit0 + secondDeposit0);
        assertEq(setup.token1.balanceOf(address(setup.vault)), firstDeposit1 + secondDeposit1);
    }

    function test_deposit_WithFeesAccumulated_CollectsFees() public {
        // Create vault with TVL fees
        TestHelper.VaultSetup memory feeSetup = helper.deployVaultWithPool(
            0,
            // TestConstants.HIGH_TVL_FEE,
            TestConstants.HIGH_PERF_FEE
        );

        helper.depositToVault(feeSetup, TestConstants.MEDIUM_AMOUNT, TestConstants.MEDIUM_AMOUNT);

        // Create a position to accumulate fees
        helper.createPositionAroundCurrentTick(
            feeSetup.vault,
            feeSetup.allocator,
            TestConstants.TICK_RANGE_NARROW,
            TestConstants.SMALL_AMOUNT,
            TestConstants.SMALL_AMOUNT
        );

        uint256 delay = TestConstants.ONE_MONTH;

        // Simulate time passing to accumulate TVL fees
        helper.simulateTimePass(delay);

        // Simulate performance: double the vault tvl
        (uint256 tvl0, uint256 tvl1) = feeSetup.vault.rawAssetsValue();
        feeSetup.token0.mint(address(feeSetup.vault), tvl0);
        feeSetup.token1.mint(address(feeSetup.vault), tvl1);

        uint256 initialFeeCollectorBalance0 = feeSetup.token0.balanceOf(feeSetup.feeCollector);
        uint256 initialFeeCollectorBalance1 = feeSetup.token1.balanceOf(feeSetup.feeCollector);

        // Check pending performance fee
        (uint256 expectedPerfFee0, uint256 expectedPerfFee1) = feeSetup.vault.pendingPerformanceFee();

        uint256 tvlFeePercent = feeSetup.vault.tvlFeeScaled().mulDiv(delay, 365 days);

        (uint256 value0InVault, uint256 value1InVault) = feeSetup.vault.rawAssetsValue();

        // Make another deposit - this should trigger fee collection (TVL&PERF)
        helper.depositToVault(feeSetup, TestConstants.SMALL_AMOUNT, TestConstants.SMALL_AMOUNT);

        uint256 expectedTvlFee0 = value0InVault.mulDiv(tvlFeePercent, MAX_SCALED_PERCENTAGE);
        uint256 expectedTvlFee1 = value1InVault.mulDiv(tvlFeePercent, MAX_SCALED_PERCENTAGE);

        // Fee collector should have received fees
        assertApproxEqAbs(
            feeSetup.token0.balanceOf(feeSetup.feeCollector),
            initialFeeCollectorBalance0 + expectedTvlFee0 + expectedPerfFee0,
            1
        );
        assertApproxEqAbs(
            feeSetup.token1.balanceOf(feeSetup.feeCollector),
            initialFeeCollectorBalance1 + expectedTvlFee1 + expectedPerfFee1,
            1
        );

        // make sure lastVaultTvl0 have been updated
        (uint256 finalTvl0, uint256 finalTvl1) = feeSetup.vault.rawAssetsValue();
        (uint256 tvlFee0, uint256 tvlFee1) = feeSetup.vault.pendingTvlFee();
        finalTvl0 -= tvlFee0;
        finalTvl1 -= tvlFee1;

        // Use a reasonable base amount instead of 1 if there is an overflow
        uint128 baseAmount = uint128(1);
        if (finalTvl1 <= type(uint128).max) {
            // forge-lint: disable-next-line(unsafe-typecast)
            baseAmount = uint128(finalTvl1);
        }
        uint256 twapResult = UniswapUtils.getTwap(feeSetup.pool, TWAP_SECONDS_AGO, baseAmount, true);

        // Scale the result if we used a smaller base amount
        uint256 twapValueFrom1To0;
        if (tvl1 > type(uint128).max) {
            twapValueFrom1To0 = twapResult * tvl1;
        } else {
            twapValueFrom1To0 = twapResult;
        }

        assertApproxEqAbs(feeSetup.vault.lastVaultTvl0(), finalTvl0 + twapValueFrom1To0, 1);
    }

    function test_deposit_NetAssetsValue_UpdatesCorrectly() public {
        uint256 amount0 = TestConstants.MEDIUM_AMOUNT;
        uint256 amount1 = TestConstants.LARGE_AMOUNT;

        (uint256 initialNet0, uint256 initialNet1) = setup.vault.netAssetsValue();
        assertEq(initialNet0, 0);
        assertEq(initialNet1, 0);

        helper.depositToVault(setup, amount0, amount1);

        (uint256 finalNet0, uint256 finalNet1) = setup.vault.netAssetsValue();
        assertEq(finalNet0, amount0);
        assertEq(finalNet1, amount1);
    }

    function test_deposit_MaxAmounts_Success() public {
        uint256 maxAmount0 = TestConstants.INITIAL_BALANCE;
        uint256 maxAmount1 = TestConstants.INITIAL_BALANCE;

        vm.prank(setup.owner);
        setup.vault.deposit(maxAmount0, maxAmount1);

        assertEq(setup.token0.balanceOf(address(setup.vault)), maxAmount0);
        assertEq(setup.token1.balanceOf(address(setup.vault)), maxAmount1);
        assertEq(setup.token0.balanceOf(setup.owner), 0);
        assertEq(setup.token1.balanceOf(setup.owner), 0);
    }
}
