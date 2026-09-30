// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.20;

import {ExactInputSingleParams, ExactOutputSingleParams} from "./interfaces/uniswapV3/IUniswapV3SwapCallback.sol";
import {V4ExactInputSingleParams, V4ExactOutputSingleParams} from "./interfaces/uniswapV4/IUnlockCallback.sol";
import {UniswapV3SwapProxy} from "./UniswapV3SwapProxy.sol";
import {UniswapV4SwapProxy} from "./UniswapV4SwapProxy.sol";

/// @notice The first byte of every element of a {UniswapBatchSwapProxy-batchSwap} batch.
/// @dev Each value stands for one single-swap entry point, and the bytes after it are that entry
/// point's params, `abi.encode`d. 0x00 is deliberately unused, so a zeroed element is rejected rather
/// than read as a swap.
library SwapType {
    uint8 internal constant V3_EXACT_INPUT = 0x01; // as {UniswapV3SwapProxy-exactInputSingle}
    uint8 internal constant V3_EXACT_OUTPUT = 0x02; // as {UniswapV3SwapProxy-exactOutputSingle}
    uint8 internal constant V4_EXACT_INPUT = 0x03; // as {UniswapV4SwapProxy-exactInputSingleV4}
    uint8 internal constant V4_EXACT_OUTPUT = 0x04; // as {UniswapV4SwapProxy-exactOutputSingleV4}
}

/// @title Batched V3 + V4 swaps
/// @notice Runs several swaps, on either Uniswap version, in one atomic transaction.
/// @dev Each element is `abi.encodePacked(uint8 swapType, abi.encode(params))`. The loop dispatches
/// on the {SwapType} byte to the same internal body the matching single-swap entry point runs, so a
/// batched swap is checked (deadline, recipient, slippage, hooks) and paid (`payer = msg.sender`,
/// unchanged by an internal call) exactly as if it had been called on its own. If any swap reverts,
/// the whole batch reverts with that swap's reason.
///
/// Deliberately NOT payable, and never refunds ETH. A native-input V4 swap settles from the proxy's
/// own balance, which is empty in normal operation, so a batch cannot pay ETH in. A swap can still
/// pay ETH *out*, since the PoolManager sends it straight to the recipient. This keeps the
/// `_refundExcessNative` invariant in {UniswapV4SwapProxy} intact.
///
/// `amounts` records each swap's result so that a later version can feed one swap's output into the
/// next swap's input (chaining). Today every swap's amounts are fixed by the caller.
///
/// Abstract on purpose: this is a mixin combined into {UniswapProxy}. Deploy that rather than this.
abstract contract UniswapBatchSwapProxy is UniswapV3SwapProxy, UniswapV4SwapProxy {
    /// @notice Executes `swaps` in order, atomically
    /// @param swaps One element per swap: a {SwapType} byte followed by the ABI-encoded params
    /// @return amounts Per swap, what its single-swap entry point would return: the amount received
    /// for an exact-input swap, the amount paid for an exact-output swap
    function batchSwap(bytes[] calldata swaps) external returns (uint256[] memory amounts) {
        amounts = new uint256[](swaps.length);
        for (uint256 i = 0; i < swaps.length; i++) {
            bytes calldata item = swaps[i];
            require(item.length != 0, "Invalid swap type");
            uint8 swapType = uint8(item[0]);
            bytes calldata params = item[1:];

            if (swapType == SwapType.V3_EXACT_INPUT) {
                amounts[i] = _exactInputSingle(abi.decode(params, (ExactInputSingleParams)));
            } else if (swapType == SwapType.V3_EXACT_OUTPUT) {
                amounts[i] = _exactOutputSingle(abi.decode(params, (ExactOutputSingleParams)));
            } else if (swapType == SwapType.V4_EXACT_INPUT) {
                amounts[i] = _exactInputSingleV4(abi.decode(params, (V4ExactInputSingleParams)));
            } else if (swapType == SwapType.V4_EXACT_OUTPUT) {
                amounts[i] = _exactOutputSingleV4(abi.decode(params, (V4ExactOutputSingleParams)));
            } else {
                revert("Invalid swap type");
            }
        }
    }
}
