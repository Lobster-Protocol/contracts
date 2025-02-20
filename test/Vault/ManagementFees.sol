// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {PendingFeeUpdate} from "../../src/Vault/ERC4626Fees.sol";
import {VaultTestSetup} from "./VaultTestSetup.sol";
import {ERC4626Fees, IERC4626FeesEvents} from "../../src/Vault/ERC4626Fees.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {BASIS_POINT_SCALE} from "../../src/Vault/Constants.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

// test deposit / withdraw / mint / redeem functions with management fee
// test collecting management fees manually
contract VaultInAndOutFeesTest is VaultTestSetup {
    using Math for uint256;

    /* -----------------------TEST UPDATING MANAGEMENT FEE----------------------- */
    // todo
    /* -----------------------TEST MANUAL COLLECTION----------------------- */
    function testCollectFeesAsOwner() public {
        // rebase to 0
        rebaseVault(0, block.number + 1);

        uint256 fee = 100;
        setManagementFeeBasisPoint(fee); // 1%

        // alice deposit 1000 assets
        vm.startPrank(alice);
        uint256 initialFeeCollectorBalance = asset.balanceOf(
            vault.feeCollector()
        );

        uint256 depositAmount = 1000;
        uint256 shares = vault.deposit(depositAmount, alice);
        vm.stopPrank();

        uint256 duration = 365 days;
        uint256 expectedFee = computeManagementFees(
            depositAmount,
            fee,
            duration
        );

        // wait for 1 year
        vm.warp(duration);

        // collect the fees
        vm.startPrank(owner);
        uint256 collectedFees1 = vault.collectFees();

        // ensure fee collector shares correspond to the collected fees
        assertEq(vault.balanceOf(vault.feeCollector()), expectedFee);

        // ensure alice's shares balance did not change
        assertEq(vault.balanceOf(alice), shares);

        // ensure fee collector asset balance did not change
        assertEq(
            asset.balanceOf(vault.feeCollector()),
            initialFeeCollectorBalance
        );

        // ensure collectedFees1 is accurate
        assertEq(
            vault.balanceOf(vault.feeCollector()) - initialFeeCollectorBalance,
            collectedFees1
        );

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
        assertEq(
            asset.balanceOf(vault.feeCollector()),
            initialFeeCollectorBalance
        );

        vm.stopPrank();
    }
    /* -----------------------TEST DEPOSIT / MINT / WITHDRAW / REDEEM----------------------- */
    // todo
}
