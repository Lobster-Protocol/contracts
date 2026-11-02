// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import {
    UniV3LpVaultVariables,
    MAX_SCALED_PERCENTAGE,
    TWAP_SECONDS_AGO,
    SCALING_FACTOR
} from "../../../src/vaults/uniV3LpVault/UniV3LpVault.sol";
import {SingleVault} from "../../../src/vaults/SingleVault.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {TestHelper} from "../helpers/TestHelper.sol";
import {TestConstants} from "../helpers/Constants.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
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
        emit UniV3LpVaultVariables.Deposit(amount0, amount1);

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
        emit UniV3LpVaultVariables.Deposit(amount0, amount1);

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
        emit UniV3LpVaultVariables.Deposit(amount0, amount1);

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
        TestHelper.VaultSetup memory feeSetup =
            helper.deployVaultWithPool(TestConstants.HIGH_TVL_FEE, TestConstants.HIGH_PERF_FEE);

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
            2
        );
        assertApproxEqAbs(
            feeSetup.token1.balanceOf(feeSetup.feeCollector),
            initialFeeCollectorBalance1 + expectedTvlFee1 + expectedPerfFee1,
            2
        );

        // works since no perf since last deposit & no tvl fee
        (uint256 finalTvl0, uint256 finalTvl1) = feeSetup.vault.rawAssetsValue();
        uint256 twapResult = UniswapUtils.getTwap(
            feeSetup.pool,
            TWAP_SECONDS_AGO,
            // forge-lint: disable-next-line(unsafe-typecast)
            uint128(SCALING_FACTOR),
            true
        );
        uint256 twapValueFrom1To0 = twapResult.mulDiv(finalTvl1, SCALING_FACTOR);
        assertEq(feeSetup.vault.lastVaultTvl0(), finalTvl0 + twapValueFrom1To0);
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

    /// @notice Deposit is the first log of a deposit: the token transfers it announces come after it
    function test_deposit_EmitsDepositBeforeTransfers() public {
        uint256 amount0 = TestConstants.MEDIUM_AMOUNT;
        uint256 amount1 = TestConstants.LARGE_AMOUNT;

        vm.recordLogs();
        vm.prank(setup.owner);
        setup.vault.deposit(amount0, amount1);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(logs[0].emitter, address(setup.vault), "First log from the vault");
        assertEq(logs[0].topics[0], UniV3LpVaultVariables.Deposit.selector, "First log is Deposit");
        assertEq(logs[0].topics[1], bytes32(amount0), "Deposit assets0");
        assertEq(logs[0].topics[2], bytes32(amount1), "Deposit assets1");

        uint256 transfer0 = _firstIndexOf(logs, address(setup.token0), IERC20.Transfer.selector);
        uint256 transfer1 = _firstIndexOf(logs, address(setup.token1), IERC20.Transfer.selector);
        assertLt(transfer0, logs.length, "token0 transferred");
        assertLt(transfer1, logs.length, "token1 transferred");
        assertGt(transfer0, 0, "token0 transfer after Deposit");
        assertGt(transfer1, 0, "token1 transfer after Deposit");
    }

    /// @notice When the deposit collects pending fees, Deposit still comes first, before the fee collection's logs
    function test_deposit_WithFeesAccumulated_EmitsDepositBeforeFeeCollection() public {
        TestHelper.VaultSetup memory feeSetup = helper.deployVaultWithPool(TestConstants.HIGH_TVL_FEE, 0);
        helper.depositToVault(feeSetup, TestConstants.MEDIUM_AMOUNT, TestConstants.MEDIUM_AMOUNT);
        helper.simulateTimePass(TestConstants.ONE_MONTH);

        vm.recordLogs();
        helper.depositToVault(feeSetup, TestConstants.SMALL_AMOUNT, TestConstants.SMALL_AMOUNT);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(logs[0].emitter, address(feeSetup.vault), "First log from the vault");
        assertEq(logs[0].topics[0], UniV3LpVaultVariables.Deposit.selector, "First log is Deposit");

        uint256 feeLog = _firstIndexOf(logs, address(feeSetup.vault), UniV3LpVaultVariables.TvlFeeCollected.selector);
        assertGt(feeLog, 0, "TVL fee collected after Deposit");
        assertLt(feeLog, logs.length, "TVL fee collected");
    }

    /// @notice A deposit records the performance fee baseline and emits it: VaultTvlRecorded carries the new
    ///         lastVaultTvl0 (token0 + token1 at the TWAP) and lastQuoteScaled
    function test_deposit_EmitsVaultTvlRecorded() public {
        uint256 amount0 = TestConstants.MEDIUM_AMOUNT;
        uint256 amount1 = TestConstants.LARGE_AMOUNT;

        uint256 quoteScaled =
            UniswapUtils.getTwap(setup.pool, TWAP_SECONDS_AGO, SafeCast.toUint128(SCALING_FACTOR), true);
        uint256 expectedTvl0 = amount0 + quoteScaled.mulDiv(amount1, SCALING_FACTOR);

        vm.expectEmit(true, true, true, true, address(setup.vault));
        emit UniV3LpVaultVariables.VaultTvlRecorded(expectedTvl0, quoteScaled);

        vm.prank(setup.owner);
        setup.vault.deposit(amount0, amount1);

        assertEq(setup.vault.lastVaultTvl0(), expectedTvl0, "lastVaultTvl0");
        assertEq(setup.vault.lastQuoteScaled(), quoteScaled, "lastQuoteScaled");
    }

    /// @notice A deposit with nothing to collect restarts the TVL fee accrual and emits TvlFeeCollectedAtUpdated
    function test_deposit_NothingToCollect_EmitsTvlFeeCollectedAtUpdated() public {
        helper.simulateTimePass(TestConstants.ONE_DAY);

        vm.expectEmit(true, true, true, true, address(setup.vault));
        emit UniV3LpVaultVariables.TvlFeeCollectedAtUpdated(vm.getBlockTimestamp());

        helper.depositToVault(setup, TestConstants.SMALL_AMOUNT, TestConstants.SMALL_AMOUNT);

        assertEq(setup.vault.tvlFeeCollectedAt(), vm.getBlockTimestamp(), "tvlFeeCollectedAt");
    }

    /// @dev Index of the first log from `emitter` with `topic0`, or logs.length if there is none
    function _firstIndexOf(Vm.Log[] memory logs, address emitter, bytes32 topic0) internal pure returns (uint256) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == emitter && logs[i].topics.length > 0 && logs[i].topics[0] == topic0) return i;
        }
        return logs.length;
    }
}
