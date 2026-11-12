// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.27;

/// @notice A price range a vault holds liquidity in, on the pool whose list it is in
struct Range {
    int24 tickLower;
    int24 tickUpper;
    /// @dev The V4 position's salt. Always 0 for V3, whose positions have none.
    bytes32 salt;
}

/// @title The ranges each vault holds liquidity in, per pool
/// @notice A V3 or V4 position belongs to the vault itself, inside the pool or the PoolManager, and
/// neither can list a vault's positions. So when a vault adds liquidity through `mintWithRecording` or
/// `modifyLiquidityV4WithRecording`, the range goes into the vault's list for that pool, and
/// {rangesOf} returns the list. `mint` and `modifyLiquidityV4` touch no list.
/// @dev Each recording add also cleans up the list it writes to: every range in it that is now empty
/// (no liquidity, and for V3 nothing left to collect) is deleted. So once a recording call returns,
/// that pool's list holds each non-empty range once, the one just added included. Between two
/// recording adds on a pool, the vault can empty ranges without this contract seeing it (a V3
/// position is burnt and collected on the pool directly), so a range in the list may hold nothing
/// until the next recording add on that pool. Lists are only ever written for the vault making the
/// call.
abstract contract PositionRecorder {
    /// @dev Per vault, per registry key ({PoolRegistry}: a V3 pool's address left-padded with zeros, or
    /// a V4 PoolId), the ranges. Order is not meaningful and changes when one is deleted.
    mapping(address vault => mapping(bytes32 key => Range[])) private _ranges;

    event RangeRecorded(address indexed vault, bytes32 indexed key, int24 tickLower, int24 tickUpper, bytes32 salt);
    event RangeDeleted(address indexed vault, bytes32 indexed key, int24 tickLower, int24 tickUpper, bytes32 salt);

    /// @notice The ranges `vault` holds liquidity in on the pool `key` ({PoolRegistry-v3Key},
    /// {PoolRegistry-v4Key}), as of its last recording add on that pool. Order is not meaningful.
    function rangesOf(address vault, bytes32 key) external view returns (Range[] memory) {
        return _ranges[vault][key];
    }

    // One read of the pool or the PoolManager per range in the list; any failure reverts the whole call.
    // The events follow those reads, but `isEmpty` is `view`: compiled to STATICCALL, the callee can
    // neither change state nor reenter, so nothing can reorder or fabricate these logs (and every entry
    // point recording ranges is `nonReentrant`).
    // forge-lint: disable-start(calls-loop, reentrancy-events)
    /// @dev Called once liquidity was added to `added`, on the pool `key`, for `vault`. Deletes every
    /// empty range of the list, then adds `added` unless it is already there or is empty itself (a V4
    /// batch can empty a range it added to). `isEmpty` tells whether a vault's range on a pool is empty.
    function _recordRange(
        address vault,
        bytes32 key,
        Range memory added,
        function(address, bytes32, Range memory) internal view returns (bool) isEmpty
    )
        internal
    {
        Range[] storage ranges = _ranges[vault][key];
        bool listed = false;
        uint256 i = 0;
        while (i < ranges.length) {
            Range memory range = ranges[i];
            if (isEmpty(vault, key, range)) {
                // Swap and pop: the last range takes its place, and is looked at next
                uint256 last = ranges.length - 1;
                if (i != last) ranges[i] = ranges[last];
                ranges.pop();
                emit RangeDeleted(vault, key, range.tickLower, range.tickUpper, range.salt);
            } else {
                if (_isSame(range, added)) listed = true;
                i++;
            }
        }
        if (!listed && !isEmpty(vault, key, added)) {
            ranges.push(added);
            emit RangeRecorded(vault, key, added.tickLower, added.tickUpper, added.salt);
        }
    }

    // forge-lint: disable-end(calls-loop, reentrancy-events)

    function _isSame(Range memory a, Range memory b) private pure returns (bool) {
        return a.tickLower == b.tickLower && a.tickUpper == b.tickUpper && a.salt == b.salt;
    }
}
