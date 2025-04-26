// Maxime / Thomas ignore
// SPDX-License-Identifier: GNUv3
pragma solidity ^0.8.28;

// import {VaultTestUtils} from "../VaultTestUtils.sol";
// import {IHook} from "../../../../src/interfaces/modules/IHook.sol";
// import {IOpValidatorModule} from "../../../../src/interfaces/modules/IOpValidatorModule.sol";
// import {INav} from "../../../../src/interfaces/modules/INav.sol";
// import {IVaultFlowModule} from "../../../../src/interfaces/modules/IVaultFlowModule.sol";
// import {MockERC20} from "../../../Mocks/MockERC20.sol";
// import {LobsterVault} from "../../../../src/Vault/Vault.sol";
// import {UniswapV3VaultOperations} from "../../../../src/Modules/VaultOperations/UniswapV3.sol";
// import {IUniswapV3PoolMinimal} from "../../../../src/interfaces/uniswapV3/IUniswapV3PoolMinimal.sol";
// import {INonFungiblePositionManager} from "../../../../src/interfaces/uniswapV3/INonFungiblePositionManager.sol";

// contract UniswapV3VaultOperationsSetup is VaultTestUtils {
//     IUniswapV3PoolMinimal pool;
//             INonFungiblePositionManager positionManager;

//     function setUp() public {
//         owner = makeAddr("owner");
//         alice = makeAddr("alice");
//         bob = makeAddr("bob");
//         feeCollector = makeAddr("feeCollector");

//         ///////
//         pool = IUniswapV3PoolMinimal(address(0xC31E54c7a869B9FcBEcc14363CF510d1c41fa443/* 0x2f5e87C9312fa29aed5c179E456625D79015299c */)); // arbitrum1 WBTC/WETH pool
//         positionManager = INonFungiblePositionManager(address(0));
//         ///////

//         // module instantiation
//         IHook hook = IHook(address(0));
//         IOpValidatorModule opValidator = IOpValidatorModule(address(0));
//         IVaultFlowModule vaultOperations = new UniswapV3VaultOperations(pool, positionManager);
//         INav navModule = INav(address(0));

//         // Deploy contracts
//         asset = new MockERC20();

//         vault = new LobsterVault(
//             owner, asset, "Vault Token", "vTKN", feeCollector, opValidator, hook, navModule, vaultOperations
//         );

//         // Setup initial state
//         asset.mint(alice, 10000 ether);
//         asset.mint(bob, 10000 ether);

//         vm.startPrank(alice);
//         asset.approve(address(vault), type(uint256).max);
//         vm.stopPrank();

//         vm.startPrank(bob);
//         asset.approve(address(vault), type(uint256).max);
//         vm.stopPrank();
//     }
// }
