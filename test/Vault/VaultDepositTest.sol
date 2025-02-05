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


contract VaultDepositTest is VaultTestSetup {
    
    /* -----------------------DEPOSIT----------------------- */
    function testDeposit() public {
        rebaseVault(0, block.number + 1);

        vm.startPrank(alice);
        vault.deposit(1 ether, alice);
        assertEq(vault.balanceOf(alice), 1 ether);
        vm.stopPrank();
    }

    // Should revert if rebase is too old (> MAX_DEPOSIT_DELAY)
    function testDepositAfterLimit() public {
        rebaseVault(10, block.number + 1);

        vm.roll(vault.rebaseExpiresAt() + 1);

        vm.startPrank(alice);
        vm.expectRevert(LobsterVault.RebaseExpired.selector);
        vault.deposit(1 ether, alice);
        vm.stopPrank();
    }

    // multiple deposits
    function testMultipleDeposits() public {
        rebaseVault(0, 1);

        // alice deposits 100.33 eth
        vm.startPrank(alice);
        vault.deposit(100.33 ether, alice);
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
        // bob deposits 1 and 2 eth
        vm.startPrank(bob);
        vault.deposit(1 ether, bob);

        vm.assertEq(vault.maxWithdraw(bob), 1 ether);
        vault.deposit(2 ether, bob);
        vm.assertEq(vault.maxWithdraw(bob), 3 ether);
        vm.stopPrank();

        vm.assertEq(vault.totalAssets(), 103.33 ether);
        vm.assertEq(vault.localTotalAssets(), 3.33 ether);
    }

    function testDepositWithRebaseZeroAmount() public {
        vm.startPrank(alice);
        vault.depositWithRebase(
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
        vm.stopPrank();
    }

    function testDepositWithRebaseInvalidReceiver() public {
        vm.startPrank(alice);
        vm.expectRevert();
        vault.depositWithRebase(
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

    function testDepositWithRebaseExpiredSignature() public {
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
        vault.depositWithRebase(1 ether, alice, rebaseData);
        vm.stopPrank();
    }

    /* -----------------------DEPOSIT WITHOUT REBASE----------------------- */
    function testDepositWithoutRebase() public {
        rebaseVault(0, block.number + 1);

        // wait for rebase expiration
        vm.roll(vault.rebaseExpiresAt() + 1);

        vm.startPrank(alice);
        vm.expectRevert(LobsterVault.RebaseExpired.selector);
        vault.deposit(1 ether, alice);
        vm.stopPrank();
    }

        // todo: test deposit without rebase but with a not expired rebase

    /* -----------------------WITH REBASE----------------------- */
    function testDepositWithRebase() public {
        // no rebase yet
        vm.startPrank(alice);
        vault.depositWithRebase(
            1 ether,
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
        assertEq(vault.balanceOf(alice), 1 ether);
        vm.stopPrank();
    }
    // todo: test deposit with rebase but with a rebase that expires before the current rebase
}