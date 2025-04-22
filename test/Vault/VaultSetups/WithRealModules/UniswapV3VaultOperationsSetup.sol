// SPDX-License-Identifier: GNUv3
pragma solidity ^0.8.28;

import {VaultTestUtils} from "../VaultTestUtils.sol";
import {IHook} from "../../../../src/interfaces/modules/IHook.sol";
import {IOpValidatorModule} from "../../../../src/interfaces/modules/IOpValidatorModule.sol";
import {INav} from "../../../../src/interfaces/modules/INav.sol";
import {IVaultOperations} from "../../../../src/interfaces/modules/IVaultOperations.sol";
import {MockERC20} from "../../../Mocks/MockERC20.sol";
import {LobsterVault} from "../../../../src/Vault/Vault.sol";
import {UniswapV3VaultOperations} from "../../../../src/Modules/VaultOperations/UniswapV3.sol";

contract UniswapV3VaultOperationsSetup is VaultTestUtils {
    function setUp() public {
        owner = makeAddr("owner");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        feeCollector = makeAddr("feeCollector");

        // module instantiation
        IHook hook = IHook(address(0));
        IOpValidatorModule opValidator = IOpValidatorModule(address(0));
        IVaultOperations vaultOperations = new UniswapV3VaultOperations();
        INav navModule = INav(address(0));

        // Deploy contracts
        asset = new MockERC20();

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
