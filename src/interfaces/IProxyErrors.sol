// SPDX-License-Identifier: MIT
pragma solidity >=0.8.4;

/// @title Every custom error LobsterProxy and its mixins revert with
/// @dev One place, so integrators decode a single error ABI. Inherited through {Deadline}, the root
/// of every mixin. Libraries shared with the vault contracts (TransferHelper's `STF`/`ST`/`SA`/`STE`,
/// TickMath's `T`/`R`) keep their short revert strings, the swap path's own token transfers revert with
/// the same `STF`/`ST`, and Uniswap's own errors (V3 pools, the V4 PoolManager) surface unchanged.
interface IProxyErrors {
    // --- Every entry point
    /// @notice `block.timestamp` is past the call's `deadline`
    error TransactionTooOld();
    /// @notice An entry point was called while another one is running (OpenZeppelin's selector)
    error ReentrancyGuardReentrantCall();
    /// @notice `mint`'s recipient is not the caller
    error RecipientMustBeCaller();

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
    /// @notice A swap consumed more than `amountIn` or `amountInMaximum`, or adding V4 liquidity would
    /// cost more than `amount0Limit` / `amount1Limit`
    error TooMuchRequested();
    /// @notice `mint` deposited less than `amount0Min` / `amount1Min`
    error PriceSlippageCheck();
    /// @notice A V4 pool with a hook; only `hooks == address(0)` is supported (`modifyLiquidityV4`;
    /// `swap` cannot even encode one)
    error HooksNotSupported();
    /// @notice `unlockCallback` called by someone other than the PoolManager
    error NotPoolManager();
    /// @notice A pool or the PoolManager returned deltas of an impossible sign, or a V3 swap paid nothing
    error UnexpectedDelta();

    // --- swap
    /// @notice `swap` data that does not follow the packed format (see SwapFlags)
    error MalformedSwap();
    /// @notice A V3 leg's pool address has no pool deployed
    error NotAPool();
    /// @notice A callback the proxy did not expect: a V3 swap callback from anyone but the pool being
    /// called, or an unlock that is neither a swap nor a liquidity unlock
    error UnexpectedCallback();
    /// @notice The PoolManager settled a different amount than the proxy paid it
    error UnexpectedSettlement();
    /// @notice The call ended with parked funds not spent
    error FundsLeftInProxy();
    /// @notice A HELD leg found nothing parked to spend
    error NothingHeld();

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
