// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./UniV3LpVault.sol";

/**
 * @title UniV3LpVaultFactory
 * @author Elli <nathan@lobster-protocol.com>
 * @notice Factory contract for deploying UniV3LpVault contracts with deterministic addresses
 * @dev Uses CREATE2 opcode for deterministic vault deployment, enabling address prediction before deployment.
 *      This factory maintains a registry of all deployed vaults and provides address computation utilities.
 */
contract UniV3LpVaultFactory {
    /**
     * @notice Emitted when a new vault is successfully deployed
     * @param vault The address of the newly deployed vault
     * @param pool The Uniswap V3 pool address associated with the vault
     * @param deployer The address that initiated the vault deployment
     * @param salt The unique salt used for CREATE2 deployment
     */
    event VaultDeployed(address indexed vault, address indexed pool, address indexed deployer, bytes32 salt);

    /**
     * @notice Registry mapping to verify if an address is a vault deployed by this factory
     * @dev Used for authentication and validation of vault contracts
     */
    mapping(address => bool) public isVault;

    /**
     * @notice Deploys a new UniV3LpVault contract using CREATE2 for deterministic addressing
     * @dev The vault address can be pre-computed using `computeVaultAddress` with the same parameters.
     *      Reverts if deployment fails or if a vault already exists at the computed address.
     *
     * @param salt Unique bytes32 salt for deterministic address generation (use different salts for different vaults)
     * @param initialOwner The address that will own the vault (typically has admin privileges)
     * @param initialExecutor The address authorized to execute vault operations
     * @param token0 The first token address in the Uniswap V3 pool pair
     * @param token1 The second token address in the Uniswap V3 pool pair
     * @param pool The Uniswap V3 pool address where liquidity will be managed
     * @param initialFeeCollector The address that will receive collected fees
     * @param initialtvlFee The TVL (Total Value Locked) management fee (in basis points, see vault implementation)
     * @param initialPerformanceFee The performance fee percentage (in basis points, see vault implementation)
     * @param delta Token ratio weight (0 to 1e18) for performance fee calculation
     *              - delta = 0 -> performance fee based entirely on token0 accumulation relative to token1
     *              - delta = 1e18 -> performance fee based entirely on token1 accumulation relative to token0
     *              - delta = 0.5e18 -> equal weighting of both tokens (50% - 50% hold value)
     *
     * @return vault The address of the newly deployed vault contract
     */
    function deployVault(
        bytes32 salt,
        address initialOwner,
        address initialExecutor,
        address token0,
        address token1,
        address pool,
        address initialFeeCollector,
        uint256 initialtvlFee,
        uint256 initialPerformanceFee,
        uint256 delta
    )
        external
        returns (address vault)
    {
        // Deploy vault using CREATE2 for deterministic addressing
        vault = address(
            new UniV3LpVault{salt: salt}(
                initialOwner,
                initialExecutor,
                token0,
                token1,
                pool,
                initialFeeCollector,
                initialtvlFee,
                initialPerformanceFee,
                delta
            )
        );

        isVault[vault] = true;

        emit VaultDeployed(vault, pool, msg.sender, salt);

        return vault;
    }

    /**
     * @notice Computes the deterministic address where a vault will be deployed
     * @dev Useful for predicting vault addresses before deployment or verifying deployment parameters.
     *      The computed address will match the actual deployment address if all parameters are identical.
     *
     * @param salt Unique bytes32 salt for deterministic address generation (must match deployment salt)
     * @param initialOwner Owner address for the vault
     * @param initialExecutor Executor address for the vault
     * @param token0 First token address in the Uniswap V3 pool
     * @param token1 Second token address in the Uniswap V3 pool
     * @param pool Uniswap V3 pool address
     * @param initialFeeCollector Fee collector address
     * @param initialtvlFee TVL management fee amount
     * @param initialPerformanceFee Performance fee amount
     * @param delta Token ratio weight for performance fee calculation (0 to 1e18)
     *
     * @return predicted The deterministic address where the vault will be deployed with these parameters
     */
    function computeVaultAddress(
        bytes32 salt,
        address initialOwner,
        address initialExecutor,
        address token0,
        address token1,
        address pool,
        address initialFeeCollector,
        uint256 initialtvlFee,
        uint256 initialPerformanceFee,
        uint256 delta
    )
        external
        view
        returns (address predicted)
    {
        // Construct the complete bytecode including constructor arguments
        bytes memory bytecode = abi.encodePacked(
            type(UniV3LpVault).creationCode,
            abi.encode(
                initialOwner,
                initialExecutor,
                token0,
                token1,
                pool,
                initialFeeCollector,
                initialtvlFee,
                initialPerformanceFee,
                delta
            )
        );

        // Compute CREATE2 address: keccak256(0xff ++ factoryAddress ++ salt ++ keccak256(bytecode))
        bytes32 hash = keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, keccak256(bytecode)));

        // Convert hash to address (take last 20 bytes)
        return address(uint160(uint256(hash)));
    }
}
