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
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Delay required before a new executor can be enabled (7 days)
    uint256 public constant EXECUTOR_UPDATE_DELAY = 7 days;

    /// @notice Delay required before a new executor manager can be enabled (3 days)
    uint256 public constant EXECUTOR_MANAGER_UPDATE_DELAY = 3 days;

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice Current executor address authorized to perform vault operations
    address public executor;

    /// @notice Manager authorized to update the executor (operated by lobster team)
    address public executorManager;

    /// @notice Timestamp when executor update was initiated
    uint256 public executorUpdatedAt;

    /// @notice Pending executor waiting for time delay to complete
    address public pendingExecutor;

    /// @notice Timestamp when executor manager update was initiated
    uint256 public executorManagerUpdatedAt;

    /// @notice Pending executor manager waiting for time delay to complete
    address public pendingExecutorManager;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event ExecutorUpdateInitiated(address indexed newExecutor, uint256 timestamp);
    event ExecutorUpdated(address indexed oldExecutor, address indexed newExecutor);
    event ExecutorManagerUpdateInitiated(address indexed newManager, uint256 timestamp);
    event ExecutorManagerUpdated(address indexed oldManager, address indexed newManager);
    event ExecutorUpdateCancelled(address indexed cancelledExecutor);
    event ExecutorManagerUpdateCancelled(address indexed cancelledManager);

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error Unauthorized();
    error ZeroValue();
    error IncompleteDelay(uint256 remainingSeconds);
    error NoPendingUpdate();
    error ZeroAddress();
    error InvalidDelay();

    /*//////////////////////////////////////////////////////////////
                                MODIFIERS
    //////////////////////////////////////////////////////////////*/

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
        if (newExecutor == address(0)) revert ZeroAddress();

        pendingExecutor = newExecutor;
        executorUpdatedAt = block.timestamp;

        emit ExecutorUpdateInitiated(newExecutor, block.timestamp);
    }

    /**
     * @notice Enable the pending executor after delay period
     */
    function enableExecutor() external onlyExecutorManagerOrOwner {
        if (pendingExecutor == address(0)) revert NoPendingUpdate();

        uint256 timeElapsed = block.timestamp - executorUpdatedAt;
        if (timeElapsed < EXECUTOR_UPDATE_DELAY) {
            revert IncompleteDelay(EXECUTOR_UPDATE_DELAY - timeElapsed);
        }

        address oldExecutor = executor;
        executor = pendingExecutor;
        pendingExecutor = address(0);
        executorUpdatedAt = 0;

        emit ExecutorUpdated(oldExecutor, executor);
    }

    /**
     * @notice Cancel pending executor update
     */
    function cancelExecutorUpdate() external onlyExecutorManagerOrOwner {
        if (pendingExecutor == address(0)) revert NoPendingUpdate();

        address cancelled = pendingExecutor;
        pendingExecutor = address(0);
        executorUpdatedAt = 0;

        emit ExecutorUpdateCancelled(cancelled);
    }

    /*//////////////////////////////////////////////////////////////
                    EXECUTOR MANAGER MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Initiate executor manager update with time delay
     * @param newExecutorManager Address of the new executor manager
     */
    function setExecutorManager(address newExecutorManager) external onlyOwner {
        if (newExecutorManager == address(0)) revert ZeroAddress();

        pendingExecutorManager = newExecutorManager;
        executorManagerUpdatedAt = block.timestamp;

        emit ExecutorManagerUpdateInitiated(newExecutorManager, block.timestamp);
    }

    /**
     * @notice Enable the pending executor manager after delay period
     */
    function enableExecutorManager() external onlyOwner {
        if (pendingExecutorManager == address(0)) revert NoPendingUpdate();

        uint256 timeElapsed = block.timestamp - executorManagerUpdatedAt;
        if (timeElapsed < EXECUTOR_MANAGER_UPDATE_DELAY) {
            revert IncompleteDelay(EXECUTOR_MANAGER_UPDATE_DELAY - timeElapsed);
        }

        address oldManager = executorManager;
        executorManager = pendingExecutorManager;
        pendingExecutorManager = address(0);
        executorManagerUpdatedAt = 0;

        emit ExecutorManagerUpdated(oldManager, executorManager);
    }

    /**
     * @notice Cancel pending executor manager update
     */
    function cancelExecutorManagerUpdate() external onlyOwner {
        if (pendingExecutorManager == address(0)) revert NoPendingUpdate();

        address cancelled = pendingExecutorManager;
        pendingExecutorManager = address(0);
        executorManagerUpdatedAt = 0;

        emit ExecutorManagerUpdateCancelled(cancelled);
    }

    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Get time remaining for executor update
     * @return remainingTime Time in seconds remaining for delay, 0 if ready
     */
    function getExecutorUpdateTimeRemaining() external view returns (uint256 remainingTime) {
        if (pendingExecutor == address(0) || executorUpdatedAt == 0) {
            return 0;
        }

        uint256 timeElapsed = block.timestamp - executorUpdatedAt;
        if (timeElapsed >= EXECUTOR_UPDATE_DELAY) {
            return 0;
        }

        return EXECUTOR_UPDATE_DELAY - timeElapsed;
    }

    /**
     * @notice Get time remaining for executor manager update
     * @return remainingTime Time in seconds remaining for delay, 0 if ready
     */
    function getExecutorManagerUpdateTimeRemaining() external view returns (uint256 remainingTime) {
        if (pendingExecutorManager == address(0) || executorManagerUpdatedAt == 0) {
            return 0;
        }

        uint256 timeElapsed = block.timestamp - executorManagerUpdatedAt;
        if (timeElapsed >= EXECUTOR_MANAGER_UPDATE_DELAY) {
            return 0;
        }

        return EXECUTOR_MANAGER_UPDATE_DELAY - timeElapsed;
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

    // todo: add call fct
}
