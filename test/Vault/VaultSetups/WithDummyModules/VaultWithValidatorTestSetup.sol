// SPDX-License-Identifier: GNU AGPL v3.0
pragma solidity ^0.8.28;

import {LobsterVault} from "../../../../src/Vault/Vault.sol";
import {Counter} from "../../../Mocks/Counter.sol";
import {MockERC20} from "../../../Mocks/MockERC20.sol";
import {IHook} from "../../../../src/interfaces/modules/IHook.sol";
import {INav} from "../../../../src/interfaces/modules/INav.sol";
import {IOpValidatorModule} from "../../../../src/interfaces/modules/IOpValidatorModule.sol";
import {VaultTestUtils} from "../VaultTestUtils.sol";
import {DummyHook} from "../../../Mocks/modules/DummyHook.sol";
import {DummyValidator} from "../../../Mocks/modules/DummyValidator.sol";
import {IVaultOperations} from "../../../../src/interfaces/modules/IVaultOperations.sol";

// Vault base setup with validator function to be used in other test files
contract VaultWithValidatorTestSetup is VaultTestUtils {
    function setUp() public {
        owner = makeAddr("owner");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        feeCollector = makeAddr("feeCollector");

        IHook hook = IHook(address(0));
        IOpValidatorModule opValidator = new DummyValidator();
        IVaultOperations vaultOperations = IVaultOperations(address(0));
        INav navModule = INav(address(0));

        // Deploy contracts
        asset = new MockERC20();
        counter = new Counter();

        vault = new LobsterVault(
            owner, asset, "Vault Token", "vTKN", feeCollector, opValidator, hook, navModule, vaultOperations
        );

        // Setup initial state
        asset.mint(alice, 10000 ether);
        asset.mint(bob, 10000 ether);

        vm.startPrank(alice);
        asset.approve(address(vault), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(bob);
        asset.approve(address(vault), type(uint256).max);
        vm.stopPrank();
    }
}
