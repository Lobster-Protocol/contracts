// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.20;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {SwapFlags} from "../../src/libraries/SwapFlags.sol";
import {UniswapSwapProxy} from "../../src/UniswapSwapProxy.sol";

/// @notice Builds `UniswapSwapProxy.swap` calldata (see {SwapFlags}) from readable legs, the way a
/// backend would: tokens enter the call's token table in order of first use.
library SwapCalldata {
    struct Leg {
        bool v4;
        bool exactOut;
        /// @dev The output stays with the proxy for a later HELD leg of the same call
        bool park;
        /// @dev Exact input only: spends everything earlier legs parked of `tokenIn`
        bool held;
        /// @dev With `held`: spends only the Q128 share in `amount` of what is parked. Encoded as given, so
        /// a test can also build the invalid SHARE without HELD.
        bool share;
        address tokenIn;
        address tokenOut;
        uint24 fee;
        /// @dev V4 only
        int24 tickSpacing;
        /// @dev amountIn, or amountOut with `exactOut`, or the share with `share`; not encoded with `held`
        /// alone
        uint128 amount;
        /// @dev amountOutMinimum, or amountInMaximum with `exactOut`
        uint128 bound;
        /// @dev 0: no limit
        uint160 sqrtPriceLimitX96;
    }

    /// @notice The `data` argument of `swap`
    function encode(uint256 deadline, Leg[] memory legs) internal pure returns (bytes memory data) {
        address[] memory tokens = new address[](2 * legs.length);
        uint256 count;
        bytes memory body;
        for (uint256 i = 0; i < legs.length; i++) {
            uint256 inIndex;
            uint256 outIndex;
            (inIndex, count) = _index(tokens, count, legs[i].tokenIn);
            (outIndex, count) = _index(tokens, count, legs[i].tokenOut);
            body = bytes.concat(body, encodeLeg(legs[i], inIndex, outIndex));
        }
        data = bytes.concat(bytes4(SafeCast.toUint32(deadline)), bytes1(SafeCast.toUint8(count)));
        for (uint256 t = 0; t < count; t++) {
            data = bytes.concat(data, bytes20(tokens[t]));
        }
        data = bytes.concat(data, body);
    }

    /// @notice Full calldata of `swap(encode(deadline, legs))`
    function call(uint256 deadline, Leg[] memory legs) internal pure returns (bytes memory) {
        return abi.encodeCall(UniswapSwapProxy.swap, (encode(deadline, legs)));
    }

    /// @notice One leg, given its token indices
    function encodeLeg(Leg memory leg, uint256 inIndex, uint256 outIndex) internal pure returns (bytes memory) {
        uint8 flags = (leg.v4 ? SwapFlags.V4 : 0) | (leg.exactOut ? SwapFlags.EXACT_OUT : 0)
            | (leg.park ? SwapFlags.PARK : 0) | (leg.held ? SwapFlags.HELD : 0)
            | (leg.sqrtPriceLimitX96 != 0 ? SwapFlags.PRICE_LIMIT : 0) | (leg.share ? SwapFlags.SHARE : 0);
        bytes memory out = bytes.concat(
            bytes1(flags), bytes1(SafeCast.toUint8(inIndex)), bytes1(SafeCast.toUint8(outIndex)), bytes3(leg.fee)
        );
        if (leg.v4) out = bytes.concat(out, _int24(leg.tickSpacing));
        if (!leg.held || leg.share) out = bytes.concat(out, bytes16(leg.amount));
        out = bytes.concat(out, bytes16(leg.bound));
        if (leg.sqrtPriceLimitX96 != 0) out = bytes.concat(out, bytes20(leg.sqrtPriceLimitX96));
        return out;
    }

    function _index(
        address[] memory tokens,
        uint256 count,
        address token
    )
        private
        pure
        returns (uint256 index, uint256 newCount)
    {
        for (uint256 t = 0; t < count; t++) {
            if (tokens[t] == token) return (t, count);
        }
        tokens[count] = token;
        return (count, count + 1);
    }

    /// @dev Two's complement, big-endian
    function _int24(int24 value) private pure returns (bytes3 b) {
        assembly ("memory-safe") {
            b := shl(232, and(value, 0xffffff))
        }
    }
}
