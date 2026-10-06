// SPDX-License-Identifier: GPL-3.0
pragma solidity =0.8.26;

import "forge-std/Test.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {ForkBase} from "../helpers/ForkBase.sol";
import {
    ExactInputSingleParams,
    ExactOutputSingleParams
} from "../../../src/interfaces/uniswapV3/IUniswapV3SwapCallback.sol";

/// @notice Behaviour of the V3 swap entry points at the `uint256` -> `int256` conversion boundary.
/// @dev In Solidity 0.8 an explicit `int256(uint256)` conversion wraps rather than reverting, and in
/// V3 the sign of `amountSpecified` selects exact-input vs exact-output. A wrapped amount therefore
/// silently changes the swap's mode. The entry points convert with `SafeCast.toInt256`, and these
/// tests pin down that every amount at or above 2**255 is rejected before any pool is touched.
///
/// The V4 mixin takes `uint128` amounts, which cannot reach the sign bit, so the boundary does not
/// arise there.
contract AmountCastsTest is ForkBase {
    /// @dev 2**255: the first value a plain cast wraps, to type(int256).min. As `amountIn` that was an
    /// exact-OUTPUT order for ~2**255, which buys out the whole pool and passes any
    /// `amountOutMinimum`. It is also UniversalRouter's CONTRACT_BALANCE sentinel, so a plausible
    /// input from an integrator. 2**255 + 1 and type(uint256).max cover the rest of the wrapped range.
    function _wrappingAmounts() internal pure returns (uint256[3] memory) {
        return [uint256(2 ** 255), 2 ** 255 + 1, type(uint256).max];
    }

    function test_exactInputSingle_rejectsAmountsThatWouldWrap() public {
        uint256[3] memory amounts = _wrappingAmounts();
        uint256[4] memory before = _approverHoldings();

        for (uint256 i = 0; i < amounts.length; i++) {
            vm.prank(approver);
            vm.expectRevert(abi.encodeWithSelector(SafeCast.SafeCastOverflowedUintToInt.selector, amounts[i]));
            proxy.exactInputSingle(
                ExactInputSingleParams({
                    tokenIn: USDC,
                    tokenOut: WETH,
                    fee: 500,
                    recipient: recipient,
                    deadline: block.timestamp,
                    amountIn: amounts[i],
                    amountOutMinimum: tradeWeth, // a meaningful guard, which the wrap used to bypass
                    sqrtPriceLimitX96: 0
                })
            );
        }

        _assertApproverUntouched(before, "wrapping amountIn");
    }

    function test_exactOutputSingle_rejectsAmountsThatWouldWrap() public {
        uint256[3] memory amounts = _wrappingAmounts();
        uint256[4] memory before = _approverHoldings();

        for (uint256 i = 0; i < amounts.length; i++) {
            vm.prank(approver);
            vm.expectRevert(abi.encodeWithSelector(SafeCast.SafeCastOverflowedUintToInt.selector, amounts[i]));
            proxy.exactOutputSingle(
                ExactOutputSingleParams({
                    tokenIn: USDC,
                    tokenOut: WETH,
                    fee: 500,
                    recipient: recipient,
                    deadline: block.timestamp,
                    amountOut: amounts[i],
                    amountInMaximum: type(uint256).max,
                    sqrtPriceLimitX96: 0
                })
            );
        }

        _assertApproverUntouched(before, "wrapping amountOut");
    }

    /// @dev Why the checked cast is needed, as language arithmetic. Deliberately not a swap: driving
    /// a real pool with an amount near 2**255 makes it walk the entire tick range and hammers the
    /// RPC, which tests the node rather than the contract.
    function test_castBoundaryIsSilent() public pure {
        // Below the boundary the sign — and therefore the swap mode — is preserved.
        assertEq(int256(uint256(type(int256).max)), type(int256).max, "2**255-1 should stay positive");

        // At the boundary a plain cast wraps, with no revert. V3 reads a negative amountSpecified as
        // exact-OUTPUT, so without SafeCast `exactInputSingle` would quietly become `exactOutputSingle`.
        assertEq(int256(uint256(type(int256).max) + 1), type(int256).min, "2**255 should wrap negative");
        assertLt(int256(uint256(type(int256).max) + 1), 0, "wrapped value must be negative");

        // And at the top of the range it wraps all the way to -1: "exact output of one unit".
        assertEq(int256(type(uint256).max), -1, "uint256 max should cast to -1");

        // The V4 mixin is safe without SafeCast because its amounts are uint128:
        assertEq(int256(uint256(type(uint128).max)), 340282366920938463463374607431768211455);
        assertGt(int256(uint256(type(uint128).max)), 0, "uint128 can never reach the sign bit");
    }
}
