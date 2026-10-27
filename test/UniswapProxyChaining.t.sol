// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.24;

import {BatchSwapFixture} from "./helpers/BatchSwapFixture.sol";
import {BatchSwapCalls} from "./helpers/BatchSwapCalls.sol";
import {UniswapBatchSwapProxy, SwapType} from "../src/UniswapBatchSwapProxy.sol";
import {UniswapV3SwapProxy} from "../src/UniswapV3SwapProxy.sol";
import {UniswapV4SwapProxy} from "../src/UniswapV4SwapProxy.sol";
import {Chaining} from "../src/libraries/Chaining.sol";
import {TickMath} from "../src/libraries/uniswapV3/TickMath.sol";
import {ExactInputSingleParams, ExactOutputSingleParams} from "../src/interfaces/uniswapV3/IUniswapV3SwapCallback.sol";
import {MintParams} from "../src/interfaces/uniswapV3/IUniswapV3MintCallback.sol";
import {V4ExactInputSingleParams, V4ExactOutputSingleParams} from "../src/interfaces/uniswapV4/IUnlockCallback.sol";
import {IUniswapV3FactoryMinimal} from "../src/interfaces/uniswapV3/IUniswapV3FactoryMinimal.sol";
import {IUniswapV3PoolMinimal} from "../src/interfaces/uniswapV3/IUniswapV3PoolMinimal.sol";
import {
    PoolKey as ProxyPoolKey,
    IPoolManagerMinimal,
    SwapParams
} from "../src/interfaces/uniswapV4/IPoolManagerMinimal.sol";
import {V4Leg, V4UnlockData} from "../src/interfaces/uniswapV4/IUnlockCallback.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/// @notice A token that, the first time it is transferred to `target`, calls `target` with `attack`
/// and records what happened.
contract ReentrantERC20 is MockERC20 {
    address public target;
    bytes public attack;
    bool public armed;
    uint256 public attempts;
    bool public attackSucceeded;
    bytes public attackRevertData;

    constructor() MockERC20("Reentrant", "RENT", 18) {}

    function arm(address _target, bytes calldata _attack) external {
        target = _target;
        attack = _attack;
        armed = true;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (armed && to == target) {
            armed = false;
            attempts++;
            (attackSucceeded, attackRevertData) = target.call(attack);
        }
        return super.transfer(to, amount);
    }
}

/// @notice Chaining inside `batchSwap`: a swap spending exactly what the previous one produced.
/// @dev The reference for every route is the same legs made as separate direct calls, with each
/// intermediate output delivered to the user and fed by hand into the next leg as its exact input. A
/// chained route must match it to the wei, leg by leg, and leave the proxy holding nothing.
///
/// Route graph (five pools, both versions, native ETH in the middle):
///   token0 --V3--  token1 --V3--  tokenC
///   token0 --V4--  token1 --V4--  ETH  --V4--  tokenC
contract UniswapProxyChainingTest is BatchSwapFixture {
    uint8 constant E_V3_01 = 0; // V3 token0 <-> token1 (fixture pool)
    uint8 constant E_V3_1C = 1; // V3 token1 <-> tokenC
    uint8 constant E_V4_01 = 2; // V4 token0 <-> token1 (cleanKey)
    uint8 constant E_V4_E1 = 3; // V4 ETH    <-> token1 (nativeKey)
    uint8 constant E_V4_EC = 4; // V4 ETH    <-> tokenC (nativeKeyC)

    address constant ETH = address(0);
    address constant HERE = Chaining.ADDRESS_THIS;

    /// @dev An exact-input leg. `amountIn == 0` spends the previous leg's output (HELD_BALANCE in the
    /// batch). `last` sends the output to `recipient`; otherwise it is parked (batch) or delivered to
    /// the user to feed the next leg by hand (reference).
    struct Leg {
        uint8 edge;
        address tokenIn;
        uint256 amountIn;
        bool last;
    }

    MockERC20 public tokenC;
    ProxyPoolKey public nativeKeyC; // ETH / tokenC, no hook

    function setUp() public virtual override {
        super.setUp();

        tokenC = new MockERC20("Token C", "TKC", 18);
        tokenC.mint(address(this), 100_000e18);
        tokenC.approve(address(proxy), type(uint256).max);
        tokenC.approve(address(lpRouter), type(uint256).max);

        // V3 token1/tokenC at price 1
        IUniswapV3FactoryMinimal(v3Factory).createPool(address(token1), address(tokenC), FEE);
        _v3PoolFor(address(token1), address(tokenC)).initialize(SQRT_PRICE_1_1);
        _mintV3(address(token1), address(tokenC));

        // V4 ETH/tokenC at price 1
        PoolKey memory k = _v4CoreKey(ETH, address(tokenC));
        manager.initialize(k, SQRT_PRICE_1_1);
        _addV4Liquidity(k, 10_000e18);
        nativeKeyC = _toProxyKey(k);

        tokenC.mint(user, 10_000e18);
        vm.prank(user);
        tokenC.approve(address(proxy), type(uint256).max);
    }

    // ---------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------

    function _sorted(address a, address b) internal pure returns (address, address) {
        return a < b ? (a, b) : (b, a);
    }

    function _v3PoolFor(address a, address b) internal view returns (IUniswapV3PoolMinimal) {
        return IUniswapV3PoolMinimal(IUniswapV3FactoryMinimal(v3Factory).getPool(a, b, FEE));
    }

    /// @dev Wide liquidity (1000 of each) in a V3 pool, paid by this contract
    function _mintV3(address a, address b) internal {
        (address t0, address t1) = _sorted(a, b);
        _allowAnyMintPrice(address(_v3PoolFor(t0, t1)));
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
                deadline: block.timestamp
            })
        );
    }

    function _edgeTokens(uint8 edge) internal view returns (address a, address b) {
        if (edge == E_V3_01 || edge == E_V4_01) return (address(token0), address(token1));
        if (edge == E_V3_1C) return (address(token1), address(tokenC));
        if (edge == E_V4_E1) return (ETH, address(token1));
        return (ETH, address(tokenC));
    }

    function _otherSide(uint8 edge, address tokenIn) internal view returns (address) {
        (address a, address b) = _edgeTokens(edge);
        require(tokenIn == a || tokenIn == b, "leg: token not on this edge");
        return tokenIn == a ? b : a;
    }

    function _v3Item(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        address to,
        uint160 limit
    )
        internal
        view
        returns (bytes memory)
    {
        return abi.encodePacked(
            SwapType.V3_EXACT_INPUT,
            abi.encode(
                ExactInputSingleParams({
                    tokenIn: tokenIn,
                    tokenOut: tokenOut,
                    fee: FEE,
                    recipient: to,
                    deadline: block.timestamp,
                    amountIn: amountIn,
                    amountOutMinimum: 0,
                    sqrtPriceLimitX96: limit
                })
            )
        );
    }

    /// @dev An exact-input batch item over `edge`. In V4, currency0 < currency1 (ETH is address(0)),
    /// so `zeroForOne` is just `tokenIn < tokenOut`.
    function _item(uint8 edge, address tokenIn, uint256 amountIn, address to) internal view returns (bytes memory) {
        address tokenOut = _otherSide(edge, tokenIn);
        if (edge == E_V3_01 || edge == E_V3_1C) return _v3Item(tokenIn, tokenOut, amountIn, to, 0);

        ProxyPoolKey memory key = edge == E_V4_01 ? cleanKey : edge == E_V4_E1 ? nativeKey : nativeKeyC;
        return abi.encodePacked(
            SwapType.V4_EXACT_INPUT,
            abi.encode(
                V4ExactInputSingleParams({
                    poolKey: key,
                    zeroForOne: tokenIn < tokenOut,
                    recipient: to,
                    deadline: block.timestamp,
                    // forge-lint: disable-next-line(unsafe-typecast)
                    amountIn: uint128(amountIn), // test amounts are far below 2**128
                    amountOutMinimum: 0,
                    sqrtPriceLimitX96: 0
                })
            )
        );
    }

    function _batchItems(Leg[] memory legs) internal view returns (bytes[] memory items) {
        items = new bytes[](legs.length);
        for (uint256 i = 0; i < legs.length; i++) {
            items[i] = _item(legs[i].edge, legs[i].tokenIn, legs[i].amountIn, legs[i].last ? recipient : HERE);
        }
    }

    /// @dev The reference: each leg a separate direct call by `user`, intermediate outputs delivered to
    /// `user` and passed by hand as the next leg's exact `amountIn` (as msg.value when it is ETH).
    function _runManually(Leg[] memory legs) internal returns (uint256[] memory outs) {
        outs = new uint256[](legs.length);
        uint256 previous;
        for (uint256 i = 0; i < legs.length; i++) {
            uint256 amountIn = legs[i].amountIn == 0 ? previous : legs[i].amountIn;
            bytes memory call_ = BatchSwapCalls.toDirectCall(
                _item(legs[i].edge, legs[i].tokenIn, amountIn, legs[i].last ? recipient : user)
            );
            vm.prank(user);
            (bool ok, bytes memory ret) = address(proxy).call{value: legs[i].tokenIn == ETH ? amountIn : 0}(call_);
            assertTrue(ok, "reference leg failed");
            outs[i] = abi.decode(ret, (uint256));
            previous = outs[i];
        }
    }

    /// @dev Everything a route could move, for the user and the recipient: token0, token1, tokenC, ETH
    function _all() internal view returns (uint256[8] memory h) {
        h[0] = token0.balanceOf(user);
        h[1] = token1.balanceOf(user);
        h[2] = tokenC.balanceOf(user);
        h[3] = user.balance;
        h[4] = token0.balanceOf(recipient);
        h[5] = token1.balanceOf(recipient);
        h[6] = tokenC.balanceOf(recipient);
        h[7] = recipient.balance;
    }

    function _assertNothingParked() internal view {
        assertEq(token0.balanceOf(address(proxy)), 0, "proxy holds token0");
        assertEq(token1.balanceOf(address(proxy)), 0, "proxy holds token1");
        assertEq(tokenC.balanceOf(address(proxy)), 0, "proxy holds tokenC");
        assertEq(address(proxy).balance, 0, "proxy holds ETH");
    }

    /// @dev The central property: the chained batch matches the manual sequence leg by leg, ends with
    /// the same balances for user and recipient, and leaves the proxy empty.
    function _assertChainMatchesManual(Leg[] memory legs) internal returns (uint256[] memory amounts) {
        uint256 snap = vm.snapshotState();
        uint256[] memory expected = _runManually(legs);
        uint256[8] memory expectedAfter = _all();
        vm.revertToState(snap);

        vm.prank(user);
        amounts = proxy.batchSwap(_batchItems(legs));

        assertEq(amounts.length, legs.length, "one amount per leg");
        for (uint256 i = 0; i < legs.length; i++) {
            assertEq(amounts[i], expected[i], "chained leg differs from the manual sequence");
        }
        uint256[8] memory actual = _all();
        for (uint256 i = 0; i < 8; i++) {
            assertEq(actual[i], expectedAfter[i], string.concat("balance ", vm.toString(i), " differs from manual"));
        }
        _assertNothingParked();
    }

    // ---------------------------------------------------------------------------
    // Routes
    // ---------------------------------------------------------------------------

    /// @notice token0 -V3-> token1 -V3-> tokenC -V4-> ETH, one transaction, only the first amount fixed
    function test_chain_threeHopsEndingInNativeEth() public {
        Leg[] memory legs = new Leg[](3);
        legs[0] = Leg(E_V3_01, address(token0), 1e18, false);
        legs[1] = Leg(E_V3_1C, address(token1), 0, false);
        legs[2] = Leg(E_V4_EC, address(tokenC), 0, true);

        uint256 ethBefore = recipient.balance;
        uint256[] memory amounts = _assertChainMatchesManual(legs);

        assertGt(amounts[2], 0, "no ETH out");
        assertEq(recipient.balance - ethBefore, amounts[2], "recipient did not get the final ETH");
    }

    /// @notice ETH as the intermediate: token1 -V4-> ETH (parked) -V4-> tokenC
    function test_chain_nativeEthInTheMiddle() public {
        Leg[] memory legs = new Leg[](2);
        legs[0] = Leg(E_V4_E1, address(token1), 1e18, false);
        legs[1] = Leg(E_V4_EC, ETH, 0, true);

        _assertChainMatchesManual(legs);
    }

    /// @notice V4 -> V3 -> V3: an ERC20 parked by the PoolManager, then spent through V3 callbacks
    function test_chain_crossesVersionsBothWays() public {
        Leg[] memory legs = new Leg[](3);
        legs[0] = Leg(E_V4_01, address(token1), 1e18, false); // -> token0
        legs[1] = Leg(E_V3_01, address(token0), 0, false); // -> token1
        legs[2] = Leg(E_V3_1C, address(token1), 0, true); // -> tokenC

        _assertChainMatchesManual(legs);
    }

    /// @notice Two independent chained routes in one batch
    function test_chain_twoRoutesInOneBatch() public {
        Leg[] memory legs = new Leg[](4);
        legs[0] = Leg(E_V3_01, address(token0), 1e18, false); // route A: token0 -> token1
        legs[1] = Leg(E_V3_1C, address(token1), 0, true); //              -> tokenC
        legs[2] = Leg(E_V4_EC, address(tokenC), 2e18, false); // route B: tokenC -> ETH
        legs[3] = Leg(E_V4_E1, ETH, 0, true); //                          -> token1

        _assertChainMatchesManual(legs);
    }

    /// @notice A random walk of 1-4 hops over all five pools, both versions, ETH in the middle or at
    /// the end, from a random starting token and amount
    function testFuzz_randomRoute_matchesManualSequence(
        uint256 seed,
        uint256 hops,
        uint256 amount,
        uint8 start
    )
        public
    {
        uint256 n = bound(hops, 1, 4);
        address[3] memory starts = [address(token0), address(token1), address(tokenC)];
        address token = starts[start % 3];

        Leg[] memory legs = new Leg[](n);
        for (uint256 i = 0; i < n; i++) {
            uint8 edge = _randomEdgeFrom(token, uint256(keccak256(abi.encode(seed, i))));
            legs[i] = Leg(edge, token, i == 0 ? bound(amount, 1e15, 5e18) : 0, i == n - 1);
            token = _otherSide(edge, token);
        }

        _assertChainMatchesManual(legs);
    }

    function _randomEdgeFrom(address token, uint256 r) internal view returns (uint8) {
        if (token == address(token0)) return [E_V3_01, E_V4_01][r % 2];
        if (token == address(token1)) return [E_V3_01, E_V3_1C, E_V4_01, E_V4_E1][r % 4];
        if (token == address(tokenC)) return [E_V3_1C, E_V4_EC][r % 2];
        return [E_V4_E1, E_V4_EC][r % 2]; // ETH
    }

    /// @notice Two outputs parked in the same token merge; the next HELD_BALANCE leg spends both
    function test_chain_mergesTwoParkedOutputs() public {
        bytes[] memory swaps = new bytes[](3);
        swaps[0] = _item(E_V3_01, address(token0), 1e18, HERE);
        swaps[1] = _item(E_V4_01, address(token0), 1e18, HERE);
        swaps[2] = _item(E_V3_1C, address(token1), Chaining.HELD_BALANCE, recipient);

        // Reference: both legs to the user, then one leg spending their sum
        uint256 snap = vm.snapshotState();
        vm.startPrank(user);
        uint256 a = proxy.exactInputSingle(
            abi.decode(_slice1(_item(E_V3_01, address(token0), 1e18, user)), (ExactInputSingleParams))
        );
        uint256 b = proxy.exactInputSingleV4(
            abi.decode(_slice1(_item(E_V4_01, address(token0), 1e18, user)), (V4ExactInputSingleParams))
        );
        uint256 c = proxy.exactInputSingle(
            abi.decode(_slice1(_item(E_V3_1C, address(token1), a + b, recipient)), (ExactInputSingleParams))
        );
        vm.stopPrank();
        vm.revertToState(snap);

        vm.prank(user);
        uint256[] memory amounts = proxy.batchSwap(swaps);

        assertEq(amounts[0], a, "first parked leg");
        assertEq(amounts[1], b, "second parked leg");
        assertEq(amounts[2], c, "merged leg did not spend exactly the sum");
        _assertNothingParked();
    }

    /// @notice An exact-output leg can park its exact amount for the next leg to spend
    function test_chain_exactOutputLegFeedsTheNext() public {
        bytes memory exactOut = abi.encodePacked(
            SwapType.V3_EXACT_OUTPUT,
            abi.encode(
                ExactOutputSingleParams({
                    tokenIn: address(token0),
                    tokenOut: address(token1),
                    fee: FEE,
                    recipient: HERE,
                    deadline: block.timestamp,
                    amountOut: 2e18,
                    amountInMaximum: type(uint256).max,
                    sqrtPriceLimitX96: 0
                })
            )
        );

        // Reference: get exactly 2 token1, then spend exactly 2 token1
        uint256 snap = vm.snapshotState();
        vm.startPrank(user);
        uint256 paid = proxy.exactOutputSingle(
            ExactOutputSingleParams({
                tokenIn: address(token0),
                tokenOut: address(token1),
                fee: FEE,
                recipient: user,
                deadline: block.timestamp,
                amountOut: 2e18,
                amountInMaximum: type(uint256).max,
                sqrtPriceLimitX96: 0
            })
        );
        uint256 out = proxy.exactInputSingle(
            abi.decode(_slice1(_item(E_V3_1C, address(token1), 2e18, recipient)), (ExactInputSingleParams))
        );
        vm.stopPrank();
        vm.revertToState(snap);

        vm.prank(user);
        uint256[] memory amounts =
            proxy.batchSwap(_batch(exactOut, _item(E_V3_1C, address(token1), Chaining.HELD_BALANCE, recipient)));

        assertEq(amounts[0], paid, "exact-output leg paid a different amount");
        assertEq(amounts[1], out, "next leg did not spend exactly the parked 2 token1");
        _assertNothingParked();
    }

    /// @dev Drops the leading SwapType byte, leaving the abi-encoded params
    function _slice1(bytes memory item) internal pure returns (bytes memory params) {
        params = new bytes(item.length - 1);
        for (uint256 i = 0; i < params.length; i++) {
            params[i] = item[i + 1];
        }
    }

    // ---------------------------------------------------------------------------
    // Nothing may be left behind
    // ---------------------------------------------------------------------------

    function test_fundsLeftInProxy_revert() public {
        uint256[8] memory before = _all();

        // Parked, and nothing spends it
        vm.prank(user);
        vm.expectRevert(bytes("Funds left in proxy"));
        proxy.batchSwap(_batch(_item(E_V3_01, address(token0), 1e18, HERE)));

        // Parked, but the next leg is paid by the caller instead of spending it
        vm.prank(user);
        vm.expectRevert(bytes("Funds left in proxy"));
        proxy.batchSwap(
            _batch(_item(E_V3_01, address(token0), 1e18, HERE), _item(E_V3_1C, address(token1), 1e17, recipient))
        );

        // Parked, then only partly spent: a price limit one tick away stops the next leg early
        bool zeroForOne = address(token1) < address(tokenC);
        uint160 oneTickAway = TickMath.getSqrtRatioAtTick(zeroForOne ? int24(-1) : int24(1));
        vm.prank(user);
        vm.expectRevert(bytes("Funds left in proxy"));
        proxy.batchSwap(
            _batch(
                _item(E_V3_01, address(token0), 1e18, HERE),
                _v3Item(address(token1), address(tokenC), Chaining.HELD_BALANCE, recipient, oneTickAway)
            )
        );

        // Parked ETH, never spent
        vm.prank(user);
        vm.expectRevert(bytes("Funds left in proxy"));
        proxy.batchSwap(_batch(_item(E_V4_E1, address(token1), 1e18, HERE)));

        uint256[8] memory afterAll = _all();
        for (uint256 i = 0; i < 8; i++) {
            assertEq(afterAll[i], before[i], "a rejected batch moved funds");
        }
        _assertNothingParked();
    }

    function test_heldBalanceWithNothingHeld_reverts() public {
        vm.prank(user);
        vm.expectRevert(bytes("Nothing held"));
        proxy.batchSwap(_batch(_item(E_V3_1C, address(token1), Chaining.HELD_BALANCE, recipient)));

        vm.prank(user);
        vm.expectRevert(bytes("Nothing held"));
        proxy.batchSwap(_batch(_item(E_V4_EC, ETH, Chaining.HELD_BALANCE, recipient)));
    }

    // ---------------------------------------------------------------------------
    // Native ETH rules
    // ---------------------------------------------------------------------------

    /// @notice In a batch, native input can only be ETH an earlier swap parked, spent via HELD_BALANCE
    function test_nativeInputMustComeFromAPreviousSwap() public {
        vm.prank(user);
        vm.expectRevert(bytes("Native input must come from a previous swap"));
        proxy.batchSwap(_batch(_item(E_V4_EC, ETH, 1e18, recipient)));

        bytes memory exactOutNativeIn = abi.encodePacked(
            SwapType.V4_EXACT_OUTPUT,
            abi.encode(
                V4ExactOutputSingleParams({
                    poolKey: nativeKeyC,
                    zeroForOne: true, // ETH in
                    recipient: recipient,
                    deadline: block.timestamp,
                    amountOut: 1e17,
                    amountInMaximum: type(uint128).max,
                    sqrtPriceLimitX96: 0
                })
            )
        );
        vm.prank(user);
        vm.expectRevert(bytes("Native input must come from a previous swap"));
        proxy.batchSwap(_batch(exactOutNativeIn));
    }

    function test_receiveAcceptsEthOnlyFromThePoolManager() public {
        vm.prank(user);
        (bool ok,) = address(proxy).call{value: 1e18}("");
        assertFalse(ok, "proxy accepted ETH from a user");

        vm.deal(address(manager), 1e18);
        vm.prank(address(manager));
        (ok,) = address(proxy).call{value: 1e18}("");
        assertTrue(ok, "proxy refused ETH from the PoolManager");
    }

    // ---------------------------------------------------------------------------
    // ADDRESS_THIS means nothing outside a batch
    // ---------------------------------------------------------------------------

    function test_addressThisIsRejectedOutsideABatch() public {
        vm.startPrank(user);

        vm.expectRevert(bytes("Invalid recipient"));
        proxy.exactInputSingle(
            abi.decode(_slice1(_item(E_V3_01, address(token0), 1e18, HERE)), (ExactInputSingleParams))
        );

        vm.expectRevert(bytes("Invalid recipient"));
        proxy.exactInputSingleV4(
            abi.decode(_slice1(_item(E_V4_01, address(token0), 1e18, HERE)), (V4ExactInputSingleParams))
        );

        vm.expectRevert(bytes("Invalid recipient"));
        proxy.mint(
            MintParams({
                token0: address(token0),
                token1: address(token1),
                fee: FEE,
                tickLower: -TICK_RANGE,
                tickUpper: TICK_RANGE,
                amount0Desired: 1e18,
                amount1Desired: 1e18,
                amount0Min: 0,
                amount1Min: 0,
                recipient: HERE,
                deadline: block.timestamp
            })
        );

        vm.stopPrank();
    }

    // ---------------------------------------------------------------------------
    // Reentrancy: parked funds cannot be reached mid-batch
    // ---------------------------------------------------------------------------

    /// @notice The attack the lock exists for. The victim's batch parks token1, then swaps into a token
    /// that calls back into the proxy the moment the pool delivers it. The callback tries to run its
    /// own batch spending the parked token1 to the attacker. It must be refused, and the victim's batch
    /// must complete normally.
    function test_reentrantTokenCannotSpendParkedFunds() public {
        ReentrantERC20 evil = new ReentrantERC20();
        evil.mint(address(this), 100_000e18);
        evil.approve(address(proxy), type(uint256).max);
        IUniswapV3FactoryMinimal(v3Factory).createPool(address(token0), address(evil), FEE);
        _v3PoolFor(address(token0), address(evil)).initialize(SQRT_PRICE_1_1);
        _mintV3(address(token0), address(evil));

        address attacker = makeAddr("attacker");
        evil.arm(
            address(proxy),
            abi.encodeCall(
                UniswapBatchSwapProxy.batchSwap,
                (_batch(_v3Item(address(token1), address(token0), Chaining.HELD_BALANCE, attacker, 0)))
            )
        );

        bytes[] memory victim = new bytes[](4);
        victim[0] = _item(E_V3_01, address(token0), 1e18, HERE); // parks token1
        victim[1] = _v3Item(address(token0), address(evil), 1e18, HERE, 0); // delivering EVIL triggers the attack
        victim[2] = _item(E_V3_1C, address(token1), Chaining.HELD_BALANCE, recipient);
        victim[3] = _v3Item(address(evil), address(token0), Chaining.HELD_BALANCE, recipient, 0);

        vm.prank(user);
        proxy.batchSwap(victim);

        assertEq(evil.attempts(), 1, "the attack never fired; test proves nothing");
        assertFalse(evil.attackSucceeded(), "re-entrant batch succeeded");
        assertEq(
            evil.attackRevertData(),
            abi.encodeWithSelector(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector),
            "re-entrant batch failed for an unexpected reason"
        );
        assertEq(token0.balanceOf(attacker), 0, "attacker received parked funds");
        assertEq(evil.balanceOf(address(proxy)), 0, "proxy holds EVIL");
        _assertNothingParked();
    }

    /// @notice The lock covers the direct entry points too
    function test_directEntryPointsAreLockedDuringABatch() public {
        ReentrantERC20 evil = new ReentrantERC20();
        evil.mint(address(this), 100_000e18);
        evil.approve(address(proxy), type(uint256).max);
        IUniswapV3FactoryMinimal(v3Factory).createPool(address(token0), address(evil), FEE);
        _v3PoolFor(address(token0), address(evil)).initialize(SQRT_PRICE_1_1);
        _mintV3(address(token0), address(evil));

        evil.arm(
            address(proxy),
            abi.encodeCall(
                UniswapV3SwapProxy.exactInputSingle,
                (abi.decode(_slice1(_item(E_V3_01, address(token0), 1e18, makeAddr("x"))), (ExactInputSingleParams)))
            )
        );

        bytes[] memory victim = new bytes[](2);
        victim[0] = _v3Item(address(token0), address(evil), 1e18, HERE, 0);
        victim[1] = _v3Item(address(evil), address(token0), Chaining.HELD_BALANCE, recipient, 0);
        vm.prank(user);
        proxy.batchSwap(victim);

        assertEq(evil.attempts(), 1, "the attack never fired");
        assertEq(
            evil.attackRevertData(),
            abi.encodeWithSelector(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector),
            "direct entry point was not locked"
        );
    }

    // ---------------------------------------------------------------------------
    // Consecutive chained V4 swaps share one unlock
    // ---------------------------------------------------------------------------

    /// @dev Expects exactly `count` PoolManager unlocks during the next call
    function _expectUnlocks(uint64 count) internal {
        vm.expectCall(address(manager), abi.encodeWithSelector(IPoolManagerMinimal.unlock.selector), count);
    }

    /// @notice V4 -> V4 -> V4, each spending what the previous parked: one unlock, and the intermediate
    /// tokens never reach the proxy
    function test_v4Chain_runsInOneUnlock() public {
        bytes[] memory swaps = new bytes[](3);
        swaps[0] = _item(E_V4_01, address(token0), 1e18, HERE);
        swaps[1] = _item(E_V4_E1, address(token1), Chaining.HELD_BALANCE, HERE);
        swaps[2] = _item(E_V4_EC, ETH, Chaining.HELD_BALANCE, recipient);

        _expectUnlocks(1);
        vm.prank(user);
        proxy.batchSwap(swaps);
        _assertNothingParked();
    }

    /// @notice V4 swaps that do not chain each get their own, cheaper, single-swap unlock
    function test_unchainedV4Swaps_getAnUnlockEach() public {
        bytes[] memory swaps = new bytes[](3);
        swaps[0] = _item(E_V4_01, address(token0), 1e18, recipient); // not parked
        swaps[1] = _item(E_V4_01, address(token1), 1e18, HERE); // parks token0...
        swaps[2] = _item(E_V4_EC, address(tokenC), 1e18, recipient); // ...but this does not spend it
        swaps = _append(swaps, _item(E_V3_01, address(token0), Chaining.HELD_BALANCE, recipient));

        _expectUnlocks(3);
        vm.prank(user);
        proxy.batchSwap(swaps);
        _assertNothingParked();
    }

    /// @notice A V3 swap between V4 swaps splits them: V4 -> V3 -> V4 is two unlocks. (That such a
    /// route matches the manual sequence is covered by the route tests above.)
    function test_v3SwapBreaksAV4Chain() public {
        Leg[] memory legs = new Leg[](3);
        legs[0] = Leg(E_V4_01, address(token1), 1e18, false); // -> token0
        legs[1] = Leg(E_V3_01, address(token0), 0, false); // -> token1
        legs[2] = Leg(E_V4_E1, address(token1), 0, true); // -> ETH

        _expectUnlocks(2);
        vm.prank(user);
        proxy.batchSwap(_batchItems(legs));
        _assertNothingParked();
    }

    /// @notice A chained V4 leg spends everything held: credit parked earlier in its unlock AND what an
    /// earlier V3 swap parked in the proxy itself
    function test_v4Chain_spendsCreditAndProxyBalanceTogether() public {
        bytes[] memory swaps = new bytes[](3);
        swaps[0] = _item(E_V3_01, address(token0), 1e18, HERE); // token1 parked in the proxy
        swaps[1] = _item(E_V4_01, address(token0), 1e18, HERE); // token1 parked as V4 credit
        swaps[2] = _item(E_V4_E1, address(token1), Chaining.HELD_BALANCE, recipient); // spends both

        // Reference: both legs to the user, then one leg spending their sum
        uint256 snap = vm.snapshotState();
        vm.startPrank(user);
        uint256 a = proxy.exactInputSingle(
            abi.decode(_slice1(_item(E_V3_01, address(token0), 1e18, user)), (ExactInputSingleParams))
        );
        uint256 b = proxy.exactInputSingleV4(
            abi.decode(_slice1(_item(E_V4_01, address(token0), 1e18, user)), (V4ExactInputSingleParams))
        );
        uint256 c = proxy.exactInputSingleV4(
            abi.decode(_slice1(_item(E_V4_E1, address(token1), a + b, recipient)), (V4ExactInputSingleParams))
        );
        vm.stopPrank();
        vm.revertToState(snap);

        _expectUnlocks(1); // the two V4 swaps chain; the V3 swap needs no unlock
        vm.prank(user);
        uint256[] memory amounts = proxy.batchSwap(swaps);

        assertEq(amounts[0], a, "V3 leg");
        assertEq(amounts[1], b, "first V4 leg");
        assertEq(amounts[2], c, "chained leg did not spend credit + proxy balance");
        _assertNothingParked();
    }

    /// @notice An exact-output V4 leg can open a chain: its exact output is parked as credit and spent
    function test_v4Chain_openedByAnExactOutputLeg() public {
        bytes memory exactOut = abi.encodePacked(
            SwapType.V4_EXACT_OUTPUT,
            abi.encode(
                V4ExactOutputSingleParams({
                    poolKey: cleanKey,
                    zeroForOne: true, // token0 in, exactly 2 token1 out
                    recipient: HERE,
                    deadline: block.timestamp,
                    amountOut: 2e18,
                    amountInMaximum: type(uint128).max,
                    sqrtPriceLimitX96: 0
                })
            )
        );

        uint256 snap = vm.snapshotState();
        vm.startPrank(user);
        V4ExactOutputSingleParams memory direct = abi.decode(_slice1(exactOut), (V4ExactOutputSingleParams));
        direct.recipient = user;
        uint256 paid = proxy.exactOutputSingleV4(direct);
        uint256 out = proxy.exactInputSingleV4(
            abi.decode(_slice1(_item(E_V4_E1, address(token1), 2e18, recipient)), (V4ExactInputSingleParams))
        );
        vm.stopPrank();
        vm.revertToState(snap);

        _expectUnlocks(1);
        vm.prank(user);
        uint256[] memory amounts =
            proxy.batchSwap(_batch(exactOut, _item(E_V4_E1, address(token1), Chaining.HELD_BALANCE, recipient)));

        assertEq(amounts[0], paid, "exact-output leg");
        assertEq(amounts[1], out, "chained leg did not spend exactly the 2 parked token1");
        _assertNothingParked();
    }

    /// @notice A chained leg that stops early leaves credit behind; it is moved into the proxy when the
    /// unlock ends, and the end-of-batch check refuses the batch
    function test_v4Chain_partlySpent_reverts() public {
        // token1 -> ETH with a limit one tick away spends only part of the parked token1
        V4ExactInputSingleParams memory stopsEarly = abi.decode(
            _slice1(_item(E_V4_E1, address(token1), Chaining.HELD_BALANCE, recipient)), (V4ExactInputSingleParams)
        );
        stopsEarly.sqrtPriceLimitX96 = TickMath.getSqrtRatioAtTick(1); // oneForZero pushes the price up

        uint256[8] memory before = _all();
        vm.prank(user);
        vm.expectRevert(bytes("Funds left in proxy"));
        proxy.batchSwap(
            _batch(
                _item(E_V4_01, address(token0), 1e18, HERE),
                abi.encodePacked(SwapType.V4_EXACT_INPUT, abi.encode(stopsEarly))
            )
        );

        uint256[8] memory afterAll = _all();
        for (uint256 i = 0; i < 8; i++) {
            assertEq(afterAll[i], before[i], "a rejected batch moved funds");
        }
    }

    /// @notice Forged chain-format callback data is refused like any other: only the PoolManager may
    /// call `unlockCallback`
    function test_forgedChainCallbackIsRefused() public {
        V4Leg[] memory legs = new V4Leg[](1);
        legs[0] = V4Leg({
            poolKey: cleanKey,
            zeroForOne: true,
            exactInput: true,
            fromHeld: false,
            amount: 1e18,
            bound: 0,
            sqrtPriceLimitX96: 0,
            recipient: makeAddr("attacker")
        });
        bytes memory forged = bytes.concat(bytes1(0x01), abi.encode(V4UnlockData({payer: user, legs: legs})));
        uint256[8] memory before = _all();

        vm.prank(makeAddr("attacker"));
        vm.expectRevert(bytes("Not pool manager"));
        proxy.unlockCallback(forged);

        uint256[8] memory afterAll = _all();
        for (uint256 i = 0; i < 8; i++) {
            assertEq(afterAll[i], before[i], "a forged callback moved funds");
        }
    }

    function _append(bytes[] memory a, bytes memory b) internal pure returns (bytes[] memory out) {
        out = new bytes[](a.length + 1);
        for (uint256 i = 0; i < a.length; i++) {
            out[i] = a[i];
        }
        out[a.length] = b;
    }
}
