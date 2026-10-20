// SPDX-License-Identifier: MIT
pragma solidity >=0.8.20;

import {PoolKey, SwapParams} from "./IPoolManagerMinimal.sol";

/// @notice Unlock data for a single swap: the common case, and the cheapest to encode and decode.
/// @dev The PoolManager does not forward the original caller, so the payer has to be carried here.
/// No `hookData` field: {UniswapProxy} only accepts pools with `hooks == address(0)`, so there is
/// never a hook to pass data to. Its encoding always starts with a zero byte (the first word is
/// `poolKey.currency0`, an address), which is how `unlockCallback` tells it from a chain.
struct V4SwapCallbackData {
    PoolKey poolKey;
    SwapParams swapParams;
    address payer;
    address recipient;
}

/// @notice One swap. Built only by the proxy, from validated params.
struct V4Leg {
    PoolKey poolKey;
    bool zeroForOne;
    bool exactInput;
    /// @dev Exact input only: spend everything the proxy holds of the input currency (credit left
    /// by earlier legs of the same unlock, plus its own balance), paid by the proxy. `amount` is
    /// then ignored. Set only by `batchSwap`, for `amountIn == Chaining.HELD_BALANCE`.
    bool fromHeld;
    /// @dev amountIn for exact input, amountOut for exact output
    uint128 amount;
    /// @dev amountOutMinimum for exact input, amountInMaximum for exact output
    uint128 bound;
    /// @dev 0 means no limit
    uint160 sqrtPriceLimitX96;
    /// @dev Already validated. `address(this)` means park: keep the output as credit in the
    /// PoolManager for a later leg, and move whatever is left into the proxy when the unlock ends.
    address recipient;
}

/// @notice Unlock data for a chain of swaps run in one unlock, each spending what the previous parked.
/// @dev Passed through `IPoolManager#unlock` behind a leading tag byte. The payer pays every leg that
/// is not `fromHeld`.
struct V4UnlockData {
    address payer;
    V4Leg[] legs;
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
