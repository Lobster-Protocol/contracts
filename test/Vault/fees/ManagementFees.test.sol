// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {SimpleVaultTestSetup} from "../VaultSetups/SimpleVaultTestSetup.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

// test deposit / withdraw / mint / redeem functions with management fee
// test collecting management fees manually
contract VaultInAndOutFeesTest is SimpleVaultTestSetup {
    using Math for uint256;

    /* -----------------------TEST UPDATING MANAGEMENT FEE----------------------- */
    // todo
    /* -----------------------TEST MANUAL COLLECTION----------------------- */
    function testCollectFeesAsOwner() public {
        uint256 blockTimestamp = block.timestamp;
        uint16 fee = 100;
        setManagementFeeBasisPoint(fee); // 1%

        // alice deposit 1000 assets
        vm.startPrank(alice);
        uint256 initialFeeCollectorBalance = asset.balanceOf(vault.feeCollector());

        uint256 depositAmount = 1000;
        uint256 shares = vault.deposit(depositAmount, alice);
        vm.stopPrank();

        uint256 duration = 365 days;
        uint256 expectedFee = computeManagementFees(depositAmount, fee, duration);

        // wait for 1 year
        vm.warp(blockTimestamp + duration);

        // collect the fees
        vm.startPrank(owner);
        uint256 collectedFees1 = vault.collectFees();

        // ensure fee collector shares correspond to the collected fees
        assertEq(vault.balanceOf(vault.feeCollector()), expectedFee);

        // ensure alice's shares balance did not change
        assertEq(vault.balanceOf(alice), shares);

        // ensure fee collector asset balance did not change
        assertEq(asset.balanceOf(vault.feeCollector()), initialFeeCollectorBalance);

        // ensure collectedFees1 is accurate
        assertEq(vault.balanceOf(vault.feeCollector()) - initialFeeCollectorBalance, collectedFees1);

        // ensure we can't withdraw again in the same block
        uint256 vaultTotalSupplyBefore = vault.totalSupply();
        uint256 collectedFees2 = vault.collectFees();

        // ensure collectedFees2 is 0
        assertEq(collectedFees2, 0);

        // ensure no shares were minted
        assertEq(vaultTotalSupplyBefore, vault.totalSupply());

        // ensure alice's shares balance did not change
        assertEq(vault.balanceOf(alice), shares);

        // ensure fee collector asset balance did not change
        assertEq(asset.balanceOf(vault.feeCollector()), initialFeeCollectorBalance);

        vm.stopPrank();
    }

    /* -----------------------TEST DEPOSIT / MINT / WITHDRAW / REDEEM----------------------- */
    function testDeposit() public {
        uint256 initialFeeCollectorBalance = asset.balanceOf(vault.feeCollector());

        // alice deposit 1000 assets
        vm.startPrank(alice);
        uint256 depositAmount = 1000;
        uint256 shares = vault.deposit(depositAmount, alice);
        vm.stopPrank();

        uint16 fee = 100;
        setManagementFeeBasisPoint(fee); // 1%

        uint256 feeInforcementTimestamp = block.timestamp;

        uint256 duration = 365 days;
        uint256 expectedFee = computeManagementFees(shares, fee, duration);

        // go 1 year in the future
        vm.warp(feeInforcementTimestamp + duration);

        // bob deposit
        vm.startPrank(bob);
        uint256 bobDeposit = 1000;
        uint256 bobShares = vault.deposit(bobDeposit, bob);
        vm.stopPrank();

        // management fees must have been collected
        assertEq(vault.balanceOf(vault.feeCollector()), initialFeeCollectorBalance + expectedFee);

        // ensure no assets where moved out of the vault
        assertEq(asset.balanceOf(address(vault)), depositAmount + bobDeposit);

        // ensure alice can withdraw her deposit - fee
        assertEq(vault.maxWithdraw(alice), vault.convertToAssets(shares));

        // ensure bob can withdraw his deposit
        assertEq(vault.maxWithdraw(bob), vault.convertToAssets(bobShares));

        // ensure alice shares did not change
        assertEq(vault.balanceOf(alice), shares);
    }

    function testMint() public {
        uint256 initialFeeCollectorBalance = asset.balanceOf(vault.feeCollector());

        // alice mint 1000 shares
        vm.startPrank(alice);
        uint256 mintAmount = 1000;
        uint256 assets = vault.mint(mintAmount, alice);
        vm.stopPrank();

        uint16 fee = 100;
        setManagementFeeBasisPoint(fee); // 1%

        uint256 feeInforcementTimestamp = block.timestamp;

        uint256 duration = 365 days;
        uint256 expectedFee = computeManagementFees(mintAmount, fee, duration);

        // go 1 year in the future
        vm.warp(feeInforcementTimestamp + duration);

        // bob mint
        vm.startPrank(bob);
        uint256 bobMint = 1000;
        uint256 bobAssets = vault.mint(bobMint, bob);
        vm.stopPrank();

        // management fees must have been collected
        assertEq(vault.balanceOf(vault.feeCollector()), initialFeeCollectorBalance + expectedFee);

        // ensure no assets where moved out of the vault
        assertEq(asset.balanceOf(address(vault)), assets + bobAssets);

        // ensure alice can redeem her shares - fee
        assertEq(vault.maxWithdraw(alice), assets - vault.convertToShares(expectedFee));

        // ensure bob can redeem his shares
        assertEq(vault.maxRedeem(bob), vault.convertToShares(bobAssets));

        // // ensure alice shares did not change
        assertEq(vault.balanceOf(alice), mintAmount);
    }

    // todo
}
