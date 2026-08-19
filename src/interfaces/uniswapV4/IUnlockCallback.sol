// SPDX-License-Identifier: MIT
pragma solidity >=0.8.20;

import {PoolKey, SwapParams} from "./IPoolManagerMinimal.sol";

/// @notice Encoded and passed through `IPoolManager#unlock`, decoded again in `unlockCallback`.
/// @dev The PoolManager does not forward the original caller, so the payer has to be carried here.
/// @dev No `hookData` field: {UniswapProxy} only accepts pools with `hooks == address(0)`, so there
/// is never a hook to pass data to.
struct V4SwapCallbackData {
    PoolKey poolKey;
    SwapParams swapParams;
    address payer;
    address recipient;
}

struct V4ExactInputSingleParams {
    /// @dev `poolKey.hooks` must be address(0); hooked pools are rejected
    PoolKey poolKey;
    bool zeroForOne;
    address recipient;
    uint256 deadline;
    /// @dev v4 deltas are int128, so amounts are bounded by uint128
    uint128 amountIn;
    uint128 amountOutMinimum;
    uint160 sqrtPriceLimitX96;
}

struct V4ExactOutputSingleParams {
    /// @dev `poolKey.hooks` must be address(0); hooked pools are rejected
    PoolKey poolKey;
    bool zeroForOne;
    address recipient;
    uint256 deadline;
    uint128 amountOut;
    uint128 amountInMaximum;
    uint160 sqrtPriceLimitX96;
}

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
