// SPDX-License-Identifier: GNU AGPL v3.0
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import {VaultTestSetup} from "./VaultTestSetup.sol";

contract VaultRedeemTest is VaultTestSetup {
    /* -----------------------REDEEM----------------------- */

    function testRedeem() public {
        // Setup initial state
        vm.startPrank(alice);
        vault.mint(10 ether, alice);
        uint256 initialBalance = asset.balanceOf(alice);
        // Withdraw half the assets
        vault.redeem(5 ether, alice, alice);
        assertEq(vault.balanceOf(alice), 5 ether);
        assertEq(asset.balanceOf(alice), initialBalance + 5 ether);
        assertEq(vault.totalAssets(), 5 ether);
        assertEq(vault.maxRedeem(alice), 5 ether);
        assertEq(vault.totalSupply(), 5 ether);
        vm.stopPrank();
    }
    /* -----------------------MAX REDEEM----------------------- */
    // todo
    /* -----------------------PREVIEW REDEEM----------------------- */
    // todo
}
