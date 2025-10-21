// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.28;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title SingleVault
 * @author Elli <nathan@lobster-protocol.com>
 * @notice A vault contract with time-delayed allocator updates and approved depositor functionality
 * @dev Inherits from Ownable2Step for secure ownership transfers and includes reentrancy protection
 */
contract SingleVault is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice Current allocator address authorized to perform vault operations
    address public allocator;

    /// @notice Wether the owned locked the contract or not. Blocks almost of underlying functions for the allocator & allocator manager
    bool public locked;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event AllocatorUpdated(address indexed newAllocator);
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
        _whenNotLocked();
        _;
    }

    modifier onlyOwnerOrAllocator() {
        _onlyOwnerOrAllocator();

        _;
    }

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Initialize the vault with an initial owner
     * @param initialOwner The address that will become the initial owner
     */
    constructor(address initialOwner, address initialAllocator) Ownable(initialOwner) {
        if (initialOwner == address(0) || initialAllocator == address(0)) {
            revert ZeroAddress();
        }

        allocator = initialAllocator;
    }

    /*//////////////////////////////////////////////////////////////
                        EXECUTOR MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Initiate allocator update with time delay
     * @param newAllocator Address of the new allocator
     */
    function setAllocator(address newAllocator) external onlyOwner {
        allocator = newAllocator;
        emit AllocatorUpdated(newAllocator);
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

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    function _onlyOwnerOrAllocator() internal view {
        if (msg.sender != allocator && msg.sender != owner()) {
            revert Unauthorized();
        }
    }

    function _whenNotLocked() internal view {
        if (locked) revert ContractLocked();
    }
}
