// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./UniV3LpVault.sol";

/**
 * @title UniV3LpVaultFactory
 * @notice Factory contract for deploying UniV3LpVault contracts using CREATE2
 * @dev Allows deterministic vault deployment based on salt and parameters
 */
contract UniV3LpVaultFactory {
    /// @notice Emitted when a new vault is deployed
    event VaultDeployed(address indexed vault, address indexed pool, address indexed deployer, bytes32 salt);

    /// @notice Mapping to check if an address is a vault deployed by this factory
    mapping(address => bool) public isVault;

    /**
     * @notice Deploys a new UniV3LpVault using CREATE2
     * @param salt Unique salt for deterministic address generation
     * @param initialOwner Owner address for the vault
     * @param initialExecutor Executor address for the vault
     * @param token0 First token in the Uniswap V3 pool
     * @param token1 Second token in the Uniswap V3 pool
     * @param pool Uniswap V3 pool address
     * @param initialFeeCollector Fee collector address
     * @param initialtvlFee TVL fee amount
     * @param initialPerformanceFee Performance fee amount
     * @return vault Address of the deployed vault
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
        uint256 initialPerformanceFee
    )
        external
        returns (address vault)
    {
        // Deploy vault using CREATE2
        vault = address(
            new UniV3LpVault{salt: salt}(
                initialOwner,
                initialExecutor,
                token0,
                token1,
                pool,
                initialFeeCollector,
                initialtvlFee,
                initialPerformanceFee
            )
        );

        // Mark as deployed vault
        isVault[vault] = true;

        emit VaultDeployed(vault, pool, msg.sender, salt);

        return vault;
    }

    /**
     * @notice Computes the address of a vault before deployment
     * @param salt Unique salt for deterministic address generation
     * @param initialOwner Owner address for the vault
     * @param initialExecutor Executor address for the vault
     * @param token0 First token in the Uniswap V3 pool
     * @param token1 Second token in the Uniswap V3 pool
     * @param pool Uniswap V3 pool address
     * @param initialFeeCollector Fee collector address
     * @param initialtvlFee TVL fee amount
     * @param initialPerformanceFee Performance fee amount
     * @return predicted Address where the vault will be deployed
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
        uint256 initialPerformanceFee
    )
        external
        view
        returns (address predicted)
    {
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
                initialPerformanceFee
            )
        );

        bytes32 hash = keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, keccak256(bytecode)));

        return address(uint160(uint256(hash)));
    }
}
