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
import {UniswapV3Infra} from "../../../Mocks/uniswapV3/UniswapV3Infra.sol";
import {IUniswapV3FactoryMinimal} from "../../../../src/interfaces/uniswapV3/IUniswapV3FactoryMinimal.sol";
import {IWETH} from "../../../../src/interfaces/IWETH.sol";
import {DummyValidator} from "../../../Mocks/modules/DummyValidator.sol";
import {IUniswapV3RouterMinimal} from "../../../../src/interfaces/uniswapV3/IUniswapV3RouterMinimal.sol";

struct UniswapV3Data {
    IUniswapV3FactoryMinimal factory;
    INonFungiblePositionManager positionManager;
    IUniswapV3RouterMinimal router;
    address tokenA;
    address tokenB;
    uint24 poolFee;
    uint160 poolInitialSqrtPriceX96;
}

contract UniswapV3VaultFlowSetup is VaultTestUtils, UniswapV3Infra {
    UniswapV3Data public uniswapV3Data;

    function setUp() public {
        owner = makeAddr("owner");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        feeCollector = makeAddr("feeCollector");

        (IUniswapV3FactoryMinimal factory,, INonFungiblePositionManager positionManager, IUniswapV3RouterMinimal router)
        = deploy();

        uniswapV3Data.poolFee = 3000; // 0.3%
        uniswapV3Data.positionManager = positionManager;
        uniswapV3Data.factory = factory;
        uniswapV3Data.router = router;
        uniswapV3Data.poolInitialSqrtPriceX96 = 2 ** 96; // = quote = 1:1 if both tokens have the same decimals value
        asset = new MockERC20();
        uniswapV3Data.tokenA = address(asset);
        uniswapV3Data.tokenB = address(new MockERC20());

        // Deploy and initialize the pool weth/mocked token pool
        IUniswapV3PoolMinimal pool = createPoolAndInitialize(
            uniswapV3Data.factory,
            address(asset), // tokenA
            address(uniswapV3Data.tokenB),
            uniswapV3Data.poolFee,
            uniswapV3Data.poolInitialSqrtPriceX96
        );

        // module instantiation
        IHook hook = IHook(address(0));
        IOpValidatorModule opValidator = new DummyValidator();
        IVaultFlowModule vaultOperations = new UniswapV3VaultFlow(
            pool,
            uniswapV3Data.positionManager,
            address(uniswapV3Data.router),
            address(asset), // tokenA
            0
        );
        INav navModule = INav(address(0));

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
