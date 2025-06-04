// SPDX-License-Identifier: GPLv3
pragma solidity ^0.8.28;

import "forge-std/Script.sol";
import {UniV3LobsterVault} from "../src/Vault/UniV3LobsterVault.sol";
import {IUniswapV3FactoryMinimal} from "../src/interfaces/uniswapV3/IUniswapV3FactoryMinimal.sol";
import {INonFungiblePositionManager} from "../src/interfaces/uniswapV3/INonFungiblePositionManager.sol";
import {IUniswapV3RouterMinimal} from "../src/interfaces/uniswapV3/IUniswapV3RouterMinimal.sol";
import {IUniswapV3PoolMinimal} from "../src/interfaces/uniswapV3/IUniswapV3PoolMinimal.sol";
import {IOpValidatorModule} from "../src/interfaces/modules/IOpValidatorModule.sol";
import {MockERC20} from "../test/Mocks/MockERC20.sol";
import {DummyValidator} from "../test/Mocks/modules/DummyValidator.sol";

// forge script script/DeployUniV3Vault-dummyValidator.s.sol:DeployUniV3LobsterVaultDummyValidator --rpc-url sepolia --private-key <YOUR_PRIVATE_KEY> --broadcast
contract DeployUniV3LobsterVaultDummyValidator is Script {
    // Existing Uniswap V3 contract addresses - sepolia
    IUniswapV3FactoryMinimal constant FACTORY = IUniswapV3FactoryMinimal(0x0227628f3F023bb0B980b67D528571c95c6DaC1c);
    INonFungiblePositionManager constant POSITION_MANAGER =
        INonFungiblePositionManager(0x1238536071E1c677A632429e3655c799b22cDA52);
    IUniswapV3RouterMinimal constant ROUTER = IUniswapV3RouterMinimal(0x3A9D48AB9751398BbFa63ad67599Bb04e4BdF98b);

    // Pool configuration
    uint24 constant POOL_FEE = 3000; // 0.3%
    uint160 constant INITIAL_SQRT_PRICE_X96 = 2 ** 96; // 1:1 price ratio

    // Vault configuration
    uint256 constant FEE_BASIS_POINTS = 100; // 1% fee

    function run()
        external
        returns (
            UniV3LobsterVault vault,
            IUniswapV3PoolMinimal pool,
            MockERC20 tokenA,
            MockERC20 tokenB,
            IOpValidatorModule opValidator
        )
    {
        // Start broadcasting with the provided private key
        vm.startBroadcast();

        address feeCollector = address(0x9198aEf8f3019f064d0826eB9e07Fb07a3d3a4BD);

        console.log("Deployer address:", msg.sender);

        // 1. Deploy test tokens
        console.log("Deploying test tokens...");
        tokenA = new MockERC20();
        tokenB = new MockERC20();

        // Ensure tokenA < tokenB for proper ordering
        if (address(tokenA) > address(tokenB)) {
            (tokenA, tokenB) = (tokenB, tokenA);
        }

        console.log("TokenA deployed at:", address(tokenA));
        console.log("TokenB deployed at:", address(tokenB));

        // 2. Create Uniswap V3 pool
        console.log("Creating Uniswap V3 pool...");
        address poolAddress = FACTORY.createPool(address(tokenA), address(tokenB), POOL_FEE);
        pool = IUniswapV3PoolMinimal(poolAddress);

        console.log("Pool created at:", poolAddress);

        // 3. Initialize the pool with 1:1 price ratio
        console.log("Initializing pool with sqrt price:", INITIAL_SQRT_PRICE_X96);
        pool.initialize(INITIAL_SQRT_PRICE_X96);

        // 4. Deploy validator module
        console.log("Deploying validator module...");
        opValidator = new DummyValidator();
        console.log("Validator deployed at:", address(opValidator));

        // 5. Deploy UniV3LobsterVault
        console.log("Deploying UniV3LobsterVault...");
        vault = new UniV3LobsterVault(opValidator, pool, POSITION_MANAGER, feeCollector, FEE_BASIS_POINTS);

        console.log("UniV3LobsterVault deployed at:", address(vault));

        // 6. Mint some test tokens to deployer for testing
        uint256 mintAmount = 1000000 ether; // 1M tokens
        tokenA.mint(msg.sender, mintAmount);
        tokenB.mint(msg.sender, mintAmount);

        console.log("Minted", mintAmount / 1e18, "tokens of each type to deployer");

        vm.stopBroadcast();

        // Log deployment summary
        console.log("\n=== DEPLOYMENT SUMMARY ===");
        console.log("Factory:", address(FACTORY));
        console.log("Position Manager:", address(POSITION_MANAGER));
        console.log("Router:", address(ROUTER));
        console.log("TokenA:", address(tokenA));
        console.log("TokenB:", address(tokenB));
        console.log("Pool:", address(pool));
        console.log("Pool Fee:", POOL_FEE);
        console.log("Validator:", address(opValidator));
        console.log("Vault:", address(vault));
        console.log("Fee Collector:", feeCollector);
        console.log("Fee Basis Points:", FEE_BASIS_POINTS);
        console.log("Deployer:", msg.sender);

        return (vault, pool, tokenA, tokenB, opValidator);
    }
}
