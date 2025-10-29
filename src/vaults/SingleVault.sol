// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.28;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title SingleVault
 * @author Elli <nathan@lobster-protocol.com>
 * @notice A base vault contract with delegated execution rights and emergency lock functionality
 * @dev Provides a two-tier access control system: Owner (full control) and Allocator (limited operational control)
 * @dev Inherits from Ownable2Step for secure ownership transfers and includes reentrancy protection
 * @dev The owner can lock the vault to prevent allocator operations in emergency situations
 */
contract SingleVault is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice Address authorized to perform vault operations alongside the owner
    /// @dev The allocator has limited permissions compared to the owner and can be blocked by the lock
    address public allocator;

    /// @notice Emergency lock flag that blocks allocator operations when enabled
    /// @dev When true, prevents allocator from executing most vault functions
    /// @dev Only the owner can toggle this lock and owner operations remain unaffected
    bool public locked;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Emitted when the allocator address is updated
     * @param newAllocator The address of the newly set allocator
     */
    event AllocatorUpdated(address indexed newAllocator);

    /**
     * @notice Emitted when the vault lock status changes
     * @param isLocked The new lock status (true = locked, false = unlocked)
     */
    event VaultLocked(bool indexed isLocked);

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Thrown when caller lacks required permissions for the operation
    error Unauthorized();

    /// @notice Thrown when a zero value is provided where a non-zero value is expected
    error ZeroValue();

    /// @notice Thrown when a zero address is provided where a valid address is required
    error ZeroAddress();

    /// @notice Thrown when attempting allocator operations while vault is locked
    error ContractLocked();

    /*//////////////////////////////////////////////////////////////
                                MODIFIERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Ensures the vault is not locked before allowing execution
     * @dev Primarily used to protect allocator operations during emergency situations
     */
    modifier whenNotLocked() {
        _whenNotLocked();
        _;
    }

    /**
     * @notice Restricts function access to either the owner or allocator
     * @dev Provides operational flexibility while maintaining security boundaries
     */
    modifier onlyOwnerOrAllocator() {
        _onlyOwnerOrAllocator();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Initializes the vault with an initial owner and allocator
     * @param initialOwner The address that will become the vault owner
     * @param initialAllocator The address that will become the initial allocator
     */
    constructor(address initialOwner, address initialAllocator) Ownable(initialOwner) {
        // Validate addresses are not zero
        if (initialOwner == address(0) || initialAllocator == address(0)) {
            revert ZeroAddress();
        }

        allocator = initialAllocator;
    }

    /*//////////////////////////////////////////////////////////////
                        ALLOCATOR MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Updates the allocator address
     * @dev Only callable by the owner; change takes effect immediately
     * @dev No timelock is enforced for allocator changes
     * @param newAllocator Address of the new allocator
     */
    function setAllocator(address newAllocator) external onlyOwner {
        allocator = newAllocator;
        emit AllocatorUpdated(newAllocator);
    }

    /*//////////////////////////////////////////////////////////////
                        EMERGENCY CONTROLS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Toggles the vault lock status
     * @dev Only callable by the owner; used to prevent allocator operations in emergencies
     * @dev When locked, allocator cannot perform operations but owner retains full control
     * @param isLocked true to lock the vault, false to unlock
     */
    function lock(bool isLocked) external onlyOwner {
        locked = isLocked;

        emit VaultLocked(isLocked);
    }

    /*//////////////////////////////////////////////////////////////
                        ETH REJECTION
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Rejects all direct ETH transfers to the vault
     * @dev Prevents accidental ETH deposits that could become stuck
     */
    receive() external payable {
        revert("ETH not accepted");
    }

    /**
     * @notice Rejects all undefined function calls and ETH transfers
     * @dev Provides additional protection against accidental interactions
     */
    fallback() external payable {
        revert("ETH not accepted");
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Internal function to verify caller is owner or allocator
     * @dev Used by the onlyOwnerOrAllocator modifier
     */
    function _onlyOwnerOrAllocator() internal view {
        if (msg.sender != allocator && msg.sender != owner()) {
            revert Unauthorized();
        }
    }

    /**
     * @notice Internal function to verify vault is not locked
     * @dev Used by the whenNotLocked modifier to prevent allocator operations when locked
     */
    function _whenNotLocked() internal view {
        if (locked) revert ContractLocked();
    }
}
