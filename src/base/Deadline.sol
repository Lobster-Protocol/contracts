// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.20;

/// @title Shared deadline guard
/// @notice Reverts a transaction that sat in the mempool past the caller's deadline.
/// @dev In its own base so the v3 and v4 mixins can each use it without depending on the other.
/// Declaring the same modifier in two mixins would collide the moment {UniswapProxy} inherits both.
abstract contract Deadline {
    modifier checkDeadline(uint256 deadline) {
        _checkDeadline(deadline);
        _;
    }

    function _checkDeadline(uint256 deadline) internal view {
        require(block.timestamp <= deadline, "Transaction too old");
    }
}
