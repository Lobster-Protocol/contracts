// SPDX-License-Identifier: GPL-3.0
pragma solidity =0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {ForkBase} from "../helpers/ForkBase.sol";
import {SwapCalldata} from "../../helpers/SwapCalldata.sol";
import {IUniswapV3PoolMinimal} from "../../../src/interfaces/uniswapV3/IUniswapV3PoolMinimal.sol";
import {IProxyErrors} from "../../../src/interfaces/IProxyErrors.sol";

/// @notice HELD | SHARE against live pools: the route the aggregator returns, WETH -> USDC, then USDC split
/// across several pools, from what the first swap really delivered.
/// @dev The offline suite (test/LobsterShare.t.sol) proves the ledger for every order. This one confirms
/// it against the canonical deployments and real tokens, USDT's missing return value included: each call
/// must match the same swaps made one by one, each given by hand the input the rule says, and leave the
/// proxy holding nothing. Mainnet only: the extra pools do not exist on Sepolia.
contract ShareSplitTest is ForkBase {
    uint128 internal constant HALF = uint128(1) << 127;
    uint128 internal constant SIXTY = uint128((uint256(3) << 128) / 5);

    /// @dev What a call's legs did when made one by one, see {_reference}
    struct Reference {
        uint256[] amounts;
        uint256[] paid;
        /// @dev What the first leg delivered: the amount being split
        uint256 delivered;
        uint256[4] holdings;
        uint256 eth;
    }

    function setUp() public override {
        super.setUp();
        _requireCanonicalTokens();
        _allow(approver, proxy.v3Key(_poolFor(USDC, USDT, 100)), SWAP);
        _allow(approver, proxy.v3Key(_poolFor(USDC, DAI, 100)), SWAP);
        _allow(approver, proxy.v3Key(_poolFor(USDT, WETH, 3000)), SWAP);
    }

    /// @notice V3 only: WETH -> USDC, then 50% to USDT and the rest to WETH. The first pool receives exactly
    /// the computed share, and no unlock is opened.
    function test_v3Only_splitsWhatTheFirstSwapDelivered() public {
        SwapCalldata.Leg[] memory legs = new SwapCalldata.Leg[](3);
        legs[0] = _parked(_v3In(WETH, USDC, 3000, tradeWeth, 0));
        legs[1] = _shareOf(_v3In(USDC, USDT, 100, 0, 0), HALF);
        legs[2] = _held(_v3In(USDC, WETH, 500, 0, 0));
        Reference memory ref = _reference(legs);
        address firstPool = _poolFor(USDC, USDT, 100);
        uint256 firstPoolBefore = IERC20(USDC).balanceOf(firstPool);

        _expectUnlocks(0);
        _assertRun(legs, ref);

        assertEq(
            IERC20(USDC).balanceOf(firstPool) - firstPoolBefore, (ref.delivered * HALF) >> 128, "not exactly the share"
        );
    }

    /// @notice First consumer V4: the V3 pool pays the PoolManager, the V4 leg spends part of that credit
    /// and the PoolManager pays the next V3 pool the rest
    function test_firstConsumerV4_restGoesToV3() public {
        SwapCalldata.Leg[] memory legs = new SwapCalldata.Leg[](3);
        legs[0] = _parked(_v3In(WETH, USDC, 3000, tradeWeth, 0));
        legs[1] = _shareOf(_v4In(false, 0, 0), HALF);
        legs[2] = _held(_v3In(USDC, USDT, 100, 0, 0));
        Reference memory ref = _reference(legs);

        _expectUnlocks(1);
        _assertRun(legs, ref);
    }

    /// @notice First consumer V3, then a V4 leg gets the rest: the V3 producer pays the PoolManager, which
    /// pays the V3 pool, and the V4 leg spends the rest as credit
    function test_firstConsumerV3_restGoesToV4() public {
        SwapCalldata.Leg[] memory legs = new SwapCalldata.Leg[](3);
        legs[0] = _parked(_v3In(WETH, USDC, 3000, tradeWeth, 0));
        legs[1] = _shareOf(_v3In(USDC, USDT, 100, 0, 0), HALF);
        legs[2] = _held(_v4In(false, 0, 0));
        Reference memory ref = _reference(legs);

        _expectUnlocks(1);
        _assertRun(legs, ref);
    }

    /// @notice Three consumers mixing versions at 50/30/20, encoded as 50%, 60% of the rest, plain HELD
    function test_threeConsumers_50_30_20_mixingVersions() public {
        SwapCalldata.Leg[] memory legs = new SwapCalldata.Leg[](4);
        legs[0] = _parked(_v3In(WETH, USDC, 3000, tradeWeth, 0));
        legs[1] = _shareOf(_v3In(USDC, USDT, 100, 0, 0), HALF);
        legs[2] = _shareOf(_v4In(false, 0, 0), SIXTY);
        legs[3] = _held(_v3In(USDC, DAI, 100, 0, 0));
        Reference memory ref = _reference(legs);

        _expectUnlocks(1);
        _assertRun(legs, ref);
    }

    /// @notice A V4 output split across two V3 pools: it stays credit, and the PoolManager pays each pool
    function test_v4Output_splitAcrossTwoV3Pools() public {
        SwapCalldata.Leg[] memory legs = new SwapCalldata.Leg[](3);
        legs[0] = _parked(_v4In(true, tradeWeth, 0)); // ETH in from msg.value, USDC parked
        legs[1] = _shareOf(_v3In(USDC, USDT, 100, 0, 0), HALF);
        legs[2] = _held(_v3In(USDC, DAI, 100, 0, 0));
        Reference memory ref = _reference(legs);

        _assertRun(legs, ref);
    }

    /// @notice USDT, whose transfers return nothing, split from the proxy's own balance
    function test_usdt_splitFromTheProxysBalance() public {
        SwapCalldata.Leg[] memory legs = new SwapCalldata.Leg[](3);
        legs[0] = _parked(_v3In(WETH, USDT, 500, tradeWeth, 0));
        legs[1] = _shareOf(_v3In(USDT, USDC, 100, 0, 0), HALF);
        legs[2] = _held(_v3In(USDT, WETH, 3000, 0, 0));
        Reference memory ref = _reference(legs);

        _expectUnlocks(0);
        _assertRun(legs, ref);
    }

    /// @notice Native ETH split as credit, on the one live V4 pool the suite uses, both times against
    /// the same pool: nothing is drawn from msg.value
    function test_nativeEth_splitAsCredit() public {
        SwapCalldata.Leg[] memory legs = new SwapCalldata.Leg[](3);
        legs[0] = _parked(_v4In(false, tradeUsdc, 0)); // USDC in, ETH parked
        legs[1] = _shareOf(_v4In(true, 0, 0), HALF);
        legs[2] = _held(_v4In(true, 0, 0));
        Reference memory ref = _reference(legs);
        uint256 ethBefore = approver.balance;

        _assertRun(legs, ref);

        assertEq(approver.balance, ethBefore, "ETH moved although it was only an intermediate");
    }

    /// @notice A share that stops at its price limit leaves the rest parked for the next leg, which spends it
    /// on the other version
    function test_partialFill_restGoesToTheNextLeg() public {
        // USDC sorts below USDT, so USDC in pushes this pool's price down: a limit a hair below the live price
        // stops the leg, and the order is large enough for even a deep stable pool to get there
        require(USDC < USDT, "test assumes USDC sorts below USDT");
        (uint160 sqrtPrice,,,,,,) = IUniswapV3PoolMinimal(_poolFor(USDC, USDT, 100)).slot0();
        SwapCalldata.Leg memory stops = _shareOf(_v3In(USDC, USDT, 100, 0, 0), HALF);
        stops.sqrtPriceLimitX96 = sqrtPrice - (sqrtPrice / 10_000_000);

        SwapCalldata.Leg[] memory legs = new SwapCalldata.Leg[](3);
        legs[0] = _parked(_v3In(WETH, USDC, 3000, 100 ether, 0));
        legs[1] = stops;
        legs[2] = _held(_v4In(false, 0, 0));
        Reference memory ref = _reference(legs);
        assertLt(ref.paid[1], (ref.delivered * HALF) >> 128, "premise: the limit stops the leg short of its share");
        assertEq(ref.paid[2], ref.delivered - ref.paid[1], "the next leg did not spend what the partial fill left");

        _assertRun(legs, ref);
    }

    /// @notice A share with no later leg to spend the rest reverts and moves nothing, whichever place the
    /// rest waits in: the proxy, or PoolManager credit
    function test_shareWithNoLaterLeg_revertsFundsLeftInProxy() public {
        uint256[4] memory before = _approverHoldings();

        SwapCalldata.Leg[] memory legs = new SwapCalldata.Leg[](2);
        legs[0] = _parked(_v3In(WETH, USDC, 3000, tradeWeth, 0));
        legs[1] = _shareOf(_v3In(USDC, USDT, 100, 0, 0), HALF);
        bytes memory inProxy = _swapData(legs);
        vm.prank(approver);
        vm.expectRevert(IProxyErrors.FundsLeftInProxy.selector);
        proxy.swap(inProxy);

        legs[1] = _shareOf(_v4In(false, 0, 0), HALF);
        bytes memory asCredit = _swapData(legs);
        vm.prank(approver);
        vm.expectRevert(IProxyErrors.FundsLeftInProxy.selector);
        proxy.swap(asCredit);

        _assertApproverUntouched(before, "refused split");
    }

    /// @notice Random shares across three consumers on live pools spend exactly what the first swap
    /// delivered and match the same swaps made one by one, whichever consumer is the V4 one
    function testFuzz_randomShares_matchOneByOne(uint128 rawFirst, uint128 rawSecond, uint8 v4Position) public {
        // At least 0.1% each, so no consumer's input is dust a stable pool rounds to nothing
        uint128 first = SafeCast.toUint128(bound(rawFirst, uint256(1) << 118, type(uint128).max - (uint256(1) << 118)));
        uint128 second =
            SafeCast.toUint128(bound(rawSecond, uint256(1) << 118, type(uint128).max - (uint256(1) << 118)));
        SwapCalldata.Leg[] memory legs = new SwapCalldata.Leg[](4);
        legs[0] = _parked(_v3In(WETH, USDC, 3000, tradeWeth, 0));
        uint256 position = v4Position % 3;
        legs[1] = _shareOf(position == 0 ? _v4In(false, 0, 0) : _v3In(USDC, USDT, 100, 0, 0), first);
        legs[2] = _shareOf(position == 1 ? _v4In(false, 0, 0) : _v3In(USDC, DAI, 100, 0, 0), second);
        legs[3] = _held(position == 2 ? _v4In(false, 0, 0) : _v3In(USDC, WETH, 500, 0, 0));
        Reference memory ref = _reference(legs);

        _expectUnlocks(1);
        _assertRun(legs, ref);
    }

    // ---------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------

    /// @dev The legs as one-leg calls by the approver, each HELD leg given by hand the input the rule says.
    /// Rewinds. All these routes park one token at a time.
    function _reference(SwapCalldata.Leg[] memory legs) internal returns (Reference memory ref) {
        uint256 snap = vm.snapshotState();
        ref.amounts = new uint256[](legs.length);
        ref.paid = new uint256[](legs.length);
        uint256 parked;
        for (uint256 i = 0; i < legs.length; i++) {
            SwapCalldata.Leg memory one = abi.decode(abi.encode(legs[i]), (SwapCalldata.Leg));
            one.held = false;
            one.share = false;
            one.park = false;
            if (legs[i].held) {
                one.amount = SafeCast.toUint128(legs[i].share ? (parked * legs[i].amount) >> 128 : parked);
            }
            uint256 value = one.tokenIn == address(0) ? one.amount : 0;
            uint256 inBefore = _balance(one.tokenIn);
            uint256 outBefore = _balance(one.tokenOut);
            ref.amounts[i] = _swapOne(approver, one, value);
            ref.paid[i] = inBefore - _balance(one.tokenIn);
            if (i == 0) ref.delivered = _balance(one.tokenOut) - outBefore;
            if (legs[i].held) parked -= ref.paid[i];
            if (legs[i].park) parked += _balance(one.tokenOut) - outBefore;
        }
        assertEq(parked, 0, "test bug: the reference leaves parked funds unspent");
        ref.holdings = _approverHoldings();
        ref.eth = approver.balance;
        vm.revertToState(snap);
    }

    function _balance(address token) internal view returns (uint256) {
        return token == address(0) ? approver.balance : IERC20(token).balanceOf(approver);
    }

    /// @dev `legs` as one call must match `ref`, and leave the proxy holding nothing. Sends the msg.value a
    /// leg paying native ETH itself needs.
    function _assertRun(SwapCalldata.Leg[] memory legs, Reference memory ref) internal {
        uint256 value;
        for (uint256 i = 0; i < legs.length; i++) {
            if (legs[i].tokenIn == address(0) && !legs[i].held) value += legs[i].amount;
        }
        bytes memory data = _swapData(legs);
        vm.prank(approver);
        uint256[] memory amounts = proxy.swap{value: value}(data);

        assertEq(amounts.length, legs.length, "one amount per leg");
        for (uint256 i = 0; i < legs.length; i++) {
            assertEq(
                amounts[i], ref.amounts[i], string.concat("leg ", vm.toString(i), " differs from the one-leg call")
            );
        }
        uint256[4] memory holdings = _approverHoldings();
        for (uint256 i = 0; i < 4; i++) {
            assertEq(holdings[i], ref.holdings[i], "approver balances differ from one-by-one");
        }
        assertEq(approver.balance, ref.eth, "approver ETH differs from one-by-one");
        assertEq(IERC20(USDC).balanceOf(address(proxy)), 0, "proxy retained USDC");
        assertEq(IERC20(USDT).balanceOf(address(proxy)), 0, "proxy retained USDT");
        assertEq(IERC20(DAI).balanceOf(address(proxy)), 0, "proxy retained DAI");
        assertEq(IERC20(WETH).balanceOf(address(proxy)), 0, "proxy retained WETH");
        assertEq(address(proxy).balance, 0, "proxy retained ETH");
    }
}
