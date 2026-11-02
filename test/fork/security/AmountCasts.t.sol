// SPDX-License-Identifier: GPL-3.0
pragma solidity =0.8.28;

import "forge-std/Test.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {ForkBase} from "../helpers/ForkBase.sol";
import {SwapCalldata} from "../../helpers/SwapCalldata.sol";
import {SwapFlags} from "../../../src/libraries/SwapFlags.sol";
import {IProxyErrors} from "../../../src/interfaces/IProxyErrors.sol";
import {IUniswapV3PoolMinimal} from "../../../src/interfaces/uniswapV3/IUniswapV3PoolMinimal.sol";
import {IPoolManagerMinimal, SwapParams} from "../../../src/interfaces/uniswapV4/IPoolManagerMinimal.sol";

/// @notice Behaviour of `swap` at the amount-encoding boundary.
/// @dev In Solidity 0.8 an explicit `int256(uint256)` conversion wraps rather than reverting, and in
/// V3 the sign of `amountSpecified` selects exact-input vs exact-output (V4: the opposite sign). A
/// wrapped amount therefore silently changes the swap's mode. The removed single-swap entry points took
/// `uint256` amounts and needed `SafeCast.toInt256`; the packed format makes every amount, V3 and V4
/// alike, a 16-byte field ({SwapFlags}). So no amount at or above 2**128 can be expressed, the proxy
/// can negate any amount it reads without wrapping, and calldata that tries to carry a wider amount
/// no longer parses: it is rejected with `MalformedSwap` before any pool is touched.
contract AmountCastsTest is ForkBase {
    /// @dev 2**255: the first value a plain cast wraps, to type(int256).min. As `amountIn` that was an
    /// exact-OUTPUT order for ~2**255, which buys out the whole pool and passes any
    /// `amountOutMinimum`. It is also UniversalRouter's CONTRACT_BALANCE sentinel, so a plausible
    /// input from an integrator. 2**255 + 1 and type(uint256).max cover the rest of the wrapped range.
    function _wrappingAmounts() internal pure returns (uint256[3] memory) {
        return [uint256(2 ** 255), 2 ** 255 + 1, type(uint256).max];
    }

    /// @notice An exact-input leg whose amount is written as a full 32-byte word, as the removed
    /// uint256 ABI took it, is malformed: no pool is touched and nothing moves
    function test_exactInput_amountsThatWouldWrapAreMalformed() public {
        uint256[3] memory amounts = _wrappingAmounts();
        uint256[4] memory before = _approverHoldings();

        _expectUnlocks(0);
        _expectNoSwapOn(USDC_WETH_500);
        for (uint256 i = 0; i < amounts.length; i++) {
            // a meaningful guard as the bound, which the wrap used to bypass
            _expectMalformed(_wideAmountData(0, USDC, WETH, amounts[i], tradeWeth));
            _expectMalformed(_wideAmountData(SwapFlags.V4, USDC, address(0), amounts[i], tradeWeth));
        }

        _assertApproverUntouched(before, "wrapping amountIn");
    }

    /// @notice Why the field width matters, as language arithmetic
    /// @dev Deliberately not a swap: driving a real pool with an amount near the field's maximum makes
    /// it walk the entire tick range and hammers the RPC, which tests the node rather than the contract.
    function test_castBoundaryIsSilent() public pure {
        // Below the boundary the sign — and therefore the swap mode — is preserved.
        assertEq(int256(uint256(type(int256).max)), type(int256).max, "2**255-1 should stay positive");

        // At the boundary a plain cast wraps, with no revert. V3 reads a negative amountSpecified as
        // exact-OUTPUT, so a uint256 amount cast without SafeCast would quietly become an exact-output order.
        assertEq(int256(uint256(type(int256).max) + 1), type(int256).min, "2**255 should wrap negative");
        assertLt(int256(uint256(type(int256).max) + 1), 0, "wrapped value must be negative");

        // And at the top of the range it wraps all the way to -1: "exact output of one unit".
        assertEq(int256(type(uint256).max), -1, "uint256 max should cast to -1");

        // Every amount field is a uint128, which can never reach the sign bit, in either direction:
        // V3 sends +amount for exact input and -amount for exact output, V4 the reverse.
        assertEq(int256(uint256(type(uint128).max)), 340282366920938463463374607431768211455);
        assertGt(int256(uint256(type(uint128).max)), 0, "uint128 can never reach the sign bit");
        assertLt(-int256(uint256(type(uint128).max)), 0, "a negated uint128 stays negative");
    }

    /// @notice The exact-output counterpart: a 32-byte amountOut is malformed, nothing runs
    function test_exactOutput_amountsThatWouldWrapAreMalformed() public {
        uint256[3] memory amounts = _wrappingAmounts();
        uint256[4] memory before = _approverHoldings();

        _expectUnlocks(0);
        _expectNoSwapOn(USDC_WETH_500);
        for (uint256 i = 0; i < amounts.length; i++) {
            uint128 noMaximum = type(uint128).max;
            _expectMalformed(_wideAmountData(SwapFlags.EXACT_OUT, USDC, WETH, amounts[i], noMaximum));
            _expectMalformed(
                _wideAmountData(SwapFlags.V4 | SwapFlags.EXACT_OUT, USDC, address(0), amounts[i], noMaximum)
            );
        }

        _assertApproverUntouched(before, "wrapping amountOut");
    }

    /// @notice The largest amount the format can carry, type(uint128).max, reaches the pool exactly and
    /// with the sign of its mode, on V3 and V4, exact input and exact output
    /// @dev Checked on the calldata the proxy sends: V3 `amountSpecified` is +amount for exact input and
    /// -amount for exact output, V4 the reverse. A price limit one unit away from the live price stops
    /// each swap at once, so the call settles a few wei instead of walking the whole tick range.
    function test_largestEncodableAmount_reachesThePoolWithItsSign() public {
        uint128 largest = type(uint128).max;
        int256 wide = int256(uint256(type(uint128).max));
        (uint160 v3Price,,,,,,) = IUniswapV3PoolMinimal(USDC_WETH_500).slot0();
        uint160 v4Price = SafeCast.toUint160(_v4Slot0(proxy.v4Key(_v4EthUsdc())) & type(uint160).max);
        // USDC < WETH and ETH < USDC: both legs sell currency0, so the price moves down
        bytes memory payFromCaller = abi.encodePacked(USDC, uint8(0), uint256(0));

        SwapCalldata.Leg memory leg = _v3In(USDC, WETH, 500, largest, 0);
        leg.sqrtPriceLimitX96 = v3Price - 1;
        vm.expectCall(
            USDC_WETH_500,
            abi.encodeCall(IUniswapV3PoolMinimal.swap, (approver, true, wide, v3Price - 1, payFromCaller))
        );
        _swapOne(approver, leg, 0);

        (v3Price,,,,,,) = IUniswapV3PoolMinimal(USDC_WETH_500).slot0();
        leg = _v3Out(USDC, WETH, 500, largest, largest);
        leg.sqrtPriceLimitX96 = v3Price - 1;
        vm.expectCall(
            USDC_WETH_500,
            abi.encodeCall(IUniswapV3PoolMinimal.swap, (approver, true, -wide, v3Price - 1, payFromCaller))
        );
        _swapOne(approver, leg, 0);

        leg = _v4In(true, largest, 0);
        leg.sqrtPriceLimitX96 = v4Price - 1;
        vm.expectCall(
            POOL_MANAGER,
            abi.encodeCall(
                IPoolManagerMinimal.swap,
                (
                    _v4EthUsdc(),
                    SwapParams({zeroForOne: true, amountSpecified: -wide, sqrtPriceLimitX96: v4Price - 1}),
                    ""
                )
            )
        );
        _swapOne(approver, leg, 1 gwei);

        v4Price = SafeCast.toUint160(_v4Slot0(proxy.v4Key(_v4EthUsdc())) & type(uint160).max);
        leg = _v4Out(true, largest, largest);
        leg.sqrtPriceLimitX96 = v4Price - 1;
        vm.expectCall(
            POOL_MANAGER,
            abi.encodeCall(
                IPoolManagerMinimal.swap,
                (
                    _v4EthUsdc(),
                    SwapParams({zeroForOne: true, amountSpecified: wide, sqrtPriceLimitX96: v4Price - 1}),
                    ""
                )
            )
        );
        _swapOne(approver, leg, 1 gwei);
    }

    // ---------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------

    /// @dev `swap` data with one leg whose amount is written as a 32-byte word instead of the 16-byte
    /// field the format defines. `flags` may add V4 (on the live ETH/USDC pool) and EXACT_OUT.
    function _wideAmountData(
        uint8 flags,
        address tokenIn,
        address tokenOut,
        uint256 amount,
        uint128 bound
    )
        internal
        view
        returns (bytes memory)
    {
        bytes memory head = abi.encodePacked(
            bytes4(SafeCast.toUint32(vm.getBlockTimestamp())), uint8(2), tokenIn, tokenOut, flags, uint8(0), uint8(1)
        );
        bytes memory pool = flags & SwapFlags.V4 != 0
            ? abi.encodePacked(V4_FEE, _int24Bytes(V4_TICK_SPACING))
            : abi.encodePacked(uint24(500));
        return bytes.concat(head, pool, abi.encodePacked(amount), abi.encodePacked(bound));
    }

    /// @dev The approver, who registered both pools, sends `data`; it must revert `MalformedSwap`
    function _expectMalformed(bytes memory data) internal {
        vm.prank(approver);
        vm.expectRevert(IProxyErrors.MalformedSwap.selector);
        proxy.swap(data);
    }

    /// @dev Two's complement, big-endian
    function _int24Bytes(int24 value) internal pure returns (bytes3 b) {
        assembly ("memory-safe") {
            b := shl(232, and(value, 0xffffff))
        }
    }
}
