// SPDX-License-Identifier: GPL-3.0
// Matches the exact pin in src/UniswapProxy.sol, so the broadcast artifact is byte-identical to the
// one the tests exercise.
pragma solidity =0.8.26;

import "forge-std/Script.sol";
import {UniswapProxy} from "../src/UniswapProxy.sol";

contract DeployUniswapProxy is Script {
    // Network-specific addresses
    struct NetworkConfig {
        address uniV3Factory;
        address poolManager;
    }

    function run() external returns (UniswapProxy proxy) {
        NetworkConfig memory config = getNetworkConfig();

        // A wrong factory address silently breaks every callback check (CallbackValidation derives
        // pool addresses from it), and a wrong PoolManager breaks every v4 swap. Both are immutable
        // after construction, so verify there is code at each before spending gas.
        require(config.uniV3Factory.code.length > 0, "No code at UniV3 factory");
        require(config.poolManager.code.length > 0, "No code at PoolManager");

        vm.startBroadcast();

        proxy = new UniswapProxy(config.uniV3Factory, config.poolManager);

        vm.stopBroadcast();

        console.log("UniswapProxy deployed at:  ", address(proxy));
        console.log("Uniswap V3 Factory:        ", config.uniV3Factory);
        console.log("Uniswap V4 PoolManager:    ", config.poolManager);
    }

    function getNetworkConfig() internal view returns (NetworkConfig memory) {
        uint256 chainId = block.chainid;

        // Anvil's default chain id. A mainnet fork keeps chain id 1 unless `--chain-id` overrides it,
        // so this branch only fires for a non-forked node, where mainnet addresses are still the
        // right answer for a fork started from mainnet state.
        if (chainId == 1 || chainId == 31337) {
            return NetworkConfig({
                uniV3Factory: 0x1F98431c8aD98523631AE4a59f267346ea31F984,
                poolManager: 0x000000000004444c5dc75cB358380D2e3dE08A90
            });
        }
        if (chainId == 42161) {
            // Arbitrum One
            return NetworkConfig({
                uniV3Factory: 0x1F98431c8aD98523631AE4a59f267346ea31F984,
                poolManager: 0x360E68faCcca8cA495c1B759Fd9EEe466db9FB32
            });
        }
        if (chainId == 11155111) {
            // Sepolia
            return NetworkConfig({
                uniV3Factory: 0x0227628f3F023bb0B980b67D528571c95c6DaC1c,
                poolManager: 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543
            });
        }
        revert("Unknown network");
    }
}
