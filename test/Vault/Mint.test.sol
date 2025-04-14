// SPDX-License-Identifier: GNU AGPL v3.0
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import {VaultTestSetup} from "./VaultTestSetup.sol";

contract VaultMintTest is VaultTestSetup {
    function testMint() public {
        vm.startPrank(alice);
        uint256 previewedAssets = vault.previewMint(1 ether);
        vault.mint(1 ether, alice);
        assertEq(vault.balanceOf(alice), 1 ether);
        assertEq(asset.balanceOf(address(vault)), previewedAssets);
        vm.stopPrank();
    }

    // multiple mints
    function testMultipleMints() public {
        uint256 aliceMint = 100.33 ether;
        uint256 bobMint = 1 ether;
        uint256 bobSecondDeposit = aliceMint + bobMint;

        // alice deposits
        vm.startPrank(alice);
        vault.deposit(aliceMint, alice);
        vm.assertEq(vault.maxRedeem(alice), aliceMint);
        vm.stopPrank();

        // bob deposits 1 and 2 eth
        vm.startPrank(bob);
        vault.deposit(bobMint, bob);

        vm.assertEq(vault.maxRedeem(bob), bobMint);
        vault.deposit(bobSecondDeposit, bob);
        vm.assertEq(vault.maxRedeem(bob), bobMint + bobSecondDeposit);
        vm.stopPrank();

        vm.assertEq(vault.totalAssets(), aliceMint + bobMint+ bobSecondDeposit);
    }
}
