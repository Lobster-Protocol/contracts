// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.28;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

// todo: rename executor -> allocator + add fct to update it ?
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

    /// @notice Wether the owned locked the contract or not. Blocks almost of underlying functions for the executor & executor manager
    bool public locked;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event ExecutorUpdated(address indexed newExecutor);
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
        if (msg.sender != executor && msg.sender != owner()) {
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
    constructor(address initialOwner, address initialExecutor) Ownable(initialOwner) {
        if (initialOwner == address(0) || initialExecutor == address(0)) {
            revert ZeroAddress();
        }

        executor = initialExecutor;
    }

    /*//////////////////////////////////////////////////////////////
                        EXECUTOR MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Initiate executor update with time delay
     * @param newExecutor Address of the new executor
     */
    function setExecutor(address newExecutor) external onlyOwner {
        executor = newExecutor;
        emit ExecutorUpdated(newExecutor);
    }

    /*//////////////////////////////////////////////////////////////
                    EXECUTOR MANAGER MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    function lock(bool isLocked) external onlyOwner {
        locked = isLocked;

        emit VaultLocked(isLocked);
    }

    receive() external payable {
        revert("ETH not accepted");
    }

    fallback() external payable {
        revert("ETH not accepted");
    }
}
