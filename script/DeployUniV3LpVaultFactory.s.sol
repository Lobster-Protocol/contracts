// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.28;

import "forge-std/Script.sol";
import "../src/vaults/uniV3LpVault/UniV3LpVault.sol";
import "../src/vaults/uniV3LpVault/UniV3LpVaultFactory.sol";

/**
 * @title DeployFactory
 * @notice Forge script to deploy UniV3LpVault implementation, factory, and first vault
 * @dev Usage:
 *      forge script script/DeployFactory.s.sol:DeployFactory --rpc-url <RPC_URL> --broadcast --verify
 */
contract DeployFactory is Script {
    address public implementation;
    address public factory;
    address public vault;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("Deployer address:", deployer);
        console.log("Deployer balance:", deployer.balance);

        vm.startBroadcast(deployerPrivateKey);

        // Deploy implementation
        console.log("\nDeploying Implementation...");
        implementation = address(new UniV3LpVault());
        console.log("Implementation:", implementation);

        // Deploy factory
        console.log("\nDeploying Factory...");
        factory = address(new UniV3LpVaultFactory(implementation, address(1), 0));
        console.log("Factory:", factory);

        // Deploy first vault
        console.log("\nDeploying First Vault...");
        vault = UniV3LpVaultFactory(factory)
            .deployVault(
                bytes32(uint256(1)), // salt
                address(0x57216272F995c6FbE1Ca425925975A1eAAe08596), // initialOwner
                address(0x57216272F995c6FbE1Ca425925975A1eAAe08596), // initialAllocator
                address(0x82aF49447D8a07e3bd95BD0d56f35241523fBab1), // token0 (WETH)
                address(0xaf88d065e77c8cC2239327C5EDb3A432268e5831), // token1 (USDC)
                address(0xC6962004f452bE9203591991D15f6b388e09E8D0), // pool
                address(0x57216272F995c6FbE1Ca425925975A1eAAe08596), // initialFeeCollector
                1e18, // initialtvlFee (1%)
                1e18, // initialPerformanceFee (1%)
                5e17 // delta (50%)
            );
        console.log("Vault:", vault);

        vm.stopBroadcast();

        console.log("\n=== Deployment Summary ===");
        console.log("Implementation:", implementation);
        console.log("Factory:", factory);
        console.log("Vault:", vault);
    }
}
