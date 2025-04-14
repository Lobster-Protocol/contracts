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
    function testMint() public {
        rebaseVault(0, block.number + 1);

        vm.startPrank(alice);
        uint256 previewedAssets = vault.previewMint(1 ether);
        vault.mint(1 ether, alice);
        assertEq(vault.balanceOf(alice), 1 ether);
        assertEq(asset.balanceOf(address(vault)), previewedAssets);
        vm.stopPrank();
    }

    // Should revert if rebase is too old (> MAX_DEPOSIT_DELAY)
    function testMintAfterLimit() public {
        rebaseVault(10, block.number + 1);

        vm.roll(vault.rebaseExpiresAt() + 1);

        vm.startPrank(alice);
        vm.expectRevert(LobsterVault.RebaseExpired.selector);
        vault.mint(1 ether, alice);
        vm.stopPrank();
    }

    // multiple mints
    function testMultipleMints() public {
        rebaseVault(0, 1);

        // alice mints 100.33 shares
        vm.startPrank(alice);
        vault.mint(100.33 ether, alice);
        vm.assertEq(vault.maxWithdraw(alice), 100.33 ether);
        vm.stopPrank();

        // lobster algorithm bridges 100 eth to the other chain
        vm.startPrank(lobsterAlgorithm);

        // remove 100 eth from the vault balance (like if they were bridged to the other chain)
        vault.executeOp(
            Op({
                target: address(asset),
                value: 0,
                data: abi.encodeWithSignature(
                    "transfer(address,uint256)",
                    address(1),
                    100 ether
                )
            })
        );
        vm.stopPrank();

        // save the new total assets in l3
        rebaseVault(100 ether, 2);

        // bob mints 1 and 2 shares
        vm.startPrank(bob);
        vault.mint(1 ether, bob);
        vm.assertEq(vault.maxWithdraw(bob), 1 ether);

        vault.mint(2 ether, bob);
        vm.assertEq(vault.maxWithdraw(bob), 3 ether);
        vm.stopPrank();

        vm.assertEq(vault.totalAssets(), 103.33 ether);
        vm.assertEq(vault.localTotalAssets(), 3.33 ether);
    }

    function testMintWithRebaseZeroAmount() public {
        vm.startPrank(alice);
        vault.mintWithRebase(
            0,
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
        assertEq(vault.balanceOf(alice), 0);
        assertEq(vault.totalAssets(), 0);
        vm.stopPrank();
    }

    function testMintWithRebaseInvalidReceiver() public {
        vm.startPrank(alice);
        vm.expectRevert();
        vault.mintWithRebase(
            1 ether,
            address(0),
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
    }

    function testMintWithRebaseExpiredSignature() public {
        vm.startPrank(alice);
        bytes memory rebaseData = getValidRebaseData(
            address(vault),
            0,
            block.number,
            0,
            RebaseType.DEPOSIT,
            new bytes(0)
        );
        vm.roll(block.number + 2);
        vm.expectRevert();
        vault.mintWithRebase(1 ether, alice, rebaseData);
        vm.stopPrank();
    }

    /* -----------------------MINT WITHOUT REBASE----------------------- */
    function testMintWithoutRebase() public {
        rebaseVault(0, block.number + 1);

        // wait for rebase expiration
        vm.roll(vault.rebaseExpiresAt() + 1);

        vm.startPrank(alice);
        vm.expectRevert(LobsterVault.RebaseExpired.selector);
        vault.mint(1 ether, alice);
        vm.stopPrank();
    }

    /* -----------------------MINT WITH REBASE----------------------- */
    function testMintWithRebase() public {
        // no rebase yet
        vm.startPrank(alice);
        uint256 initialBalance = asset.balanceOf(alice);
        uint256 sharesToMint = 1 ether;
        uint256 assets = vault.mintWithRebase(
            sharesToMint,
            alice,
            getValidRebaseData(
                address(vault),
                0 ether,
                block.number + 1,
                0,
                RebaseType.DEPOSIT,
                new bytes(0)
            )
        );
        assertEq(vault.balanceOf(alice), sharesToMint);
        assertEq(asset.balanceOf(alice), initialBalance - assets);
        vm.stopPrank();
    }

    function testMintWithRebasePreviewAccuracy() public {
        vm.startPrank(alice);
        uint256 sharesToMint = 1 ether;
        uint256 previewedAssets = vault.previewMint(sharesToMint);
        uint256 actualAssets = vault.mintWithRebase(
            sharesToMint,
            alice,
            getValidRebaseData(
                address(vault),
                0 ether,
                block.number + 1,
                0,
                RebaseType.DEPOSIT,
                new bytes(0)
            )
        );
        assertEq(
            previewedAssets,
            actualAssets,
            "Preview mint should match actual mint"
        );
        vm.stopPrank();
    }

    function testMintWithRebaseAfterBridge() public {
        // Initial mint
        vm.startPrank(alice);
        vault.mintWithRebase(
            5 ether,
            alice,
            getValidRebaseData(
                address(vault),
                0 ether,
                block.number + 1,
                0,
                RebaseType.DEPOSIT,
                new bytes(0)
            )
        );
        vm.stopPrank();

        // Bridge simulation
        vm.startPrank(lobsterAlgorithm);
        vault.executeOp(
            Op({
                target: address(asset),
                value: 0,
                data: abi.encodeWithSignature(
                    "transfer(address,uint256)",
                    address(1),
                    2 ether
                )
            })
        );
        vm.stopPrank();

        // Update rebase value
        rebaseVault(2 ether, 2);

        // New mint after bridge
        vm.startPrank(bob);
        uint256 mintAmount = 1 ether;
        uint256 previewedAssets = vault.previewMint(mintAmount);
        uint256 actualAssets = vault.mintWithRebase(
            mintAmount,
            bob,
            getValidRebaseData(
                address(vault),
                2 ether,
                block.number + 3,
                0,
                RebaseType.DEPOSIT,
                new bytes(0)
            )
        );
        assertEq(previewedAssets, actualAssets);
        assertEq(vault.balanceOf(bob), mintAmount);
        vm.stopPrank();
    }
}
