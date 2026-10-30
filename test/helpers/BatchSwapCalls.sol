// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.20;

import {SwapType} from "../../src/UniswapBatchSwapProxy.sol";
import {UniswapV3SwapProxy} from "../../src/UniswapV3SwapProxy.sol";
import {UniswapV4SwapProxy} from "../../src/UniswapV4SwapProxy.sol";

/// @notice Turns a `batchSwap` element into the equivalent direct call to the matching single-swap
/// entry point, so tests can run exactly the same swap both ways.
/// @dev The two encodings differ only in their prefix: a 1-byte {SwapType} for the batch, a 4-byte
/// selector for the direct call. Both are followed by the same `abi.encode(params)`, because for a
/// single struct argument `abi.encodeCall(f, (params))` is exactly `f.selector ++ abi.encode(params)`.
library BatchSwapCalls {
    function toDirectCall(bytes memory item) internal pure returns (bytes memory) {
        uint8 swapType = uint8(item[0]);
        bytes4 selector;
        if (swapType == SwapType.V3_EXACT_INPUT) selector = UniswapV3SwapProxy.exactInputSingle.selector;
        else if (swapType == SwapType.V3_EXACT_OUTPUT) selector = UniswapV3SwapProxy.exactOutputSingle.selector;
        else if (swapType == SwapType.V4_EXACT_INPUT) selector = UniswapV4SwapProxy.exactInputSingleV4.selector;
        else if (swapType == SwapType.V4_EXACT_OUTPUT) selector = UniswapV4SwapProxy.exactOutputSingleV4.selector;
        else revert("BatchSwapCalls: not a swap type");

        bytes memory params = new bytes(item.length - 1);
        for (uint256 i = 0; i < params.length; i++) {
            params[i] = item[i + 1];
        }
        return bytes.concat(selector, params);
    }
}
