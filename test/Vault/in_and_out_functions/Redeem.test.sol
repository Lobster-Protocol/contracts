// SPDX-License-Identifier: GNU AGPL v3.0
pragma solidity ^0.8.28;

import {SimpleVaultTestSetup} from "../VaultSetups/SimpleVaultTestSetup.sol";

contract VaultRedeemTest is SimpleVaultTestSetup {
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
    function testPreviewRedeemNoFee() public view {
        // deposit 1000
        uint256 sharesToRedeem = 1000;
        uint256 assets = vault.previewRedeem(sharesToRedeem);

        // at first, 1 share = 1 asset
        assertEq(assets, sharesToRedeem);
    }
}
