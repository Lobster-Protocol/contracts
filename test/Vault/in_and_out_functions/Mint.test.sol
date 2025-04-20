// SPDX-License-Identifier: GNU AGPL v3.0
pragma solidity ^0.8.28;

import {SimpleVaultTestSetup} from "../VaultSetups/SimpleVaultTestSetup.sol";

contract VaultMintTest is SimpleVaultTestSetup {
    /* -----------------------MINT----------------------- */

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

        vm.assertEq(vault.totalAssets(), aliceMint + bobMint + bobSecondDeposit);
    }

    /* -----------------------MAX MINT----------------------- */
    // todo
    /* -----------------------PREVIEW MINT----------------------- */
    function testPreviewMintNoFee() public view {
        // deposit 1000
        uint256 mintAmount = 1000;
        uint256 assets = vault.previewMint(mintAmount);

        // at first, 1 share = 1 asset
        assertEq(assets, mintAmount);
    }

    function testPreviewMintFee() public {
        uint256 entryFeeBasisPoints = 100; // 1%
        setEntryFeeBasisPoint(entryFeeBasisPoints);

        // deposit 1000
        uint256 mintAmount = 1000;
        uint256 expectedFee = computeFees(mintAmount, entryFeeBasisPoints);
        uint256 assets = vault.previewMint(mintAmount);

        // at first, 1 share = 1 asset, assets = mintAmount + expectedFee (we send the amount of shares to get how many assets we must send to get (+ fees))
        assertEq(assets, mintAmount + expectedFee);
    }
}
