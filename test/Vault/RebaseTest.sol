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

contract VaultRebaseTest is VaultTestSetup {
    function testRebase() public {
        // Initial setup
        vm.startPrank(alice);
        uint256 initialDeposit = 150 ether;
        vault.depositWithRebase(
            initialDeposit,
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

        // Algo bridges 10 eth
        uint256 bridgedAmount = 10 ether;
        bridge(bridgedAmount, address(1));

        // 10 eth become 20 in the other chain
        uint256 updatedBridgedAmount = 20 ether;
        rebaseVault(updatedBridgedAmount, 2);

        // ensure the vault value is updated after rebase
        assertEq(
            vault.maxWithdraw(alice),
            initialDeposit - bridgedAmount + updatedBridgedAmount - 1
        ); // -1 because of floating point precision
        assertEq(vault.localTotalAssets(), initialDeposit - bridgedAmount);
        assertEq(vault.valueOutsideVault(), updatedBridgedAmount);
        assertEq(
            vault.totalAssets(),
            initialDeposit - bridgedAmount + updatedBridgedAmount
        );
    }

    function testValueUpdateAfterRebase() public {
        // rebase to 0
        rebaseVault(0 ether, 1);

        // alice deposit 60 eth
        vm.startPrank(alice);
        vault.deposit(60 ether, alice); // no rebase since last rebase is still valid
        vm.stopPrank();

        // bob deposit 40 eth
        vm.startPrank(bob);
        vault.deposit(40 ether, bob); // no rebase since last rebase is still valid
        vm.stopPrank();

        // Algo bridges 10 eth
        bridge(10 ether, address(1));

        // 10 eth become 20 in the other chain
        rebaseVault(20 ether, 2);

        // ensure alice's assets is updated after rebase
        assertEq(vault.maxWithdraw(alice), 66 ether - 1); // -1 because of floating point precision
        assertEq(vault.maxWithdraw(bob), 44 ether - 1); // -1 because of floating point precision
        assertEq(vault.localTotalAssets(), 90 ether);
        assertEq(vault.valueOutsideVault(), 20 ether);
        assertEq(vault.totalAssets(), 110 ether); // 5 from the vault, 10 from rebase
    }

    function testRebaseWithWithdrawOperations() public {
        // Initial setup
        vm.startPrank(alice);
        uint256 initialDeposit = 150 ether;
        vault.depositWithRebase(
            initialDeposit,
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

        // Algo bridges 10 eth
        uint256 bridgedAmount = 10 ether;
        bridge(bridgedAmount, address(1));

        // algo moves 100 eth to another contract (on the same chain)
        uint256 amountMoved = 100 ether;
        vm.startPrank(lobsterAlgorithm);
        vault.executeOp(
            Op({
                target: address(asset),
                value: 0,
                data: abi.encodeWithSignature(
                    "transfer(address,uint256)",
                    counter,
                    amountMoved
                )
            })
        );
        vm.stopPrank();

        // ALice wants to withdraw 50 eth so we need to get some eth back from the other contract
        uint256 amountToWithdraw = 50 ether;
        uint256 amountToGetFromThirdParty = amountToWithdraw -
            (initialDeposit - bridgedAmount - amountMoved);
        Op[] memory withdrawOperations = new Op[](1);
        withdrawOperations[0] = Op({
            target: address(counter),
            value: 0,
            data: abi.encodeWithSignature(
                "incrementAndClaim(uint256)",
                amountToGetFromThirdParty
            )
        });

        uint256 alicesBalanceBefore = asset.balanceOf(alice);

        uint256 newValueOutsideChain = 20 ether;

        // withdraw
        vm.startPrank(alice);
        vault.withdrawWithRebase(
            amountToWithdraw,
            alice,
            alice,
            getValidRebaseData(
                address(vault),
                bridgedAmount + amountMoved,
                block.number + 2,
                50, // no slippage expected
                RebaseType.WITHDRAW,
                abi.encode(withdrawOperations, newValueOutsideChain)
            )
        );
        vm.stopPrank();

        assertEq(
            asset.balanceOf(alice),
            alicesBalanceBefore + amountToWithdraw
        );
        assertEq(
            vault.totalAssets(),
            vault.balanceOf(address(vault)) + newValueOutsideChain
        );
    }
}
