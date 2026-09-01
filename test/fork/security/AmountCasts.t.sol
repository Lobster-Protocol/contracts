// SPDX-License-Identifier: GPL-3.0
pragma solidity =0.8.26;

import "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ForkBase} from "../helpers/ForkBase.sol";
import {
    ExactInputSingleParams,
    ExactOutputSingleParams
} from "../../../src/interfaces/uniswapV3/IUniswapV3SwapCallback.sol";

/// @notice Behaviour of the V3 swap entry points at the `uint256` -> `int256` conversion boundary.
/// @dev In Solidity 0.8 an explicit `int256(uint256)` conversion wraps rather than reverting, and in
/// V3 the sign of `amountSpecified` selects exact-input vs exact-output. These tests pin down what
/// the entry points do for amounts at and above 2**255.
///
/// The V4 mixin takes `uint128` amounts, which cannot reach the sign bit, so the boundary does not
/// arise there.
contract AmountCastsTest is ForkBase {
    /// @dev `amountIn = type(uint256).max` converts to int256(-1), which V3 reads as exact output
    /// of one unit.
    function test_exactInputSingle_maxAmountInFlipsToExactOutput() public {
        uint256 usdcBefore = IERC20(USDC).balanceOf(approver);
        uint256 wethBefore = IERC20(WETH).balanceOf(recipient);

        vm.prank(approver);
        uint256 amountOut = proxy.exactInputSingle(
            ExactInputSingleParams({
                tokenIn: USDC,
                tokenOut: WETH,
                fee: 500,
                recipient: recipient,
                deadline: block.timestamp,
                amountIn: type(uint256).max,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );

        // Current behaviour: the call succeeds and executes as an exact-output swap.
        assertEq(amountOut, 1, "expected the wrapped cast to produce an exact-output-of-1 swap");
        assertLt(usdcBefore - IERC20(USDC).balanceOf(approver), tradeUsdc, "spent more than dust");
        assertEq(IERC20(WETH).balanceOf(recipient), wethBefore + 1, "did not receive exactly 1 wei");
    }

    /// @dev The mirror case: `amountOut = type(uint256).max` converts to `+1`, a positive
    /// amountSpecified, which V3 reads as exact input of one unit.
    function test_exactOutputSingle_maxAmountOutFlipsToExactInput() public {
        uint256 usdcBefore = IERC20(USDC).balanceOf(approver);

        vm.prank(approver);
        uint256 amountIn = proxy.exactOutputSingle(
            ExactOutputSingleParams({
                tokenIn: USDC,
                tokenOut: WETH,
                fee: 500,
                recipient: recipient,
                deadline: block.timestamp,
                amountOut: type(uint256).max,
                amountInMaximum: type(uint256).max,
                sqrtPriceLimitX96: 0
            })
        );

        assertEq(amountIn, 1, "expected the wrapped cast to produce an exact-input-of-1 swap");
        assertEq(usdcBefore - IERC20(USDC).balanceOf(approver), 1, "spent more than 1 unit");
    }

    /// @dev The root cause in isolation, as arithmetic. Deliberately not a swap: driving a real pool
    /// with an amount near 2**255 makes it walk the entire tick range and hammers the RPC, which
    /// tests the node rather than the contract.
    function test_castBoundaryIsSilent() public pure {
        // Below the boundary the sign — and therefore the swap mode — is preserved.
        assertEq(int256(uint256(type(int256).max)), type(int256).max, "2**255-1 should stay positive");

        // At the boundary it wraps, with no revert. V3 reads a negative amountSpecified as
        // exact-OUTPUT, so `exactInputSingle` quietly becomes `exactOutputSingle` here.
        assertEq(int256(uint256(type(int256).max) + 1), type(int256).min, "2**255 should wrap negative");
        assertLt(int256(uint256(type(int256).max) + 1), 0, "wrapped value must be negative");

        // And at the top of the range it wraps all the way to -1: "exact output of one unit".
        assertEq(int256(type(uint256).max), -1, "uint256 max should cast to -1");

        // The fix is a checked cast (or a `require(amount <= uint256(type(int256).max))`) on the
        // four `int256(params.amountIn / amountOut)` sites in UniswapV3SwapProxy. The V4 mixin is
        // already safe because its amounts are uint128:
        assertEq(int256(uint256(type(uint128).max)), 340282366920938463463374607431768211455);
        assertGt(int256(uint256(type(uint128).max)), 0, "uint128 can never reach the sign bit");
    }

    /// @dev A caller that sets a meaningful `amountOutMinimum` is unaffected: the converted swap
    /// delivers a single unit and the slippage check rejects it.
    function test_slippageGuardStillCatchesTheFlippedSwap() public {
        vm.prank(approver);
        vm.expectRevert("Too little received");
        proxy.exactInputSingle(
            ExactInputSingleParams({
                tokenIn: USDC,
                tokenOut: WETH,
                fee: 500,
                recipient: recipient,
                deadline: block.timestamp,
                amountIn: type(uint256).max,
                amountOutMinimum: tradeWeth,
                sqrtPriceLimitX96: 0
            })
        );
    }
}
