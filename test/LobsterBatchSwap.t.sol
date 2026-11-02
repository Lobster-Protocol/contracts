// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.20;

import {VmSafe} from "forge-std/Vm.sol";

import {UniswapSwapProxy} from "../src/UniswapSwapProxy.sol";
import {SwapFlags} from "../src/libraries/SwapFlags.sol";
import {IUniswapV3PoolMinimal} from "../src/interfaces/uniswapV3/IUniswapV3PoolMinimal.sol";
// The proxy deliberately uses its own vendored types, so they are distinct from v4-core's even
// though they are ABI-identical. Alias them to keep the two worlds visibly separate.
import {
    PoolKey as ProxyPoolKey,
    IHooks as ProxyIHooks,
    IPoolManagerMinimal
} from "../src/interfaces/uniswapV4/IPoolManagerMinimal.sol";
import {BatchSwapFixture} from "./helpers/BatchSwapFixture.sol";
import {SwapCalldata} from "./helpers/SwapCalldata.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IProxyErrors} from "../src/interfaces/IProxyErrors.sol";

import {PoolId} from "v4-core/src/types/PoolId.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";

/// @notice LobsterProxy's `swap` with several legs: V3 and V4 swaps in one atomic call.
/// @dev Runs against a real V3 factory and a real V4 PoolManager side by side, so a single call can
/// cross both versions. Every pool is registered for the user (the vault), so the registry is never
/// what stops a swap here; its checks have their own suites. The central property: a multi-leg call is
/// exactly equivalent to making the same swaps one by one (one-leg calls) from the same account,
/// except that it is all-or-nothing. Chaining (PARK / HELD) has its own suite.
contract LobsterBatchSwapTest is BatchSwapFixture {
    address constant ETH = address(0);
    bytes32 constant TRANSFER_TOPIC = keccak256("Transfer(address,address,uint256)");

    // ---------------------------------------------------------------------------
    // Multi-leg call == the same legs one by one
    // ---------------------------------------------------------------------------

    /// @notice The defining property: a call of V3 and V4 legs, in both directions, has exactly the
    /// effect of the same four swaps made one by one — same amounts, same balances.
    function test_mixedV3AndV4Call_matchesSameSwapsMadeOneByOne() public {
        SwapCalldata.Leg[] memory legs = new SwapCalldata.Leg[](4);
        legs[0] = _v3In(address(token0), address(token1), 1e18, 0);
        legs[1] = _v4In(cleanKey, false, 1e18, 0); // token1 -> token0
        legs[2] = _v3In(address(token1), address(token0), 0.5e18, 0);
        legs[3] = _v4In(cleanKey, true, 0.5e18, 0); // token0 -> token1

        uint256[6] memory before = _holdings();

        (bool succeeded, uint256[] memory amounts) = _assertBatchMatchesOneByOne(legs);
        assertTrue(succeeded, "fixture: every swap should succeed");

        // amounts[i] is what leg i returns as a one-leg call. The caller is also the recipient, so
        // each token's net change is what it received minus what it paid.
        assertEq(
            token1.balanceOf(user) + 1e18 + 0.5e18, before[1] + amounts[0] + amounts[3], "token1: received minus paid"
        );
        assertEq(
            token0.balanceOf(user) + 1e18 + 0.5e18, before[0] + amounts[1] + amounts[2], "token0: received minus paid"
        );
        _assertProxyHoldsNothing();
    }

    /// @notice The same property over random calls: any length up to six, any mix of the four swap
    /// kinds, pools, directions and sizes, including the native pool paying out ETH.
    function testFuzz_randomCall_matchesSameSwapsMadeOneByOne(uint256 seed, uint256 length) public {
        uint256 n = bound(length, 1, 6);
        SwapCalldata.Leg[] memory legs = new SwapCalldata.Leg[](n);
        for (uint256 i = 0; i < n; i++) {
            legs[i] = _randomSwap(uint256(keccak256(abi.encode(seed, i))));
        }

        _assertBatchMatchesOneByOne(legs);
    }

    /// @notice Every swap kind (V3 and V4, exact input and exact output), on all three pools, in one
    /// call: each leg executes, exact-output legs deliver exactly their amount, the proxy keeps nothing.
    /// The three exact-output legs buy three different assets (token1, token0, ETH), so reconciling
    /// each asset's net change with every leg pins each one's delivery.
    function test_everySwapKind_onEveryPool_runsInOneCall() public {
        SwapCalldata.Leg[] memory legs = new SwapCalldata.Leg[](7);
        legs[0] = _v3In(address(token0), address(token1), 1e18, 0);
        legs[1] = _v3In(address(token1), address(token0), 1e18, 0);
        legs[2] = _v4In(cleanKey, true, 1e18, 0);
        legs[3] = _v4In(nativeKey, false, 1e18, 0); // token1 -> ETH
        legs[4] = _v3Out(address(token0), address(token1), 1e18, type(uint256).max); // token0 -> exactly 1 token1
        legs[5] = _v4Out(cleanKey, false, 1e18, type(uint128).max); // token1 -> exactly 1 token0
        legs[6] = _v4Out(nativeKey, false, 1e18, type(uint128).max); // token1 -> exactly 1 ETH
        uint256[6] memory before = _holdings();

        uint256[] memory amounts = _swapAs(user, legs);

        assertEq(amounts.length, legs.length, "one amount per leg");
        for (uint256 i = 0; i < amounts.length; i++) {
            assertGt(amounts[i], 0, "leg did not execute");
        }
        // An exact-input leg pays its 1e18 and receives amounts[i]; an exact-output leg pays amounts[i]
        // and receives exactly its 1e18. Per asset: what was paid on the left, what was received on the right.
        assertEq(
            token0.balanceOf(user) + 1e18 + 1e18 + amounts[4], // paid by legs 0, 2, 4
            before[0] + amounts[1] + 1e18, // received by legs 1, 5
            "token0: received minus paid"
        );
        assertEq(
            token1.balanceOf(user) + 1e18 + 1e18 + amounts[5] + amounts[6], // paid by legs 1, 3, 5, 6
            before[1] + amounts[0] + amounts[2] + 1e18, // received by legs 0, 2, 4
            "token1: received minus paid"
        );
        assertEq(user.balance, before[2] + amounts[3] + 1e18, "ETH: received by legs 3, 6"); // no leg pays ETH
        _assertProxyHoldsNothing();
    }

    /// @notice A call must have at least one leg: empty data, a header alone, a token table cut short,
    /// or a header and full token table with no leg after them are malformed and change nothing.
    /// Replaces the empty batch, which was a no-op returning no amounts.
    function test_callWithoutLegs_isMalformed() public {
        uint256[6] memory before = _holdings();
        vm.expectCall(address(v3Pool), abi.encodeWithSelector(IUniswapV3PoolMinimal.swap.selector), 0);
        vm.expectCall(address(manager), abi.encodeWithSelector(IPoolManagerMinimal.unlock.selector), 0);

        _expectMalformed("", "empty data");
        _expectMalformed(_header(0), "header only");
        _expectMalformed(bytes.concat(_header(2), bytes20(address(token0))), "token table cut short");
        _expectMalformed(_withTable(_table(address(token0), address(token1)), ""), "header and token table only");

        _assertHoldingsEq(_holdings(), before, "calls without legs");
    }

    // ---------------------------------------------------------------------------
    // Atomicity and error reporting
    // ---------------------------------------------------------------------------

    /// @notice A failing leg undoes the legs before it, including their effect on pool prices, and
    /// the caller sees the failing leg's own revert reason.
    function test_failingLeg_revertsWholeCallWithItsReason() public {
        SwapCalldata.Leg[] memory legs = _batch(
            _v3In(address(token0), address(token1), 1e18, 0),
            _v4In(cleanKey, true, 1e18, 2e18) // unreachable minimum
        );

        uint256[6] memory before = _holdings();
        uint160 priceBefore = _v3Price();

        vm.prank(user);
        vm.expectRevert(IProxyErrors.TooLittleReceived.selector);
        proxy.swap(_data(legs));

        _assertHoldingsEq(_holdings(), before, "reverted call");
        assertEq(_v3Price(), priceBefore, "first leg's price impact survived the revert");
    }

    /// @notice A multi-leg call does not bypass any per-swap check: the call's deadline, each leg's
    /// own amountOutMinimum and amountInMaximum, and the registry of the exact pool a leg targets,
    /// which for a V4 leg is always the hookless one: registering a hooked pool's PoolId does not
    /// make its currencies swappable (the old suite expected HooksNotSupported; a leg cannot encode
    /// hooks any more).
    function test_perLegChecksStillApplyInsideCall() public {
        vm.warp(1_750_000_000);
        SwapCalldata.Leg memory validLeg = _v3In(address(token0), address(token1), 1e18, 0);
        uint256[6] memory before = _holdings();

        // The deadline, one per call, is enforced
        vm.prank(user);
        vm.expectRevert(IProxyErrors.TransactionTooOld.selector);
        proxy.swap(
            SwapCalldata.encode(
                vm.getBlockTimestamp() - 1, _batch(validLeg, _v3In(address(token1), address(token0), 1e18, 0))
            )
        );

        // So is each leg's own amountOutMinimum
        vm.prank(user);
        vm.expectRevert(IProxyErrors.TooLittleReceived.selector);
        proxy.swap(_data(_batch(validLeg, _v3In(address(token1), address(token0), 1e18, 2e18))));

        // ...and each exact-output leg's own amountInMaximum
        vm.prank(user);
        vm.expectRevert(IProxyErrors.TooMuchRequested.selector);
        proxy.swap(_data(_batch(validLeg, _v4Out(cleanKey, false, 1e18, 0.5e18))));

        // Only the hooked PoolId registered: the leg targets the hookless pool, which is not
        ProxyPoolKey memory hooked = cleanKey;
        hooked.hooks = ProxyIHooks(makeAddr("someHook"));
        bytes32 hookedId = proxy.v4Key(hooked);
        bytes32 hooklessId = proxy.v4Key(cleanKey);
        _allow(user, hookedId, SWAP);
        _disallow(user, hooklessId);
        vm.prank(user);
        vm.expectRevert(IProxyErrors.PoolNotAllowed.selector);
        proxy.swap(_data(_batch(validLeg, _v4In(hooked, true, 1e18, 0))));

        _assertHoldingsEq(_holdings(), before, "rejected calls");
    }

    /// @notice Amounts are 16-byte fields, so no amount can reach 2**255 and wrap negative, which would
    /// flip exact input into exact output (or back). Even the largest one the format carries keeps its
    /// direction inside a multi-leg call: a V3 pool is asked for +(2**128 - 1) as an exact input and
    /// -(2**128 - 1) as an exact output, the PoolManager (opposite sign convention) for -(2**128 - 1)
    /// as an exact input and +(2**128 - 1) as an exact output. Each of the four runs when a price limit
    /// stops it (on V4 only what a leg actually swaps must fit in int128, SwapFlags), and an exact
    /// output without a price limit must still fill completely.
    /// Replaces the SafeCast revert on 2**255, which the format cannot express any more.
    function test_largestEncodableAmount_keepsItsSwapDirection() public {
        SwapCalldata.Leg memory validLeg = _v4In(cleanKey, true, 1e18, 0);
        uint128 max = type(uint128).max;
        int256 maxSigned = SafeCast.toInt256(uint256(max));

        // Exact input of the maximum, stopped by a sqrt price limit 1% down: the pool sees a positive amount
        SwapCalldata.Leg memory exactIn = _v3In(address(token0), address(token1), max, 0);
        exactIn.sqrtPriceLimitX96 = SQRT_PRICE_1_1 / 100 * 99;
        vm.expectCall(
            address(v3Pool),
            abi.encodeWithSelector(
                IUniswapV3PoolMinimal.swap.selector, user, true, maxSigned, exactIn.sqrtPriceLimitX96
            ),
            1
        );
        uint256 token0Before = token0.balanceOf(user);
        uint256[] memory amounts = _swapAs(user, _batch(exactIn, validLeg));
        assertGt(amounts[0], 0, "exact input of the maximum did not execute");
        assertLt(token0Before - token0.balanceOf(user), 100e18, "paid more than a swap down to the limit costs");

        // Exact output of the maximum, stopped by a sqrt price limit 1% up: the pool sees a negative amount
        SwapCalldata.Leg memory exactOut = _v3Out(address(token1), address(token0), max, max);
        exactOut.sqrtPriceLimitX96 = SQRT_PRICE_1_1 / 100 * 101;
        vm.expectCall(
            address(v3Pool),
            abi.encodeWithSelector(
                IUniswapV3PoolMinimal.swap.selector, user, false, -maxSigned, exactOut.sqrtPriceLimitX96
            ),
            1
        );
        amounts = _swapAs(user, _batch(exactOut, validLeg));
        assertGt(amounts[0], 0, "exact output of the maximum did not execute");

        // V4 exact input of the maximum, stopped by a sqrt price limit 1% down: the PoolManager sees a
        // negative amount
        (uint160 v4Price,,,) = StateLibrary.getSlot0(manager, PoolId.wrap(proxy.v4Key(cleanKey)));
        SwapCalldata.Leg memory v4ExactIn = _v4In(cleanKey, true, max, 0);
        v4ExactIn.sqrtPriceLimitX96 = v4Price / 100 * 99;
        ProxyPoolKey memory key = cleanKey;
        vm.expectCall(
            address(manager),
            abi.encodeWithSelector(
                IPoolManagerMinimal.swap.selector, key, true, -maxSigned, v4ExactIn.sqrtPriceLimitX96
            ),
            1
        );
        amounts = _swapAs(user, _batch(v4ExactIn, _v3In(address(token0), address(token1), 1e18, 0)));
        assertGt(amounts[0], 0, "V4 exact input of the maximum did not execute");
        _assertProxyHoldsNothing();

        // V4 exact output of the maximum, stopped by a sqrt price limit 1% up: the PoolManager sees a
        // positive amount
        (v4Price,,,) = StateLibrary.getSlot0(manager, PoolId.wrap(proxy.v4Key(cleanKey)));
        SwapCalldata.Leg memory v4ExactOut = _v4Out(cleanKey, false, max, max); // token1 -> token0
        v4ExactOut.sqrtPriceLimitX96 = v4Price / 100 * 101;
        vm.expectCall(
            address(manager),
            abi.encodeWithSelector(
                IPoolManagerMinimal.swap.selector, key, false, maxSigned, v4ExactOut.sqrtPriceLimitX96
            ),
            1
        );
        amounts = _swapAs(user, _batch(v4ExactOut, _v3In(address(token0), address(token1), 1e18, 0)));
        assertGt(amounts[0], 0, "V4 exact output of the maximum did not execute");
        _assertProxyHoldsNothing();

        // Without a price limit, an exact output that the pool cannot fill is refused
        uint256[6] memory before = _holdings();
        vm.prank(user);
        vm.expectRevert(IProxyErrors.TooLittleReceived.selector);
        proxy.swap(_data(_batch(_v3Out(address(token1), address(token0), max, max), validLeg)));
        _assertHoldingsEq(_holdings(), before, "rejected call");
    }

    /// @notice A leg has no recipient field: on V3 and V4 alike, an output that is not parked goes to
    /// the caller, so a call cannot send its output to the proxy (or anywhere else). Replaces the
    /// rejection of `recipient = address(proxy)` on V3 and V4 legs, which can no longer be encoded.
    function test_outputsLandAtTheCaller_neverInTheProxy() public {
        SwapCalldata.Leg[] memory legs =
            _batch(_v4In(cleanKey, true, 1e18, 0), _v3In(address(token0), address(token1), 1e18, 0));
        uint256[6] memory before = _holdings();

        // The PoolManager pays the V4 output to the caller, the V3 pool pays the V3 output to the caller
        vm.expectCall(
            address(manager), abi.encodeWithSelector(IPoolManagerMinimal.take.selector, address(token1), user), 1
        );
        vm.expectCall(address(v3Pool), abi.encodeWithSelector(IUniswapV3PoolMinimal.swap.selector, user), 1);
        vm.recordLogs();
        uint256[] memory amounts = _swapAs(user, legs);

        assertEq(token1.balanceOf(user), before[1] + amounts[0] + amounts[1], "outputs did not land at the caller");
        assertEq(token0.balanceOf(user), before[0] - 2e18, "the caller paid other than the inputs");
        _assertNoTransferInvolves(vm.getRecordedLogs(), address(proxy), "a token moved through the proxy");
        _assertProxyHoldsNothing();
    }

    // ---------------------------------------------------------------------------
    // Malformed calls (SwapFlags layout rules), refused before anything runs
    // ---------------------------------------------------------------------------

    /// @notice A leg whose flags byte has a bit outside V4 | EXACT_OUT | PARK | HELD | PRICE_LIMIT, or
    /// HELD with EXACT_OUT, is refused, and refusing it means the valid leg placed before it never
    /// runs: no pool swap, no unlock, no balance or price change. Replaces the unknown swap types
    /// (0x00, 0x05, 0xff and the empty item; 0x00 is a valid V3 exact-input leg now).
    function test_unknownFlags_areRejectedBeforeAnythingRuns() public {
        bytes memory validLeg = SwapCalldata.encodeLeg(_v3In(address(token0), address(token1), 1e18, 0), 0, 1);
        bytes memory fields = _slice(validLeg, 1, validLeg.length); // the leg after its flags byte
        uint8[6] memory invalid = [
            uint8(0x20),
            0x40,
            0x80,
            0xff,
            SwapFlags.HELD | SwapFlags.EXACT_OUT,
            SwapFlags.V4 | SwapFlags.HELD | SwapFlags.EXACT_OUT
        ];

        uint256[6] memory before = _holdings();
        uint160 priceBefore = _v3Price();
        vm.expectCall(address(v3Pool), abi.encodeWithSelector(IUniswapV3PoolMinimal.swap.selector), 0);
        vm.expectCall(address(manager), abi.encodeWithSelector(IPoolManagerMinimal.unlock.selector), 0);

        for (uint256 i = 0; i < invalid.length; i++) {
            _expectMalformed(
                _withTable(
                    _table(address(token0), address(token1)), bytes.concat(validLeg, bytes1(invalid[i]), fields)
                ),
                string.concat("flags ", vm.toString(invalid[i]))
            );
        }

        _assertHoldingsEq(_holdings(), before, "rejected calls");
        assertEq(_v3Price(), priceBefore, "a rejected call moved the pool");
    }

    /// @notice Every flags byte with an unknown bit, or with HELD and EXACT_OUT together, is refused,
    /// whatever follows it.
    function testFuzz_anyUnknownFlagIsRejected(uint8 flags, bytes calldata fields) public {
        vm.assume(
            flags & ~SwapFlags.ALL != 0
                || flags & (SwapFlags.HELD | SwapFlags.EXACT_OUT) == (SwapFlags.HELD | SwapFlags.EXACT_OUT)
        );
        bytes memory validLeg = SwapCalldata.encodeLeg(_v3In(address(token0), address(token1), 1e18, 0), 0, 1);
        uint256[6] memory before = _holdings();
        vm.expectCall(address(v3Pool), abi.encodeWithSelector(IUniswapV3PoolMinimal.swap.selector), 0);

        _expectMalformed(
            _withTable(_table(address(token0), address(token1)), bytes.concat(validLeg, bytes1(flags), fields)),
            "unknown flags accepted"
        );

        _assertHoldingsEq(_holdings(), before, "rejected call");
    }

    /// @notice "HELD only with exact input" is a rule of its own, not a side effect of a broken layout:
    /// a HELD exact-output leg laid out exactly as a HELD leg (22 bytes on V3, 25 on V4, as the encoder
    /// emits it), after a valid PARK leg that it would spend, is refused before anything runs: no pool
    /// swap, no unlock. The same data with only EXACT_OUT cleared is a valid chain, which runs.
    function test_wellFormedHeldExactOutputLeg_isRejectedBeforeAnythingRuns() public {
        address[] memory two = _table(address(token0), address(token1));
        // token0 -> token1 parked, then a HELD leg back to token0: on the V3 pool, then on the V4 one
        SwapCalldata.Leg[2] memory parkLegs =
            [_v3In(address(token0), address(token1), 1e18, 0), _v4In(cleanKey, true, 1e18, 0)];
        SwapCalldata.Leg[2] memory heldLegs =
            [_v3In(address(token1), address(token0), 0, 0), _v4In(cleanKey, false, 0, 0)];
        uint256[2] memory heldSizes = [uint256(22), 25];
        string[2] memory version = ["V3", "V4"];
        bytes[2] memory heldExactOut;
        for (uint256 i = 0; i < 2; i++) {
            parkLegs[i].park = true;
            heldLegs[i].held = true;
            bytes memory park = SwapCalldata.encodeLeg(parkLegs[i], 0, 1);
            bytes memory heldIn = SwapCalldata.encodeLeg(heldLegs[i], 1, 0);
            heldLegs[i].exactOut = true;
            bytes memory heldOut = SwapCalldata.encodeLeg(heldLegs[i], 1, 0);
            assertEq(heldOut.length, heldSizes[i], string.concat("fixture: not the ", version[i], " HELD layout"));
            assertEq(uint8(heldOut[0]), uint8(heldIn[0]) | SwapFlags.EXACT_OUT, "fixture: flags");
            assertEq(_slice(heldOut, 1, heldOut.length), _slice(heldIn, 1, heldIn.length), "fixture: fields differ");

            // Control: as exact input, the HELD leg completes a chain that runs
            vm.prank(user);
            uint256[] memory amounts = proxy.swap(_withTable(two, bytes.concat(park, heldIn)));
            assertGt(amounts[1], 0, string.concat("fixture: the ", version[i], " chain did not run"));

            heldExactOut[i] = _withTable(two, bytes.concat(park, heldOut));
        }

        uint256[6] memory before = _holdings();
        uint160 priceBefore = _v3Price();
        vm.expectCall(address(v3Pool), abi.encodeWithSelector(IUniswapV3PoolMinimal.swap.selector), 0);
        vm.expectCall(address(manager), abi.encodeWithSelector(IPoolManagerMinimal.unlock.selector), 0);

        for (uint256 i = 0; i < 2; i++) {
            _expectMalformed(heldExactOut[i], string.concat(version[i], " HELD exact-output leg"));
        }

        _assertHoldingsEq(_holdings(), before, "rejected calls");
        assertEq(_v3Price(), priceBefore, "a rejected call moved the pool");
    }

    /// @notice The data must end exactly where its last leg does: every prefix of a valid two-leg
    /// call that cuts the header, the token table or a leg is refused (only the cut right after the
    /// first leg is a valid one-leg call), and so is every tail too short to be a leg. Replaces the
    /// truncated V4 params, which reverted in abi.decode.
    function test_truncatedOrTrailingData_isRejected() public {
        bytes memory data =
            _data(_batch(_v3In(address(token0), address(token1), 1e18, 0), _v4In(cleanKey, false, 1e18, 0)));
        uint256 tableEnd = SwapFlags.HEADER_SIZE + 2 * 20;
        uint256 firstLegEnd = tableEnd + 6 + 16 + 16; // V3 exact input: no tickSpacing, no price limit
        assertEq(data.length, firstLegEnd + 6 + 3 + 16 + 16, "fixture: unexpected layout");

        uint256[6] memory before = _holdings();
        vm.expectCall(address(v3Pool), abi.encodeWithSelector(IUniswapV3PoolMinimal.swap.selector), 0);
        vm.expectCall(address(manager), abi.encodeWithSelector(IPoolManagerMinimal.unlock.selector), 0);

        for (uint256 cut = 0; cut < data.length; cut++) {
            if (cut == firstLegEnd) continue; // a complete one-leg call
            _expectMalformed(_slice(data, 0, cut), string.concat("data cut at byte ", vm.toString(cut)));
        }
        for (uint256 extra = 1; extra < SwapFlags.MIN_LEG_SIZE; extra++) {
            _expectMalformed(
                bytes.concat(data, new bytes(extra)), string.concat(vm.toString(extra), " zero bytes after")
            );
            _expectMalformed(
                bytes.concat(data, _slice(data, tableEnd, tableEnd + extra)),
                string.concat("the first ", vm.toString(extra), " bytes of a leg after")
            );
        }

        _assertHoldingsEq(_holdings(), before, "rejected calls");
    }

    /// @notice The other layout rules of SwapFlags, each on a leg placed after a valid one, each
    /// refused before anything runs: token indices inside the table, two different tokens per leg
    /// (a zeroed leg is the same token twice), no native ETH on a V3 leg, no zero price limit.
    function test_everyLayoutRule_isEnforcedBeforeAnythingRuns() public {
        address[] memory two = _table(address(token0), address(token1));
        bytes memory valid = SwapCalldata.encodeLeg(_v3In(address(token0), address(token1), 1e18, 0), 0, 1);
        uint256[6] memory before = _holdings();
        vm.expectCall(address(v3Pool), abi.encodeWithSelector(IUniswapV3PoolMinimal.swap.selector), 0);
        vm.expectCall(address(manager), abi.encodeWithSelector(IPoolManagerMinimal.unlock.selector), 0);

        // An index outside the token table, on either side, or no table at all
        _expectMalformed(_withTable(two, bytes.concat(valid, _v3LegAt(2, 1))), "tokenIn index outside the table");
        _expectMalformed(_withTable(two, bytes.concat(valid, _v3LegAt(0, 2))), "tokenOut index outside the table");
        _expectMalformed(_withTable(new address[](0), valid), "empty token table");

        // The same token on both sides: one index twice, or one address listed twice
        _expectMalformed(_withTable(two, bytes.concat(valid, _v3LegAt(1, 1))), "same index on both sides");
        _expectMalformed(
            _withTable(_table(address(token0), address(token1), address(token0)), bytes.concat(valid, _v3LegAt(0, 2))),
            "same token listed twice"
        );
        // ...which is what a zeroed leg is (V3 exact input from token 0 to token 0), so it never swaps
        _expectMalformed(_withTable(two, bytes.concat(valid, new bytes(38))), "zeroed leg");

        // Native ETH on a V3 leg, as input or as output (V3 has no native pools)
        address[] memory withEth = _table(address(token0), address(token1), ETH);
        _expectMalformed(_withTable(withEth, bytes.concat(valid, _v3LegAt(2, 1))), "V3 leg paying ETH");
        _expectMalformed(_withTable(withEth, bytes.concat(valid, _v3LegAt(1, 2))), "V3 leg buying ETH");

        // PRICE_LIMIT set with a zero limit
        SwapCalldata.Leg memory limited = _v3In(address(token1), address(token0), 1e18, 0);
        limited.sqrtPriceLimitX96 = 1;
        bytes memory zeroLimit = SwapCalldata.encodeLeg(limited, 1, 0);
        for (uint256 i = zeroLimit.length - 20; i < zeroLimit.length; i++) {
            zeroLimit[i] = 0;
        }
        _expectMalformed(_withTable(two, bytes.concat(valid, zeroLimit)), "PRICE_LIMIT with a zero limit");

        _assertHoldingsEq(_holdings(), before, "rejected calls");
    }

    /// @notice A call carries at most 255 legs: 255 pass validation (here they then fail on the first
    /// leg's execution, with nothing held), 256 are refused as malformed before anything runs.
    function test_atMost255Legs() public {
        SwapCalldata.Leg memory held = _v3In(address(token0), address(token1), 0, 0);
        held.held = true;
        bytes memory leg = SwapCalldata.encodeLeg(held, 0, 1);
        address[] memory two = _table(address(token0), address(token1));

        vm.prank(user);
        vm.expectRevert(IProxyErrors.NothingHeld.selector);
        proxy.swap(_withTable(two, _repeat(leg, 255)));

        _expectMalformed(_withTable(two, _repeat(leg, 256)), "256 legs");
    }

    // ---------------------------------------------------------------------------
    // Native ETH
    // ---------------------------------------------------------------------------

    /// @notice `swap` is payable, but a call keeps only the ETH its legs spend: with no native input
    /// the caller gets its whole msg.value back, whether the call ran inside an unlock or not.
    /// Replaces "batchSwap rejects ETH" (it was not payable).
    function test_swapIsPayable_unspentEthIsRefunded() public {
        uint256 ethBefore = user.balance;

        vm.prank(user);
        proxy.swap{value: 1e18}(
            _data(_batch(_v3In(address(token0), address(token1), 1e18, 0), _v4In(cleanKey, true, 1e18, 0)))
        );
        assertEq(user.balance, ethBefore, "msg.value not refunded (V3 and V4 legs)");

        vm.prank(user);
        proxy.swap{value: 1e18}(_data(_batch(_v3In(address(token0), address(token1), 1e18, 0))));
        assertEq(user.balance, ethBefore, "msg.value not refunded (V3 legs only)");

        _assertProxyHoldsNothing();
    }

    /// @notice Native-ETH input on V4 legs is paid from the call's msg.value, leg after leg, and the
    /// caller keeps the change: without msg.value the first native leg cannot be paid, with too little
    /// the leg that runs out reverts the whole call, and with enough the caller pays exactly what the
    /// legs spent. Replaces "native input cannot be paid in a batch".
    function test_nativeInputLegs_arePaidFromMsgValue() public {
        SwapCalldata.Leg[] memory legs = new SwapCalldata.Leg[](3);
        legs[0] = _v3In(address(token0), address(token1), 1e18, 0);
        legs[1] = _v4In(nativeKey, true, 1e18, 0); // 1 ETH -> token1
        legs[2] = _v4Out(nativeKey, true, 0.5e18, 1e18); // ETH -> exactly 0.5 token1
        uint256[6] memory before = _holdings();

        vm.prank(user);
        vm.expectRevert(IProxyErrors.NotEnoughEthSent.selector);
        proxy.swap(_data(legs));

        vm.prank(user);
        vm.expectRevert(IProxyErrors.NotEnoughEthSent.selector);
        proxy.swap{value: 1.2e18}(_data(legs)); // the first native leg only

        _assertHoldingsEq(_holdings(), before, "rejected calls");

        vm.prank(user);
        uint256[] memory amounts = proxy.swap{value: 5e18}(_data(legs));

        assertEq(before[2] - user.balance, 1e18 + amounts[2], "the caller paid other than what the native legs spent");
        assertEq(token1.balanceOf(user), before[1] + amounts[0] + amounts[1] + 0.5e18, "outputs");
        _assertProxyHoldsNothing();
    }

    /// @notice Receiving native ETH works, and the PoolManager pays the caller directly: the proxy
    /// never touches the ETH.
    function test_nativeOutputV4Leg_paysTheCallerDirectly() public {
        uint256 ethBefore = recipient.balance;

        vm.expectCall(address(manager), abi.encodeWithSelector(IPoolManagerMinimal.take.selector, ETH, user), 1);
        uint256[] memory amounts = _swapAs(
            user,
            _batch(
                _v3In(address(token0), address(token1), 1e18, 0),
                _v4In(nativeKey, false, 1e18, 0) // token1 in, ETH out
            )
        );

        assertGt(amounts[1], 0, "no ETH output");
        assertEq(recipient.balance - ethBefore, amounts[1], "recipient did not receive ETH");
        _assertProxyHoldsNothing();
    }

    /// @notice ETH force-fed to the proxy (a selfdestruct, a coinbase payment; it has no `receive`)
    /// belongs to no one, and no call spends it or refunds it. Without a native leg, a call gets back
    /// exactly its own msg.value (nothing if it sent none), with or without an unlock. A native-input
    /// leg is paid from msg.value only: short of its input it reverts NotEnoughEthSent although the
    /// stray ETH would cover it, and with a surplus the caller pays exactly the input and gets the
    /// surplus back. After every call the proxy holds exactly the stray ETH. Replaces the sweep of the
    /// stray ETH to the next caller, which also let a native-input leg spend it.
    function test_forceFedEth_isNeitherSpentNorRefunded() public {
        uint256 stray = 5e18;
        vm.deal(address(proxy), stray);
        uint256 ethBefore = user.balance;

        // No native leg: msg.value 0 or 1 ETH, on a V3-only call and on a call with an unlock
        SwapCalldata.Leg[2] memory nonNative =
            [_v3In(address(token0), address(token1), 1e18, 0), _v4In(cleanKey, true, 1e18, 0)];
        string[2] memory kind = ["V3-only call", "call with an unlock"];
        uint256[2] memory values = [uint256(0), 1e18];
        for (uint256 i = 0; i < nonNative.length; i++) {
            for (uint256 j = 0; j < values.length; j++) {
                string memory ctx = string.concat(kind[i], " with msg.value ", vm.toString(values[j]));
                vm.prank(user);
                proxy.swap{value: values[j]}(_data(_batch(nonNative[i])));
                assertEq(user.balance, ethBefore, string.concat(ctx, ": refund other than msg.value"));
                assertEq(address(proxy).balance, stray, string.concat(ctx, ": the stray ETH moved"));
            }
        }

        // A native-input leg (1 ETH -> token1) with msg.value short of its input, the stray ETH being enough
        SwapCalldata.Leg[] memory native = _batch(_v4In(nativeKey, true, 1e18, 0));
        uint256[2] memory short = [uint256(0), 1e18 - 1];
        for (uint256 i = 0; i < short.length; i++) {
            vm.prank(user);
            vm.expectRevert(IProxyErrors.NotEnoughEthSent.selector);
            proxy.swap{value: short[i]}(_data(native));
            assertEq(address(proxy).balance, stray, "short msg.value: the stray ETH moved");
        }
        assertEq(user.balance, ethBefore, "short msg.value: the caller's ETH moved");

        // msg.value = input + surplus: the caller pays exactly the input and gets the surplus back
        uint256 token1Before = token1.balanceOf(user);
        vm.prank(user);
        uint256[] memory amounts = proxy.swap{value: 1e18 + 0.5e18}(_data(native));
        assertEq(user.balance + 1e18, ethBefore, "native leg: the caller paid other than its input");
        assertEq(token1.balanceOf(user), token1Before + amounts[0], "native leg output");
        assertEq(address(proxy).balance, stray, "native leg: the stray ETH moved");
        assertEq(token0.balanceOf(address(proxy)), 0, "proxy retained token0");
        assertEq(token1.balanceOf(address(proxy)), 0, "proxy retained token1");
    }

    /// @notice A caller that cannot receive ETH (a contract with no `receive` and no `fallback`) is not
    /// blocked by ETH force-fed to the proxy: a call that sends no ETH gets none back, so its V3-only
    /// call and its call with a V4 leg (ERC20 only) both succeed, it receives no ETH, and the stray
    /// ETH stays in the proxy. (While every call swept the proxy's balance to its caller, force-feeding
    /// the proxy made such a caller's swaps revert.)
    function test_callerThatCannotReceiveEth_isNotBlockedByForceFedEth() public {
        EthRejectingVault vault = new EthRejectingVault();
        token0.mint(address(vault), 10e18);
        vault.approve(address(token0), address(proxy));
        _allow(address(vault), proxy.v3Key(address(v3Pool)), SWAP);
        _allow(address(vault), proxy.v4Key(cleanKey), SWAP);
        vm.deal(address(proxy), 5e18);
        (bool accepted,) = address(vault).call{value: 1}("");
        assertFalse(accepted, "fixture: the vault accepts ETH");

        uint256[] memory v3Only = vault.swap(proxy, _data(_batch(_v3In(address(token0), address(token1), 1e18, 0))));
        uint256[] memory withUnlock = vault.swap(proxy, _data(_batch(_v4In(cleanKey, true, 1e18, 0))));

        assertEq(token0.balanceOf(address(vault)), 8e18, "the vault paid other than its two inputs");
        assertEq(token1.balanceOf(address(vault)), v3Only[0] + withUnlock[0], "the vault did not receive its outputs");
        assertEq(address(vault).balance, 0, "the vault received ETH");
        assertEq(address(proxy).balance, 5e18, "the stray ETH moved");
    }

    /// @notice Funds that reached the proxy outside a call (a direct token transfer, force-fed ETH)
    /// are never spent by a HELD leg, which spends exactly what earlier legs of the same call parked:
    /// with nothing parked it reverts NothingHeld, and a chain through a token the proxy happens to
    /// hold, ETH included, leaves that stray balance untouched. The stray ETH is not refunded either:
    /// it stays in the proxy. Replaces `HELD_BALANCE`, which spent the whole stranded balance.
    function test_heldLegs_neverSpendStrayFunds() public {
        assertTrue(token1.transfer(address(proxy), 7e18));
        vm.deal(address(proxy), 5e18);
        uint256 ethBefore = user.balance;

        SwapCalldata.Leg[3] memory heldLegs = [
            _v3In(address(token1), address(token0), 0, 0),
            _v4In(cleanKey, false, 0, 0), // token1 in
            _v4In(nativeKey, true, 0, 0) // ETH in
        ];
        for (uint256 i = 0; i < heldLegs.length; i++) {
            heldLegs[i].held = true;
            vm.prank(user);
            vm.expectRevert(IProxyErrors.NothingHeld.selector);
            proxy.swap(_data(_batch(heldLegs[i])));
        }
        assertEq(address(proxy).balance, 5e18, "a rejected call moved the stray ETH");

        // token0 -V3-> token1 -V3-> token0: the parked token1 sits next to the stray 7e18 in the proxy
        SwapCalldata.Leg memory parkV3 = _v3In(address(token0), address(token1), 1e18, 0);
        parkV3.park = true;
        _swapAs(user, _batch(parkV3, heldLegs[0]));
        assertEq(token1.balanceOf(address(proxy)), 7e18, "the V3 chain spent stray token1");

        // token0 -V4-> token1 -V4-> token0: the parked token1 is PoolManager credit
        SwapCalldata.Leg memory parkV4 = _v4In(cleanKey, true, 1e18, 0);
        parkV4.park = true;
        _swapAs(user, _batch(parkV4, heldLegs[1]));
        assertEq(token1.balanceOf(address(proxy)), 7e18, "the V4 chain spent stray token1");

        // token1 -V4-> ETH -V4-> token1: the parked ETH is PoolManager credit, which the native HELD
        // leg spends, never the proxy's stray ETH
        SwapCalldata.Leg memory parkEth = _v4In(nativeKey, false, 1e18, 0);
        parkEth.park = true;
        uint256[] memory amounts = _swapAs(user, _batch(parkEth, heldLegs[2]));
        assertGt(amounts[1], 0, "the ETH chain did not run");
        assertEq(token1.balanceOf(address(proxy)), 7e18, "the ETH chain spent stray token1");

        assertEq(address(proxy).balance, 5e18, "the stray ETH was spent or refunded");
        assertEq(user.balance, ethBefore, "the caller's ETH changed");
        assertEq(token0.balanceOf(address(proxy)), 0, "proxy retained token0");
    }

    /// @notice The proxy has no `receive` and no `fallback`: every plain ETH transfer to it reverts,
    /// from the vault, from an outsider, and from the PoolManager itself, which never needs to pay it
    /// (native outputs are credit or are taken straight to the vault). The old `receive` admitted the
    /// PoolManager.
    function test_plainEthTransfers_revert_evenFromThePoolManager() public {
        address outsider = makeAddr("outsider");
        vm.deal(outsider, 1e18);
        address[3] memory senders = [user, outsider, address(manager)];

        for (uint256 i = 0; i < senders.length; i++) {
            assertGe(senders[i].balance, 1e18, "fixture: sender cannot fund the transfer");
            vm.prank(senders[i]);
            (bool ok,) = address(proxy).call{value: 1e18}("");
            assertFalse(ok, string.concat("plain ETH transfer accepted from ", vm.toString(senders[i])));
        }
        assertEq(address(proxy).balance, 0, "proxy holds ETH");
    }

    // ---------------------------------------------------------------------------
    // Payer authority
    // ---------------------------------------------------------------------------

    /// @notice A call pays from whoever submits it, never from another account's standing approval,
    /// and pays its outputs to that same account. The outsider is a vault in its own right here (its
    /// own registrations, its own output), so the only thing between it and the user's allowance is
    /// who pays.
    function test_callAlwaysPaysFromItsCaller() public {
        address outsider = makeAddr("outsider");
        token0.mint(outsider, 10e18);
        _allow(outsider, proxy.v3Key(address(v3Pool)), SWAP);
        _allow(outsider, proxy.v4Key(cleanKey), SWAP);
        uint256[6] memory userBefore = _holdings();
        SwapCalldata.Leg[] memory legs =
            _batch(_v3In(address(token0), address(token1), 1e18, 0), _v4In(cleanKey, true, 1e18, 0));

        // Without an approval of their own, the outsider's call cannot reach the user's allowance
        vm.prank(outsider);
        vm.expectRevert(bytes("STF"));
        proxy.swap(_data(legs));

        // With one, the outsider's call debits the outsider and pays the outsider
        vm.prank(outsider);
        token0.approve(address(proxy), type(uint256).max);
        uint256[] memory amounts = _swapAs(outsider, legs);

        assertEq(token0.balanceOf(outsider), 8e18, "outsider was not the payer");
        assertEq(token1.balanceOf(outsider), amounts[0] + amounts[1], "outsider did not receive the outputs");
        _assertHoldingsEq(_holdings(), userBefore, "the user's funds moved");
        _assertProxyHoldsNothing();
    }

    // ---------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------

    /// @dev The `data` argument of `swap` running `legs`, with the current block as deadline
    function _data(SwapCalldata.Leg[] memory legs) internal view returns (bytes memory) {
        return SwapCalldata.encode(vm.getBlockTimestamp(), legs);
    }

    /// @dev The 5-byte header: the current block as deadline, then `tokenCount`
    function _header(uint256 tokenCount) internal view returns (bytes memory) {
        return bytes.concat(bytes4(SafeCast.toUint32(vm.getBlockTimestamp())), bytes1(SafeCast.toUint8(tokenCount)));
    }

    /// @dev Hand-made `data`: the header and token table for `tokens`, then `legs` as raw bytes
    function _withTable(address[] memory tokens, bytes memory legs) internal view returns (bytes memory data) {
        data = _header(tokens.length);
        for (uint256 t = 0; t < tokens.length; t++) {
            data = bytes.concat(data, bytes20(tokens[t]));
        }
        data = bytes.concat(data, legs);
    }

    function _table(address a, address b) internal pure returns (address[] memory tokens) {
        tokens = new address[](2);
        (tokens[0], tokens[1]) = (a, b);
    }

    function _table(address a, address b, address c) internal pure returns (address[] memory tokens) {
        tokens = new address[](3);
        (tokens[0], tokens[1], tokens[2]) = (a, b, c);
    }

    /// @dev A V3 exact-input leg of 1e18 between the tokens at `inIndex` and `outIndex`
    function _v3LegAt(uint256 inIndex, uint256 outIndex) internal view returns (bytes memory) {
        return SwapCalldata.encodeLeg(_v3In(address(token0), address(token1), 1e18, 0), inIndex, outIndex);
    }

    /// @dev Calls `swap(data)` as the user and requires it to revert with exactly MalformedSwap
    function _expectMalformed(bytes memory data, string memory ctx) internal {
        vm.prank(user);
        (bool ok, bytes memory ret) = address(proxy).call(abi.encodeCall(UniswapSwapProxy.swap, (data)));
        assertFalse(ok, string.concat(ctx, ": accepted"));
        assertEq(ret, abi.encodeWithSelector(IProxyErrors.MalformedSwap.selector), string.concat(ctx, ": reason"));
    }

    /// @dev Removes `key` from `who`'s registry entries
    function _disallow(address who, bytes32 key) internal {
        bytes32[] memory keys = new bytes32[](1);
        keys[0] = key;
        vm.prank(who);
        proxy.setPools(keys, new uint8[](1));
    }

    /// @dev Fails if any ERC20 Transfer in `logs` moves tokens to or from `who`
    function _assertNoTransferInvolves(VmSafe.Log[] memory logs, address who, string memory ctx) internal pure {
        for (uint256 i = 0; i < logs.length; i++) {
            bytes32[] memory topics = logs[i].topics;
            if (topics.length != 3 || topics[0] != TRANSFER_TOPIC) continue;
            assertTrue(_topicAddress(topics[1]) != who && _topicAddress(topics[2]) != who, ctx);
        }
    }

    /// @dev An indexed address topic, read back as an address
    function _topicAddress(bytes32 topic) internal pure returns (address) {
        return abi.decode(abi.encode(topic), (address));
    }

    /// @dev `data[start:end]`, copied
    function _slice(bytes memory data, uint256 start, uint256 end) internal pure returns (bytes memory out) {
        out = new bytes(end - start);
        for (uint256 i = 0; i < out.length; i++) {
            out[i] = data[start + i];
        }
    }

    /// @dev `unit`, `times` times back to back
    function _repeat(bytes memory unit, uint256 times) internal pure returns (bytes memory out) {
        out = new bytes(unit.length * times);
        for (uint256 i = 0; i < out.length; i++) {
            out[i] = unit[i % unit.length];
        }
    }
}

/// @notice A vault that cannot receive ETH: a contract with no `receive` and no `fallback`, which
/// approves the proxy and calls `swap` itself
contract EthRejectingVault {
    function approve(address token, address spender) external {
        require(IERC20(token).approve(spender, type(uint256).max), "approve failed");
    }

    function swap(UniswapSwapProxy proxy, bytes calldata data) external returns (uint256[] memory) {
        return proxy.swap(data);
    }
}
