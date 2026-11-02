// SPDX-License-Identifier: MIT
pragma solidity >=0.8.20;

/// @title Callback for IPoolManager#unlock
/// @notice Any contract that calls IPoolManager#unlock must implement this interface
interface IUnlockCallback {
    /// @notice Called by the pool manager on `msg.sender` when the manager is unlocked
    /// @dev The implementation must leave every currency delta netted to zero before returning,
    /// otherwise the manager reverts with `CurrencyNotSettled`.
    /// @param data The data that was passed to the call to unlock
    /// @return Any data that you want to be returned from the unlock call
    function unlockCallback(bytes calldata data) external returns (bytes memory);
}
