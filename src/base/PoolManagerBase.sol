// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.27;

import {IPoolManagerMinimal} from "../interfaces/uniswapV4/IPoolManagerMinimal.sol";
import {IUnlockCallback} from "../interfaces/uniswapV4/IUnlockCallback.sol";
import {TransferHelper} from "../libraries/uniswapV3/TransferHelper.sol";
import {Guards} from "./Guards.sol";

/// @title The Uniswap V4 PoolManager, as every V4 mixin sees it
/// @notice Holds the PoolManager address, owns the single `unlockCallback`, and reads pool prices.
/// @dev Two kinds of unlock reach `unlockCallback`, told apart by their first byte: `SWAP_TAG`
/// ({UniswapSwapProxy}) and `LIQUIDITY_TAG` ({UniswapV4LiquidityProxy}). The PoolManager calls back
/// whoever called `unlock`, with the data that caller passed, so the data is always the proxy's own and
/// checking that the PoolManager is the caller is the whole authentication.
abstract contract PoolManagerBase is Guards, IUnlockCallback {
    /// @dev v4-core TickMath.MIN_SQRT_PRICE / MAX_SQRT_PRICE, the same values as V3's
    /// MIN_SQRT_RATIO / MAX_SQRT_RATIO
    uint160 internal constant MIN_SQRT_PRICE = 4295128739;
    uint160 internal constant MAX_SQRT_PRICE = 1461446703485210103287273052203988822378723970342;

    bytes1 internal constant SWAP_TAG = 0x01;
    bytes1 internal constant LIQUIDITY_TAG = 0x02;

    IPoolManagerMinimal public immutable POOL_MANAGER;

    constructor(address _poolManager) {
        POOL_MANAGER = IPoolManagerMinimal(_poolManager);
    }

    /// @inheritdoc IUnlockCallback
    /// @dev The only entry point the PoolManager uses. Every currency delta must be back to zero by the
    /// end, or the manager reverts the whole unlock with `CurrencyNotSettled`.
    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        require(msg.sender == address(POOL_MANAGER), NotPoolManager());
        bytes1 tag = data[0];
        if (tag == SWAP_TAG) return _swapCallback(data[1:]);
        if (tag == LIQUIDITY_TAG) return _liquidityCallback(data[1:]);
        revert UnexpectedCallback();
    }

    /// @dev The body of a swap unlock; `data` is what follows `SWAP_TAG`
    function _swapCallback(bytes calldata data) internal virtual returns (bytes memory);

    /// @dev The body of a liquidity unlock; `data` is what follows `LIQUIDITY_TAG`
    function _liquidityCallback(bytes calldata data) internal virtual returns (bytes memory);

    /// @dev The PoolManager storage slot holding a pool's Slot0 (v4-core `StateLibrary`: `pools` is
    /// storage slot 6)
    function _poolStateSlot(bytes32 poolId) internal pure returns (bytes32 slot) {
        assembly ("memory-safe") {
            mstore(0, poolId)
            mstore(0x20, 6)
            slot := keccak256(0, 0x40)
        }
    }

    /// @dev A pool's current tick: bits 160-183 of its Slot0 in the PoolManager
    function _tickAt(bytes32 stateSlot) internal view returns (int24 tick) {
        address manager = address(POOL_MANAGER);
        assembly ("memory-safe") {
            mstore(0, 0x1e2eaeaf) // extsload(bytes32)
            mstore(0x20, stateSlot)
            if iszero(staticcall(gas(), manager, 0x1c, 0x24, 0, 0x20)) {
                returndatacopy(0, 0, returndatasize())
                revert(0, returndatasize())
            }
            if lt(returndatasize(), 0x20) { revert(0, 0) }
            tick := signextend(2, shr(160, mload(0)))
        }
    }

    function _currentTick(bytes32 poolId) internal view returns (int24) {
        return _tickAt(_poolStateSlot(poolId));
    }

    /// @dev Returns ETH that was sent in but not consumed.
    /// The proxy is not meant to hold a balance between calls, so anything left here at the end of a
    /// payable call is this caller's change. INVARIANT: this returns only the caller's own msg.value,
    /// plus any ETH force-fed to the proxy (a selfdestruct, a coinbase payment), which belongs to no one,
    /// because (1) the proxy has no `receive`, and no path makes the PoolManager send it ETH: native
    /// outputs are credit in the PoolManager or are taken straight to the vault, and (2) no entry point
    /// can run inside another (`nonReentrant`). Revisit both before changing either.
    function _refundExcessNative() internal {
        uint256 balance = address(this).balance;
        if (balance > 0) TransferHelper.safeTransferETH(msg.sender, balance);
    }
}
