// SPDX-License-Identifier: GNU AGPL v3.0
pragma solidity ^0.8.28;
import "forge-std/Test.sol";

import {LobsterVault} from "../../../../src/Vault/Vault.sol";
import {Counter} from "../../../Mocks/Counter.sol";
import {MockERC20} from "../../../Mocks/MockERC20.sol";
import {IHook} from "../../../../src/interfaces/modules/IHook.sol";
import {INav} from "../../../../src/interfaces/modules/INav.sol";
import {IOpValidatorModule} from "../../../../src/interfaces/modules/IOpValidatorModule.sol";
import {VaultTestUtils} from "../VaultTestUtils.sol";
import {UniswapFeeCollectorHook} from "../../../../src/Modules/Hooks/UniswapFeeCollectorHook.sol";
import {IUniswapV3PoolMinimal} from "../../../../src/interfaces/uniswapV3/IUniswapV3PoolMinimal.sol";
import {DummyValidator} from "../../../Mocks/modules/DummyValidator.sol";
import {IVaultFlowModule} from "../../../../src/interfaces/modules/IVaultFlowModule.sol";
import {DummyUniswapV3PoolMinimal} from "../../../Mocks/DummyUniswapV3PoolMinimal.sol";
import {DummyHook} from "../../../Mocks/modules/DummyHook.sol";
import {NavWithRebase} from "../../../../src/Modules/NavWithRebase/navWithRebase.sol";

// Vault base setup with validator function to be used in other test files
contract VaultWithNavWithRebaseSetup is VaultTestUtils {
    DummyUniswapV3PoolMinimal uniV3MockedPool;

    function setUp() public {
        owner = makeAddr("owner");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        feeCollector = makeAddr("feeCollector");

        // module instantiation
        IHook hook = new DummyHook();
        IOpValidatorModule opValidator = new DummyValidator();
        IVaultFlowModule vaultOperations = IVaultFlowModule(address(0));
        NavWithRebase navModuleWithRebase = new NavWithRebase(owner, 0);
        INav navModule = navModuleWithRebase;

        // Deploy contracts
        asset = new MockERC20();
        counter = new Counter();

        vault = new LobsterVault(
            owner, asset, "Vault Token", "vTKN", feeCollector, opValidator, hook, navModule, vaultOperations, 0, 0, 0
        );

        // initialize nav module
        vm.startPrank(owner);
        navModuleWithRebase.initialize(address(vault));
        vm.stopPrank();
        
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
