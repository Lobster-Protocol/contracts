// SPDX-License-Identifier: GPLv3
pragma solidity ^0.8.28;

import "forge-std/Test.sol";

import {IOpValidatorModule} from "../../../../src/interfaces/modules/IOpValidatorModule.sol";
import {MockERC20} from "../../../Mocks/MockERC20.sol";
import {UniV3LobsterVault, BASIS_POINT_SCALE} from "../../../../src/Vault/UniV3LobsterVault.sol";
import {IUniswapV3PoolMinimal} from "../../../../src/interfaces/uniswapV3/IUniswapV3PoolMinimal.sol";
import {INonFungiblePositionManager} from "../../../../src/interfaces/uniswapV3/INonFungiblePositionManager.sol";
import {UniswapV3Infra} from "../../../Mocks/uniswapV3/UniswapV3Infra.sol";
import {IUniswapV3FactoryMinimal} from "../../../../src/interfaces/uniswapV3/IUniswapV3FactoryMinimal.sol";
import {DummyValidator} from "../../../Mocks/modules/DummyValidator.sol";
import {IUniswapV3RouterMinimal} from "../../../../src/interfaces/uniswapV3/IUniswapV3RouterMinimal.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {BaseOp, Op} from "../../../../src/interfaces/modules/IOpValidatorModule.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {PositionValue} from "../../../../src/libraries/uniswapV3/PositionValue.sol";
import {PoolAddress} from "../../../../src/libraries/uniswapV3/PoolAddress.sol";
import {UniswapV3VaultUtils} from "./UniswapV3VaultUtils.sol";

contract UniV3LobsterVaultFeesSetup is UniswapV3VaultUtils {
    using Math for uint256;

    address public owner;
    address public alice;
    address public bob;
    uint256 public expectedFeeBasisPoint;

    function setUp() public {
        owner = makeAddr("owner");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        address uniV3feeCutCollector = makeAddr("feeCollector");

        (IUniswapV3FactoryMinimal factory,, INonFungiblePositionManager positionManager, IUniswapV3RouterMinimal router)
        = deploy();

        uniswapV3Data.poolFee = 3000; // 0.3%
        uniswapV3Data.positionManager = positionManager;
        uniswapV3Data.factory = factory;
        uniswapV3Data.router = router;
        uniswapV3Data.poolInitialSqrtPriceX96 = 2 ** 96; // = quote = 1:1 if both tokens have the same decimals value
        expectedFeeBasisPoint = 100; // 1% fee

        // Deploy and initialize the pool weth/mocked token pool
        IUniswapV3PoolMinimal pool = createPoolAndInitialize(
            uniswapV3Data.factory,
            address(new MockERC20()),
            address(new MockERC20()),
            uniswapV3Data.poolFee,
            uniswapV3Data.poolInitialSqrtPriceX96
        );

        uniswapV3Data.tokenA = pool.token0();
        uniswapV3Data.tokenB = pool.token1();

        // mint some tokens for the alice and bob
        MockERC20(uniswapV3Data.tokenA).mint(alice, 10000 ether); // 1000 tokens with 18 decimals
        MockERC20(uniswapV3Data.tokenB).mint(alice, 10000 ether); // 1000 tokens with 18 decimals
        MockERC20(uniswapV3Data.tokenA).mint(bob, 10000 ether); // 1000 tokens with 18 decimals
        MockERC20(uniswapV3Data.tokenB).mint(bob, 10000 ether); // 1000 tokens with 18 decimals

        // module instantiation
        IOpValidatorModule opValidator = new DummyValidator();

        vault = new UniV3LobsterVault(
            opValidator,
            pool,
            positionManager,
            uniV3feeCutCollector,
            expectedFeeBasisPoint // 1% fee cut,
        );

        // Setup initial state
        MockERC20(uniswapV3Data.tokenA).mint(alice, 10000 ether);
        MockERC20(uniswapV3Data.tokenB).mint(bob, 10000 ether);

        vm.startPrank(alice);
        MockERC20(uniswapV3Data.tokenA).approve(address(vault), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(bob);
        MockERC20(uniswapV3Data.tokenB).approve(address(vault), type(uint256).max);
        vm.stopPrank();
    }
}
