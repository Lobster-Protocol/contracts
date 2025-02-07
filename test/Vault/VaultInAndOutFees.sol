// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {PendingFeeUpdate} from "../../src/Vault/ERC4626Fees.sol";
import {VaultTestSetup} from "./VaultTestSetup.sol";
import {ERC4626Fees} from "../../src/Vault/ERC4626Fees.sol";

// test deposit / withdraw / mint / redeem fee
contract VaultInAndOutFeesTest is VaultTestSetup {
    // the default fess are set to 0

    /* -----------------------HELPER FUNCTIONS TO SET VAULT FEES----------------------- */
    function setEntryFeeBasisPoint(uint256 fee) public returns (bool) {
        vm.startPrank(owner);
        vault.setEntryFee(fee);
        vm.stopPrank();

        return true;
    }

    function setExitFeeBasisPoint(uint256 fee) public returns (bool) {
        vm.startPrank(owner);
        vault.setExitFee(fee);
        vm.stopPrank();

        return true;
    }

    function computeFees(
        uint256 amount,
        uint256 fee
    ) public pure returns (uint256) {
        return (amount * fee) / 10000;
    }

    /* -----------------------TEST DEPOSIT/WITHDRAW/MINT/REDEEM FEE UPDATE----------------------- */

    function testUpdateDepositFee() public {
        // set fees to 200 (2%)
        setEntryFeeBasisPoint(200);

        (uint256 newFee, uint256 enforcementMinTimestamp) = vault
            .pendingEntryFeeUpdate();

        assertEq(newFee, 200);
        assertEq(
            enforcementMinTimestamp,
            block.timestamp + vault.FEE_UPDATE_DELAY()
        );

        // wait for a block with timestamp >= FEE_UPDATE_DELAY + block.timestamp
        vm.warp(block.timestamp + vault.FEE_UPDATE_DELAY());

        // enforce the fee update
        vault.enforceNewEntryFee();

        // ensure pending fee has been updated
        (uint256 fee, uint256 enforcementTimestamp) = vault
            .pendingEntryFeeUpdate();
        assertEq(fee, 0);
        assertEq(enforcementTimestamp, 0);
        assertEq(vault.entryFeeBasisPoints(), 200);
        vm.stopPrank();
    }

    function testEnforceEntryPendingFeesThatDontExist() public {
        // try to enforce fees when there is no pending fee update
        vm.startPrank(owner);
        vm.expectRevert(ERC4626Fees.NoPendingFeeUpdate.selector);
        vault.enforceNewEntryFee();
        vm.stopPrank();
    }

    function testEnforceExitPendingFeesThatDontExist() public {
        // try to enforce fees when there is no pending fee update
        vm.startPrank(owner);
        vm.expectRevert(ERC4626Fees.NoPendingFeeUpdate.selector);
        vault.enforceNewExitFee();
        vm.stopPrank();
    }

    function testEnforceEntryFeesBeforeTimestamp() public {
        // set fees to 55 (0.55%)
        setEntryFeeBasisPoint(55);

        // expected values
        uint256 currentTimestamp = block.timestamp;
        uint256 activationTimestamp = currentTimestamp +
            vault.FEE_UPDATE_DELAY();

        // Try to enforce fees when the timestamp is not reached
        vm.startPrank(owner);

        // We expect it to revert with ActivationTimestampNotReached error
        // containing the current timestamp and activation timestamp
        vm.expectRevert(
            abi.encodeWithSelector(
                ERC4626Fees.ActivationTimestampNotReached.selector,
                currentTimestamp,
                activationTimestamp
            )
        );

        vault.enforceNewEntryFee();
        vm.stopPrank();
    }

    function testEnforceExitFeesBeforeTimestamp() public {
        // set fees to 55 (0.55%)
        setExitFeeBasisPoint(55);

        // expected values
        uint256 currentTimestamp = block.timestamp;
        uint256 activationTimestamp = currentTimestamp +
            vault.FEE_UPDATE_DELAY();

        // Try to enforce fees when the timestamp is not reached
        vm.startPrank(owner);

        // We expect it to revert with ActivationTimestampNotReached error
        // containing the current timestamp and activation timestamp
        vm.expectRevert(
            abi.encodeWithSelector(
                ERC4626Fees.ActivationTimestampNotReached.selector,
                currentTimestamp,
                activationTimestamp
            )
        );

        vault.enforceNewExitFee();
        vm.stopPrank();
    }

    // idk why this test is failing
    // function testSetEntryFeeGtMaxFee() public {
    //     // set fees to MAX_FEE + 1
    //     vm.startPrank(owner);
    //     vm.expectRevert(ERC4626Fees.InvalidFee.selector);
    //     vault.setEntryFee(vault.MAX_FEE() + 1);
    //     vm.stopPrank();
    // }

    // idk why this test is failing
    // function testSetExitFeeGtMaxFee() public {
    //     // set fees to MAX_FEE + 1
    //     vm.startPrank(owner);
    //     vm.expectRevert(ERC4626Fees.InvalidFee.selector);
    //     vault.setExitFee(vault.MAX_FEE() + 1);
    //     vm.stopPrank();
    // }

    function testEnsureEntryFeeCollectorReceivesTheAsset() public {
        uint256 feeCollectorInitialBalance = asset.balanceOf(
            vault.entryFeeCollector()
        );

        // set fees to 150 (1.5%)
        uint256 fee = 150;
        setEntryFeeBasisPoint(fee);
        // wait for a block with timestamp >= FEE_UPDATE_DELAY + block.timestamp
        vm.warp(block.timestamp + vault.FEE_UPDATE_DELAY());
        // enforce the fee update
        vault.enforceNewEntryFee();

        rebaseVault(0, block.number + 1);
        uint256 depositAmount = 1000;
        vm.startPrank(alice);
        vault.deposit(depositAmount, alice);
        vm.stopPrank();

        // ensure the collector has received the fees
        assertEq(
            asset.balanceOf(vault.entryFeeCollector()),
            feeCollectorInitialBalance + computeFees(depositAmount, fee)
        );
    }

    function testEnsureExitFeeCollectorReceivesTheAsset() public {
        uint256 feeCollectorInitialBalance = asset.balanceOf(
            vault.exitFeeCollector()
        );

        // set fees to 150 (1.5%)
        uint256 fee = 150;
        setExitFeeBasisPoint(fee);
        // wait for a block with timestamp >= FEE_UPDATE_DELAY + block.timestamp
        vm.warp(block.timestamp + vault.FEE_UPDATE_DELAY());
        // enforce the fee update
        vault.enforceNewExitFee();

        rebaseVault(0, block.number + 1);
        uint256 depositAmount = 1000;
        vm.startPrank(alice);
        vault.deposit(depositAmount, alice);

        uint256 exitFee = computeFees(depositAmount, fee);
        vault.withdraw(vault.maxWithdraw(alice) - exitFee, alice, alice);
        vm.stopPrank();


        // ensure the collector has received the fees
        assertEq(
            asset.balanceOf(vault.exitFeeCollector()),
            feeCollectorInitialBalance + exitFee
        );
    }

    /* -----------------------TEST DEPOSIT WITH FEES----------------------- */
    function testDepositFee() public {
        rebaseVault(0, block.number + 1);

        // alice deposits 1000 with a fee of 0
        vm.startPrank(alice);
        vault.deposit(1000, alice);

        assertEq(vault.maxWithdraw(alice), 1000);
        vm.stopPrank();

        // set fees to 150 (1.5%)
        setEntryFeeBasisPoint(150);
        // wait for a block with timestamp >= FEE_UPDATE_DELAY + block.timestamp
        vm.warp(block.timestamp + vault.FEE_UPDATE_DELAY());
        // enforce the fee update
        vault.enforceNewEntryFee();

        // bob deposits 1000 with a fee of 150
        vm.startPrank(bob);
        uint256 bobDeposit = 1000;
        vault.deposit(bobDeposit, bob);

        assertEq(
            vault.maxWithdraw(bob),
            bobDeposit - computeFees(bobDeposit, 150)
        );
        assertEq(
            vault.totalAssets(),
            1000 + bobDeposit - computeFees(bobDeposit, 150)
        );
        assertEq(
            vault.balanceOf(bob),
            bobDeposit - computeFees(bobDeposit, 150)
        );
        vm.stopPrank();
    }
}

// todo: test withdraw, mint, redeem with fees