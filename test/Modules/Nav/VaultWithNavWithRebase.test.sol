// SPDX-License-Identifier: GNU AGPL v3.0
pragma solidity ^0.8.28;

import {VaultWithNavWithRebaseSetup} from "../../Vault/VaultSetups/WithRealModules/VaultWithNavWithRebaseSetup.sol";
import {NavWithRebase} from "../../../src/Modules/NavWithRebase/navWithRebase.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "../../Mocks/MockERC20.sol";

contract NavWithRebaseTest is VaultWithNavWithRebaseSetup {
    function testTryInitializingTwice() public {
        vm.startPrank(owner);
        NavWithRebase navModule = NavWithRebase(address(vault.navModule()));
        vm.expectRevert(NavWithRebase.AlreadyInitialized.selector);
        navModule.initialize(address(vault));
        vm.stopPrank();
    }

    function testValidRebase() public {
        NavWithRebase navModule = NavWithRebase(address(vault.navModule()));

        // Mint some assets to the vault
        MockERC20(vault.asset()).mint(address(vault), 1000 ether);

        // Register the rebaser address as a valid rebaser
        vm.startPrank(owner);
        navModule.setRebaser(rebaser, true);
        vm.stopPrank();

        uint256 newTotalAssets = 987654321;
        uint256 validUntil = block.timestamp + 1 days;

        bytes memory operationData = "";
        bytes memory validationData = createRebaseSignature(
            rebaser,
            newTotalAssets,
            validUntil,
            operationData
        );

        vm.prank(address(0)); // Use a different address to ensure it's the signature that's working
        navModule.rebase(
            newTotalAssets,
            validUntil,
            operationData,
            validationData
        );

        assertEq(
            navModule.totalAssets(),
            newTotalAssets + IERC20(vault.asset()).balanceOf(address(vault))
        );
        assertEq(navModule.rebaseValidUntil(), validUntil);
        assertEq(navModule.lastRebaseTimestamp(), block.timestamp);
    }

    function testInvalidRebaseSig() public {
        NavWithRebase navModule = NavWithRebase(address(vault.navModule()));

        // Mint some assets to the vault
        MockERC20(vault.asset()).mint(address(vault), 1000 ether);

        // Register the rebaser address as a valid rebaser
        vm.startPrank(owner);
        navModule.setRebaser(rebaser, true);
        vm.stopPrank();

        uint256 newTotalAssets = 987654321;
        uint256 validUntil = block.timestamp + 1 days;

        bytes memory operationData = "";
        bytes memory validationData = createRebaseSignature(
            rebaser,
            newTotalAssets,
            validUntil,
            operationData
        );

        // change the last byte of the signature to make it invalid
        validationData[validationData.length - 1] = bytes1(
            uint8(validationData[validationData.length - 1]) + 1
        );

        vm.prank(address(0)); // Use a different address to ensure it's the signature that's working
        vm.expectRevert(NavWithRebase.InvalidSignature.selector);
        navModule.rebase(
            newTotalAssets,
            validUntil,
            operationData,
            validationData
        );
    }

    // function testRebaseThenDeposit() public {
    //     NavWithRebase navModule = NavWithRebase(address(vault.navModule()));

    //     vm.startPrank(alice);
    //     // Mint some assets to the vault
    //     MockERC20(vault.asset()).mint(address(vault), 1000 ether);

    //     // Register the rebaser address as a valid rebaser
    //     vm.startPrank(owner);
    //     navModule.setRebaser(rebaser, true);
    //     vm.stopPrank();

    //     uint256 newTotalAssets = 987654321;
    //     uint256 validUntil = block.timestamp + 1 days;

    //     bytes memory operationData = "";
    //     bytes memory validationData = createRebaseSignature(
    //         rebaser,
    //         newTotalAssets,
    //         validUntil,
    //         operationData
    //     );

    //     vm.prank(address(0)); // Use a different address to ensure it's the signature that's working
    //     navModule.rebase(
    //         newTotalAssets,
    //         validUntil,
    //         operationData,
    //         validationData
    //     );

    //     assertEq(
    //         navModule.totalAssets(),
    //         newTotalAssets + IERC20(vault.asset()).balanceOf(address(vault))
    //     );
    //     assertEq(navModule.rebaseValidUntil(), validUntil);
    //     assertEq(navModule.lastRebaseTimestamp(), block.timestamp);

    //     // Deposit some assets into the vault
    //     vm.startPrank(alice);
    //     vault.deposit(100 ether, alice);
    //     vm.stopPrank();

    //     assertEq(vault.balanceOf(alice), 100 ether);
    // }
}
