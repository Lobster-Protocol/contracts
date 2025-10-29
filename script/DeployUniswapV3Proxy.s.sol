// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.20;

import "forge-std/Script.sol";
import "../src/UniswapV3Proxy.sol";

contract DeployUniswapV3Proxy is Script {
    // Network-specific addresses
    struct NetworkConfig {
        address uniV3Factory;
    }

    function run() external {
        NetworkConfig memory config = getNetworkConfig();

        vm.startBroadcast();

        UniswapV3Proxy proxy = new UniswapV3Proxy(config.uniV3Factory);

        vm.stopBroadcast();

        console.log("UniswapV3Proxy deployed at:", address(proxy));
        console.log("Uniswap V3 Factory address:", config.uniV3Factory);
    }

    function getNetworkConfig() internal view returns (NetworkConfig memory) {
        uint256 chainId = block.chainid;

        if (chainId == 42161) {
            // Arbitrum One
            return NetworkConfig({uniV3Factory: 0x1F98431c8aD98523631AE4a59f267346ea31F984});
        } else {
            // Default to mainnet addresses for unknown networks
            revert("Warning: Unknown network, using mainnet addresses");
        }
    }
}
