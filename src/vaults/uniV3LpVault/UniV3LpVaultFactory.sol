// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.28;

import {UniV3LpVault, MAX_SCALED_PERCENTAGE} from "./UniV3LpVault.sol";
import "@openzeppelin/contracts/proxy/Clones.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/**
 * @title UniV3LpVaultFactory
 * @author Elli <nathan@lobster-protocol.com>
 * @notice Factory contract for deploying UniV3LpVault proxies with deterministic addresses
 * @dev Uses OpenZeppelin's Clones library (EIP-1167 minimal proxies) with CREATE2 for gas-efficient
 *      deterministic vault deployment. Each vault is a minimal proxy that delegates to a single
 *      implementation contract, significantly reducing deployment costs.
 */
contract UniV3LpVaultFactory is Ownable2Step {
    using Clones for address;
    using SafeERC20 for IERC20;

    /**
     * @notice The implementation contract that all vault proxies delegate to
     * @dev Set once during factory deployment and immutable thereafter
     */
    address public immutable IMPLEMENTATION;

    /// @notice The protocol fee applied to all deployed vaults (if updated, only the next vault will have the new protocol fee)
    uint256 public protocolFee;

    /**
     * @notice Emitted when a new vault proxy is successfully deployed
     * @param vault The address of the newly deployed vault proxy
     * @param pool The Uniswap V3 pool address associated with the vault
     * @param deployer The address that initiated the vault deployment
     * @param salt The unique salt used for CREATE2 deployment
     */
    event VaultDeployed(address indexed vault, address indexed pool, address indexed deployer, bytes32 salt);

    /**
     * @notice Emitted when ERC20 tokens are withdrawn from the factory
     * @dev token is address(0) when withdrawing native tokens
     * @param token The token address
     * @param to The recipient address
     * @param amount The amount of tokens withdrawn
     */
    event TokenWithdrawn(address indexed token, address indexed to, uint256 amount);

    /**
     * @notice Emitted when the protocol fee is updated
     * @param oldFee The previous protocol fee
     * @param newFee The new protocol fee
     */
    event ProtocolFeeUpdated(uint256 oldFee, uint256 newFee);

    /**
     * @notice Registry mapping to verify if an address is a vault deployed by this factory
     * @dev Used for authentication and validation of vault contracts
     */
    mapping(address => bool) public isVault;

    /**
     * @notice Initializes the factory with a vault implementation contract
     * @dev The implementation should be a fully initialized UniV3LpVault that will never be used directly,
     *      only delegated to via proxies. The implementation is automatically locked during its deployment
     *      via the _disableInitializers() call in its constructor.
     * @param _implementation The address of the UniV3LpVault implementation contract
     * @param initialOwner The initial factory owner
     * @param initialProtocolFee The initial protocol fee
     */
    constructor(address _implementation, address initialOwner, uint256 initialProtocolFee) Ownable(initialOwner) {
        require(_implementation != address(0), "Invalid implementation");

        IMPLEMENTATION = _implementation;
        _updateProtocolFee(initialProtocolFee);
    }

    /**
     * @notice Deploys a new UniV3LpVault proxy using CREATE2 for deterministic addressing
     * @dev The vault address can be pre-computed using `computeVaultAddress` with the same parameters.
     *      Uses OpenZeppelin's cloneDeterministic which creates an EIP-1167 minimal proxy.
     *      Reverts if deployment fails or if a vault already exists at the computed address.
     *
     * @param salt Unique bytes32 salt for deterministic address generation (use different salts for different vaults)
     * @param initialOwner The address that will own the vault (has admin privileges and can deposit/withdraw)
     * @param initialAllocator The address authorized to execute vault strategies (can mint/burn/collect)
     * @param token0 The first token address in the Uniswap V3 pool pair (must be < token1)
     * @param token1 The second token address in the Uniswap V3 pool pair (must be > token0)
     * @param pool The Uniswap V3 pool address where liquidity will be managed
     * @param initialFeeCollector The address that will receive collected fees
     * @param initialtvlFee The TVL (Total Value Locked) annual management fee (scaled by SCALING_FACTOR, e.g., 2e18 = 2%)
     * @param initialPerformanceFee The performance fee on profits (scaled by SCALING_FACTOR, e.g., 20e18 = 20%)
     * @param delta Token ratio weight for performance fee calculation (0 to 1e18, scaled by SCALING_FACTOR)
     * @return vault The address of the newly deployed vault proxy
     */
    function deployVault(
        bytes32 salt,
        address initialOwner,
        address initialAllocator,
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
                initialAllocator,
                token0,
                token1,
                pool,
                initialFeeCollector,
                address(this),
                protocolFee,
                initialtvlFee,
                initialPerformanceFee,
                delta
            );

        // Register the vault in the factory
        isVault[vault] = true;

        emit VaultDeployed(vault, pool, msg.sender, salt);

        return vault;
    }

    /**
     * @notice Computes the deterministic address where a vault proxy will be deployed
     * @dev Useful for predicting vault addresses before deployment.
     *      Note: Only the salt matters for address prediction with EIP-1167 proxies, as all proxies
     *      share the same bytecode. The initialization parameters don't affect the address.
     *
     * @param salt Unique bytes32 salt for deterministic address generation (must match deployment salt)
     *
     * @return predicted The deterministic address where the vault will be deployed with this salt
     */
    function computeVaultAddress(bytes32 salt) external view returns (address predicted) {
        return IMPLEMENTATION.predictDeterministicAddress(salt, address(this));
    }

    /**
     * @notice Updates the protocol fee for newly deployed vaults
     * @dev Only callable by the factory owner. This change only affects vaults deployed after the update.
     *      Existing vaults retain their original protocol fee.
     * @param newProtocolFee The new protocol fee (scaled by SCALING_FACTOR, must be <= MAX_SCALED_PERCENTAGE)
     */
    function updateProtocolFee(uint256 newProtocolFee) external onlyOwner {
        _updateProtocolFee(newProtocolFee);
    }

    /**
     * @notice Withdraws ETH from the factory to the specified recipient
     * @dev Only callable by the factory owner
     * @param to The address to receive the ETH
     * @param amount The amount of ETH to withdraw
     */
    function withdrawETH(address to, uint256 amount) external onlyOwner {
        require(to != address(0), "Invalid recipient");
        require(amount <= address(this).balance, "Insufficient balance");

        (bool success,) = to.call{value: amount}("");
        require(success, "ETH transfer failed");

        emit TokenWithdrawn(address(0), to, amount);
    }

    /**
     * @notice Withdraws ERC20 tokens from the factory to the specified recipient
     * @dev Only callable by the factory owner. Used to collect protocol fees paid in ERC20 tokens.
     * @param token The ERC20 token address to withdraw
     * @param to The address to receive the tokens
     * @param amount The amount of tokens to withdraw
     */
    function withdrawToken(address token, address to, uint256 amount) external onlyOwner {
        require(token != address(0), "Invalid token");
        require(to != address(0), "Invalid recipient");

        IERC20(token).safeTransfer(to, amount);

        emit TokenWithdrawn(token, to, amount);
    }

    /**
     * @notice Allows the factory to receive ETH
     */
    receive() external payable {}

    /**
     * @notice Updates the protocol fee for newly deployed vaults
     * @dev This change only affects vaults deployed after the update.
     *      Existing vaults retain their original protocol fee.
     * @param newProtocolFee The new protocol fee (scaled by SCALING_FACTOR, must be <= MAX_SCALED_PERCENTAGE)
     */
    function _updateProtocolFee(uint256 newProtocolFee) internal {
        require(newProtocolFee <= MAX_SCALED_PERCENTAGE, "Protocol fee too high");

        uint256 oldFee = protocolFee;
        protocolFee = newProtocolFee;

        emit ProtocolFeeUpdated(oldFee, newProtocolFee);
    }
}

/**
 * @notice Struct containing all initialization parameters for a vault
 * @dev Used for batch deployment to group parameters efficiently
 */
struct VaultParams {
    address initialOwner;
    address initialAllocator;
    address token0;
    address token1;
    address pool;
    address initialFeeCollector;
    uint256 initialtvlFee;
    uint256 initialPerformanceFee;
    uint256 delta;
}
