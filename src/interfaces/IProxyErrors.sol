// SPDX-License-Identifier: MIT
pragma solidity >=0.8.4;

/// @title Every custom error LobsterProxy and its mixins revert with
/// @dev One place, so integrators decode a single error ABI. Inherited through {Deadline}, the root
/// of every mixin. Libraries shared with the vault contracts (TransferHelper's `STF`/`ST`/`SA`/`STE`,
/// TickMath's `T`/`R`) keep their short revert strings, and Uniswap's own errors (V3 pools, the V4
/// PoolManager) surface unchanged.
interface IProxyErrors {
    // --- Every entry point
    /// @notice `block.timestamp` is past the call's `deadline`
    error TransactionTooOld();
    /// @notice The recipient is not the caller (LobsterProxy entry points; batch legs may also
    /// name `Chaining.ADDRESS_THIS`)
    error RecipientMustBeCaller();
    /// @notice The recipient is address(0), the proxy or `ADDRESS_THIS` (the mixins' own entry points)
    error InvalidRecipient();

    // --- Pool registry
    /// @notice The caller has not registered this pool with the permission the call needs
    error PoolNotAllowed();
    /// @notice `setPools` got arrays of different lengths
    error LengthMismatch();
    /// @notice `setPools` got bits other than PERMISSION_MINT and PERMISSION_SWAP
    error InvalidPermissions();

    // --- Price bands
    /// @notice `setPriceBand` got minTick >= maxTick, or a tick outside the range Uniswap allows
    error InvalidPriceBand();
    /// @notice Adding liquidity to, or swapping on, a pool the caller has set no price band for
    error PriceBandNotSet();
    /// @notice Adding liquidity or swapping while the pool's current tick is outside the caller's price
    /// band, or a swap that would leave it outside
    error PriceOutOfBand();

    // --- Swaps and mint
    /// @notice Less output than `amountOutMinimum` (swaps), or than `amount0Limit` / `amount1Limit`
    /// when removing V4 liquidity or collecting fees
    error TooLittleReceived();
    /// @notice A swap consumed more than `amountIn`, or adding V4 liquidity would cost more than
    /// `amount0Limit` / `amount1Limit`
    error TooMuchRequested();
    /// @notice `mint` deposited less than `amount0Min` / `amount1Min`
    error PriceSlippageCheck();
    /// @notice A V4 pool with a hook; only `hooks == address(0)` is supported
    error HooksNotSupported();
    /// @notice `unlockCallback` or `receive` called by someone other than the PoolManager
    error NotPoolManager();
    /// @notice A hookless V4 swap returned deltas of an impossible sign
    error UnexpectedDelta();

    // --- batchSwap
    /// @notice An empty item, or a first byte other than 0x01-0x04
    error InvalidSwapType();
    /// @notice The batch ended with parked funds still in the proxy
    error FundsLeftInProxy();
    /// @notice A `HELD_BALANCE` leg found nothing to spend
    error NothingHeld();
    /// @notice Native ETH input in a batch that does not come from an earlier parked output
    error NativeInputMustComeFromAPreviousSwap();

    // --- V4 liquidity
    /// @notice The caller has not configured its Roles modifier with `setV4Roles`
    error V4RolesNotSet();
    /// @notice The Roles modifier's avatar or target is not the caller
    error RolesModifierNotTheVaults();
    /// @notice msg.value does not cover the ETH the vault owes
    error NotEnoughEthSent();
    /// @notice A liquidity unlock that `modifyLiquidityV4` did not open
    error NoLiquidityOperation();
}
