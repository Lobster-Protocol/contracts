// SPDX-License-Identifier: GNUv3
pragma solidity ^0.8.28;

import {UniswapV3VaultOperationsSetup} from "../../Vault/VaultSetups/WithRealModules/UniswapV3VaultOperationsSetup.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

contract UniswapV3VaultOperations is UniswapV3VaultOperationsSetup {
    function testDeposit() public {
        vm.startPrank(alice);
        uint256 initialAliceAssetBalance = IERC20(vault.asset()).balanceOf(alice);
        uint256 initialVaultAssetBalance = IERC20(vault.asset()).balanceOf(address(vault));

        // alice deposit
        uint256 depositedAmount = 1 ether;
        uint256 expectedShares = vault.convertToShares(depositedAmount);
        // ensure the deposit event is emitted
        vm.expectEmit(true, true, true, true);
        emit IERC4626.Deposit(alice, alice, depositedAmount, expectedShares);
        vault.deposit(depositedAmount, alice);

        vm.stopPrank();

        // ensure the transfer happened
        vm.assertEq(IERC20(vault.asset()).balanceOf(alice), initialAliceAssetBalance - depositedAmount);
        vm.assertEq(IERC20(vault.asset()).balanceOf(address(vault)), initialVaultAssetBalance + depositedAmount);
    }
}
