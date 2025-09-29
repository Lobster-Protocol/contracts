// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.28;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title SingleVault
 * @author Elli <nathan@lobster-protocol.com>
 * @notice A vault contract with time-delayed executor updates and approved depositor functionality
 * @dev Inherits from Ownable2Step for secure ownership transfers and includes reentrancy protection
 */
contract SingleVault is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice Current executor address authorized to perform vault operations
    address public executor;

    /// @notice Manager authorized to update the executor (operated by lobster team)
    address public executorManager;

    /// @notice Wether the owned locked the contract or not. Blocks almost of underlying functions for the executor & executor manager
    bool public locked;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event ExecutorUpdated(address indexed newExecutor);
    event ExecutorManagerUpdated(address indexed newManager);
    event VaultLocked(bool indexed isLocked);

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error Unauthorized();
    error ZeroValue();
    error ZeroAddress();
    error ContractLocked();

    /*//////////////////////////////////////////////////////////////
                                MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier whenNotLocked() {
        if (locked) revert ContractLocked();
        _;
    }

    modifier onlyOwnerOrExecutor() {
        require(msg.sender == owner() || msg.sender == executor, Unauthorized());
        _;
    }

    modifier onlyExecutorManagerOrOwner() {
        if (msg.sender != executorManager && msg.sender != owner()) {
            revert Unauthorized();
        }
        _;
    }

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Initialize the vault with an initial owner
     * @param initialOwner The address that will become the initial owner
     */
    constructor(address initialOwner, address initialExecutor, address initialExecutorManager) Ownable(initialOwner) {
        if (initialOwner == address(0) || initialExecutor == address(0) || initialExecutorManager == address(0)) {
            revert ZeroAddress();
        }

        executor = initialExecutor;
        executorManager = initialExecutorManager;
    }

    /*//////////////////////////////////////////////////////////////
                        CORE VAULT FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    // Contract inheriting this one must include a Deposit & Withdraw functions

    /*//////////////////////////////////////////////////////////////
                        EXECUTOR MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Initiate executor update with time delay
     * @param newExecutor Address of the new executor
     */
    function setExecutor(address newExecutor) external onlyExecutorManagerOrOwner {
        executor = newExecutor;
        emit ExecutorUpdated(newExecutor);
    }

    /*//////////////////////////////////////////////////////////////
                    EXECUTOR MANAGER MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Initiate executor manager update with time delay
     * @param newExecutorManager Address of the new executor manager
     */
    function setExecutorManager(address newExecutorManager) external onlyOwner {
        executorManager = newExecutorManager;

        emit ExecutorManagerUpdated(newExecutorManager);
    }

    /*//////////////////////////////////////////////////////////////
                        EMERGENCY FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Emergency function to recover stuck ERC20 tokens
     * @param token Token address to recover
     * @param to Address to send tokens to
     * @param amount Amount to recover
     */
    function emergencyRecoverToken(address token, address to, uint256 amount) external onlyOwner {
        if (token == address(0) || to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroValue();

        IERC20(token).safeTransfer(to, amount);
    }

    /**
     * @notice Emergency function to recover stuck ETH
     * @param to Address to send ETH to
     * @param amount Amount to recover
     */
    function emergencyRecoverETH(address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroValue();
        if (address(this).balance < amount) revert("Insufficient balance");

        (bool success,) = payable(to).call{value: amount}("");
        require(success, "ETH transfer failed");
    }

    /**
     * @dev Universal call function that calls any target with any calldata and value
     * @param target The address of the contract to call
     * @param value The amount of ETH to send with the call
     * @param data The calldata to send to the target contract
     * @return returnData The data returned by the target contract
     */
    function call(
        address target,
        uint256 value,
        bytes calldata data
    )
        public
        payable
        onlyOwner
        returns (bytes memory returnData)
    {
        (bool success, bytes memory result) = target.call{value: value}(data);

        if (!success) {
            // Revert with original error message
            assembly {
                revert(add(result, 0x20), mload(result))
            }
        }

        return result;
    }

    /**
     * @dev Batch call function that executes multiple calls in sequence
     * @param targets Array of addresses to call
     * @param values Array of ETH values to send with each call
     * @param calldatas Array of calldata for each call
     */
    function batchCall(
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata calldatas
    )
        external
        payable
        onlyOwner
    {
        uint256 length = targets.length;
        require(length == values.length && length == calldatas.length, "Array length mismatch");

        for (uint256 i = 0; i < length; i++) {
            // call, revert on error
            call(targets[i], values[i], calldatas[i]);
        }
    }

    function lock(bool isLocked) external onlyOwner {
        locked = isLocked;

        emit VaultLocked(isLocked);
    }

    // Allow contract to receive ETH
    receive() external payable {}
}
