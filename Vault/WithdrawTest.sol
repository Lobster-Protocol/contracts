// SPDX-License-Identifier: GNU AGPL v3.0
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../../src/Vault/Vault.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {MockERC20} from "../Mocks/MockERC20.sol";
import {LobsterOpValidator as OpValidator} from "../../src/Validator/OpValidator.sol";
import {MockPositionsManager} from "../Mocks/MockPositionsManager.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {Counter} from "../Mocks/Counter.sol";
import {VaultTestSetup, RebaseType} from "./VaultTestSetup.sol";

contract VaultMintTest is VaultTestSetup {
    function testWithdraw() public {
        // Setup initial state
        rebaseVault(0, block.number + 1);

        vm.startPrank(alice);
        vault.deposit(10 ether, alice);
        uint256 initialBalance = asset.balanceOf(alice);

        // Withdraw half the assets
        vault.withdraw(5 ether, alice, alice);

        assertEq(vault.balanceOf(alice), 5 ether);
        assertEq(asset.balanceOf(alice), initialBalance + 5 ether);
        assertEq(vault.totalAssets(), 5 ether);
        vm.stopPrank();
    }

    // Should revert if rebase is too old
    function testWithdrawAfterLimit() public {
        rebaseVault(0, block.number + 1);

        vm.startPrank(alice);
        vault.deposit(10 ether, alice);
        vm.roll(vault.rebaseExpiresAt() + 1);

        vm.expectRevert(LobsterVault.RebaseExpired.selector);
        vault.withdraw(5 ether, alice, alice);
        vm.stopPrank();
    }

    function testWithdrawWithRebaseStableValueOnL3() public {
        // Initial setup
        vm.startPrank(alice);
        uint256 initialDeposit = 10 ether;
        vault.depositWithRebase(
            initialDeposit,
            alice,
            getValidRebaseData(
                address(vault),
                0,
                block.number + 1,
                0,
                RebaseType.DEPOSIT,
                new bytes(0)
            )
        );
        vm.stopPrank();

        uint256 bridgeAmount = 5 ether;
        bridge(bridgeAmount, address(1));

        // Withdraw with rebase data
        vm.startPrank(alice);
        uint256 initialAliceBalance = asset.balanceOf(alice);
        uint256 initialAliceShares = vault.balanceOf(alice);
        uint256 withdrawAmount = 5 ether;

        uint256 shares = vault.withdrawWithRebase(
            withdrawAmount,
            alice,
            alice,
            getValidRebaseData(
                address(vault),
                bridgeAmount,
                block.number + 3,
                withdrawAmount, // min amount = withdraw amount here (don't expect slippage)
                RebaseType.WITHDRAW,
                new bytes(0)
            )
        );

        assertEq(vault.totalAssets(), initialDeposit - withdrawAmount);
        assertEq(asset.balanceOf(alice), initialAliceBalance + withdrawAmount);
        assertEq(vault.balanceOf(alice), initialAliceShares - shares);
        assertEq(vault.maxWithdraw(alice), initialDeposit - withdrawAmount);

        vm.stopPrank();
    }

    function testWithdrawWithRebaseWithL3ValueIncrease() public {
        // Initial setup
        vm.startPrank(alice);
        uint256 initialDeposit = 10 ether;
        vault.depositWithRebase(
            initialDeposit,
            alice,
            getValidRebaseData(
                address(vault),
                0,
                block.number + 1,
                0,
                RebaseType.DEPOSIT,
                new bytes(0)
            )
        );
        vm.stopPrank();

        uint256 bridgeAmount = 5 ether;

        bridge(bridgeAmount, address(1));

        // Withdraw with rebase data
        vm.startPrank(alice);
        uint256 initialBalance = asset.balanceOf(alice);
        uint256 withdrawAmount = 5 ether;
        uint256 updatedBridgeAmount = bridgeAmount * 2; // value on L3 doubled

        vault.withdrawWithRebase(
            withdrawAmount,
            alice,
            alice,
            getValidRebaseData(
                address(vault),
                updatedBridgeAmount,
                block.number + 3,
                withdrawAmount, // min amount = withdraw amount here (don't expect slippage)
                RebaseType.WITHDRAW,
                new bytes(0)
            )
        );

        assertEq(asset.balanceOf(alice), initialBalance + withdrawAmount);
        assertEq(
            vault.totalAssets(),
            initialDeposit - bridgeAmount + updatedBridgeAmount - withdrawAmount
        );
        assertEq(
            vault.maxWithdraw(alice),
            initialDeposit -
                bridgeAmount +
                updatedBridgeAmount -
                withdrawAmount -
                1
        ); // 1 less because of floating point precision

        vm.stopPrank();
    }

    function testWithdrawWithRebaseMinAmountNotMet() public {
        // Initial setup with 10 ETH deposit
        vm.startPrank(alice);
        uint256 initialDeposit = 10 ether;
        vault.depositWithRebase(
            initialDeposit,
            alice,
            getValidRebaseData(
                address(vault),
                0,
                block.number + 1,
                0,
                RebaseType.DEPOSIT,
                new bytes(0)
            )
        );

        // Bridge out most assets, leaving less than minAmount
        uint256 bridgedAmount = 9 ether;
        bridge(bridgedAmount, address(1));

        // Try to withdraw with high minAmount requirement
        vm.startPrank(alice);
        uint256 withdrawnAmount = 5 ether;
        vm.expectRevert(LobsterVault.NotEnoughAssets.selector);
        vault.withdrawWithRebase(
            withdrawnAmount,
            alice,
            alice,
            getValidRebaseData(
                address(vault),
                bridgedAmount,
                block.number + 2,
                2 ether, // min amount higher than available balance
                RebaseType.WITHDRAW,
                new bytes(0) // suppose whatever we do here, there are not enough funds in the current chain to withdraw
            )
        );
        vm.stopPrank();
    }

    function testWithdrawWithRebasePartialWithdraw() public {
        // todo: rename variables
        // Initial setup
        vm.startPrank(alice);
        uint256 aliceInitialAssets = asset.balanceOf(alice);
        uint256 initialDeposit = 9.2 ether;
        uint256 mintedShares = vault.depositWithRebase(
            initialDeposit,
            alice,
            getValidRebaseData(
                address(vault),
                0,
                block.number + 1,
                0,
                RebaseType.MINT,
                new bytes(0)
            )
        );
        // Bridge some assets
        uint256 bridgedAmount = initialDeposit / 30;
        bridge(bridgedAmount, address(1));
        rebaseVault(bridgedAmount, 2);

        uint256 computedAssetsInVault = initialDeposit - bridgedAmount;

        // Try to redeem more than local balance but accept partial redeem
        vm.startPrank(alice);
        uint256 tooMuchAssetsToRedeem = computedAssetsInVault + 1;
        uint256 tooMuchAssetsToRedeemShares = vault.previewRedeem(
            tooMuchAssetsToRedeem
        );
        uint256 minAssetToRetrieve = computedAssetsInVault - 1; // so we expect to retrieve computedAssetsInVault

        uint256 redeemedAssets = vault.withdrawWithRebase(
            tooMuchAssetsToRedeem, // Try to redeem more eth than available locally
            alice,
            alice,
            getValidRebaseData(
                address(vault),
                bridgedAmount,
                block.number + 3,
                minAssetToRetrieve, // min amount <= available balance
                RebaseType.REDEEM,
                new bytes(0)
            )
        );
        // ensure params have the correct caracteristics
        assertEq(true, redeemedAssets >= minAssetToRetrieve);
        assertEq(true, tooMuchAssetsToRedeem > redeemedAssets);
        assertEq(redeemedAssets, computedAssetsInVault);
        vm.stopPrank();

        assertEq(
            vault.balanceOf(alice),
            mintedShares - tooMuchAssetsToRedeemShares
        );
        assertEq(
            asset.balanceOf(alice),
            aliceInitialAssets - initialDeposit + redeemedAssets
        );
        assertEq(vault.totalAssets(), initialDeposit - redeemedAssets);
        assertEq(
            vault.maxWithdraw(alice),
            initialDeposit - tooMuchAssetsToRedeem
        );
    }

    function testWithdrawWithoutDeposit() public {
        // Setup initial state
        rebaseVault(0, block.number + 1);
        // random user deposit
        vm.startPrank(alice);
        vault.mint(10 ether, alice);
        vm.stopPrank();

        // bob tries to redeem without deposit
        vm.startPrank(bob);
        uint256 withdrawnAmount = 5 ether;
        vm.expectRevert(
            abi.encodeWithSelector(
                ERC4626.ERC4626ExceededMaxWithdraw.selector,
                bob,
                withdrawnAmount,
                vault.maxWithdraw(bob)
            )
        );
        vault.withdraw(withdrawnAmount, bob, bob);
        vm.stopPrank();
    }

    function testWithdrawWithSmallerDeposit() public {
        // Setup initial state
        rebaseVault(0, block.number + 1);
        // random user deposit
        vm.startPrank(alice);
        vault.mint(10 ether, alice);
        vm.stopPrank();

        // bob tries to redeem without deposit
        vm.startPrank(bob);
        uint256 depositAmount = 2 ether;
        vault.deposit(depositAmount, bob);
        uint256 withdrawnAmount = 5 ether;
        assertGt(withdrawnAmount, depositAmount);
        vm.expectRevert(
            abi.encodeWithSelector(
                ERC4626.ERC4626ExceededMaxWithdraw.selector,
                bob,
                withdrawnAmount,
                vault.maxWithdraw(bob)
            )
        );
        vault.withdraw(withdrawnAmount, bob, bob);
        vm.stopPrank();
    }
}

