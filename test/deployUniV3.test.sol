// SPDX-License-Identifier: GNUv3
pragma solidity ^0.8.28;

import "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IVaultFlowModule} from "../src/interfaces/modules/IVaultFlowModule.sol";
import {UniswapV3VaultFlow} from "../src/Modules/VaultFlow/UniswapV3WithTwap.sol";
import {DeployUniV3} from "./Mocks/uniswapV3/uniswapV3Factory.sol";
import {IUniswapV3FactoryMinimal} from "../src/interfaces/uniswapV3/IUniswapV3FactoryMinimal.sol";
import {INonFungiblePositionManager} from "../src/interfaces/uniswapV3/INonFungiblePositionManager.sol";
import {IWETH} from "../src/interfaces/IWETH.sol";
import {MockERC20} from "./Mocks/MockERC20.sol";

contract UniswapV3VaultOperations is DeployUniV3 {
    function testDeploy() public {
        (IUniswapV3FactoryMinimal factory, IWETH weth, INonFungiblePositionManager positionManager) = deploy();

        console.log("deployed factory: ", address(factory));
        console.log("deployed weth: ", address(weth));
        console.log("deployed position manager: ", address(positionManager));

        // create a pool
                address tokenA = address(new MockERC20());
        address tokenB = address(new MockERC20());
        uint24 fee = 3000;
        uint160 initialSqrtPriceX96 = 79228162514264337593543950336;

        createPoolAndInitialize(factory, tokenA, tokenB, fee, initialSqrtPriceX96);

        // create a position
        createPosition(positionManager, tokenA, tokenB, fee);

        revert("volontary revert");
    }
}
