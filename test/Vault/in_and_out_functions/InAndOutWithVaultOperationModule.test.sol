// SPDX-License-Identifier: GNU AGPL v3.0
pragma solidity ^0.8.28;

import {VaultWithOperationModuleTestSetup} from "../VaultSetups/WithDummyModules/VaultWithOperationModuleTestSetup.sol";
import {DummyVaultFlow, ACCEPTED_CALLER, PANIC_CALLER} from "../../Mocks/modules/DummyVaultFlow.sol";
import {Modular} from "../../../src/Modules/Modular.sol";

contract InAndOutWithVaultOperationModule is VaultWithOperationModuleTestSetup {
    /* ------------------DEPOSIT------------------ */
    function testCustomDeposit() public {
        vm.startPrank(ACCEPTED_CALLER);

        uint256 assets = 1 ether;
        uint256 shares = vault.convertToShares(assets);
        address receiver = makeAddr("some receiver");

        // expect a 'DepositHasBeenCalled' event
        vm.expectEmit(true, true, true, true);

        // Emit the same event with the expected values
        emit DummyVaultFlow.DepositHasBeenCalled(ACCEPTED_CALLER, receiver, assets, shares);

        vault.deposit(assets, receiver);

        vm.stopPrank();
    }

    function testRevertedCustomDeposit() public {
        vm.startPrank(PANIC_CALLER);

        uint256 assets = 1 ether;
        address receiver = makeAddr("some receiver");

        // expect a 'DepositHasBeenCalled' event
        vm.expectRevert(Modular.DepositModuleFailed.selector);
        vault.deposit(assets, receiver);

        vm.stopPrank();
    }

    /* ------------------MINT------------------ */
    function testCustomMint() public {
        vm.startPrank(ACCEPTED_CALLER);

        uint256 assets = 1 ether;
        uint256 shares = vault.convertToShares(assets);
        address receiver = makeAddr("some receiver");

        // expect a 'DepositHasBeenCalled' event
        vm.expectEmit(true, true, true, true);

        // Emit the same event with the expected values
        emit DummyVaultFlow.DepositHasBeenCalled(ACCEPTED_CALLER, receiver, assets, shares);

        vault.mint(shares, receiver);

        vm.stopPrank();
    }

    function testRevertedCustomMint() public {
        vm.startPrank(PANIC_CALLER);

        uint256 shares = 1 ether;
        address receiver = makeAddr("some receiver");

        // expect a 'DepositHasBeenCalled' event
        vm.expectRevert(Modular.DepositModuleFailed.selector);
        vault.mint(shares, receiver);

        vm.stopPrank();
    }

    /* ------------------WITHDRAW------------------ */
    function testCustomWithdraw() public {
        vm.startPrank(ACCEPTED_CALLER);

        uint256 assets = 0;
        uint256 shares = vault.convertToShares(assets);
        address receiver = makeAddr("some receiver");

        // expect a 'DepositHasBeenCalled' event
        vm.expectEmit(true, true, true, true);

        // Emit the same event with the expected values
        emit DummyVaultFlow.WithdrawHasBeenCalled(ACCEPTED_CALLER, receiver, ACCEPTED_CALLER, assets, shares);

        vault.withdraw(assets, receiver, ACCEPTED_CALLER);

        vm.stopPrank();
    }

    function testRevertedCustomWithdraw() public {
        vm.startPrank(ACCEPTED_CALLER);

        uint256 assets = 0;
        uint256 shares = vault.convertToShares(assets);
        address receiver = makeAddr("some receiver");

        // expect a 'DepositHasBeenCalled' event
        vm.expectEmit(true, true, true, true);

        // Emit the same event with the expected values
        emit DummyVaultFlow.WithdrawHasBeenCalled(ACCEPTED_CALLER, receiver, ACCEPTED_CALLER, assets, shares);

        vault.withdraw(shares, receiver, ACCEPTED_CALLER);

        vm.stopPrank();
    }

    /* ------------------REDEEM------------------ */
    function testCustomRedeem() public {
        vm.startPrank(ACCEPTED_CALLER);

        uint256 assets = 0;
        uint256 shares = vault.convertToShares(assets);
        address receiver = makeAddr("some receiver");

        // expect a 'DepositHasBeenCalled' event
        vm.expectEmit(true, true, true, true);

        // Emit the same event with the expected values
        emit DummyVaultFlow.WithdrawHasBeenCalled(ACCEPTED_CALLER, receiver, ACCEPTED_CALLER, assets, shares);

        vault.redeem(shares, receiver, ACCEPTED_CALLER);

        vm.stopPrank();
    }

    function testRevertedCustomRedeem() public {
        vm.startPrank(ACCEPTED_CALLER);

        uint256 assets = 0;
        uint256 shares = vault.convertToShares(assets);
        address receiver = makeAddr("some receiver");

        // expect a 'WithdrawHasBeenCalled' event
        vm.expectEmit(true, true, true, true);

        // Emit the same event with the expected values
        emit DummyVaultFlow.WithdrawHasBeenCalled(ACCEPTED_CALLER, receiver, ACCEPTED_CALLER, assets, shares);

        vault.redeem(assets, receiver, ACCEPTED_CALLER);

        vm.stopPrank();
    }
}
