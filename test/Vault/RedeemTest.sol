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

contract VaultRedeemTest is VaultTestSetup {
    function testRedeem() public {
        // Setup initial state
        rebaseVault(0, block.number + 1);
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

    // Should revert if rebase is too old
    function testRedeemAfterLimit() public {
        rebaseVault(0, block.number + 1);

        vm.startPrank(alice);
        vault.mint(10 ether, alice);
        vm.roll(vault.rebaseExpiresAt() + 1);

        vm.expectRevert(LobsterVault.RebaseExpired.selector);
        vault.redeem(5 ether, alice, alice);
        vm.stopPrank();
    }

    function testRedeemWithRebaseStableValueOnL3() public {
        // Initial setup
        vm.startPrank(alice);
        uint256 initialMint = 10 ether;
        vault.mintWithRebase(
            initialMint,
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
        vm.stopPrank();

        uint256 bridgeAmount = 5 ether;
        bridge(bridgeAmount, address(1));

        // Withdraw with rebase data
        vm.startPrank(alice);
        uint256 initialAliceBalance = asset.balanceOf(alice);
        uint256 initialAliceShares = vault.balanceOf(alice);
        uint256 withdrawAmount = 5 ether;

        uint256 shares = vault.redeemWithRebase(
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

        assertEq(vault.totalAssets(), initialMint - withdrawAmount);
        assertEq(asset.balanceOf(alice), initialAliceBalance + withdrawAmount);
        assertEq(vault.balanceOf(alice), initialAliceShares - shares);
        assertEq(vault.maxWithdraw(alice), initialMint - withdrawAmount);

        vm.stopPrank();
    }

    function testRedeemWithRebaseWithL3ValueIncrease() public {
        // Initial setup
        vm.startPrank(alice);
        uint256 initialMint = 100 ether;
        vault.mintWithRebase(
            initialMint,
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
        vm.stopPrank();

        uint256 bridgeAmount = 5 ether;
        bridge(bridgeAmount, address(1));

        // redeem with rebase data
        vm.startPrank(alice);
        uint256 initialAssetBalance = asset.balanceOf(alice);

        uint256 updatedBridgeAmount = bridgeAmount * 2; // value on L3 doubled
        rebaseVault(updatedBridgeAmount, 2);
        uint256 redeemAmount = 10 ether; // redeem 5 ether shares

        uint256 expectedValueToBeTransferredToAlice = vault.convertToAssets(
            redeemAmount
        );

        vm.startPrank(alice);
        vault.redeemWithRebase(
            redeemAmount,
            alice,
            alice,
            getValidRebaseData(
                address(vault),
                updatedBridgeAmount,
                block.number + 3,
                expectedValueToBeTransferredToAlice, // min amount = redeem amount here (don't expect slippage)
                RebaseType.REDEEM,
                new bytes(0)
            )
        );
        vm.stopPrank();

        assertEq(
            asset.balanceOf(alice),
            initialAssetBalance + expectedValueToBeTransferredToAlice
        );
        assertEq(vault.totalSupply(), initialMint - redeemAmount);
        assertEq(vault.maxRedeem(alice), initialMint - redeemAmount); // alice owns all the shares

        vm.stopPrank();
    }

    function testRedeemWithRebaseMinAmountNotMet() public {
        // Initial setup with 10 ETH mint
        vm.startPrank(alice);
        uint256 initialMint = 10 ether;
        vault.mintWithRebase(
            initialMint,
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
        // Bridge out most assets, leaving less than minAmount
        uint256 bridgedAmount = 9 ether;
        bridge(bridgedAmount, address(1));
        // Try to redeem with high minAmount requirement
        vm.startPrank(alice);
        uint256 redeemAmount = 5 ether;
        vm.expectRevert(LobsterVault.NotEnoughAssets.selector);
        vault.redeemWithRebase(
            redeemAmount,
            alice,
            alice,
            getValidRebaseData(
                address(vault),
                bridgedAmount,
                block.number + 2,
                2 ether, // min amount higher than available balance
                RebaseType.REDEEM,
                new bytes(0) // suppose whatever we do here, there are not enough funds in the current chain to redeem
            )
        );
        vm.stopPrank();
    }

    function testRedeemWithRebasePartialRedeem() public {
        // Initial setup
        vm.startPrank(alice);
        uint256 aliceInitialAssets = asset.balanceOf(alice);
        uint256 initialMint = 9.2 ether;
        uint256 mintedAssets = vault.mintWithRebase(
            initialMint,
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
        uint256 bridgedAmount = mintedAssets / 30;
        bridge(bridgedAmount, address(1));
        rebaseVault(bridgedAmount, 2);

        uint256 computedAssetsInVault = mintedAssets - bridgedAmount;

        uint256 sharesToRedeem = vault.convertToShares(computedAssetsInVault);

        // Try to redeem more than local balance but accept partial redeem
        vm.startPrank(alice);
        uint256 tooMuchSharesToRedeem = sharesToRedeem + 1;
        uint256 minAssetToRetrieve = vault.convertToAssets(sharesToRedeem);

        uint256 redeemedAssets = vault.redeemWithRebase(
            tooMuchSharesToRedeem, // Try to redeem more eth than available locally
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
        assertEq(true, tooMuchSharesToRedeem > redeemedAssets);
        vm.stopPrank();

        assertEq(vault.balanceOf(alice), initialMint - tooMuchSharesToRedeem);
        assertEq(
            asset.balanceOf(alice),
            aliceInitialAssets - mintedAssets + redeemedAssets
        );
        assertEq(vault.totalAssets(), mintedAssets - redeemedAssets);
        assertEq(vault.maxRedeem(alice), initialMint - tooMuchSharesToRedeem);
    }

    function testRedeemWithoutDeposit() public {
        // Setup initial state
        rebaseVault(0, block.number + 1);
        // random user deposit
        vm.startPrank(alice);
        vault.mint(10 ether, alice);
        vm.stopPrank();

        // bob tries to redeem without deposit
        vm.startPrank(bob);
        uint256 redeemedAmount = 5 ether;
        vm.expectRevert(
            abi.encodeWithSelector(
                ERC4626.ERC4626ExceededMaxRedeem.selector,
                address(0x1D96F2f6BeF1202E4Ce1Ff6Dad0c2CB002861d3e),
                redeemedAmount,
                vault.maxRedeem(bob)
            )
        );
        vault.redeem(redeemedAmount, bob, bob);
        vm.stopPrank();
    }

    function testRedeemWithSmallerDeposit() public {
        // Setup initial state
        rebaseVault(0, block.number + 1);
        // random user deposit
        vm.startPrank(alice);
        vault.mint(10 ether, alice);
        vm.stopPrank();

        // bob tries to redeem without deposit
        vm.startPrank(bob);
        uint256 mintAmount = 2 ether;
        vault.mint(mintAmount, bob);
        uint256 redeemedAmount = 5 ether;
        assertGt(redeemedAmount, mintAmount);
        vm.expectRevert(
            abi.encodeWithSelector(
                ERC4626.ERC4626ExceededMaxRedeem.selector,
                address(0x1D96F2f6BeF1202E4Ce1Ff6Dad0c2CB002861d3e),
                redeemedAmount,
                vault.maxRedeem(bob)
            )
        );
        vault.redeem(redeemedAmount, bob, bob);
        vm.stopPrank();
    }
}
