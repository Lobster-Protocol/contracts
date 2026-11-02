// SPDX-License-Identifier: GPL-3.0
pragma solidity =0.8.28;

import "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {ForkBase} from "../helpers/ForkBase.sol";
import {SwapCalldata} from "../../helpers/SwapCalldata.sol";
import {IUniswapV3PoolMinimal} from "../../../src/interfaces/uniswapV3/IUniswapV3PoolMinimal.sol";
import {IProxyErrors} from "../../../src/interfaces/IProxyErrors.sol";

/// @notice Multi-leg `swap` calls against live pools: V3 and V4 legs in one transaction.
/// @dev The mock suites cover the packed format and the chaining rules in depth. This one confirms
/// they hold against the canonical deployments, where V3 callbacks run inside the call's single V4
/// unlock and parked funds really move between a V3 pool, the PoolManager and the proxy.
contract BatchSwapTest is ForkBase {
    /// @dev USDC -> WETH on V3 (0.05%), USDC -> ETH on V4, then WETH -> USDC on V3 (0.3%). Two V3
    /// pools, one V4 pool, both swap directions, independent legs. Every output goes to the caller.
    function _mixedBatch(uint128 v4MinOut) internal view returns (SwapCalldata.Leg[] memory legs) {
        legs = new SwapCalldata.Leg[](3);
        legs[0] = _v3In(USDC, WETH, 500, tradeUsdc, 0);
        legs[1] = _v4In(false, tradeUsdc, v4MinOut); // USDC in, native ETH out
        legs[2] = _v3In(WETH, USDC, 3000, tradeWeth, 0);
    }

    function _price(address pool) internal view returns (uint160 sqrtPriceX96) {
        (sqrtPriceX96,,,,,,) = IUniswapV3PoolMinimal(pool).slot0();
    }

    /// @notice Independent V3 and V4 legs in one call give the same amounts and balances as the same
    /// legs made one by one, inside exactly one PoolManager unlock
    function test_mixedV3AndV4Batch_matchesSameSwapsMadeOneByOne() public {
        SwapCalldata.Leg[] memory legs = _mixedBatch(0);

        // Reference run: each leg as a one-leg call, then rewind
        uint256 snap = vm.snapshotState();
        uint256[] memory expected = new uint256[](legs.length);
        for (uint256 i = 0; i < legs.length; i++) {
            bytes memory oneLeg = _swapCall(_one(legs[i]));
            vm.prank(approver);
            (bool ok, bytes memory ret) = address(proxy).call(oneLeg);
            assertTrue(ok, "reference call failed");
            expected[i] = abi.decode(ret, (uint256[]))[0];
        }
        uint256[4] memory expectedHoldings = _approverHoldings();
        vm.revertToState(snap);

        uint256 wethBefore = IERC20(WETH).balanceOf(approver);
        uint256 usdcBefore = IERC20(USDC).balanceOf(approver);
        uint256 ethBefore = approver.balance;
        bytes memory data = _swapData(legs);

        // The V3 legs run inside the V4 leg's unlock: one unlock for the whole call
        _expectUnlocks(1);
        vm.prank(approver);
        uint256[] memory amounts = proxy.swap(data);

        assertEq(amounts.length, legs.length, "one amount per leg");
        for (uint256 i = 0; i < legs.length; i++) {
            assertEq(amounts[i], expected[i], "batched amount differs from the one-leg call");
        }
        uint256[4] memory holdings = _approverHoldings();
        for (uint256 i = 0; i < 4; i++) {
            assertEq(holdings[i], expectedHoldings[i], "approver balances differ from one-by-one");
        }

        // The caller is also the recipient, so each net change is received minus paid:
        // WETH: +first leg's output - third leg's input; ETH: +V4 output; USDC: -2 inputs + third leg's output
        assertEq(IERC20(WETH).balanceOf(approver) + tradeWeth, wethBefore + amounts[0], "WETH: received minus paid");
        assertEq(approver.balance - ethBefore, amounts[1], "V4 native output");
        assertEq(IERC20(USDC).balanceOf(approver) + 2 * tradeUsdc, usdcBefore + amounts[2], "USDC: received minus paid");
        assertEq(IERC20(USDC).balanceOf(address(proxy)), 0, "proxy retained USDC");
        assertEq(IERC20(WETH).balanceOf(address(proxy)), 0, "proxy retained WETH");
        assertEq(address(proxy).balance, 0, "proxy retained ETH");
    }

    /// @notice A chained route through native ETH, PARK and HELD legs, matches the same legs made one
    /// by one with each output fed by hand into the next, and leaves the proxy holding nothing
    /// @dev Chaining on live pools, crossing both versions with native ETH in the middle:
    ///   USDC -V4-> ETH (parked) -V4-> USDC (parked) -V3-> WETH
    /// Only the first amount is fixed; each HELD leg spends exactly what the previous one parked. The
    /// parked V4 outputs stay as PoolManager credit, and the V3 leg is paid from that credit by the
    /// PoolManager directly.
    function test_chainedRoute_matchesManualSequence() public {
        SwapCalldata.Leg[] memory legs = new SwapCalldata.Leg[](3);
        legs[0] = _parked(_v4In(false, tradeUsdc, 0));
        legs[1] = _parked(_held(_v4In(true, 0, 0)));
        legs[2] = _held(_v3In(USDC, WETH, 500, 0, 0));

        // Reference: three one-leg calls, each intermediate output delivered to the approver and
        // passed by hand (as msg.value for the ETH leg)
        uint256 snap = vm.snapshotState();
        uint256 a = _swapOne(approver, _v4In(false, tradeUsdc, 0), 0);
        uint256 b = _swapOne(approver, _v4In(true, SafeCast.toUint128(a), 0), a);
        uint256 c = _swapOne(approver, _v3In(USDC, WETH, 500, SafeCast.toUint128(b), 0), 0);
        uint256[4] memory expectedHoldings = _approverHoldings();
        uint256 expectedApproverEth = approver.balance;
        vm.revertToState(snap);

        uint256 wethBefore = IERC20(WETH).balanceOf(approver);
        bytes memory data = _swapData(legs);
        _expectUnlocks(1);
        vm.prank(approver);
        uint256[] memory amounts = proxy.swap(data);

        assertEq(amounts[0], a, "USDC -> ETH leg");
        assertEq(amounts[1], b, "ETH -> USDC leg did not spend exactly the parked ETH");
        assertEq(amounts[2], c, "USDC -> WETH leg did not spend exactly the parked USDC");
        assertEq(IERC20(WETH).balanceOf(approver) - wethBefore, c, "the caller did not get the WETH");

        uint256[4] memory holdings = _approverHoldings();
        for (uint256 i = 0; i < 4; i++) {
            assertEq(holdings[i], expectedHoldings[i], "approver balances differ from the manual sequence");
        }
        assertEq(approver.balance, expectedApproverEth, "approver ETH differs from the manual sequence");
        assertEq(IERC20(USDC).balanceOf(address(proxy)), 0, "proxy retained USDC");
        assertEq(IERC20(WETH).balanceOf(address(proxy)), 0, "proxy retained WETH");
        assertEq(address(proxy).balance, 0, "proxy retained ETH");
    }

    /// @notice A route through every kind of hand-off matches the same legs made one by one
    /// @dev WETH -V3-> USDC -V4-> ETH -V4-> USDC -V3-> WETH -V3-> USDC, every intermediate output
    /// parked and spent by the next leg:
    /// - V3 -> V4: the V3 pool pays its output straight to the PoolManager (settled in the pool's
    ///   callback, before anything else runs);
    /// - V4 -> V4: the output stays as PoolManager credit;
    /// - V4 -> V3: the PoolManager pays the V3 pool from that credit;
    /// - V3 -> V3: the output sits in the proxy until the next pool's callback.
    /// Pools are revisited, so the reference must replay the same legs in the same order.
    function test_routeThroughEveryHandOff_matchesManualSequence() public {
        SwapCalldata.Leg[] memory legs = new SwapCalldata.Leg[](5);
        legs[0] = _parked(_v3In(WETH, USDC, 3000, tradeWeth, 0));
        legs[1] = _parked(_held(_v4In(false, 0, 0)));
        legs[2] = _parked(_held(_v4In(true, 0, 0)));
        legs[3] = _parked(_held(_v3In(USDC, WETH, 500, 0, 0)));
        legs[4] = _held(_v3In(WETH, USDC, 3000, 0, 0));

        // Reference: five one-leg calls, each output passed by hand into the next
        uint256 snap = vm.snapshotState();
        uint256[5] memory expected;
        expected[0] = _swapOne(approver, _v3In(WETH, USDC, 3000, tradeWeth, 0), 0);
        expected[1] = _swapOne(approver, _v4In(false, SafeCast.toUint128(expected[0]), 0), 0);
        expected[2] = _swapOne(approver, _v4In(true, SafeCast.toUint128(expected[1]), 0), expected[1]);
        expected[3] = _swapOne(approver, _v3In(USDC, WETH, 500, SafeCast.toUint128(expected[2]), 0), 0);
        expected[4] = _swapOne(approver, _v3In(WETH, USDC, 3000, SafeCast.toUint128(expected[3]), 0), 0);
        uint256[4] memory expectedHoldings = _approverHoldings();
        uint256 expectedApproverEth = approver.balance;
        vm.revertToState(snap);

        uint256 usdcBefore = IERC20(USDC).balanceOf(approver);
        uint256 wethBefore = IERC20(WETH).balanceOf(approver);
        uint256 ethBefore = approver.balance;
        bytes memory data = _swapData(legs);
        _expectUnlocks(1);
        vm.prank(approver);
        uint256[] memory amounts = proxy.swap(data);

        for (uint256 i = 0; i < 5; i++) {
            assertEq(amounts[i], expected[i], "a leg did not spend exactly what the previous one parked");
        }
        uint256[4] memory holdings = _approverHoldings();
        for (uint256 i = 0; i < 4; i++) {
            assertEq(holdings[i], expectedHoldings[i], "approver balances differ from the manual sequence");
        }
        assertEq(approver.balance, expectedApproverEth, "approver ETH differs from the manual sequence");
        // Only the first input and the last output touched the caller
        assertEq(IERC20(WETH).balanceOf(approver), wethBefore - tradeWeth, "WETH: only the first input");
        assertEq(IERC20(USDC).balanceOf(approver), usdcBefore + amounts[4], "USDC: only the last output");
        assertEq(approver.balance, ethBefore, "ETH moved although it was only an intermediate");
        assertEq(IERC20(USDC).balanceOf(address(proxy)), 0, "proxy retained USDC");
        assertEq(IERC20(WETH).balanceOf(address(proxy)), 0, "proxy retained WETH");
        assertEq(address(proxy).balance, 0, "proxy retained ETH");
    }

    /// @notice A V4 leg failing its bound reverts the whole call, the V3 legs around it included
    function test_failingV4Swap_undoesTheV3SwapsAroundIt() public {
        uint256[4] memory before = _approverHoldings();
        uint160 price500 = _price(USDC_WETH_500);
        bytes memory data = _swapData(_mixedBatch(type(uint128).max));

        vm.prank(approver);
        vm.expectRevert(IProxyErrors.TooLittleReceived.selector);
        proxy.swap(data);

        _assertApproverUntouched(before, "reverted batch");
        assertEq(_price(USDC_WETH_500), price500, "V3 swap survived the revert");
    }

    /// @notice Every leg is checked before any runs: a call whose last leg names a pool the caller
    /// never registered reverts `PoolNotAllowed` without opening an unlock or touching any pool
    function test_unregisteredLastLeg_nothingRuns() public {
        SwapCalldata.Leg[] memory mixed = _mixedBatch(0);
        SwapCalldata.Leg[] memory legs = new SwapCalldata.Leg[](4);
        for (uint256 i = 0; i < 3; i++) {
            legs[i] = mixed[i];
        }
        // The 1% USDC/WETH tier: never registered by the approver
        legs[3] = _v3In(USDC, WETH, 10000, tradeUsdc, 0);
        uint256[4] memory before = _approverHoldings();
        uint256 ethBefore = approver.balance;
        uint160 price500 = _price(USDC_WETH_500);
        bytes memory data = _swapData(legs);

        _expectUnlocks(0);
        _expectNoSwapOn(USDC_WETH_500);
        _expectNoSwapOn(USDC_WETH_3000);
        vm.prank(approver);
        vm.expectRevert(IProxyErrors.PoolNotAllowed.selector);
        proxy.swap(data);

        _assertApproverUntouched(before, "refused batch");
        assertEq(approver.balance, ethBefore, "ETH moved on a refused batch");
        assertEq(_price(USDC_WETH_500), price500, "a V3 pool was touched");
    }

    /// @notice A native-input leg inside a multi-leg call is paid from msg.value, and the unspent ETH
    /// comes back: the same as the legs made one by one
    /// @dev `swap` is payable, so native ETH no longer has to come from an earlier leg of the call.
    function test_nativeInputLegInABatch_isPaidFromMsgValue() public {
        SwapCalldata.Leg[] memory legs = new SwapCalldata.Leg[](2);
        legs[0] = _v4In(true, tradeWeth, 0); // ETH in, from msg.value
        legs[1] = _v3In(USDC, WETH, 500, tradeUsdc, 0); // USDC in, from the caller's balance

        uint256 snap = vm.snapshotState();
        uint256 a = _swapOne(approver, legs[0], tradeWeth);
        uint256 b = _swapOne(approver, legs[1], 0);
        uint256[4] memory expectedHoldings = _approverHoldings();
        uint256 expectedApproverEth = approver.balance;
        vm.revertToState(snap);

        uint256 ethBefore = approver.balance;
        bytes memory data = _swapData(legs);
        vm.prank(approver);
        uint256[] memory amounts = proxy.swap{value: uint256(tradeWeth) * 3}(data);

        assertEq(amounts[0], a, "native-input leg differs from the one-leg call");
        assertEq(amounts[1], b, "V3 leg differs from the one-leg call");
        uint256[4] memory holdings = _approverHoldings();
        for (uint256 i = 0; i < 4; i++) {
            assertEq(holdings[i], expectedHoldings[i], "approver balances differ from one-by-one");
        }
        assertEq(approver.balance, expectedApproverEth, "approver ETH differs from one-by-one");
        assertEq(approver.balance, ethBefore - tradeWeth, "the caller paid other than the leg's input");
        assertEq(address(proxy).balance, 0, "proxy retained ETH");
    }

    /// @notice The native-input legs of one call share its msg.value: together they can spend no more
    /// than it, whatever ETH the proxy holds
    /// @dev Each native-input leg is paid out of what is left of msg.value, never out of the proxy's
    /// balance. Two legs that each fit the value but together exceed it by one wei revert
    /// `NotEnoughEthSent`, although ETH force-fed to the proxy would cover the difference; with
    /// msg.value covering both, both run and the caller pays exactly their inputs.
    function test_nativeInputLegs_shareOneMsgValue() public {
        SwapCalldata.Leg[] memory legs = new SwapCalldata.Leg[](2);
        legs[0] = _v4In(true, tradeWeth, 0);
        legs[1] = _v4In(true, tradeWeth, 0);
        uint256 bothInputs = 2 * uint256(tradeWeth);
        vm.deal(address(proxy), 10 ether);
        uint256 forceFed = address(proxy).balance;
        uint256[4] memory before = _approverHoldings();
        uint256 ethBefore = approver.balance;
        bytes memory data = _swapData(legs);

        vm.prank(approver);
        vm.expectRevert(IProxyErrors.NotEnoughEthSent.selector);
        proxy.swap{value: bothInputs - 1}(data);

        _assertApproverUntouched(before, "native legs over msg.value");
        assertEq(approver.balance, ethBefore, "ETH moved on a refused call");
        assertEq(address(proxy).balance, forceFed, "force-fed ETH was spent");

        vm.prank(approver);
        uint256[] memory amounts = proxy.swap{value: bothInputs}(data);

        assertGt(amounts[1], 0, "the second native-input leg did not run");
        assertEq(IERC20(USDC).balanceOf(approver), before[0] + amounts[0] + amounts[1], "USDC output");
        assertEq(approver.balance, ethBefore - bothInputs, "the caller did not pay exactly both inputs");
        assertEq(address(proxy).balance, forceFed, "force-fed ETH was spent");
    }

    /// @notice An outsider's batch cannot spend the approver's allowance: without an approval of its
    /// own it fails at its own payment ("STF"), and with one it pays everything itself
    /// @dev The Authorisation suite's invariant, restated for multi-leg calls: every leg is paid by
    /// `msg.sender`, so a batch can never reach someone else's standing approval. The outsider has
    /// registered the same pools, so without an approval of its own only payment can stop it.
    function test_outsiderBatch_cannotSpendApproverAllowance() public {
        uint256[4] memory before = _approverHoldings();
        bytes memory data = _swapData(_mixedBatch(0));

        vm.prank(outsider);
        vm.expectRevert(bytes("STF"));
        proxy.swap(data);

        uint256 outsiderWethBefore = IERC20(WETH).balanceOf(outsider);
        uint256 outsiderUsdcBefore = IERC20(USDC).balanceOf(outsider);
        uint256 outsiderEthBefore = outsider.balance;
        vm.startPrank(outsider);
        IERC20(USDC).approve(address(proxy), type(uint256).max);
        IERC20(WETH).approve(address(proxy), type(uint256).max);
        uint256[] memory amounts = proxy.swap(data);
        vm.stopPrank();

        // Every output reached the outsider, every input came from it
        assertEq(IERC20(WETH).balanceOf(outsider) + tradeWeth, outsiderWethBefore + amounts[0], "outsider WETH");
        assertEq(outsider.balance, outsiderEthBefore + amounts[1], "outsider ETH");
        assertEq(IERC20(USDC).balanceOf(outsider) + 2 * tradeUsdc, outsiderUsdcBefore + amounts[2], "outsider USDC");
        _assertApproverUntouched(before, "outsider batch");
    }
}
