// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {PendingFeeUpdate} from "../../src/Vault/ERC4626Fees.sol";
import {VaultTestSetup} from "./VaultTestSetup.sol";
import {ERC4626Fees, IERC4626FeesEvents} from "../../src/Vault/ERC4626Fees.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {BASIS_POINT_SCALE} from "../../src/Vault/Constants.sol";

// test deposit / withdraw / mint / redeem fee
contract VaultInAndOutFeesTest is VaultTestSetup {
    using Math for uint256;

    // the default fee is set to 0
    /* -----------------------TEST UPDATING ENTRY / EXIT FEE----------------------- */
    // todo
    /* -----------------------TEST DEPOSIT / MINT / WITHDRAW / REDEEM----------------------- */
    function testDepositWithFee() public {
        // rebase to 0
        rebaseVault(0, block.number + 1);

        uint256 fee = 100;
        setEntryFeeBasisPoint(fee); // 1%

        // alice deposit 1000 assets
        vm.startPrank(alice);
        uint256 initialAliceBalance = asset.balanceOf(alice);
        uint256 initialFeeCollectorBalance = asset.balanceOf(
            vault.feeCollector()
        );

        uint256 depositAmount = 1000;
        uint256 expectedFee = computeFees(depositAmount, fee);
        uint256 shares = vault.deposit(depositAmount, alice);
        vm.stopPrank();

        // check alice asset balance
        assertEq(asset.balanceOf(alice), initialAliceBalance - depositAmount);

        // check vault balance
        assertEq(asset.balanceOf(address(vault)), depositAmount);

        // ensure `shares`is the amount of shares minted to alice
        assertEq(shares, vault.balanceOf(alice));

        // check fee collector asset balance did not change
        assertEq(
            asset.balanceOf(vault.feeCollector()),
            initialFeeCollectorBalance
        );

        // check fee collector shares balance
        assertEq(vault.balanceOf(vault.feeCollector()), expectedFee);
    }

    function testMintWithFee() public {
        // rebase to 0
        rebaseVault(0, block.number + 1);

        uint256 fee = 100;
        setEntryFeeBasisPoint(fee); // 1%

        // alice mint 1000 shares
        vm.startPrank(alice);
        uint256 initialAliceBalance = asset.balanceOf(alice);
        uint256 initialFeeCollectorBalance = asset.balanceOf(
            vault.feeCollector()
        );

        uint256 mintAmount = 1000;
        uint256 expectedFee = computeFees(mintAmount, fee);
        uint256 assets = vault.mint(mintAmount, alice);
        vm.stopPrank();

        // check alice asset balance
        assertEq(asset.balanceOf(alice), initialAliceBalance - assets);

        // check vault balance: ensure `assets`is the amount of assets sent to the vault
        assertEq(asset.balanceOf(address(vault)), assets);

        // ensure alice minted the expected amount of shares
        assertEq(vault.balanceOf(alice), mintAmount);

        // check fee collector asset balance did not change
        assertEq(
            asset.balanceOf(vault.feeCollector()),
            initialFeeCollectorBalance
        );

        // check fee collector shares balance
        assertEq(vault.balanceOf(vault.feeCollector()), expectedFee);
    }

    function testWithdrawWithFee() public {
        // rebase to 0
        rebaseVault(0, block.number + 1);

        uint256 fee = 100;
        setExitFeeBasisPoint(fee); // 1%

        vm.startPrank(alice);
        // alice deposit 1000 assets
        uint256 initialAliceBalance = asset.balanceOf(alice);
        uint256 initialFeeCollectorBalance = asset.balanceOf(
            vault.feeCollector()
        );

        uint256 depositAmount = 1000;
        uint256 expectedFee = computeFees(depositAmount, fee);
        uint256 shares = vault.deposit(depositAmount, alice);

        // alice withdraw all her assets
        uint256 withdrawnAssets = vault.maxWithdraw(alice);
        uint256 sharesBurnt = vault.withdraw(withdrawnAssets, alice, alice); // actually a part of these is not burnt but send to fee collector
        vm.stopPrank();

        // check alice asset balance
        assertEq(asset.balanceOf(alice), initialAliceBalance - expectedFee);

        // check vault balance
        assertEq(asset.balanceOf(address(vault)), expectedFee); // (vault has been emptied, there is only the collected fees)

        // ensure `shares`is the amount of shares burnt by alice
        assertEq(sharesBurnt, shares);

        // ensure alice does not have any shares left
        assertEq(vault.balanceOf(alice), 0);

        // check fee collector asset balance did not change
        assertEq(
            asset.balanceOf(vault.feeCollector()),
            initialFeeCollectorBalance
        );

        // check fee collector shares balance
        assertEq(vault.balanceOf(vault.feeCollector()), expectedFee);
    }

    function testRedeemWithFee() public {
        // rebase to 0
        rebaseVault(0, block.number + 1);

        uint256 fee = 100;
        setExitFeeBasisPoint(fee); // 1%

        vm.startPrank(alice);
        // alice deposit 1000 assets
        uint256 initialAliceBalance = asset.balanceOf(alice);
        uint256 initialFeeCollectorBalance = asset.balanceOf(
            vault.feeCollector()
        );

        uint256 mintAmount = 1000;
        uint256 expectedFee = computeFees(mintAmount, fee);
        uint256 assets = vault.mint(mintAmount, alice);

        // alice withdraw all her assets
        uint256 withdrawnAssets = vault.maxRedeem(alice);
        uint256 assetsRedeemed = vault.redeem(withdrawnAssets, alice, alice); // assetsRedeemed = alice assets in vault before redeem
        vm.stopPrank();

        // check alice asset balance
        assertEq(
            asset.balanceOf(alice),
            initialAliceBalance - vault.convertToAssets(expectedFee)
        );

        // check vault balance
        assertEq(asset.balanceOf(address(vault)), expectedFee); // (vault has been emptied, there is only the collected fees)

        // ensure alice does not have any shares left
        assertEq(vault.balanceOf(alice), 0);

        // ensure `assetsRedeemed` is actually the amount of assets redeemed by alice
        assertEq(assetsRedeemed, assets - vault.convertToAssets(expectedFee));

        // check fee collector asset balance did not change
        assertEq(
            asset.balanceOf(vault.feeCollector()),
            initialFeeCollectorBalance
        );

        // check fee collector shares balance
        assertEq(vault.balanceOf(vault.feeCollector()), expectedFee);
    }

    /* -----------------------TEST IN & OUT AS FEE_COLLECTOR----------------------- */
    // no fees for the feeCollector withdrawals
    // todo
}
