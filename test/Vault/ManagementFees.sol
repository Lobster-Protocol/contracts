// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {PendingFeeUpdate} from "../../src/Vault/ERC4626Fees.sol";
import {VaultTestSetup} from "./VaultTestSetup.sol";
import {ERC4626Fees, IERC4626FeesEvents} from "../../src/Vault/ERC4626Fees.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

// test deposit / withdraw / mint / redeem fee
contract VaultInAndOutFeesTest is VaultTestSetup {
    // the default fess are set to 0

    /* -----------------------HELPER FUNCTIONS TO SET VAULT FEES----------------------- */
    function setManagementFeeBasisPoint(
        uint256 managementFee
    ) public returns (bool) {
        vm.startPrank(owner);
        vault.setManagementFee(managementFee);

        // wait for the fee to be activated
        vm.warp(block.timestamp + vault.FEE_UPDATE_DELAY());

        vault.enforceNewManagementFee();
        vm.stopPrank();

        return true;
    }

    function computeManagementFee(
        uint256 amount,
        uint256 timeInterval, // seconds over which the fee is computed
        uint256 fee
    ) public pure returns (uint256) {
        return (amount * fee * timeInterval) / (365 days * 10000);
    }

    /* -----------------------SET FEE----------------------- */

    function testSetManagementFee() public {
        // set management fee to 100 basis points (1%)
        vm.startPrank(owner);
        vault.setManagementFee(100);
        vm.stopPrank();

        (uint256 value, uint256 activationTimestamp) = vault
            .pendingManagementFeeUpdate();

        assertEq(value, 100);
        assertEq(
            activationTimestamp,
            block.timestamp + vault.FEE_UPDATE_DELAY()
        );
    }

    function testSetManagementFeeNoOwner() public {
        // set management fee to 100 basis points (1%)
        vm.startPrank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                Ownable.OwnableUnauthorizedAccount.selector,
                alice
            )
        );
        vault.setManagementFee(100);
        vm.stopPrank();

        (uint256 value, uint256 activationTimestamp) = vault
            .pendingManagementFeeUpdate();

        assertEq(value, 0);
        assertEq(activationTimestamp, 0);
    }

    // idk why this test is failing
    // todo: fix this
    // function testSetManagementFeeGtMax() public {
    //     // set management fee to MAX_FEE + 1 basis points
    //     vm.startPrank(owner);
    //     vm.expectRevert(IERC4626FeesEvents.InvalidFee.selector);
    //     vault.setManagementFee(vault.MAX_FEE() + 1);
    //     vm.stopPrank();

    //     (uint256 value, uint256 activationTimestamp) = vault
    //         .pendingManagementFeeUpdate();

    //     assertEq(value, 0);
    //     assertEq(activationTimestamp, 0);
    // }

    function testManagementFeeEnforcement() public {
        // set management fee to 100 basis points (1%)
        vm.startPrank(owner);
        uint256 managementFee = 100;
        vault.setManagementFee(managementFee);

        (uint256 value, uint256 activationTimestamp) = vault
            .pendingManagementFeeUpdate();

        assertEq(value, managementFee);
        assertEq(
            activationTimestamp,
            block.timestamp + vault.FEE_UPDATE_DELAY()
        );

        // wait for the fee to be activated
        vm.warp(block.timestamp + vault.FEE_UPDATE_DELAY());

        vault.enforceNewManagementFee();
        vm.stopPrank();

        assertEq(vault.managementFeeBasisPoints(), 100);

        (value, activationTimestamp) = vault.pendingManagementFeeUpdate();
        assertEq(value, 0);
        assertEq(activationTimestamp, 0);
    }

    /* -----------------------TEST FEE DISTRIBUTION----------------------- */

    function testManagementFeeCollectionNoOwner() public {
        rebaseVault(0, block.number + 1);

        // set management fee to 100 basis points (1%)
        uint256 managementFee = 100;
        setManagementFeeBasisPoint(managementFee);

        // with the vm.wrap fct called, only timestamp is increased, no need to rebase since block number did not change

        // deposit
        uint256 amountToDeposit = 1000;
        uint256 delayBeforeFeeCollection = 365 days;

        vm.startPrank(alice);
        uint256 shares = vault.deposit(amountToDeposit, alice);
        vm.stopPrank();

        // wait for delayBeforeFeeCollection seconds
        vm.warp(block.timestamp + delayBeforeFeeCollection);

        // collect fees
        vm.startPrank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                Ownable.OwnableUnauthorizedAccount.selector,
                alice
            )
        );
        vault.collectManagementFees();
        vm.stopPrank();

        // ensure vault balance remained the same
        assertEq(asset.balanceOf(address(vault)), amountToDeposit);

        // ensure shares remained the same
        assertEq(vault.totalSupply(), shares);
    }

    function testManagementFeeDistribution() public {
        rebaseVault(0, block.number + 1);

        // set management fee to 100 basis points (1%)
        uint256 managementFee = 100;
        setManagementFeeBasisPoint(managementFee);

        // with the vm.wrap fct called, only timestamp is increased, no need to rebase since block number did not change

        // deposit
        uint256 amountToDeposit = 1000;
        uint256 delayBeforeFeeCollection = 365 days;
        uint256 initialFeeCollectorBalance = asset.balanceOf(
            vault.managementFeeCollector()
        );

        uint256 expectedFee = computeManagementFee(
            amountToDeposit,
            delayBeforeFeeCollection,
            100 // 1%
        );

        vm.startPrank(alice);
        uint256 shares = vault.deposit(amountToDeposit, alice);
        vm.stopPrank();

        // wait for delayBeforeFeeCollection seconds
        vm.warp(block.timestamp + delayBeforeFeeCollection);

        // collect fees
        vm.startPrank(owner);
        uint256 collectedFee = vault.collectManagementFees();
        vm.stopPrank();

        assertEq(collectedFee, expectedFee);

        // ensure fee collector received the fee
        assertEq(
            asset.balanceOf(vault.managementFeeCollector()),
            initialFeeCollectorBalance + expectedFee
        );

        // ensure the fee was deducted from the vault
        assertEq(
            asset.balanceOf(address(vault)),
            amountToDeposit - expectedFee
        );

        // ensure shares remained the same
        assertEq(vault.totalSupply(), shares);
    }

    function testManagementFeeCollectionAtDeposit() public {
        rebaseVault(0, block.number + 1);

        uint256 initialFeeCollectorBalance = asset.balanceOf(
            vault.managementFeeCollector()
        );
        uint256 initialFeeCollectorShares = vault.balanceOf(
            vault.managementFeeCollector()
        );

        // alice deposit
        uint256 aliceDeposit = 1000;
        vm.startPrank(alice);
        uint256 aliceShares = vault.deposit(aliceDeposit, alice);
        vm.stopPrank();

        uint256 feeEnforcementTimestamp = block.timestamp;
        // set management fee to 100 basis points (1%)
        uint256 managementFee = 100;
        setManagementFeeBasisPoint(managementFee);

        // with the vm.wrap fct called, only timestamp is increased, no need to rebase since block number did not change

        // wait for some time
        vm.warp(block.timestamp + 365 days);

        // bob deposit
        uint256 bobDeposit = 2000;
        vm.startPrank(bob);
        uint256 bobShares = vault.deposit(bobDeposit, bob);
        vm.stopPrank();

        // management fee has been collected at bob's deposit

        uint256 timeElapsedFromFeeEnforcement = block.timestamp -
            feeEnforcementTimestamp;
        uint256 expectedManagementFee = computeManagementFee(
            aliceDeposit,
            timeElapsedFromFeeEnforcement,
            managementFee
        );

        // ensure fee collector received the expected fee
        assertEq(
            asset.balanceOf(vault.managementFeeCollector()),
            initialFeeCollectorBalance + expectedManagementFee
        );

        // ensure vault assets where updated correctly
        assertEq(
            asset.balanceOf(address(vault)),
            aliceDeposit + bobDeposit - expectedManagementFee
        );

        // ensure vault shares remained the same
        assertEq(vault.totalSupply(), aliceShares + bobShares);

        // ensure fee collector's share remained the same
        assertEq(
            vault.balanceOf(vault.managementFeeCollector()),
            initialFeeCollectorShares
        );

        // ensure max withdrawals values
        assertEq(
            vault.maxWithdraw(alice),
            aliceDeposit - expectedManagementFee
        );

        // bob should no be impacted by management fees
        assertEq(vault.maxWithdraw(bob), bobDeposit - 1); // -1 because of rounding errors
    }

    function testManagementFeeCollectionAtMint() public {
        rebaseVault(0, block.number + 1);

        uint256 initialFeeCollectorBalance = asset.balanceOf(
            vault.managementFeeCollector()
        );
        uint256 initialFeeCollectorShares = vault.balanceOf(
            vault.managementFeeCollector()
        );

        // alice mint
        uint256 aliceMint = 1000;
        vm.startPrank(alice);
        uint256 aliceAssets = vault.mint(aliceMint, alice);
        vm.stopPrank();

        uint256 feeEnforcementTimestamp = block.timestamp;
        // set management fee to 100 basis points (1%)
        uint256 managementFee = 100;
        setManagementFeeBasisPoint(managementFee);

        // with the vm.wrap fct called, only timestamp is increased, no need to rebase since block number did not change

        // wait for some time
        vm.warp(block.timestamp + 365 days);

        // bob mint
        uint256 bobMint = 2000;
        vm.startPrank(bob);
        uint256 bobAssets = vault.mint(bobMint, bob);
        vm.stopPrank();

        // management fee has been collected at bob's mint

        uint256 timeElapsedFromFeeEnforcement = block.timestamp -
            feeEnforcementTimestamp;
        uint256 expectedManagementFee = computeManagementFee(
            aliceMint,
            timeElapsedFromFeeEnforcement,
            managementFee
        );

        // ensure fee collector received the expected fee
        assertEq(
            asset.balanceOf(vault.managementFeeCollector()),
            initialFeeCollectorBalance + expectedManagementFee
        );

        // ensure vault assets where updated correctly
        assertEq(
            asset.balanceOf(address(vault)),
            aliceAssets + bobAssets - expectedManagementFee
        );

        // ensure vault shares remained the same
        assertEq(vault.totalSupply(), aliceMint + bobMint);

        // ensure fee collector's share remained the same
        assertEq(
            vault.balanceOf(vault.managementFeeCollector()),
            initialFeeCollectorShares
        );

        // ensure max withdrawals values
        assertEq(
            vault.maxWithdraw(alice),
            aliceAssets - expectedManagementFee
        );

        // bob should no be impacted by management fees
        assertEq(vault.maxWithdraw(bob), bobAssets - 1); // -1 because of rounding errors
    }
}

// todo: test automatic management fee collection at mint / withdrawal / redeem
