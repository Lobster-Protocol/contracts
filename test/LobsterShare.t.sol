// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.24;

import {Vm} from "forge-std/Vm.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {BatchSwapFixture} from "./helpers/BatchSwapFixture.sol";
import {SwapCalldata} from "./helpers/SwapCalldata.sol";
import {SwapFlags} from "../src/libraries/SwapFlags.sol";
import {TickMath} from "../src/libraries/uniswapV3/TickMath.sol";
import {MintParams} from "../src/interfaces/uniswapV3/IUniswapV3MintCallback.sol";
import {IUniswapV3FactoryMinimal} from "../src/interfaces/uniswapV3/IUniswapV3FactoryMinimal.sol";
import {IUniswapV3PoolMinimal} from "../src/interfaces/uniswapV3/IUniswapV3PoolMinimal.sol";
import {PoolKey as ProxyPoolKey, Currency as ProxyCurrency} from "../src/interfaces/uniswapV4/IPoolManagerMinimal.sol";
import {IProxyErrors} from "../src/interfaces/IProxyErrors.sol";

import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IERC20Minimal} from "v4-core/src/interfaces/external/IERC20Minimal.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/// @notice Stands in (through `vm.etch`) for a V3 pool that reports an output it never pays, which no pool
/// deployed by the canonical factory does: the only way to park more than a uint128 in a test.
contract OverReportingPool {
    int24 private immutable TICK;
    uint256 private immutable REPORTED;

    constructor(int24 tick, uint256 reported) {
        TICK = tick;
        REPORTED = reported;
    }

    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (2 ** 96, TICK, 0, 1, 1, 0, true);
    }

    function swap(
        address,
        bool zeroForOne,
        int256,
        uint160,
        bytes calldata
    )
        external
        view
        returns (int256 amount0, int256 amount1)
    {
        int256 out = -SafeCast.toInt256(REPORTED);
        return zeroForOne ? (int256(0), out) : (out, int256(0));
    }
}

/// @notice HELD | SHARE: one parked token feeding several pools from what the chain really produced.
/// Every pool is registered for the user (the vault).
/// @dev Each call is checked against two independent references:
/// - {_reference}: the same legs made as one-leg `swap` calls by the user, each given by hand the input
///   the rule says (`parked * share >> 128`, or all of it). Amounts and every balance must match to the wei.
/// - {_assertMoves}: a model of the proxy's ledger, which predicts every transfer of a token during the call
///   (who pays whom, how much, in what order). That is what shows the ledger is right, not only the final
///   balances: it fails if a V3 output waits in the wrong place, or if a leg pays from the wrong one.
///
/// Route graph: token0 is the sell token, token1 the token being split.
///   token0 --V3,V4--> token1 --V3,V4--> tokenC, tokenD
///   token1 --V4--> ETH --V4--> tokenC, tokenD
///   tokenC --V3,V4--> tokenD
contract LobsterShareTest is BatchSwapFixture {
    address constant ETH = address(0);
    /// @dev 50% and 60% as Q128: consumers at 50/30/20 are encoded as HALF, SIXTY, then plain HELD
    uint128 constant HALF = uint128(1) << 127;
    uint128 constant SIXTY = uint128((uint256(3) << 128) / 5);
    uint128 constant THIRD = uint128((uint256(1) << 128) / 3);
    uint128 constant MAX_SHARE = type(uint128).max;
    /// @dev keccak256("Transfer(address,address,uint256)")
    bytes32 constant TRANSFER = 0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef;

    /// @dev The longest order {test_everyOrder_matchesTheLedger} tries. Each extra leg costs 6 times more.
    uint256 constant DEFAULT_MAX_ORDER_LENGTH = 5;

    /// @dev What a call's legs did when made one by one, see {_reference}
    struct Reference {
        uint256[] amounts;
        uint256[] paid;
        uint256[] received;
        uint256[] balancesAfter;
        /// @dev The error the call must revert with, 0 if it must succeed
        bytes4 failure;
    }

    struct Move {
        address from;
        address to;
        uint256 amount;
    }

    MockERC20 public tokenC;
    MockERC20 public tokenD;
    ProxyPoolKey public keyC; // token1 / tokenC
    ProxyPoolKey public keyD; // token1 / tokenD
    ProxyPoolKey public keyCD; // tokenC / tokenD
    ProxyPoolKey public nativeKeyC; // ETH / tokenC
    ProxyPoolKey public nativeKeyD; // ETH / tokenD

    function setUp() public override {
        super.setUp();
        tokenC = _deployToken("Token C", "TKC");
        tokenD = _deployToken("Token D", "TKD");
        _listV3(address(token1), address(tokenC));
        _listV3(address(token1), address(tokenD));
        _listV3(address(tokenC), address(tokenD));
        keyC = _listV4(address(token1), address(tokenC), 0);
        keyD = _listV4(address(token1), address(tokenD), 0);
        keyCD = _listV4(address(tokenC), address(tokenD), 0);
        nativeKeyC = _listV4(ETH, address(tokenC), 10_000e18);
        nativeKeyD = _listV4(ETH, address(tokenD), 10_000e18);
    }

    // ---------------------------------------------------------------------------
    // Splits, spec by spec
    // ---------------------------------------------------------------------------

    /// @notice V3 only, parked in the proxy: the first pool receives exactly the computed share, the
    /// second exactly the rest, and nothing touches the PoolManager
    function test_v3Only_firstPoolReceivesExactlyTheShare() public {
        SwapCalldata.Leg[] memory legs =
            _legs(_park(_v3In01(1e18)), _shareOf(_v3Consumer(tokenC), HALF), _heldOf(_v3Consumer(tokenD)));
        Reference memory ref = _reference(legs);
        uint256 parked = ref.received[0];
        uint256 first = (parked * HALF) >> 128;
        uint256 poolCBefore = token1.balanceOf(_poolOf(legs[1]));
        uint256 poolDBefore = token1.balanceOf(_poolOf(legs[2]));

        vm.expectCall(address(manager), abi.encodeWithSelector(IPoolManager.unlock.selector), 0);
        _assertRun(legs, ref);

        assertEq(token1.balanceOf(_poolOf(legs[1])) - poolCBefore, first, "first pool: not exactly the share");
        assertEq(token1.balanceOf(_poolOf(legs[2])) - poolDBefore, parked - first, "second pool: not exactly the rest");
    }

    /// @notice First consumer V4: the V3 producer pays the PoolManager directly, the V4 leg spends part of
    /// that credit without any transfer, and the PoolManager pays the V3 pool the rest
    function test_firstConsumerV4_restGoesToV3() public {
        SwapCalldata.Leg[] memory legs =
            _legs(_park(_v3In01(1e18)), _shareOf(_v4Consumer(keyC, tokenC), HALF), _heldOf(_v3Consumer(tokenD)));
        Reference memory ref = _reference(legs);
        uint256 rest = ref.received[0] - ((ref.received[0] * HALF) >> 128);

        vm.expectCall(
            address(manager),
            abi.encodeCall(IPoolManager.take, (Currency.wrap(address(token1)), _poolOf(legs[2]), rest))
        );
        _assertRun(legs, ref);
        assertEq(ref.paid[2], rest, "the V3 pool did not get the rest");
    }

    /// @notice First consumer V4 on a parked V4 output: everything stays credit
    function test_v4Output_firstConsumerV4_restGoesToV3() public {
        SwapCalldata.Leg[] memory legs =
            _legs(_park(_v4In01(1e18)), _shareOf(_v4Consumer(keyC, tokenC), THIRD), _heldOf(_v3Consumer(tokenD)));
        _assertRun(legs, _reference(legs));
    }

    /// @notice First consumer V3, then a V4 leg gets the rest: the order does not change where the output
    /// waits. The V3 producer pays the PoolManager, which pays the V3 pool, and the rest is spent as credit
    /// with no transfer.
    function test_firstConsumerV3_restGoesToV4() public {
        SwapCalldata.Leg[] memory legs =
            _legs(_park(_v3In01(1e18)), _shareOf(_v3Consumer(tokenC), HALF), _heldOf(_v4Consumer(keyD, tokenD)));
        Reference memory ref = _reference(legs);
        uint256 first = (ref.received[0] * HALF) >> 128;

        vm.expectCall(
            address(manager),
            abi.encodeCall(IPoolManager.take, (Currency.wrap(address(token1)), _poolOf(legs[1]), first))
        );
        _assertRun(legs, ref);
        assertEq(ref.paid[1], first, "the V3 pool did not get the share");
    }

    /// @notice A V3 leg that stops early leaves what it did not spend in the proxy when no V4 leg was meant
    /// to get any, so the V4 leg after it pays the PoolManager from the proxy: the one way a proxy balance
    /// still reaches V4 at all
    function test_plainV3LegStoppingEarly_restInProxyGoesToV4() public {
        SwapCalldata.Leg[] memory legs =
            _legs(_park(_v3In01(1e18)), _heldOf(_v3Consumer(tokenC)), _heldOf(_v4Consumer(keyD, tokenD)));
        legs[1].sqrtPriceLimitX96 = _oneTickAway(address(token1), address(tokenC));
        Reference memory ref = _reference(legs);
        uint256 rest = ref.received[0] - ref.paid[1];
        assertGt(ref.paid[1], 0, "test bug: the V3 leg did not run");
        assertGt(rest, 0, "test bug: the V3 leg did not stop early");

        vm.expectCall(address(token1), abi.encodeCall(IERC20Minimal.transfer, (address(manager), rest)), 1);
        _assertRun(legs, ref);
    }

    /// @notice First consumer V3 on a parked V4 output: the PoolManager pays the V3 pool, the rest stays
    /// credit for the V4 leg
    function test_v4Output_firstConsumerV3_restGoesToV4() public {
        SwapCalldata.Leg[] memory legs =
            _legs(_park(_v4In01(1e18)), _shareOf(_v3Consumer(tokenC), HALF), _heldOf(_v4Consumer(keyD, tokenD)));
        _assertRun(legs, _reference(legs));
    }

    /// @notice Three consumers at 50/30/20, encoded as 50%, 60% of the rest, plain HELD, in every mix of
    /// versions: each pool gets 50, 30 and 20 percent of what was parked, the last one the rounding dust
    function test_threeConsumers_50_30_20_everyMixOfVersions() public {
        for (uint256 mix = 0; mix < 16; mix++) {
            uint256 snap = vm.snapshotState();
            SwapCalldata.Leg memory producer = mix & 1 != 0 ? _v4In01(9e18) : _v3In01(9e18);
            SwapCalldata.Leg memory c1 = mix & 2 != 0 ? _v4Consumer(keyC, tokenC) : _v3Consumer(tokenC);
            SwapCalldata.Leg memory c2 = mix & 4 != 0 ? _v4Consumer(keyD, tokenD) : _v3Consumer(tokenD);
            SwapCalldata.Leg memory c3 = mix & 8 != 0 ? _v4Consumer(nativeKey, ETH) : _v3Back();
            SwapCalldata.Leg[] memory legs = new SwapCalldata.Leg[](4);
            legs[0] = _park(producer);
            legs[1] = _shareOf(c1, HALF);
            legs[2] = _shareOf(c2, SIXTY);
            legs[3] = _heldOf(c3);

            Reference memory ref = _reference(legs);
            uint256 parked = ref.received[0];
            assertEq(ref.paid[1], parked / 2, "first consumer: not 50%");
            assertApproxEqAbs(ref.paid[2], (parked * 3) / 10, 2, "second consumer: not 30%");
            assertApproxEqAbs(ref.paid[3], parked / 5, 3, "third consumer: not 20%");
            assertEq(ref.paid[1] + ref.paid[2] + ref.paid[3], parked, "the consumers did not spend exactly the parked");
            _assertRun(legs, ref);
            vm.revertToStateAndDelete(snap);
        }
    }

    /// @notice A share is of what is parked when the leg runs, not of the original total: the same 50%
    /// twice spends 50% then 25%
    function test_shareIsOfWhatIsLeft_notOfTheTotal() public {
        SwapCalldata.Leg[] memory legs = _legs(
            _park(_v3In01(8e18)),
            _shareOf(_v3Consumer(tokenC), HALF),
            _shareOf(_v3Consumer(tokenD), HALF),
            _heldOf(_v4Consumer(keyC, tokenC))
        );
        Reference memory ref = _reference(legs);
        uint256 parked = ref.received[0];
        assertEq(ref.paid[1], parked / 2, "first");
        assertEq(ref.paid[2], (parked - parked / 2) / 2, "second: 50% of the rest, not of the total");
        _assertRun(legs, ref);
    }

    /// @notice Share legs can park their own outputs: a diamond across versions, whose branches merge. A V3
    /// SHARE leg then pays from credit (`take`) and settles its own output to the PoolManager in the same
    /// callback.
    function test_diamond_shareLegsPark_andMerge() public {
        SwapCalldata.Leg[] memory legs = new SwapCalldata.Leg[](5);
        legs[0] = _park(_v4In01(4e18)); // token1 as credit
        legs[1] = _park(_shareOf(_v3Consumer(tokenC), SIXTY)); // pays from credit; tokenC to the manager
        legs[2] = _park(_heldOf(_v3Consumer(tokenD))); // pays from credit; tokenD in the proxy
        legs[3] = _park(_heldOf(_v4Between(keyCD, tokenC, tokenD))); // spends tokenC, parks tokenD as credit
        legs[4] = _heldOf(_v3Between(tokenD, tokenC)); // merges tokenD from credit and proxy
        _assertRun(legs, _reference(legs));
    }

    /// @notice Native ETH can be split too, as credit: it never draws on msg.value, which comes back whole
    function test_nativeEth_split_leavesMsgValueAlone() public {
        SwapCalldata.Leg[] memory legs = _legs(
            _park(_v4Consumer(nativeKey, ETH)), // token1 -> ETH, parked
            _shareOf(_v4Between(nativeKeyC, ETH, tokenC), HALF),
            _heldOf(_v4Between(nativeKeyD, ETH, tokenD))
        );
        legs[0].held = false;
        legs[0].amount = 1e18;
        Reference memory ref = _reference(legs);
        uint256 ethBefore = user.balance;
        bytes memory data = _packed(legs);

        vm.prank(user);
        uint256[] memory amounts = proxy.swap{value: 5e18}(data);

        assertEq(amounts[1], ref.amounts[1], "first ETH consumer");
        assertEq(amounts[2], ref.amounts[2], "second ETH consumer");
        assertEq(user.balance, ethBefore, "ETH moved although it was only an intermediate");
        assertEq(address(proxy).balance, 0, "proxy retained ETH");
        _assertBalancesEq(_balances(), ref.balancesAfter, "native split");
    }

    // ---------------------------------------------------------------------------
    // The ledger, for every order
    // ---------------------------------------------------------------------------

    /// @notice Every order of up to DEFAULT_MAX_ORDER_LENGTH legs (or SHARE_MAX_ORDER_LENGTH from the
    /// environment) over one token, each leg being one of: V3 parks, V4 parks, V3 share, V4 share, V3 held,
    /// V4 held. So this includes every order in which a token is parked again after a partial spend, by any
    /// producer, for any consumer. A call must either revert as the model says (`NothingHeld` when a
    /// consumer finds nothing, `FundsLeftInProxy` when some is left), or do what the legs made one by one
    /// do, with exactly the transfers the ledger model predicts.
    function test_everyOrder_matchesTheLedger() public {
        vm.pauseGasMetering();
        uint256 maxLength = vm.envOr("SHARE_MAX_ORDER_LENGTH", DEFAULT_MAX_ORDER_LENGTH);
        uint256 orders;
        uint256 succeeded;
        for (uint256 length = 1; length <= maxLength; length++) {
            uint256 count = 6 ** length;
            for (uint256 code = 0; code < count; code++) {
                if (this.checkOrder(code, length)) succeeded++;
                orders++;
            }
        }
        assertEq(orders, (6 ** (maxLength + 1) - 6) / 5, "test bug: not every order was tried");
        assertEq(succeeded, _validOrders(maxLength), "the model and the count of valid orders disagree");
    }

    /// @dev How many orders of 1 to `maxLength` legs must succeed, counted without running anything. An order
    /// succeeds when no consumer finds nothing parked and nothing is parked at its end, and only two states
    /// matter: from "nothing parked" the 2 producers lead to "parked"; from "parked" the 2 producers and the 2
    /// shares (which always leave something) stay there, and the 2 plain HELD legs empty it.
    function _validOrders(uint256 maxLength) internal pure returns (uint256 total) {
        uint256 empty = 1;
        uint256 parked = 0;
        for (uint256 length = 1; length <= maxLength; length++) {
            (empty, parked) = (2 * parked, 2 * empty + 4 * parked);
            total += empty;
        }
    }

    /// @dev One order of {test_everyOrder_matchesTheLedger}, in its own frame so its memory does not
    /// accumulate. Leaves no trace. Returns whether the call succeeded.
    function checkOrder(uint256 code, uint256 length) external returns (bool succeeded) {
        SwapCalldata.Leg[] memory legs = new SwapCalldata.Leg[](length);
        for (uint256 i = 0; i < length; i++) {
            legs[i] = _orderLeg(code % 6);
            code /= 6;
        }
        uint256 snap = vm.snapshotState();
        Reference memory ref = _reference(legs);
        if (ref.failure == bytes4(0)) {
            _assertRun(legs, ref);
            succeeded = true;
        } else {
            _assertRefused(legs, ref.failure);
        }
        vm.revertToStateAndDelete(snap);
    }

    function _orderLeg(uint256 op) internal view returns (SwapCalldata.Leg memory) {
        if (op == 0) return _park(_v3In01(1e18));
        if (op == 1) return _park(_v4In01(1e18));
        if (op == 2) return _shareOf(_v3Consumer(tokenC), HALF);
        if (op == 3) return _shareOf(_v4Consumer(keyC, tokenC), THIRD);
        if (op == 4) return _heldOf(_v3Consumer(tokenC));
        return _heldOf(_v4Consumer(keyC, tokenC));
    }

    /// @notice A token parked again after a partial spend, the orders that used to be impossible, by name:
    /// outputs can wait in different places, and a HELD leg then spends the credit first and the proxy's
    /// balance after
    function test_parkedAgainAfterAPartialSpend() public {
        // A V3 share decides nothing, so a V4 leg later makes both V3 outputs credit
        SwapCalldata.Leg[] memory legs = _legs(
            _park(_v3In01(1e18)),
            _shareOf(_v3Consumer(tokenC), HALF),
            _park(_v3In01(1e18)),
            _shareOf(_v4Consumer(keyC, tokenC), HALF),
            _heldOf(_v3Consumer(tokenD))
        );
        uint256 snap = vm.snapshotState();
        _assertRun(legs, _reference(legs));
        vm.revertToStateAndDelete(snap);

        // A V4 share decides the first output, a later V4 leg the second: credit twice
        legs = _legs(
            _park(_v3In01(1e18)),
            _shareOf(_v4Consumer(keyC, tokenC), HALF),
            _park(_v3In01(1e18)),
            _shareOf(_v3Consumer(tokenC), HALF),
            _heldOf(_v4Consumer(keyD, tokenD))
        );
        snap = vm.snapshotState();
        _assertRun(legs, _reference(legs));
        vm.revertToStateAndDelete(snap);

        // Credit (spent by a V4 leg), then the proxy (spent by a plain V3 leg): both places at once
        legs = _legs(
            _park(_v3In01(1e18)),
            _shareOf(_v4Consumer(keyC, tokenC), HALF),
            _park(_v3In01(1e18)),
            _heldOf(_v3Consumer(tokenC))
        );
        snap = vm.snapshotState();
        _assertRun(legs, _reference(legs));
        vm.revertToStateAndDelete(snap);

        // Parked by V4 while the proxy still holds a V3 output
        legs = _legs(
            _park(_v3In01(1e18)),
            _shareOf(_v3Consumer(tokenC), HALF),
            _park(_v4In01(1e18)),
            _shareOf(_v3Consumer(tokenD), HALF),
            _heldOf(_v3Consumer(tokenC))
        );
        _assertRun(legs, _reference(legs));
    }

    // ---------------------------------------------------------------------------
    // Fuzz
    // ---------------------------------------------------------------------------

    /// @notice Random shares across 2 to 4 consumers on random versions and pools, with one or two random
    /// producers: the consumers spend exactly what was parked, the proxy ends with nothing, and everything
    /// matches the same swaps made one by one
    function testFuzz_randomShares_spendExactlyWhatWasParked(
        uint256 seed,
        uint128 amount,
        uint128 rawShare0,
        uint128 rawShare1,
        uint128 rawShare2
    )
        public
    {
        uint256 consumers = 2 + (seed % 3);
        bool twoProducers = (seed >> 8) & 1 != 0;
        uint256 producers = twoProducers ? 2 : 1;
        uint256 size = bound(amount, 1e6, 20e18);
        uint128[3] memory shares = [rawShare0, rawShare1, rawShare2];

        SwapCalldata.Leg[] memory legs = new SwapCalldata.Leg[](producers + consumers);
        legs[0] = _park((seed >> 16) & 1 != 0 ? _v4In01(size) : _v3In01(size));
        if (twoProducers) legs[1] = _park((seed >> 17) & 1 != 0 ? _v4In01(size) : _v3In01(size));
        for (uint256 i = 0; i < consumers; i++) {
            SwapCalldata.Leg memory consumer = _anyConsumer(uint256(keccak256(abi.encode(seed, i))));
            bool last = i == consumers - 1;
            // Half the runs use a usable range; the rest any uint128, down to shares that round to nothing
            uint128 share =
                (seed >> 24) & 1 != 0 ? shares[i < 3 ? i : 2] : uint128(bound(shares[i < 3 ? i : 2], 1e30, MAX_SHARE));
            if (share == 0) share = 1;
            legs[producers + i] = last ? _heldOf(consumer) : _shareOf(consumer, share);
        }

        Reference memory ref = _reference(legs);
        if (ref.failure != bytes4(0)) {
            // Only a share rounding to zero can fail here: a later share never finds nothing, since each
            // leaves at least 1 unit
            assertEq(ref.failure, IProxyErrors.NothingHeld.selector, "unexpected failure");
            _assertRefused(legs, ref.failure);
            return;
        }
        uint256 parked;
        uint256 spent;
        for (uint256 i = 0; i < producers; i++) {
            parked += ref.received[i];
        }
        for (uint256 i = producers; i < legs.length; i++) {
            spent += ref.paid[i];
        }
        assertEq(spent, parked, "the consumers did not spend exactly what was parked");
        _assertRun(legs, ref);
    }

    /// @notice A share below 1 never spends everything, whatever is parked, so rounding alone can never
    /// leave the last consumer with nothing
    function testFuzz_shareAlwaysLeavesSomething(uint128 parked, uint128 share) public pure {
        vm.assume(parked != 0);
        assertLt((uint256(parked) * share) >> 128, parked);
    }

    /// @notice The conversion ../aggregator-test uses (a Q192 share rounded up to Q128) makes a consumer
    /// spend exactly the planned amount when the chain delivers exactly the plan, and the next one the rest
    function testFuzz_q192ShareRoundedUp_spendsThePlannedAmount(uint96 planned, uint96 rest) public pure {
        vm.assume(planned != 0 && rest != 0);
        uint256 total = uint256(planned) + rest;
        uint256 q192 = Math.mulDiv(planned, uint256(1) << 192, total);
        uint256 q128 = (q192 + type(uint64).max) >> 64;
        assertLe(q128, type(uint128).max, "does not fit the share field");
        assertEq((total * q128) >> 128, planned, "spent other than the plan");
    }

    // ---------------------------------------------------------------------------
    // Reverts
    // ---------------------------------------------------------------------------

    /// @notice A share with no later leg spending the rest reverts, wherever the rest is waiting: in the
    /// proxy, as credit from a V3 pool, or as credit from a V4 swap. Even the largest share leaves 1 unit.
    function test_shareWithNoLaterLeg_revertsFundsLeftInProxy() public {
        _assertRefused(_legs(_park(_v3In01(1e18)), _shareOf(_v3Consumer(tokenC), HALF)), _fundsLeft());
        _assertRefused(_legs(_park(_v3In01(1e18)), _shareOf(_v4Consumer(keyC, tokenC), HALF)), _fundsLeft());
        _assertRefused(_legs(_park(_v4In01(1e18)), _shareOf(_v3Consumer(tokenC), HALF)), _fundsLeft());
        _assertRefused(_legs(_park(_v4In01(1e18)), _shareOf(_v4Consumer(keyC, tokenC), HALF)), _fundsLeft());
        _assertRefused(_legs(_park(_v3In01(1e18)), _shareOf(_v3Consumer(tokenC), MAX_SHARE)), _fundsLeft());
        _assertRefused(_legs(_park(_v4In01(1e18)), _shareOf(_v4Consumer(keyC, tokenC), MAX_SHARE)), _fundsLeft());
    }

    /// @notice share == 0 is `MalformedSwap`, before anything runs: on V3 and V4, with a price limit, with
    /// and without anything parked (a check made when the leg runs would see `NothingHeld` first)
    function test_shareOfZero_isMalformed_beforeAnythingRuns() public {
        SwapCalldata.Leg memory limited = _shareOf(_v3Consumer(tokenC), 0);
        limited.sqrtPriceLimitX96 = _oneTickAway(address(token1), address(tokenC));
        vm.expectCall(address(v3Pool), abi.encodeWithSelector(IUniswapV3PoolMinimal.swap.selector), 0);
        vm.expectCall(address(manager), abi.encodeWithSelector(IPoolManager.unlock.selector), 0);

        _assertMalformed(_legs(_park(_v3In01(1e18)), _shareOf(_v3Consumer(tokenC), 0), _heldOf(_v3Consumer(tokenD))));
        _assertMalformed(
            _legs(_park(_v3In01(1e18)), _shareOf(_v4Consumer(keyC, tokenC), 0), _heldOf(_v3Consumer(tokenD)))
        );
        _assertMalformed(_legs(_park(_v3In01(1e18)), limited, _heldOf(_v3Consumer(tokenD))));
        _assertMalformed(_legs(_shareOf(_v3Consumer(tokenC), 0)));
        _assertMalformed(_legs(_shareOf(_v4Consumer(keyC, tokenC), 0)));
    }

    /// @notice SHARE without HELD, and SHARE with EXACT_OUT with or without HELD, are `MalformedSwap`
    /// before anything runs
    function test_shareFlagMisuse_isMalformed_beforeAnythingRuns() public {
        SwapCalldata.Leg memory noHeld = _shareOf(_v3Consumer(tokenC), HALF);
        noHeld.held = false;
        SwapCalldata.Leg memory noHeldV4 = _shareOf(_v4Consumer(keyC, tokenC), HALF);
        noHeldV4.held = false;
        SwapCalldata.Leg memory exactOut = _shareOf(_v3Consumer(tokenC), HALF);
        exactOut.held = false;
        exactOut.exactOut = true;
        exactOut.bound = type(uint128).max;
        SwapCalldata.Leg memory heldExactOut = _shareOf(_v3Consumer(tokenC), HALF);
        heldExactOut.exactOut = true;
        heldExactOut.bound = type(uint128).max;
        vm.expectCall(address(v3Pool), abi.encodeWithSelector(IUniswapV3PoolMinimal.swap.selector), 0);

        _assertMalformed(_legs(_park(_v3In01(1e18)), noHeld, _heldOf(_v3Consumer(tokenD))));
        _assertMalformed(_legs(_park(_v3In01(1e18)), noHeldV4, _heldOf(_v3Consumer(tokenD))));
        _assertMalformed(_legs(_park(_v3In01(1e18)), exactOut, _heldOf(_v3Consumer(tokenD))));
        _assertMalformed(_legs(_park(_v3In01(1e18)), heldExactOut, _heldOf(_v3Consumer(tokenD))));
    }

    /// @notice The amount field is required with SHARE and refused without it: a HELD | SHARE leg laid out
    /// like a plain HELD one, or a plain HELD leg carrying a share, does not parse
    function test_shareField_mustMatchTheFlag() public {
        SwapCalldata.Leg[] memory good = _legs(_park(_v3In01(1e18)), _shareOf(_v3Consumer(tokenC), HALF));
        bytes memory data = _packed(good);

        // Drop the 16-byte share: the last leg no longer fits
        bytes memory truncated = new bytes(data.length - 16);
        for (uint256 i = 0; i < truncated.length; i++) {
            truncated[i] = data[i];
        }
        vm.prank(user);
        vm.expectRevert(IProxyErrors.MalformedSwap.selector);
        proxy.swap(truncated);

        // Clear SHARE from the flags byte: 16 bytes are left over, too few for another leg
        bytes memory noFlag = bytes.concat(data);
        uint256 flagsAt = data.length - 38;
        assertEq(uint8(noFlag[flagsAt]), SwapFlags.HELD | SwapFlags.SHARE, "test bug: not the flags byte");
        noFlag[flagsAt] = bytes1(SwapFlags.HELD);
        vm.prank(user);
        vm.expectRevert(IProxyErrors.MalformedSwap.selector);
        proxy.swap(noFlag);
    }

    /// @notice A share so small the input rounds to 0 reverts `NothingHeld`; the smallest that does not,
    /// spends 1 unit
    function test_shareRoundingToZero_revertsNothingHeld() public {
        uint256 parked = _reference(_legs(_v3In01(1e18))).received[0];
        uint128 tooSmall = SafeCast.toUint128((uint256(1) << 128) / parked - 1);
        uint128 smallest = SafeCast.toUint128((uint256(1) << 128) / parked + 1);
        assertEq((parked * tooSmall) >> 128, 0, "test bug: rounds to something");
        assertEq((parked * smallest) >> 128, 1, "test bug: not exactly 1 unit");

        _assertRefused(
            _legs(_park(_v3In01(1e18)), _shareOf(_v3Consumer(tokenC), 1), _heldOf(_v3Consumer(tokenD))),
            IProxyErrors.NothingHeld.selector
        );
        _assertRefused(
            _legs(_park(_v3In01(1e18)), _shareOf(_v3Consumer(tokenC), tooSmall), _heldOf(_v3Consumer(tokenD))),
            IProxyErrors.NothingHeld.selector
        );
        _assertRefused(
            _legs(_park(_v3In01(1e18)), _shareOf(_v4Consumer(keyC, tokenC), tooSmall), _heldOf(_v3Consumer(tokenD))),
            IProxyErrors.NothingHeld.selector
        );

        SwapCalldata.Leg[] memory legs =
            _legs(_park(_v3In01(1e18)), _shareOf(_v3Consumer(tokenC), smallest), _heldOf(_v3Consumer(tokenD)));
        Reference memory ref = _reference(legs);
        assertEq(ref.paid[1], 1, "the smallest usable share should spend 1 unit");
        _assertRun(legs, ref);
    }

    /// @notice A valid share with nothing parked reverts `NothingHeld`, like plain HELD
    function test_shareWithNothingParked_revertsNothingHeld() public {
        _assertRefused(_legs(_shareOf(_v3Consumer(tokenC), HALF)), IProxyErrors.NothingHeld.selector);
        _assertRefused(_legs(_shareOf(_v4Consumer(keyC, tokenC), HALF)), IProxyErrors.NothingHeld.selector);
        // Parked under another token: nothing of this one
        _assertRefused(
            _legs(_park(_v3Between(tokenC, tokenD)), _shareOf(_v3Consumer(tokenC), HALF)),
            IProxyErrors.NothingHeld.selector
        );
    }

    // ---------------------------------------------------------------------------
    // HELD | SHARE | PRICE_LIMIT
    // ---------------------------------------------------------------------------

    /// @notice V3, fields in the order share, bound, limit: the pool is called with the computed share and
    /// the limit, and the bound is what the output is checked against
    function test_shareWithLimit_v3_parsesShareBoundAndLimit() public {
        uint160 limit = _farLimit(address(token1), address(tokenC));
        SwapCalldata.Leg memory leg = _shareOf(_v3Consumer(tokenC), HALF);
        leg.sqrtPriceLimitX96 = limit;
        SwapCalldata.Leg[] memory legs = _legs(_park(_v3In01(1e18)), leg, _heldOf(_v3Consumer(tokenD)));
        Reference memory ref = _reference(legs);
        uint256 input = (ref.received[0] * HALF) >> 128;
        assertEq(ref.paid[1], input, "premise: the far limit does not stop this leg");

        // The size: 6 head + 16 share + 16 bound + 20 limit
        assertEq(SwapCalldata.encodeLeg(leg, 0, 1).length, 58, "layout");

        // The bound, exactly met, then missed by 1
        uint256 snap = vm.snapshotState();
        legs[1].bound = _u128(ref.received[1] + 1);
        _assertRefused(legs, IProxyErrors.TooLittleReceived.selector);
        vm.revertToStateAndDelete(snap);
        legs[1].bound = _u128(ref.received[1]);

        vm.expectCall(
            _poolOf(legs[1]),
            abi.encodeWithSelector(
                IUniswapV3PoolMinimal.swap.selector,
                user,
                address(token1) < address(tokenC),
                SafeCast.toInt256(input),
                limit
            ),
            1
        );
        _assertRun(legs, ref);
    }

    /// @notice V4, fields in the order share, bound, limit, after the tick spacing
    function test_shareWithLimit_v4_parsesShareBoundAndLimit() public {
        uint160 limit = _farLimit(address(token1), address(tokenC));
        SwapCalldata.Leg memory leg = _shareOf(_v4Consumer(keyC, tokenC), HALF);
        leg.sqrtPriceLimitX96 = limit;
        SwapCalldata.Leg[] memory legs = _legs(_park(_v4In01(1e18)), leg, _heldOf(_v3Consumer(tokenD)));
        Reference memory ref = _reference(legs);
        uint256 input = (ref.received[0] * HALF) >> 128;
        assertEq(ref.paid[1], input, "premise: the far limit does not stop this leg");

        // The size: 6 head + 3 tick spacing + 16 share + 16 bound + 20 limit, the largest leg
        assertEq(SwapCalldata.encodeLeg(leg, 0, 1).length, 61, "layout");

        uint256 snap = vm.snapshotState();
        legs[1].bound = _u128(ref.received[1] + 1);
        _assertRefused(legs, IProxyErrors.TooLittleReceived.selector);
        vm.revertToStateAndDelete(snap);
        legs[1].bound = _u128(ref.received[1]);

        vm.expectCall(
            address(manager),
            abi.encodeCall(
                IPoolManager.swap,
                (
                    _toV4CoreKey(keyC),
                    IPoolManager.SwapParams({
                        zeroForOne: address(token1) < address(tokenC),
                        amountSpecified: -SafeCast.toInt256(input),
                        sqrtPriceLimitX96: limit
                    }),
                    ""
                )
            ),
            1
        );
        _assertRun(legs, ref);
    }

    /// @notice A PRICE_LIMIT of 0 is refused on a share leg too (the limit field must be read at its own
    /// position, which the share moved)
    function test_shareWithZeroLimit_isMalformed() public {
        bytes memory good = _packed(_legs(_park(_v3In01(1e18)), _withLimit(_shareOf(_v3Consumer(tokenC), HALF))));
        bytes memory zeroLimit = bytes.concat(good);
        for (uint256 i = good.length - 20; i < good.length; i++) {
            zeroLimit[i] = 0;
        }
        vm.prank(user);
        vm.expectRevert(IProxyErrors.MalformedSwap.selector);
        proxy.swap(zeroLimit);
    }

    /// @notice A share leg that stops at its limit spends less than its share, and what it did not spend
    /// stays parked for the next leg, on every pairing of versions
    function test_partialFill_restGoesToTheNextLeg() public {
        for (uint256 mix = 0; mix < 8; mix++) {
            uint256 snap = vm.snapshotState();
            SwapCalldata.Leg memory producer = mix & 1 != 0 ? _v4In01(2e18) : _v3In01(2e18);
            SwapCalldata.Leg memory partialLeg =
                _shareOf(mix & 2 != 0 ? _v4Consumer(keyC, tokenC) : _v3Consumer(tokenC), HALF);
            partialLeg.sqrtPriceLimitX96 = _oneTickAway(address(token1), address(tokenC));
            SwapCalldata.Leg memory last = _heldOf(mix & 4 != 0 ? _v4Consumer(keyD, tokenD) : _v3Consumer(tokenD));
            SwapCalldata.Leg[] memory legs = _legs(_park(producer), partialLeg, last);

            Reference memory ref = _reference(legs);
            uint256 parked = ref.received[0];
            assertGt(ref.paid[1], 0, "premise: the limit lets something through");
            assertLt(ref.paid[1], (parked * HALF) >> 128, "premise: the limit stops the leg short of its share");
            assertEq(ref.paid[2], parked - ref.paid[1], "the next leg did not spend what the partial fill left");
            _assertRun(legs, ref);
            vm.revertToStateAndDelete(snap);
        }
    }

    /// @notice After a partial fill, a later share is of what is really left, which is more than planned
    function test_partialFill_laterShareAppliesToWhatIsLeft() public {
        SwapCalldata.Leg memory partialLeg = _shareOf(_v3Consumer(tokenC), HALF);
        partialLeg.sqrtPriceLimitX96 = _oneTickAway(address(token1), address(tokenC));
        SwapCalldata.Leg[] memory legs = _legs(
            _park(_v4In01(2e18)), partialLeg, _shareOf(_v4Consumer(keyD, tokenD), HALF), _heldOf(_v3Consumer(tokenD))
        );
        Reference memory ref = _reference(legs);
        uint256 parked = ref.received[0];
        uint256 left = parked - ref.paid[1];
        assertGt(left, parked - ((parked * HALF) >> 128), "premise: the first leg was only partly filled");
        assertEq(ref.paid[2], (left * HALF) >> 128, "the share was not of what is left");
        _assertRun(legs, ref);
    }

    /// @notice A partial fill with no later leg to spend the rest, on the last consumer: `FundsLeftInProxy`
    function test_partialFill_ofTheLastConsumer_revertsFundsLeftInProxy() public {
        SwapCalldata.Leg memory stops = _heldOf(_v3Consumer(tokenD));
        stops.sqrtPriceLimitX96 = _oneTickAway(address(token1), address(tokenD));
        _assertRefused(_legs(_park(_v3In01(2e18)), _shareOf(_v3Consumer(tokenC), HALF), stops), _fundsLeft());
    }

    // ---------------------------------------------------------------------------
    // The other rules still hold on a share leg
    // ---------------------------------------------------------------------------

    /// @notice Tokens sent to the proxy outside a call belong to no one: they are not part of what a share
    /// is taken from, and stay where they are
    function test_strayTokens_areNotInTheShareBase() public {
        SwapCalldata.Leg[] memory legs =
            _legs(_park(_v3In01(1e18)), _shareOf(_v3Consumer(tokenC), HALF), _heldOf(_v4Consumer(keyD, tokenD)));
        Reference memory ref = _reference(legs);
        deal(address(token1), address(proxy), 5e18);
        bytes memory data = _packed(legs);

        vm.prank(user);
        uint256[] memory amounts = proxy.swap(data);

        assertEq(amounts[1], ref.amounts[1], "the stray tokens changed the share");
        assertEq(amounts[2], ref.amounts[2], "the stray tokens changed the rest");
        assertEq(token1.balanceOf(address(proxy)), 5e18, "the stray tokens were spent");
    }

    /// @notice The band is checked on a share leg like on any other
    function test_shareLeg_leavingItsBand_reverts() public {
        address pool = IUniswapV3FactoryMinimal(v3Factory).getPool(address(token1), address(tokenC), FEE);
        bytes32 key = proxy.v3Key(pool);
        vm.prank(user);
        proxy.setPriceBand(key, -1, 1);
        _assertRefused(
            _legs(_park(_v3In01(5e18)), _shareOf(_v3Consumer(tokenC), HALF), _heldOf(_v3Consumer(tokenD))),
            IProxyErrors.PriceOutOfBand.selector
        );
    }

    /// @notice A share leg on a pool the caller did not register is refused before anything runs
    function test_shareLeg_unregisteredPool_nothingRuns() public {
        address pool = IUniswapV3FactoryMinimal(v3Factory).getPool(address(token1), address(tokenC), FEE);
        bytes32[] memory keys = new bytes32[](1);
        keys[0] = proxy.v3Key(pool);
        uint8[] memory perms = new uint8[](1);
        vm.prank(user);
        proxy.setPools(keys, perms);

        vm.expectCall(address(v3Pool), abi.encodeWithSelector(IUniswapV3PoolMinimal.swap.selector), 0);
        _assertRefused(
            _legs(_park(_v3In01(1e18)), _shareOf(_v3Consumer(tokenC), HALF), _heldOf(_v3Consumer(tokenD))),
            IProxyErrors.PoolNotAllowed.selector
        );
    }

    // ---------------------------------------------------------------------------
    // The format
    // ---------------------------------------------------------------------------

    /// @notice Byte for byte the layout ../aggregator-test pins in `encoding_matches_the_packed_layout`, so
    /// the two encoders cannot drift apart unnoticed
    function test_layout_matchesTheRustHarness() public pure {
        address a = address(0xaa);
        address b = address(0xbb);
        address c = address(0xcc);
        SwapCalldata.Leg[] memory legs = new SwapCalldata.Leg[](3);
        legs[0].tokenIn = a;
        legs[0].tokenOut = b;
        legs[0].fee = 3000;
        legs[0].amount = 0x10;
        legs[0].park = true;
        legs[1].tokenIn = b;
        legs[1].tokenOut = c;
        legs[1].fee = 500;
        legs[1].held = true;
        legs[1].share = true;
        legs[1].amount = 0x20;
        legs[2].tokenIn = b;
        legs[2].tokenOut = a;
        legs[2].fee = 100;
        legs[2].held = true;

        assertEq(
            SwapCalldata.encode(0x01020304, legs),
            bytes.concat(
                hex"01020304" hex"03",
                hex"00000000000000000000000000000000000000aa",
                hex"00000000000000000000000000000000000000bb",
                hex"00000000000000000000000000000000000000cc",
                // PARK, fixed amount
                hex"04" hex"00" hex"01" hex"000bb8" hex"00000000000000000000000000000010"
                hex"00000000000000000000000000000000",
                // HELD | SHARE, the share in the amount slot
                hex"28" hex"01" hex"02" hex"0001f4" hex"00000000000000000000000000000020"
                hex"00000000000000000000000000000000",
                // HELD, no amount
                hex"08" hex"01" hex"00" hex"000064" hex"00000000000000000000000000000000"
            )
        );
    }

    /// @notice The flag's value and ALL, which the off-chain encoders hard-code
    function test_flagValues() public pure {
        assertEq(uint256(SwapFlags.SHARE), 0x20);
        assertEq(uint256(SwapFlags.ALL), 0x3f);
    }

    /// @notice What a HELD leg finds parked must fit in uint128 before any share is applied: the share's
    /// multiplication is unchecked and relies on it. Reported at 2**200, the product would wrap and spend
    /// a wrong amount; at 2**128, one above the ceiling, it would not wrap but must still be refused.
    function test_parkedAboveUint128_isMalformed() public {
        uint256[2] memory reported = [uint256(1) << 200, uint256(1) << 128];
        for (uint256 i = 0; i < reported.length; i++) {
            SwapCalldata.Leg[] memory withShare =
                _legs(_park(_v3In01(1e18)), _shareOf(_v3Consumer(tokenC), HALF), _heldOf(_v3Consumer(tokenD)));
            SwapCalldata.Leg[] memory plain = _legs(_park(_v3In01(1e18)), _heldOf(_v3Consumer(tokenC)));
            uint256 snap = vm.snapshotState();
            address pool = _poolOf(withShare[0]);
            (, int24 tick,,,,,) = IUniswapV3PoolMinimal(pool).slot0();
            vm.etch(pool, address(new OverReportingPool(tick, reported[i])).code);

            _assertMalformed(withShare);
            _assertMalformed(plain);
            vm.revertToStateAndDelete(snap);
        }
    }

    /// @notice The largest amount that fits, at the largest share: the product does not wrap. Only the
    /// ledger is exercised, since the fake pool never pays: the next leg's own pool then refuses the input.
    function test_parkedAtUint128Max_withTheLargestShare_doesNotWrap() public {
        SwapCalldata.Leg[] memory legs = _legs(_park(_v3In01(1e18)), _shareOf(_v3Consumer(tokenC), type(uint128).max));
        address pool = _poolOf(legs[0]);
        (, int24 tick,,,,,) = IUniswapV3PoolMinimal(pool).slot0();
        vm.etch(pool, address(new OverReportingPool(tick, type(uint128).max)).code);

        // The input is uint128.max - 1, far past what the real pool can take but no MalformedSwap
        vm.prank(user);
        (bool ok, bytes memory ret) = address(proxy).call(abi.encodeCall(proxy.swap, (_packed(legs))));
        assertFalse(ok, "the proxy holds nothing to pay this with");
        assertTrue(bytes4(ret) != IProxyErrors.MalformedSwap.selector, "an amount that fits was refused");
        assertTrue(bytes4(ret) != IProxyErrors.NothingHeld.selector, "the product wrapped");
    }

    /// @notice The bitmap the proxy checks flags against says exactly what the written rules say, for every
    /// value of the flags byte
    function test_validFlags_bitmapMatchesTheRules() public pure {
        uint256 heldExactOut = SwapFlags.HELD | SwapFlags.EXACT_OUT;
        for (uint256 flags = 0; flags < 256; flags++) {
            bool valid = flags & ~uint256(SwapFlags.ALL) == 0 && flags & heldExactOut != heldExactOut
                && (flags & SwapFlags.SHARE == 0 || flags & SwapFlags.HELD != 0);
            assertEq((SwapFlags.VALID >> flags) & 1 != 0, valid, vm.toString(flags));
        }
    }

    // ---------------------------------------------------------------------------
    // Helpers: setup
    // ---------------------------------------------------------------------------

    function _deployToken(string memory name, string memory symbol) internal returns (MockERC20 token) {
        token = new MockERC20(name, symbol, 18);
        token.mint(address(this), 100_000e18);
        token.approve(address(proxy), type(uint256).max);
        token.approve(address(lpRouter), type(uint256).max);
        token.mint(user, 10_000e18);
        vm.prank(user);
        token.approve(address(proxy), type(uint256).max);
    }

    /// @dev A 1:1 V3 pool with wide liquidity, registered for the user
    function _listV3(address a, address b) internal {
        (address t0, address t1) = a < b ? (a, b) : (b, a);
        address pool = IUniswapV3FactoryMinimal(v3Factory).createPool(t0, t1, FEE);
        IUniswapV3PoolMinimal(pool).initialize(SQRT_PRICE_1_1);
        _allow(address(this), proxy.v3Key(pool), MINT);
        proxy.mint(
            MintParams({
                token0: t0,
                token1: t1,
                fee: FEE,
                tickLower: -TICK_RANGE,
                tickUpper: TICK_RANGE,
                amount0Desired: 1000e18,
                amount1Desired: 1000e18,
                amount0Min: 0,
                amount1Min: 0,
                recipient: address(this),
                deadline: vm.getBlockTimestamp()
            })
        );
        _allow(user, proxy.v3Key(pool), SWAP);
    }

    /// @dev A 1:1 hookless V4 pool with wide liquidity, registered for the user
    function _listV4(address a, address b, uint256 value) internal returns (ProxyPoolKey memory key) {
        (address c0, address c1) = a < b ? (a, b) : (b, a);
        PoolKey memory core = _v4CoreKey(c0, c1);
        manager.initialize(core, SQRT_PRICE_1_1);
        _addV4Liquidity(core, value);
        key = _toProxyKey(core);
        _allow(user, proxy.v4Key(key), SWAP);
    }

    function _toV4CoreKey(ProxyPoolKey memory key) internal pure returns (PoolKey memory) {
        return _v4CoreKey(ProxyCurrency.unwrap(key.currency0), ProxyCurrency.unwrap(key.currency1));
    }

    // ---------------------------------------------------------------------------
    // Helpers: legs
    // ---------------------------------------------------------------------------

    function _v3In01(uint256 amount) internal view returns (SwapCalldata.Leg memory) {
        return _v3In(address(token0), address(token1), amount, 0);
    }

    function _v4In01(uint256 amount) internal view returns (SwapCalldata.Leg memory) {
        return _v4In(cleanKey, address(token0) < address(token1), _u128(amount), 0);
    }

    /// @dev token1 -> token on V3
    function _v3Consumer(MockERC20 token) internal view returns (SwapCalldata.Leg memory) {
        return _v3In(address(token1), address(token), 0, 0);
    }

    /// @dev token1 -> token0 on V3, the pool the V3 producer used
    function _v3Back() internal view returns (SwapCalldata.Leg memory) {
        return _v3In(address(token1), address(token0), 0, 0);
    }

    function _v3Between(MockERC20 tokenIn, MockERC20 tokenOut) internal pure returns (SwapCalldata.Leg memory leg) {
        leg = _v3In(address(tokenIn), address(tokenOut), 1e18, 0);
    }

    /// @dev token1 -> `token` on the V4 pool `key`
    function _v4Consumer(ProxyPoolKey memory key, address token) internal view returns (SwapCalldata.Leg memory) {
        return _v4In(key, address(token1) < token, 0, 0);
    }

    function _v4Consumer(ProxyPoolKey memory key, MockERC20 token) internal view returns (SwapCalldata.Leg memory) {
        return _v4Consumer(key, address(token));
    }

    function _v4Between(
        ProxyPoolKey memory key,
        MockERC20 tokenIn,
        MockERC20 tokenOut
    )
        internal
        pure
        returns (SwapCalldata.Leg memory)
    {
        return _v4In(key, address(tokenIn) < address(tokenOut), 0, 0);
    }

    function _v4Between(
        ProxyPoolKey memory key,
        address tokenIn,
        MockERC20 tokenOut
    )
        internal
        pure
        returns (SwapCalldata.Leg memory)
    {
        return _v4In(key, tokenIn < address(tokenOut), 0, 0);
    }

    /// @dev A consumer of token1 on one of five pools
    function _anyConsumer(uint256 r) internal view returns (SwapCalldata.Leg memory) {
        uint256 pick = r % 5;
        if (pick == 0) return _v3Consumer(tokenC);
        if (pick == 1) return _v3Consumer(tokenD);
        if (pick == 2) return _v4Consumer(keyC, tokenC);
        if (pick == 3) return _v4Consumer(keyD, tokenD);
        return _v4Consumer(nativeKey, ETH);
    }

    function _park(SwapCalldata.Leg memory leg) internal pure returns (SwapCalldata.Leg memory) {
        leg.park = true;
        return leg;
    }

    function _heldOf(SwapCalldata.Leg memory leg) internal pure returns (SwapCalldata.Leg memory) {
        leg.held = true;
        leg.amount = 0;
        return leg;
    }

    function _shareOf(SwapCalldata.Leg memory leg, uint128 share) internal pure returns (SwapCalldata.Leg memory) {
        leg.held = true;
        leg.share = true;
        leg.amount = share;
        return leg;
    }

    function _withLimit(SwapCalldata.Leg memory leg) internal pure returns (SwapCalldata.Leg memory) {
        leg.sqrtPriceLimitX96 = _farLimit(leg.tokenIn, leg.tokenOut);
        return leg;
    }

    /// @dev One tick from 1:1 in the leg's direction: a pool at price 1 stops there after a small part of
    /// any input of a token or more
    function _oneTickAway(address tokenIn, address tokenOut) internal pure returns (uint160) {
        return TickMath.getSqrtRatioAtTick(tokenIn < tokenOut ? int24(-1) : int24(1));
    }

    /// @dev 3000 ticks from 1:1 in the leg's direction: a limit these sizes never reach
    function _farLimit(address tokenIn, address tokenOut) internal pure returns (uint160) {
        return TickMath.getSqrtRatioAtTick(tokenIn < tokenOut ? int24(-3000) : int24(3000));
    }

    function _legs(
        SwapCalldata.Leg memory a,
        SwapCalldata.Leg memory b,
        SwapCalldata.Leg memory c
    )
        internal
        pure
        returns (SwapCalldata.Leg[] memory legs)
    {
        legs = new SwapCalldata.Leg[](3);
        legs[0] = a;
        legs[1] = b;
        legs[2] = c;
    }

    function _legs(SwapCalldata.Leg memory a) internal pure returns (SwapCalldata.Leg[] memory legs) {
        legs = new SwapCalldata.Leg[](1);
        legs[0] = a;
    }

    function _legs(
        SwapCalldata.Leg memory a,
        SwapCalldata.Leg memory b
    )
        internal
        pure
        returns (SwapCalldata.Leg[] memory legs)
    {
        legs = new SwapCalldata.Leg[](2);
        legs[0] = a;
        legs[1] = b;
    }

    function _legs(
        SwapCalldata.Leg memory a,
        SwapCalldata.Leg memory b,
        SwapCalldata.Leg memory c,
        SwapCalldata.Leg memory d
    )
        internal
        pure
        returns (SwapCalldata.Leg[] memory legs)
    {
        legs = new SwapCalldata.Leg[](4);
        legs[0] = a;
        legs[1] = b;
        legs[2] = c;
        legs[3] = d;
    }

    function _legs(
        SwapCalldata.Leg memory a,
        SwapCalldata.Leg memory b,
        SwapCalldata.Leg memory c,
        SwapCalldata.Leg memory d,
        SwapCalldata.Leg memory e
    )
        internal
        pure
        returns (SwapCalldata.Leg[] memory legs)
    {
        legs = new SwapCalldata.Leg[](5);
        legs[0] = a;
        legs[1] = b;
        legs[2] = c;
        legs[3] = d;
        legs[4] = e;
    }

    function _packed(SwapCalldata.Leg[] memory legs) internal view returns (bytes memory) {
        return SwapCalldata.encode(vm.getBlockTimestamp(), legs);
    }

    function _poolOf(SwapCalldata.Leg memory leg) internal view returns (address) {
        return IUniswapV3FactoryMinimal(v3Factory).getPool(leg.tokenIn, leg.tokenOut, leg.fee);
    }

    function _fundsLeft() internal pure returns (bytes4) {
        return IProxyErrors.FundsLeftInProxy.selector;
    }

    // ---------------------------------------------------------------------------
    // Helpers: the references
    // ---------------------------------------------------------------------------

    function _assets() internal view returns (address[5] memory) {
        return [address(token0), address(token1), address(tokenC), address(tokenD), ETH];
    }

    function _assetIndex(address token) internal view returns (uint256) {
        address[5] memory assets = _assets();
        for (uint256 i = 0; i < 5; i++) {
            if (assets[i] == token) return i;
        }
        revert("unknown token");
    }

    function _balanceOf(address token, address who) internal view returns (uint256) {
        return token == ETH ? who.balance : MockERC20(token).balanceOf(who);
    }

    /// @dev Everything a call could move: every asset of the user, the PoolManager and the proxy. A pool's
    /// side is what those three lose or gain, and the amounts already pin it per leg.
    function _balances() internal view returns (uint256[] memory b) {
        address[3] memory holders = [user, address(manager), address(proxy)];
        address[5] memory assets = _assets();
        b = new uint256[](15);
        for (uint256 h = 0; h < 3; h++) {
            for (uint256 a = 0; a < 5; a++) {
                b[5 * h + a] = _balanceOf(assets[a], holders[h]);
            }
        }
    }

    function _assertBalancesEq(uint256[] memory actual, uint256[] memory expected, string memory ctx) internal pure {
        string[3] memory holders = ["user", "PoolManager", "proxy"];
        string[5] memory assets = ["token0", "token1", "tokenC", "tokenD", "ETH"];
        for (uint256 i = 0; i < expected.length; i++) {
            assertEq(actual[i], expected[i], string.concat(ctx, ": ", holders[i / 5], " ", assets[i % 5]));
        }
    }

    /// @dev Each leg as a one-leg `swap` by the user, delivering to the user. A HELD leg gets by hand the
    /// input the rule says: what earlier legs parked and later ones have not spent, times its share. If the
    /// rule says the call must fail, `failure` says how, and the legs after that one do not run. Rewinds.
    function _reference(SwapCalldata.Leg[] memory legs) internal returns (Reference memory ref) {
        uint256 snap = vm.snapshotState();
        uint256[5] memory parked;
        ref.amounts = new uint256[](legs.length);
        ref.paid = new uint256[](legs.length);
        ref.received = new uint256[](legs.length);
        for (uint256 i = 0; i < legs.length; i++) {
            SwapCalldata.Leg memory one = abi.decode(abi.encode(legs[i]), (SwapCalldata.Leg));
            one.park = false;
            one.held = false;
            one.share = false;
            if (legs[i].held) {
                uint256 input = parked[_assetIndex(one.tokenIn)];
                if (legs[i].share) input = (input * legs[i].amount) >> 128;
                if (input == 0) {
                    ref.failure = IProxyErrors.NothingHeld.selector;
                    break;
                }
                one.amount = _u128(input);
            }
            uint256 value = one.tokenIn == ETH ? one.amount : 0;
            uint256 inBefore = _balanceOf(one.tokenIn, user);
            uint256 outBefore = _balanceOf(one.tokenOut, user);
            bytes memory data = _packed(_legs(one));
            vm.prank(user);
            ref.amounts[i] = proxy.swap{value: value}(data)[0];
            ref.paid[i] = inBefore - _balanceOf(one.tokenIn, user);
            ref.received[i] = _balanceOf(one.tokenOut, user) - outBefore;
            if (legs[i].held) parked[_assetIndex(one.tokenIn)] -= ref.paid[i];
            if (legs[i].park) parked[_assetIndex(one.tokenOut)] += ref.received[i];
        }
        if (ref.failure == bytes4(0)) {
            for (uint256 t = 0; t < 5; t++) {
                if (parked[t] != 0) ref.failure = IProxyErrors.FundsLeftInProxy.selector;
            }
        }
        ref.balancesAfter = _balances();
        vm.revertToStateAndDelete(snap);
    }

    /// @dev Runs `legs` as one call by the user. It must succeed, match `ref` leg by leg and balance by
    /// balance, make exactly the transfers the ledger model predicts, and leave the proxy holding nothing.
    function _assertRun(SwapCalldata.Leg[] memory legs, Reference memory ref) internal {
        assertEq(ref.failure, bytes4(0), "test bug: the reference says this call must fail");
        bytes memory data = _packed(legs);
        vm.recordLogs();
        vm.prank(user);
        uint256[] memory amounts = proxy.swap(data);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(amounts.length, legs.length, "one amount per leg");
        for (uint256 i = 0; i < legs.length; i++) {
            assertEq(
                amounts[i], ref.amounts[i], string.concat("leg ", vm.toString(i), " differs from the one-leg call")
            );
        }
        _assertBalancesEq(_balances(), ref.balancesAfter, "call vs one-leg calls");
        _assertMoves(legs, ref, logs, address(token1));
        _assertMoves(legs, ref, logs, address(tokenC));
        _assertMoves(legs, ref, logs, address(tokenD));
        assertEq(token1.balanceOf(address(proxy)), 0, "proxy retained token1");
        assertEq(tokenC.balanceOf(address(proxy)), 0, "proxy retained tokenC");
        assertEq(tokenD.balanceOf(address(proxy)), 0, "proxy retained tokenD");
        assertEq(address(proxy).balance, 0, "proxy retained ETH");
    }

    /// @dev The call must revert with exactly `failure` and move nothing
    function _assertRefused(SwapCalldata.Leg[] memory legs, bytes4 failure) internal {
        uint256[] memory before = _balances();
        bytes memory data = _packed(legs);
        vm.prank(user);
        (bool ok, bytes memory ret) = address(proxy).call(abi.encodeCall(proxy.swap, (data)));
        assertFalse(ok, "the call should have reverted");
        assertEq(ret, abi.encodeWithSelector(failure), "reverted with another error");
        _assertBalancesEq(_balances(), before, "a refused call moved funds");
    }

    function _assertMalformed(SwapCalldata.Leg[] memory legs) internal {
        _assertRefused(legs, IProxyErrors.MalformedSwap.selector);
    }

    /// @dev The ledger model: every transfer of `token` the call must make, in order, compared with what
    /// the token really logged.
    /// - A V4 output parked is credit: no transfer.
    /// - A V3 output parked goes to the PoolManager as credit if a V4 leg spends that token after it and
    ///   before any plain HELD V3 leg does, otherwise to the proxy.
    /// - A HELD leg spends credit first, then the proxy's balance: on V3 the PoolManager then the proxy pay
    ///   the pool; on V4 credit needs no transfer and the proxy pays the PoolManager.
    /// - Anything else moves between the user and the pool (the PoolManager, on V4).
    function _assertMoves(
        SwapCalldata.Leg[] memory legs,
        Reference memory ref,
        Vm.Log[] memory logs,
        address token
    )
        internal
        view
    {
        Move[] memory expected = new Move[](2 * legs.length);
        uint256 n;
        uint256 credit;
        uint256 held;
        for (uint256 i = 0; i < legs.length; i++) {
            SwapCalldata.Leg memory leg = legs[i];
            address venue = leg.v4 ? address(manager) : _poolOf(leg);
            if (leg.tokenOut == token) {
                uint256 received = ref.received[i];
                if (!leg.park) {
                    if (received > 0) expected[n++] = Move({from: venue, to: user, amount: received});
                } else if (leg.v4) {
                    credit += received;
                } else if (_v4SpendsItNext(legs, i, token)) {
                    if (received > 0) expected[n++] = Move({from: venue, to: address(manager), amount: received});
                    credit += received;
                } else {
                    if (received > 0) expected[n++] = Move({from: venue, to: address(proxy), amount: received});
                    held += received;
                }
            }
            if (leg.tokenIn == token) {
                uint256 paid = ref.paid[i];
                if (!leg.held) {
                    if (paid > 0) expected[n++] = Move({from: user, to: venue, amount: paid});
                } else {
                    uint256 fromCredit = paid < credit ? paid : credit;
                    uint256 fromProxy = paid - fromCredit;
                    credit -= fromCredit;
                    held -= fromProxy;
                    if (!leg.v4 && fromCredit > 0) {
                        expected[n++] = Move({from: address(manager), to: venue, amount: fromCredit});
                    }
                    if (fromProxy > 0) expected[n++] = Move({from: address(proxy), to: venue, amount: fromProxy});
                }
            }
        }
        assertEq(credit, 0, "model: credit left over");
        assertEq(held, 0, "model: proxy balance left over");

        uint256 seen;
        for (uint256 l = 0; l < logs.length; l++) {
            if (logs[l].emitter != token || logs[l].topics[0] != TRANSFER) continue;
            assertLt(seen, n, "more transfers than the ledger explains");
            Move memory move = expected[seen++];
            assertEq(address(uint160(uint256(logs[l].topics[1]))), move.from, "transfer from the wrong place");
            assertEq(address(uint160(uint256(logs[l].topics[2]))), move.to, "transfer to the wrong place");
            assertEq(abi.decode(logs[l].data, (uint256)), move.amount, "transfer of the wrong amount");
        }
        assertEq(seen, n, "fewer transfers than the ledger explains");
    }

    /// @dev Whether a V4 leg spends `token` after `producer`, with only V3 shares of it in between
    function _v4SpendsItNext(
        SwapCalldata.Leg[] memory legs,
        uint256 producer,
        address token
    )
        internal
        pure
        returns (bool)
    {
        for (uint256 j = producer + 1; j < legs.length; j++) {
            if (!legs[j].held || legs[j].tokenIn != token) continue;
            if (legs[j].v4) return true;
            if (!legs[j].share) return false;
        }
        return false;
    }
}
