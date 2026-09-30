// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.20;

/// @title Batch several entry points into one atomic transaction
/// @notice Runs each element of `data` as a call to this same contract, in order. If any element
/// reverts, the whole batch reverts with that element's revert data, so either every call in the
/// batch took effect or none did.
/// @dev Each element runs through `delegatecall` to `address(this)`: our own code, in our own
/// context. That keeps `msg.sender` equal to the account that called `multicall`, which is what lets
/// every entry point's `payer = msg.sender` work unchanged. A plain `call` to ourselves would make
/// the proxy the payer instead. The deployed contract has no storage, so a self-`delegatecall` has
/// nothing to corrupt.
///
/// Deliberately NOT payable. `delegatecall` hands the same `msg.value` to every element, so in a
/// payable batch each element would see, and could spend, the full amount. Keeping `msg.value` at 0
/// removes that class of bug outright, at the cost that native ETH cannot be *paid* inside a batch.
///
/// Only selectors approved by {_isBatchable} may appear in a batch. Nothing outside this contract
/// can be reached from here: the target is always `address(this)`.
abstract contract Multicall {
    /// @notice Executes `data` as a sequence of calls to this contract, atomically
    /// @param data ABI-encoded calls, e.g. `abi.encodeCall(UniswapV3SwapProxy.exactInputSingle, (params))`
    /// @return results The ABI-encoded return value of each call, in the same order as `data`
    function multicall(bytes[] calldata data) external returns (bytes[] memory results) {
        results = new bytes[](data.length);
        for (uint256 i = 0; i < data.length; i++) {
            // Elements shorter than 4 bytes are zero-padded here and match no real selector
            require(_isBatchable(bytes4(data[i])), "Not batchable");

            (bool success, bytes memory result) = address(this).delegatecall(data[i]);
            if (!success) {
                // Re-throw the element's revert data unchanged, so the caller sees the original
                // reason (e.g. "Too little received") rather than a generic batch failure
                assembly ("memory-safe") {
                    revert(add(result, 0x20), mload(result))
                }
            }
            results[i] = result;
        }
    }

    /// @dev Which entry points may be batched. Implemented by the deployable contract, the only
    /// place that sees every mixin.
    function _isBatchable(bytes4 selector) internal pure virtual returns (bool);
}
