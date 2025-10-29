// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./UniV3LpVault.sol";
import "@openzeppelin/contracts/proxy/Clones.sol";

/**
 * @title UniV3LpVaultFactory
 * @author Elli <nathan@lobster-protocol.com>
 * @notice Factory contract for deploying UniV3LpVault proxies with deterministic addresses
 * @dev Uses OpenZeppelin's Clones library (EIP-1167 minimal proxies) with CREATE2 for gas-efficient
 *      deterministic vault deployment. Each vault is a minimal proxy that delegates to a single
 *      implementation contract, significantly reducing deployment costs.
 */
contract UniV3LpVaultFactory {
    using Clones for address;

    /**
     * @notice The implementation contract that all vault proxies delegate to
     * @dev Set once during factory deployment and immutable thereafter
     */
    address public immutable IMPLEMENTATION;

    /**
     * @notice Emitted when a new vault proxy is successfully deployed
     * @param vault The address of the newly deployed vault proxy
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
     * @notice Initializes the factory with a vault implementation contract
     * @dev The implementation should be a fully initialized UniV3LpVault that will never be used directly,
     *      only delegated to via proxies. Consider deploying the implementation with disabled initializers.
     * @param _implementation The address of the UniV3LpVault implementation contract
     */
    constructor(address _implementation) {
        require(_implementation != address(0), "Invalid implementation");
        IMPLEMENTATION = _implementation;
    }

    /**
     * @notice Deploys a new UniV3LpVault proxy using CREATE2 for deterministic addressing
     * @dev The vault address can be pre-computed using `computeVaultAddress` with the same parameters.
     *      Uses OpenZeppelin's cloneDeterministic which creates an EIP-1167 minimal proxy.
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
     * @return vault The address of the newly deployed vault proxy
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
        // Deploy minimal proxy using CREATE2
        vault = IMPLEMENTATION.cloneDeterministic(salt);

        // Initialize the proxy with the vault parameters
        UniV3LpVault(vault)
            .initialize(
                initialOwner,
                initialExecutor,
                token0,
                token1,
                pool,
                initialFeeCollector,
                initialtvlFee,
                initialPerformanceFee,
                delta
            );

        isVault[vault] = true;

        emit VaultDeployed(vault, pool, msg.sender, salt);

        return vault;
    }

    /**
     * @notice Computes the deterministic address where a vault proxy will be deployed
     * @dev Useful for predicting vault addresses before deployment.
     *      Note: Only the salt matters for address prediction with proxies, as all proxies
     *      share the same bytecode. The initialization parameters don't affect the address.
     *
     * @param salt Unique bytes32 salt for deterministic address generation (must match deployment salt)
     *
     * @return predicted The deterministic address where the vault will be deployed with this salt
     */
    function computeVaultAddress(bytes32 salt) external view returns (address predicted) {
        return IMPLEMENTATION.predictDeterministicAddress(salt, address(this));
    }
}
