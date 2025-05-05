// Maxime / Thomas ignore
// SPDX-License-Identifier: GPLv3
pragma solidity ^0.8.28;

import {VaultTestUtils} from "../VaultTestUtils.sol";
import {IHook} from "../../../../src/interfaces/modules/IHook.sol";
import {IOpValidatorModule} from "../../../../src/interfaces/modules/IOpValidatorModule.sol";
import {INav} from "../../../../src/interfaces/modules/INav.sol";
import {IVaultFlowModule} from "../../../../src/interfaces/modules/IVaultFlowModule.sol";
import {MockERC20} from "../../../Mocks/MockERC20.sol";
import {LobsterVault} from "../../../../src/Vault/Vault.sol";
import {UniswapV3VaultFlow} from "../../../../src/Modules/VaultFlow/UniswapV3WithTwap.sol";
import {IUniswapV3PoolMinimal} from "../../../../src/interfaces/uniswapV3/IUniswapV3PoolMinimal.sol";
import {INonFungiblePositionManager} from "../../../../src/interfaces/uniswapV3/INonFungiblePositionManager.sol";

contract UniswapV3VaultOperationsSetup is VaultTestUtils {
    IUniswapV3PoolMinimal pool;
    INonFungiblePositionManager positionManager;

    function setUp() public {
        owner = makeAddr("owner");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        feeCollector = makeAddr("feeCollector");

        /////// arbitrum
        // // eth/usdc: 0xC31E54c7a869B9FcBEcc14363CF510d1c41fa443
        // pool = IUniswapV3PoolMinimal(
        //     address(
        //         0xC31E54c7a869B9FcBEcc14363CF510d1c41fa443 /* 0x2f5e87C9312fa29aed5c179E456625D79015299c */
        //     )
        // ); // arbitrum1 WBTC/WETH pool
        // positionManager = INonFungiblePositionManager(address(0xC36442b4a4522E871399CD717aBDD847Ab11FE88));
        // address weth = address(0x82aF49447D8a07e3bd95BD0d56f35241523fBab1);
        ///////
        /////// sepolia
        pool = IUniswapV3PoolMinimal(address(0x3289680dD4d6C10bb19b899729cda5eEF58AEfF1)); // sepolia USDC/WETH pool
        positionManager = INonFungiblePositionManager(address(0x1238536071E1c677A632429e3655c799b22cDA52));
        address weth = address(0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14);
        ///////

        // module instantiation
        IHook hook = IHook(address(0));
        IOpValidatorModule opValidator = IOpValidatorModule(address(0));
        IVaultFlowModule vaultOperations = new UniswapV3VaultFlow(pool, positionManager, weth, 0);
        INav navModule = INav(address(0));

        // Deploy contracts
        asset = MockERC20(weth); // new MockERC20();

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
