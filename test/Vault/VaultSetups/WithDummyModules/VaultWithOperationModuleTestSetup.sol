// SPDX-License-Identifier: GNUv3
pragma solidity ^0.8.28;

import {VaultTestUtils} from "../VaultTestUtils.sol";
import {IVaultFlowModule} from "../../../../src/interfaces/modules/IVaultFlowModule.sol";
import {IHook} from "../../../../src/interfaces/modules/IHook.sol";
import {IOpValidatorModule} from "../../../../src/interfaces/modules/IOpValidatorModule.sol";
import {INav} from "../../../../src/interfaces/modules/INav.sol";
import {DummyVaultFlow} from "../../../Mocks/modules/DummyVaultFlow.sol";
import {MockERC20} from "../../../Mocks/MockERC20.sol";
import {Counter} from "../../../Mocks/Counter.sol";
import {LobsterVault} from "../../../../src/Vault/Vault.sol";

contract VaultWithOperationModuleTestSetup is VaultTestUtils {
    function setUp() public {
        owner = makeAddr("owner");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        feeCollector = makeAddr("feeCollector");

        IHook hook = IHook(address(0));
        IOpValidatorModule opValidator = IOpValidatorModule(address(0));
        IVaultFlowModule vaultOperations = new DummyVaultFlow();
        INav navModule = INav(address(0));

        // Deploy contracts
        asset = new MockERC20();
        counter = new Counter();

        vault = new LobsterVault(
            owner, asset, "Vault Token", "vTKN", feeCollector, opValidator, hook, navModule, vaultOperations, 0, 0, 0
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
