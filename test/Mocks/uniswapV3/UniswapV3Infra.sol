// SPDX-License-Identifier: GPLv3
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import {IUniswapV3FactoryMinimal} from "../../../src/interfaces/uniswapV3/IUniswapV3FactoryMinimal.sol";
import {INonFungiblePositionManager} from "../../../src/interfaces/uniswapV3/INonFungiblePositionManager.sol";
import {FACTORY_BYTECODE} from "./bytecodes/factory.sol";
import {NON_FUNGIBLE_POSITION_MANAGER_BYTECODE} from "./bytecodes/positionManager.sol";
import {WETH_BYTECODE} from "./bytecodes/weth.sol";
import {IWETH} from "../../../src/interfaces/IWETH.sol";
import {TOKEN_POSITION_DESCRIPTOR_BYTECODE} from "./bytecodes/tokenPositionDescriptor.sol";
import {MockERC20} from "../MockERC20.sol";
import {IUniswapV3PoolMinimal} from "../../../src/interfaces/uniswapV3/IUniswapV3PoolMinimal.sol";
import {IUniswapV3RouterMinimal} from "../../../src/interfaces/uniswapV3/IUniswapV3RouterMinimal.sol";
import {ROUTER_BYTECODE} from "./bytecodes/router.sol";

// deploy and interact with Uniswap V3 contracts
contract UniswapV3Infra is Test {
    function deploy()
        public
        returns (
            IUniswapV3FactoryMinimal factory,
            IWETH weth,
            INonFungiblePositionManager positionManager,
            IUniswapV3RouterMinimal router
        )
    {
        // Deploy factory
        bytes memory factoryBytecode = FACTORY_BYTECODE;

        // No need for constructor arguments

        address deployedFactory;
        assembly {
            // Make sure we're not trying to deploy empty bytecode
            if iszero(mload(factoryBytecode)) { revert(0, 0) }

            deployedFactory :=
                create(
                    0, // No ETH sent
                    add(factoryBytecode, 0x20), // Skip the first 32 bytes (length prefix)
                    mload(factoryBytecode) // Length of bytecode
                )

            // If deployment failed, revert with a detailed message
            if iszero(deployedFactory) {
                mstore(0x00, 0x08c379a0) // Error signature
                mstore(0x04, 0x20) // String offset
                mstore(0x24, 23) // String length
                mstore(0x44, "Factory deployment failed") // String data
                revert(0, 0x64) // Revert with reason
            }
        }

        factory = IUniswapV3FactoryMinimal(deployedFactory);

        // Deploy weth
        bytes memory wethBytecode = WETH_BYTECODE;
        address deployedWeth;
        assembly {
            // Make sure we're not trying to deploy empty bytecode
            if iszero(mload(wethBytecode)) { revert(0, 0) }

            deployedWeth :=
                create(
                    0, // No ETH sent
                    add(wethBytecode, 0x20), // Skip the first 32 bytes (length prefix)
                    mload(wethBytecode) // Length of bytecode
                )

            // If deployment failed, revert with a detailed message
            if iszero(deployedWeth) {
                mstore(0x00, 0x08c379a0) // Error signature
                mstore(0x04, 0x20) // String offset
                mstore(0x24, 23) // String length
                mstore(0x44, "WETH deployment failed") // String data
                revert(0, 0x64) // Revert with reason
            }
        }
        weth = IWETH(deployedWeth);

        // deploy token position descriptor
        bytes memory tokenPositionDescriptorBytecode = TOKEN_POSITION_DESCRIPTOR_BYTECODE;

        bytes memory nativeCurrencyLabelBytes = abi.encodePacked("ETH");
        bytes memory tokenPositionDescriptorConstructorArgs = abi.encode(
            // address _WETH9, bytes32 _nativeCurrencyLabelBytes
            address(weth),
            bytes32(nativeCurrencyLabelBytes)
        );

        // Append constructor args to the bytecode
        bytes memory tokenPositionDescriptorBytecodeWithArgs =
            bytes.concat(tokenPositionDescriptorBytecode, tokenPositionDescriptorConstructorArgs);

        address deployedTokenPositionDescriptor;
        assembly {
            // Make sure we're not trying to deploy empty bytecode
            if iszero(mload(tokenPositionDescriptorBytecodeWithArgs)) { revert(0, 0) }

            deployedTokenPositionDescriptor :=
                create(
                    0, // No ETH sent
                    add(tokenPositionDescriptorBytecodeWithArgs, 0x20), // Skip the first 32 bytes (length prefix)
                    mload(tokenPositionDescriptorBytecodeWithArgs) // Length of bytecode
                )

            // If deployment failed, revert with a detailed message
            if iszero(deployedTokenPositionDescriptor) {
                mstore(0x00, 0x08c379a0) // Error signature
                mstore(0x04, 0x20) // String offset
                mstore(0x24, 30) // String length
                mstore(0x44, "TPDescriptor deployment failed") // String data
                revert(0, 0x64) // Revert with reason
            }
        }

        // Deploy position manager
        bytes memory positionManagerBytecode = NON_FUNGIBLE_POSITION_MANAGER_BYTECODE;

        // Encode constructor arguments
        bytes memory positionManagerConstructorArgs = abi.encode(
            address(factory), // _factory
            address(weth), // _WETH9
            address(deployedTokenPositionDescriptor) // _tokenDescriptor_
        );

        // Append constructor arguments to bytecode
        bytes memory positionManagerBytecodeWithArgs =
            bytes.concat(positionManagerBytecode, positionManagerConstructorArgs);

        address deployedPositionManager;
        assembly {
            // Make sure we're not trying to deploy empty bytecode
            if iszero(mload(positionManagerBytecodeWithArgs)) { revert(0, 0) }

            deployedPositionManager :=
                create(
                    0, // No ETH sent
                    add(positionManagerBytecodeWithArgs, 0x20), // Skip the first 32 bytes (length prefix)
                    mload(positionManagerBytecodeWithArgs) // Length of bytecode
                )

            // If deployment failed, revert with a detailed message
            if iszero(deployedPositionManager) {
                mstore(0x00, 0x08c379a0) // Error signature
                mstore(0x04, 0x20) // String offset
                mstore(0x24, 30) // String length
                mstore(0x44, "PM deployment failed") // String data
                revert(0, 0x64) // Revert with reason
            }
        }

        positionManager = INonFungiblePositionManager(deployedPositionManager);

        // Deploy router
        bytes memory routerBytecode = ROUTER_BYTECODE;
        bytes memory routerConstructorArgs = abi.encode(
            address(factory), // _factory
            address(weth) // _WETH9
        );

        bytes memory routerBytecodeWithArgs = bytes.concat(routerBytecode, routerConstructorArgs);

        address deployedRouter;
        assembly {
            // Make sure we're not trying to deploy empty bytecode
            if iszero(mload(routerBytecodeWithArgs)) { revert(0, 0) }

            deployedRouter :=
                create(
                    0, // No ETH sent
                    add(routerBytecodeWithArgs, 0x20), // Skip the first 32 bytes (length prefix)
                    mload(routerBytecodeWithArgs) // Length of bytecode
                )

            // If deployment failed, revert with a detailed message
            if iszero(deployedRouter) {
                mstore(0x00, 0x08c379a0) // Error signature
                mstore(0x04, 0x20) // String offset
                mstore(0x24, 23) // String length
                mstore(0x44, "Router deployment failed") // String data
                revert(0, 0x64) // Revert with reason
            }
        }

        router = IUniswapV3RouterMinimal(deployedRouter);
    }

    function createPoolAndInitialize(
        IUniswapV3FactoryMinimal factory,
        address tokenA,
        address tokenB,
        uint24 fee,
        uint160 initialSqrtPriceX96
    )
        public
        returns (IUniswapV3PoolMinimal pool)
    {
        // Create a pool with the specified parameters
        pool = IUniswapV3PoolMinimal(factory.createPool(tokenA, tokenB, fee));

        // Initialize the pool with the specified initial price
        // The initial price is set to 1:1 for simplicity
        pool.initialize(initialSqrtPriceX96);
    }

    function createPosition(
        INonFungiblePositionManager positionManager,
        address tokenA,
        address tokenB,
        uint256 amountA,
        uint256 amountB,
        uint24 fee,
        address recipient
    )
        public
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        int24 tickLower = -6000; // Lower tick range
        int24 tickUpper = 6000; // Upper tick range

        // Minimum amounts to accept (for slippage protection)
        uint256 amountAMin = (amountA * 99) / 100; // 1% slippage tolerance
        uint256 amountBMin = (amountB * 99) / 100; // 1% slippage tolerance

        // Approve the position manager to spend our tokens
        MockERC20(tokenA).approve(address(positionManager), amountA);
        MockERC20(tokenB).approve(address(positionManager), amountB);

        // Set a deadline 30 minutes from now
        uint256 deadline = block.timestamp + 30 minutes;

        INonFungiblePositionManager.MintParams memory params = INonFungiblePositionManager.MintParams({
            token0: tokenA < tokenB ? tokenA : tokenB,
            token1: tokenA < tokenB ? tokenB : tokenA,
            fee: fee,
            tickLower: tickLower,
            tickUpper: tickUpper,
            amount0Desired: tokenA < tokenB ? amountA : amountB,
            amount1Desired: tokenA < tokenB ? amountB : amountA,
            amount0Min: tokenA < tokenB ? amountAMin : amountBMin,
            amount1Min: tokenA < tokenB ? amountBMin : amountAMin,
            recipient: recipient,
            deadline: deadline
        });

        // Mint the position
        (tokenId, liquidity, amount0, amount1) = positionManager.mint(params);

        return (tokenId, liquidity, amount0, amount1);
    }
}
