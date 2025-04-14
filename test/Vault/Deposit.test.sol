// SPDX-License-Identifier: GNU AGPL v3.0
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import {VaultTestSetup} from "./VaultTestSetup.sol";


contract VaultDepositTest is VaultTestSetup {
    
    /* -----------------------DEPOSIT----------------------- */
    function testDeposit() public {
        vm.startPrank(alice);
        vault.deposit(1 ether, alice);
        assertEq(vault.balanceOf(alice), 1 ether);
        vm.stopPrank();
    }

    // multiple deposits
    function testMultipleDeposits() public {
        uint256 aliceDeposit = 100.33 ether;
        uint256 bobDeposit = 1 ether;
        uint256 bobSecondDeposit = aliceDeposit + bobDeposit;

        // alice deposits
        vm.startPrank(alice);
        vault.deposit(aliceDeposit, alice);
        vm.assertEq(vault.maxWithdraw(alice), aliceDeposit);
        vm.stopPrank();

        // bob deposits 1 and 2 eth
        vm.startPrank(bob);
        vault.deposit(bobDeposit, bob);

        vm.assertEq(vault.maxWithdraw(bob), bobDeposit);
        vault.deposit(bobSecondDeposit, bob);
        vm.assertEq(vault.maxWithdraw(bob), bobDeposit + bobSecondDeposit);
        vm.stopPrank();

        vm.assertEq(vault.totalAssets(), aliceDeposit + bobDeposit+ bobSecondDeposit);
    }
}