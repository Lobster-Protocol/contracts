// SPDX-License-Identifier: MIT
pragma solidity >=0.8.20;

/// @dev A Currency is just an address. The zero address is the native currency (ETH), which is a
/// first-class citizen in v4 — unlike v3, where it always had to be wrapped into WETH.
type Currency is address;

/// @dev Two int128 packed into one int256: the upper 128 bits are amount0, the lower 128 bits are
/// amount1. See {BalanceDeltaLibrary} for the accessors.
type BalanceDelta is int256;

/// @notice v4 pools may attach a hook contract. We never call it directly, we only need the address
/// so that the PoolKey hashes to the right pool id.
interface IHooks {}

/// @notice Uniquely identifies a v4 pool. Unlike v3 there is no pool contract to derive, the key
/// itself is hashed by the PoolManager into a `PoolId`.
struct PoolKey {
    Currency currency0;
    Currency currency1;
    uint24 fee;
    int24 tickSpacing;
    IHooks hooks;
}

/// @notice Parameters for IPoolManager#swap
struct SwapParams {
    /// @dev Whether to swap currency0 for currency1 or vice versa
    bool zeroForOne;
    /// @dev The desired input amount if negative (exactIn), or the desired output amount if positive (exactOut).
    /// NOTE: this is the opposite of the v3 convention.
    int256 amountSpecified;
    /// @dev The sqrt price at which, if reached, the swap will stop executing
    uint160 sqrtPriceLimitX96;
}

/// @notice Parameters for IPoolManager#modifyLiquidity (v4-core `IPoolManager.ModifyLiquidityParams`)
struct ModifyLiquidityParams {
    int24 tickLower;
    int24 tickUpper;
    /// @dev Positive adds liquidity, negative removes it, zero only collects fees
    int256 liquidityDelta;
    /// @dev Distinguishes positions of the same owner over the same range
    bytes32 salt;
}

/// @title Minimal interface of the Uniswap V4 PoolManager singleton
/// @dev Only the subset used by this repo. Mirrors Uniswap/v4-core `src/interfaces/IPoolManager.sol`.
interface IPoolManagerMinimal {
    /// @notice All operations go through an unlock. The manager calls `unlockCallback` on msg.sender.
    /// @param data Any data to pass through to the callback
    /// @return Any data returned by the callback
    function unlock(bytes calldata data) external returns (bytes memory);

    /// @notice Swap against the given pool
    /// @return swapDelta The balance delta of the address swapping. Negative amounts are owed to the
    /// pool by the swapper, positive amounts are owed to the swapper by the pool.
    function swap(
        PoolKey memory key,
        SwapParams memory params,
        bytes calldata hookData
    )
        external
        returns (BalanceDelta swapDelta);

    /// @notice Checkpoints the manager's current ERC20 balance of `currency` in transient storage, so
    /// that a subsequent `settle()` can derive how much was paid. Must be called before sending tokens.
    function sync(Currency currency) external;

    /// @notice Called to pay what is owed, crediting the delta by whatever arrived since `sync`
    /// (or by msg.value for the native currency)
    /// @return paid The amount of currency settled
    function settle() external payable returns (uint256 paid);

    /// @notice Like `settle`, but credits the payment to `recipient` instead of the caller
    function settleFor(address recipient) external payable returns (uint256 paid);

    /// @notice Called to net out value owed to the caller, sending it to `to`
    function take(Currency currency, address to, uint256 amount) external;

    /// @notice Adds or removes liquidity, or collects fees (zero delta). The position belongs to
    /// msg.sender. Only callable while the manager is unlocked, by anyone.
    /// @return callerDelta Principal plus fees, owed by (negative) or to (positive) msg.sender
    /// @return feesAccrued The fees part of `callerDelta`
    function modifyLiquidity(
        PoolKey memory key,
        ModifyLiquidityParams memory params,
        bytes calldata hookData
    )
        external
        returns (BalanceDelta callerDelta, BalanceDelta feesAccrued);

    /// @notice Reads one transient storage slot of the manager, e.g. an account's currency delta
    function exttload(bytes32 slot) external view returns (bytes32 value);

    /// @notice Reads one storage slot of the manager, e.g. a pool's Slot0 (v4-core `StateLibrary`)
    function extsload(bytes32 slot) external view returns (bytes32 value);
}
