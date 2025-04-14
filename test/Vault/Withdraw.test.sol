// SPDX-License-Identifier: GNU AGPL v3.0
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import {VaultTestSetup} from "./VaultTestSetup.sol";

contract VaultMintTest is VaultTestSetup {
    /* -----------------------WITHDRAW---------------------- */
    function testWithdraw() public {
        // Setup initial state
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

    /* -----------------------MAX WITHDRAW----------------------- */
    // todo
    /* -----------------------PREVIEW WITHDRAW----------------------- */
    // todo
}
