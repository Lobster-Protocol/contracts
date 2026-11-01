// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.24;

import {BatchSwapFixture} from "./helpers/BatchSwapFixture.sol";
import {SwapCalldata} from "./helpers/SwapCalldata.sol";
import {SwapFlags} from "../src/libraries/SwapFlags.sol";
import {MintParams} from "../src/interfaces/uniswapV3/IUniswapV3MintCallback.sol";
import {IUniswapV3FactoryMinimal} from "../src/interfaces/uniswapV3/IUniswapV3FactoryMinimal.sol";
import {IUniswapV3PoolMinimal} from "../src/interfaces/uniswapV3/IUniswapV3PoolMinimal.sol";
import {
    PoolKey as ProxyPoolKey,
    Currency as ProxyCurrency,
    IPoolManagerMinimal
} from "../src/interfaces/uniswapV4/IPoolManagerMinimal.sol";
import {TickMath} from "../src/libraries/uniswapV3/TickMath.sol";
import {IProxyErrors} from "../src/interfaces/IProxyErrors.sol";

import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @notice An ERC20 that, the first time it is moved while armed, runs an arbitrary call and either
/// bubbles its revert or records it. The hook fires on `transfer`, on `transferFrom`, or both, so it
/// can stand in for a malicious input token (paid with `transferFrom`) or a malicious output token
/// (delivered with `transfer`). It is created disarmed, so the fixture can seed pools and liquidity
/// with it before any test arms it.
/// @dev Mirrors the old suite's `ReentrantERC20`, generalised to attack the PoolManager (settle, take,
/// sync) from inside a swap the proxy is driving.
contract HostileToken is MockERC20 {
    address public callee;
    bytes public payload;
    bool public armed;
    bool public onTransfer;
    bool public onTransferFrom;
    bool public bubble;
    uint256 public fires;
    bool public attackSucceeded;
    bytes public attackReturn;

    constructor() MockERC20("Hostile", "EVIL", 18) {}

    /// @param _bubble true: the attack's revert is re-thrown (so the whole swap aborts at the hook);
    /// false: it is swallowed and recorded, so the swap runs on and must be caught by a later invariant
    function arm(
        address _callee,
        bytes calldata _payload,
        bool _onTransfer,
        bool _onTransferFrom,
        bool _bubble
    )
        external
    {
        callee = _callee;
        payload = _payload;
        onTransfer = _onTransfer;
        onTransferFrom = _onTransferFrom;
        bubble = _bubble;
        armed = true;
    }

    function _fire() private {
        armed = false; // once per call
        fires++;
        (bool ok, bytes memory ret) = callee.call(payload);
        attackSucceeded = ok;
        attackReturn = ret;
        if (bubble && !ok) {
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (armed && onTransfer) _fire();
        return super.transfer(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (armed && onTransferFrom) _fire();
        return super.transferFrom(from, to, amount);
    }
}

/// @notice A plain contract that calls the proxy's `uniswapV3SwapCallback` directly, to prove the
/// callback refuses anyone who is not the pool the proxy is mid-swap with.
contract CallbackIntruder {
    function fakeV3Callback(address proxy, int256 a0, int256 a1, bytes calldata data) external {
        IProxyErrorsCallback(proxy).uniswapV3SwapCallback(a0, a1, data);
    }
}

interface IProxyErrorsCallback {
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external;
}

/// @notice Adversarial suite for the mechanisms the swap-engine rewrite introduced: the one-unlock
/// hand-off of V3 outputs to the PoolManager (sync/settle/take), the memory ledger and its
/// end-of-call zero check, the packed-calldata validation, native-ETH accounting, the callback
/// guards and the transient lock. Built on the five-pool graph of {LobsterProxyGasTest}, plus a
/// hostile token with a V3 and a V4 pool against token1 for the settle-hijack cases.
///
/// Route graph (five pools, both versions, native ETH in the middle):
///   token0 --V3--  token1 --V3--  tokenC
///   token0 --V4--  token1 --V4--  ETH  --V4--  tokenC
/// plus:  evil --V3-- token1   and   evil --V4-- token1
contract LobsterSwapEngineTest is BatchSwapFixture {
    using SafeCast for uint256;

    uint8 constant E_V3_01 = 0;
    uint8 constant E_V3_1C = 1;
    uint8 constant E_V4_01 = 2;
    uint8 constant E_V4_E1 = 3;
    uint8 constant E_V4_EC = 4;
    address constant ETH = address(0);

    MockERC20 tokenC;
    ProxyPoolKey nativeKeyC; // ETH / tokenC, no hook

    HostileToken evil;
    IUniswapV3PoolMinimal evilV3Pool; // evil / token1
    ProxyPoolKey evilV4Key; // evil / token1, no hook

    address attacker = makeAddr("attacker");
    address outsider = makeAddr("outsider");

    function setUp() public override {
        super.setUp();

        // --- The third token and the two pools that complete the five-pool graph
        tokenC = new MockERC20("Token C", "TKC", 18);
        tokenC.mint(address(this), 100_000e18);
        tokenC.approve(address(proxy), type(uint256).max);
        tokenC.approve(address(lpRouter), type(uint256).max);
        IUniswapV3FactoryMinimal(v3Factory).createPool(address(token1), address(tokenC), FEE);
        _v3PoolFor(address(token1), address(tokenC)).initialize(SQRT_PRICE_1_1);
        _mintV3(address(token1), address(tokenC));
        PoolKey memory kc = _v4CoreKey(ETH, address(tokenC));
        manager.initialize(kc, SQRT_PRICE_1_1);
        _addV4Liquidity(kc, 10_000e18);
        nativeKeyC = _toProxyKey(kc);

        tokenC.mint(user, 10_000e18);
        vm.prank(user);
        tokenC.approve(address(proxy), type(uint256).max);
        _allow(user, proxy.v3Key(address(_v3PoolFor(address(token1), address(tokenC)))), SWAP);
        _allow(user, proxy.v4Key(nativeKeyC), SWAP);

        // --- A hostile token, with a V3 and a V4 pool against token1 (both created while disarmed)
        evil = new HostileToken();
        evil.mint(address(this), 100_000e18);
        evil.mint(address(evil), 10e18); // so a hook can push a stray wei into the PoolManager
        evil.approve(address(proxy), type(uint256).max);
        evil.approve(address(lpRouter), type(uint256).max);

        IUniswapV3FactoryMinimal(v3Factory).createPool(address(evil), address(token1), FEE);
        evilV3Pool = _v3PoolFor(address(evil), address(token1));
        evilV3Pool.initialize(SQRT_PRICE_1_1);
        _mintV3(address(evil), address(token1));

        PoolKey memory ke = _v4CoreKey(_lo(address(evil), address(token1)), _hi(address(evil), address(token1)));
        manager.initialize(ke, SQRT_PRICE_1_1);
        _addV4Liquidity(ke, 0);
        evilV4Key = _toProxyKey(ke);

        evil.mint(user, 10_000e18);
        vm.prank(user);
        evil.approve(address(proxy), type(uint256).max);
        _allow(user, proxy.v3Key(address(evilV3Pool)), SWAP);
        _allow(user, proxy.v4Key(evilV4Key), SWAP);
    }

    // ---------------------------------------------------------------------------------------------
    // Shared helpers
    // ---------------------------------------------------------------------------------------------

    function _lo(address a, address b) internal pure returns (address) {
        return a < b ? a : b;
    }

    function _hi(address a, address b) internal pure returns (address) {
        return a < b ? b : a;
    }

    function _v3PoolFor(address a, address b) internal view returns (IUniswapV3PoolMinimal) {
        return IUniswapV3PoolMinimal(IUniswapV3FactoryMinimal(v3Factory).getPool(a, b, FEE));
    }

    /// @dev Wide V3 liquidity (1000 of each), paid by this contract, registering the pool for itself
    function _mintV3(address a, address b) internal {
        (address t0, address t1) = a < b ? (a, b) : (b, a);
        _allow(address(this), proxy.v3Key(address(_v3PoolFor(a, b))), MINT);
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

    /// @dev Every token the engine could move, for user / proxy / attacker / outsider
    function _snapshot() internal view returns (uint256[16] memory h) {
        h[0] = token0.balanceOf(user);
        h[1] = token1.balanceOf(user);
        h[2] = tokenC.balanceOf(user);
        h[3] = evil.balanceOf(user);
        h[4] = user.balance;
        h[5] = token0.balanceOf(address(proxy));
        h[6] = token1.balanceOf(address(proxy));
        h[7] = tokenC.balanceOf(address(proxy));
        h[8] = evil.balanceOf(address(proxy));
        h[9] = address(proxy).balance;
        h[10] = token1.balanceOf(attacker);
        h[11] = evil.balanceOf(attacker);
        h[12] = attacker.balance;
        h[13] = token0.balanceOf(outsider);
        h[14] = token1.balanceOf(outsider);
        h[15] = evil.balanceOf(outsider);
    }

    function _assertSnapshotEq(uint256[16] memory a, uint256[16] memory b, string memory ctx) internal pure {
        for (uint256 i = 0; i < 16; i++) {
            assertEq(a[i], b[i], string.concat(ctx, ": tracked balance ", vm.toString(i), " moved"));
        }
    }

    function _assertProxyEmpty() internal view {
        assertEq(token0.balanceOf(address(proxy)), 0, "proxy retained token0");
        assertEq(token1.balanceOf(address(proxy)), 0, "proxy retained token1");
        assertEq(tokenC.balanceOf(address(proxy)), 0, "proxy retained tokenC");
        assertEq(evil.balanceOf(address(proxy)), 0, "proxy retained evil");
        assertEq(address(proxy).balance, 0, "proxy retained ETH");
    }

    /// @dev `swap(encode(now, legs))` as a low-level call by `who`, so the caller sees the raw revert
    function _trySwap(address who, SwapCalldata.Leg[] memory legs) internal returns (bool ok, bytes memory ret) {
        vm.prank(who);
        (ok, ret) = address(proxy).call(SwapCalldata.call(block.timestamp, legs));
    }

    function _trySwapValue(
        address who,
        SwapCalldata.Leg[] memory legs,
        uint256 value
    )
        internal
        returns (bool ok, bytes memory ret)
    {
        vm.prank(who);
        (ok, ret) = address(proxy).call{value: value}(SwapCalldata.call(block.timestamp, legs));
    }

    function _selector(bytes memory ret) internal pure returns (bytes4 sel) {
        if (ret.length >= 4) sel = bytes4(ret);
    }

    /// @dev A V3 leg over an arbitrary pool (the fixture's `_v3In` hardwires FEE, which is fine here)
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

    function _evilLtToken1() internal view returns (bool) {
        return address(evil) < address(token1);
    }

    /// @dev Asserts `ret` is a revert whose selector is `a` or `b`
    function _assertRevertedWithEither(bytes memory ret, bytes4 a, bytes4 b, string memory ctx) internal pure {
        bytes4 sel = _selector(ret);
        assertTrue(sel == a || sel == b, string.concat(ctx, ": unexpected revert selector 0x", vm.toString(sel)));
    }

    // ---------------------------------------------------------------------------------------------
    // 1. The settle-hijack regression: a malicious V3 INPUT token in a [V3 X->T PARK][V4 T->.. HELD]
    //    route. T is handed to the PoolManager and settled at the start of the V3 callback; the input
    //    X is then paid, and X's transferFrom hook tries to claim funds out of the PoolManager. The
    //    manager accounts every take/settle to msg.sender (here the token), so the hook cannot extract
    //    anything without leaving an unsettled delta that aborts the whole unlock.
    // ---------------------------------------------------------------------------------------------

    /// @dev Builds the victim route and runs it with `evil` (the V3 input) armed to call the manager
    /// with `payload` from inside its transferFrom; asserts the whole swap reverts and nothing moved.
    function _runInputHijack(bytes memory payload, string memory ctx) internal {
        // [V3 evil->token1 PARK]  then  [V4 token1->token0 HELD]
        SwapCalldata.Leg memory leg0 = _v3In(address(evil), address(token1), 1e18, 0);
        leg0.park = true;
        SwapCalldata.Leg memory leg1 = _v4In(cleanKey, false, 0, 0); // token1 -> token0
        leg1.held = true;

        evil.arm(address(manager), payload, false, true, false); // record, do not bubble
        uint256[16] memory before = _snapshot();

        (bool ok, bytes memory ret) = _trySwap(user, _legs(leg0, leg1));

        assertFalse(ok, string.concat(ctx, ": the hijack call did not revert"));
        _assertRevertedWithEither(
            ret, IProxyErrors.UnexpectedSettlement.selector, IPoolManager.CurrencyNotSettled.selector, ctx
        );
        _assertSnapshotEq(_snapshot(), before, ctx);
    }

    /// @notice A malicious V3 input token that tries to `take` the V3 output already handed to the
    /// PoolManager reverts the whole call: the take is booked against the token, not the proxy, so the
    /// unlock ends with an unsettled delta.
    function test_settleHijack_inputTokenTakesParkedOutput_reverts() public {
        bytes memory payload =
            abi.encodeWithSignature("take(address,address,uint256)", address(token1), attacker, uint256(1));
        _runInputHijack(payload, "input hijack: take parked output");
    }

    /// @notice The same defense holds for any currency the hook tries to drain, not just the parked one.
    function test_settleHijack_inputTokenTakesOtherCurrency_reverts() public {
        bytes memory payload =
            abi.encodeWithSignature("take(address,address,uint256)", address(evil), attacker, uint256(1));
        _runInputHijack(payload, "input hijack: take input currency");
    }

    /// @notice A hook that drains a third, unrelated currency from the PoolManager still cannot net
    /// out: its own delta is left unsettled and the unlock aborts.
    function test_settleHijack_inputTokenTakesUnrelatedCurrency_reverts() public {
        bytes memory payload =
            abi.encodeWithSignature("take(address,address,uint256)", address(token0), attacker, uint256(1));
        _runInputHijack(payload, "input hijack: take token0");
    }

    // ---------------------------------------------------------------------------------------------
    // 2. The same hijack through a malicious OUTPUT token of a V3->PoolManager hand-off, and through
    //    the sync->transfer->settle window of a V4 ERC20 payment. Here the hook runs BEFORE the proxy
    //    settles, so it corrupts the settled amount: the `require(_settle() == amountOut)` guard
    //    (UnexpectedSettlement) catches it, with CurrencyNotSettled as the backstop.
    // ---------------------------------------------------------------------------------------------

    /// @dev [V3 token1->evil PARK][V4 evil->token1 HELD]: evil is produced by the V3 leg and sent to
    /// the PoolManager; evil's transfer hook runs in the proxy's sync->settle window.
    function _runOutputHijack(bytes memory payload, address callee, string memory ctx) internal {
        SwapCalldata.Leg memory leg0 = _v3In(address(token1), address(evil), 1e18, 0);
        leg0.park = true;
        SwapCalldata.Leg memory leg1 = _v4In(evilV4Key, _evilLtToken1(), 0, 0); // evil -> token1
        leg1.held = true;

        evil.arm(callee, payload, true, false, false); // fire on transfer (output delivery)
        uint256[16] memory before = _snapshot();

        (bool ok, bytes memory ret) = _trySwap(user, _legs(leg0, leg1));

        assertFalse(ok, string.concat(ctx, ": the hijack call did not revert"));
        _assertRevertedWithEither(
            ret, IProxyErrors.UnexpectedSettlement.selector, IPoolManager.CurrencyNotSettled.selector, ctx
        );
        _assertSnapshotEq(_snapshot(), before, ctx);
    }

    /// @notice A malicious V3 output token that settles its own arrival before the proxy does breaks
    /// the proxy's settlement check: the call reverts and nothing moves.
    function test_settleHijack_outputTokenSettlesEarly_reverts() public {
        _runOutputHijack(abi.encodeWithSignature("settle()"), address(manager), "output hijack: early settle");
    }

    /// @notice A malicious V3 output token that takes part of its own just-delivered amount back out of
    /// the PoolManager reverts the call.
    function test_settleHijack_outputTokenTakesItself_reverts() public {
        bytes memory payload =
            abi.encodeWithSignature("take(address,address,uint256)", address(evil), attacker, uint256(1));
        _runOutputHijack(payload, address(manager), "output hijack: take");
    }

    /// @notice A malicious V3 output token that sends one extra wei to the PoolManager so the settled
    /// amount overshoots what the pool reported reverts the call.
    function test_settleHijack_outputTokenSendsOneWeiBack_reverts() public {
        bytes memory payload = abi.encodeWithSignature("transfer(address,uint256)", address(manager), uint256(1));
        _runOutputHijack(payload, address(evil), "output hijack: one wei back");
    }

    /// @notice A malicious V3 output token that re-syncs another currency in the proxy's settle window
    /// reverts the call.
    function test_settleHijack_outputTokenResyncsAnotherCurrency_reverts() public {
        bytes memory payload = abi.encodeWithSignature("sync(address)", address(token0));
        _runOutputHijack(payload, address(manager), "output hijack: re-sync");
    }

    /// @notice The sync->transfer->settle window of a V4 ERC20 input is guarded the same way: a
    /// malicious input token that settles early (before it has paid) makes the V4 payment's settlement
    /// mismatch, and the call reverts.
    function test_settleHijack_v4InputSettlesEarly_reverts() public {
        SwapCalldata.Leg memory leg = _v4In(evilV4Key, _evilLtToken1(), _u128(1e18), 0); // evil -> token1

        evil.arm(address(manager), abi.encodeWithSignature("settle()"), false, true, false);
        uint256[16] memory before = _snapshot();

        (bool ok, bytes memory ret) = _trySwap(user, _legs(leg));

        assertFalse(ok, "v4 input hijack: the hijack call did not revert");
        _assertRevertedWithEither(
            ret,
            IProxyErrors.UnexpectedSettlement.selector,
            IPoolManager.CurrencyNotSettled.selector,
            "v4 input hijack: early settle"
        );
        _assertSnapshotEq(_snapshot(), before, "v4 input hijack: early settle");
    }

    /// @notice A V4 ERC20 input token that drains an unrelated currency during its payment reverts.
    function test_settleHijack_v4InputTakesOtherCurrency_reverts() public {
        SwapCalldata.Leg memory leg = _v4In(evilV4Key, _evilLtToken1(), _u128(1e18), 0);

        bytes memory payload =
            abi.encodeWithSignature("take(address,address,uint256)", address(token1), attacker, uint256(1));
        evil.arm(address(manager), payload, false, true, false);
        uint256[16] memory before = _snapshot();

        (bool ok, bytes memory ret) = _trySwap(user, _legs(leg));

        assertFalse(ok, "v4 input hijack: take did not revert");
        _assertRevertedWithEither(
            ret,
            IProxyErrors.UnexpectedSettlement.selector,
            IPoolManager.CurrencyNotSettled.selector,
            "v4 input hijack: take"
        );
        _assertSnapshotEq(_snapshot(), before, "v4 input hijack: take");
    }

    // ---------------------------------------------------------------------------------------------
    // Raw-calldata helpers for hand-crafting malformed `data`
    // ---------------------------------------------------------------------------------------------

    function _rawCall(bytes memory data) internal pure returns (bytes memory) {
        return abi.encodeWithSignature("swap(bytes)", data);
    }

    function _trySwapRaw(address who, bytes memory data) internal returns (bool ok, bytes memory ret) {
        vm.prank(who);
        (ok, ret) = address(proxy).call(_rawCall(data));
    }

    function _header(uint32 deadline, uint8 tokenCount) internal pure returns (bytes memory) {
        return bytes.concat(bytes4(deadline), bytes1(tokenCount));
    }

    /// @dev A full V3 exact-input leg, raw (flags | in | out | fee | amount | bound)
    function _v3LegBytes(
        uint8 flags,
        uint8 inIdx,
        uint8 outIdx,
        uint128 amount,
        uint128 bound
    )
        internal
        pure
        returns (bytes memory)
    {
        return bytes.concat(bytes1(flags), bytes1(inIdx), bytes1(outIdx), bytes3(FEE), bytes16(amount), bytes16(bound));
    }

    function _assertMalformed(bytes memory data, string memory ctx) internal {
        uint256[16] memory before = _snapshot();
        (bool ok, bytes memory ret) = _trySwapRaw(user, data);
        assertFalse(ok, string.concat(ctx, ": accepted malformed data"));
        assertEq(_selector(ret), IProxyErrors.MalformedSwap.selector, string.concat(ctx, ": not MalformedSwap"));
        _assertSnapshotEq(_snapshot(), before, ctx);
    }

    // ---------------------------------------------------------------------------------------------
    // 3. Validation runs before execution: a later leg that is unregistered, has no band, or is
    //    malformed makes the whole call revert without opening the unlock, calling any pool, or
    //    moving a single balance.
    // ---------------------------------------------------------------------------------------------

    function _expectNoExecution() internal {
        vm.expectCall(address(manager), abi.encodeWithSelector(IPoolManagerMinimal.unlock.selector), 0);
        vm.expectCall(address(v3Pool), abi.encodeWithSelector(IUniswapV3PoolMinimal.swap.selector), 0);
    }

    /// @notice A valid V3 leg followed by a V4 leg on a pool the caller never registered: the call
    /// reverts in validation (PoolNotAllowed) with no unlock, no V3 swap and no balance change.
    function test_validation_laterLegUnregistered_nothingRuns() public {
        bytes32[] memory keys = new bytes32[](1);
        keys[0] = proxy.v4Key(cleanKey);
        uint8[] memory perms = new uint8[](1);
        perms[0] = 0;
        vm.prank(user);
        proxy.setPools(keys, perms); // unregister the V4 token0/token1 pool for the user

        SwapCalldata.Leg memory leg0 = _v3In(address(token0), address(token1), 1e18, 0);
        SwapCalldata.Leg memory leg1 = _v4In(cleanKey, true, _u128(1e18), 0); // token0 -> token1, V4
        uint256[16] memory before = _snapshot();

        _expectNoExecution();
        (bool ok, bytes memory ret) = _trySwap(user, _legs(leg0, leg1));

        assertFalse(ok, "unregistered later leg: did not revert");
        assertEq(_selector(ret), IProxyErrors.PoolNotAllowed.selector, "unregistered later leg: wrong error");
        _assertSnapshotEq(_snapshot(), before, "unregistered later leg");
    }

    /// @notice A later V4 leg whose pool has had its price band cleared reverts in validation
    /// (PriceBandNotSet): nothing runs, nothing moves.
    function test_validation_laterLegBandUnset_nothingRuns() public {
        bytes32 cleanV4Key = proxy.v4Key(cleanKey);
        vm.prank(user);
        proxy.setPriceBand(cleanV4Key, 0, 0); // clear the band but keep the permission

        SwapCalldata.Leg memory leg0 = _v3In(address(token0), address(token1), 1e18, 0);
        SwapCalldata.Leg memory leg1 = _v4In(cleanKey, true, _u128(1e18), 0);
        uint256[16] memory before = _snapshot();

        _expectNoExecution();
        (bool ok, bytes memory ret) = _trySwap(user, _legs(leg0, leg1));

        assertFalse(ok, "band unset later leg: did not revert");
        assertEq(_selector(ret), IProxyErrors.PriceBandNotSet.selector, "band unset later leg: wrong error");
        _assertSnapshotEq(_snapshot(), before, "band unset later leg");
    }

    /// @notice A valid V3 leg followed by malformed trailing bytes reverts in validation
    /// (MalformedSwap): no unlock, no V3 swap, no balance change.
    function test_validation_laterLegMalformed_nothingRuns() public {
        bytes memory good =
            SwapCalldata.encode(block.timestamp, _legs(_v3In(address(token0), address(token1), 1e18, 0)));
        bytes memory data = bytes.concat(good, bytes1(0x00)); // one trailing byte: not a leg boundary
        uint256[16] memory before = _snapshot();

        _expectNoExecution();
        (bool ok, bytes memory ret) = _trySwapRaw(user, data);

        assertFalse(ok, "malformed trailing byte: did not revert");
        assertEq(_selector(ret), IProxyErrors.MalformedSwap.selector, "malformed trailing byte: wrong error");
        _assertSnapshotEq(_snapshot(), before, "malformed trailing byte");
    }

    // ---------------------------------------------------------------------------------------------
    // 4. MalformedSwap: one case per validation rule in the SwapFlags NatSpec, plus a byte-mutation
    //    fuzz over a valid encoded call.
    // ---------------------------------------------------------------------------------------------

    /// @notice Every structural rule in the SwapFlags NatSpec rejects with MalformedSwap.
    function test_malformed_everyRuleReverts() public {
        // Rule: data is longer than the header (there is at least a token table and a leg)
        _assertMalformed(bytes(""), "empty data");
        _assertMalformed(_header(uint32(block.timestamp), 0), "header only");

        // Rule: the token table fits in the data
        _assertMalformed(
            bytes.concat(_header(uint32(block.timestamp), 5), hex"00112233445566778899"), "token table does not fit"
        );

        // Rule: there is at least one leg (data must extend past the token table)
        _assertMalformed(
            bytes.concat(_header(uint32(block.timestamp), 2), bytes20(address(token0)), bytes20(address(token1))),
            "no legs"
        );

        bytes memory table =
            bytes.concat(_header(uint32(block.timestamp), 2), bytes20(address(token0)), bytes20(address(token1)));

        // Rule: no unknown flag bit is set (0x20 is outside SwapFlags.ALL)
        _assertMalformed(bytes.concat(table, _v3LegBytes(0x20, 0, 1, 1e18, 0)), "unknown flag bit");

        // Rule: HELD is only valid with exact input (HELD | EXACT_OUT is rejected)
        _assertMalformed(
            bytes.concat(
                table,
                bytes.concat(
                    bytes1(SwapFlags.HELD | SwapFlags.EXACT_OUT),
                    bytes1(uint8(0)),
                    bytes1(uint8(1)),
                    bytes3(FEE),
                    bytes16(uint128(0))
                )
            ),
            "HELD with EXACT_OUT"
        );

        // Rule: token indices are inside the table
        _assertMalformed(bytes.concat(table, _v3LegBytes(0, 5, 1, 1e18, 0)), "tokenIn index out of range");
        _assertMalformed(bytes.concat(table, _v3LegBytes(0, 0, 5, 1e18, 0)), "tokenOut index out of range");

        // Rule: a leg's two tokens differ
        _assertMalformed(bytes.concat(table, _v3LegBytes(0, 0, 0, 1e18, 0)), "tokenIn == tokenOut");

        // Rule: a V3 leg names no native ETH (address(0))
        bytes memory ethTable =
            bytes.concat(_header(uint32(block.timestamp), 2), bytes20(address(0)), bytes20(address(token1)));
        _assertMalformed(bytes.concat(ethTable, _v3LegBytes(0, 0, 1, 1e18, 0)), "V3 leg on native ETH");

        // Rule: a PRICE_LIMIT, when flagged, is non-zero
        _assertMalformed(
            bytes.concat(table, bytes.concat(_v3LegBytes(SwapFlags.PRICE_LIMIT, 0, 1, 1e18, 0), bytes20(uint160(0)))),
            "zero price limit"
        );

        // Rule: every leg fits (a V3 leg needs 38 bytes; give it 10)
        _assertMalformed(bytes.concat(table, hex"00000100000000000000"), "truncated leg");

        // Rule: data ends exactly at a leg boundary (one trailing byte)
        _assertMalformed(bytes.concat(table, _v3LegBytes(0, 0, 1, 1e18, 0), bytes1(0x00)), "trailing byte");
    }

    /// @notice Mutating any single byte of a valid encoded `swap` call either reverts or, if it still
    /// executes, only ever moves the caller's own balances: the proxy ends empty and no outsider or
    /// attacker balance changes.
    function testFuzz_mutatedValidCall_neverLeaksOutsideCaller(uint256 seed) public {
        bytes memory data =
            SwapCalldata.encode(block.timestamp, _legs(_v3In(address(token0), address(token1), 1e18, 0)));
        uint256 index = bound(seed, 0, data.length - 1);
        uint8 delta = uint8(1 + (seed >> 8) % 255);
        data[index] = bytes1(uint8(data[index]) ^ delta); // guaranteed to differ

        uint256 outsiderT0 = token0.balanceOf(outsider);
        uint256 outsiderT1 = token1.balanceOf(outsider);
        uint256 attackerT0 = token0.balanceOf(attacker);
        uint256 attackerT1 = token1.balanceOf(attacker);

        _trySwapRaw(user, data); // may or may not revert; either way must not leak

        assertEq(token0.balanceOf(outsider), outsiderT0, "mutation leaked token0 to an outsider");
        assertEq(token1.balanceOf(outsider), outsiderT1, "mutation leaked token1 to an outsider");
        assertEq(token0.balanceOf(attacker), attackerT0, "mutation leaked token0 to the attacker");
        assertEq(token1.balanceOf(attacker), attackerT1, "mutation leaked token1 to the attacker");
        _assertProxyEmpty();
    }

    // ---------------------------------------------------------------------------------------------
    // 5. Ledger invariants: after any successful call the proxy holds nothing, and a V3 output routed
    //    to the PoolManager (TO_MANAGER) never passes through the proxy mid-call.
    // ---------------------------------------------------------------------------------------------

    function _edgeTokens(uint8 edge) internal view returns (address, address) {
        if (edge == E_V3_01 || edge == E_V4_01) return (address(token0), address(token1));
        if (edge == E_V3_1C) return (address(token1), address(tokenC));
        if (edge == E_V4_E1) return (ETH, address(token1));
        return (ETH, address(tokenC)); // E_V4_EC
    }

    function _otherSide(uint8 edge, address tokenIn) internal view returns (address) {
        (address a, address b) = _edgeTokens(edge);
        return tokenIn == a ? b : a;
    }

    function _isV4Edge(uint8 edge) internal pure returns (bool) {
        return edge == E_V4_01 || edge == E_V4_E1 || edge == E_V4_EC;
    }

    function _incidentEdges(address token) internal view returns (uint8[] memory edges) {
        if (token == address(token0)) {
            edges = new uint8[](2);
            (edges[0], edges[1]) = (E_V3_01, E_V4_01);
        } else if (token == address(token1)) {
            edges = new uint8[](4);
            (edges[0], edges[1], edges[2], edges[3]) = (E_V3_01, E_V3_1C, E_V4_01, E_V4_E1);
        } else if (token == address(tokenC)) {
            edges = new uint8[](2);
            (edges[0], edges[1]) = (E_V3_1C, E_V4_EC);
        } else {
            edges = new uint8[](2); // ETH
            (edges[0], edges[1]) = (E_V4_E1, E_V4_EC);
        }
    }

    function _mkLeg(
        uint8 edge,
        address tokenIn,
        bool exactOut,
        bool park,
        bool held,
        uint128 amount,
        uint128 bound_
    )
        internal
        view
        returns (SwapCalldata.Leg memory leg)
    {
        leg.v4 = _isV4Edge(edge);
        leg.exactOut = exactOut;
        leg.park = park;
        leg.held = held;
        leg.tokenIn = tokenIn;
        leg.tokenOut = _otherSide(edge, tokenIn);
        leg.fee = FEE;
        if (leg.v4) leg.tickSpacing = TICK_SPACING;
        if (!held) leg.amount = amount;
        leg.bound = bound_;
    }

    /// @dev A random connected walk of 1-4 hops over the five-pool graph, starting from an ERC20 so no
    /// native input is needed. Intermediate outputs are parked and spent by the next HELD leg, so the
    /// route mixes PARK, HELD and (on its first leg) exact output.
    function _randomRoute(uint256 seed) internal view returns (SwapCalldata.Leg[] memory legs) {
        uint256 hops = bound(seed, 1, 4);
        address[3] memory starts = [address(token0), address(token1), address(tokenC)];
        address cur = starts[bound(seed >> 3, 0, 2)];
        bool exactOutFirst = (seed >> 5) & 1 == 1;

        legs = new SwapCalldata.Leg[](hops);
        for (uint256 i = 0; i < hops; i++) {
            uint8[] memory inc = _incidentEdges(cur);
            uint8 edge = inc[uint256(keccak256(abi.encode(seed, i, "e"))) % inc.length];
            bool isFirst = i == 0;
            bool isLast = i == hops - 1;
            bool held = !isFirst;
            bool park = !isLast;
            bool exactOut = isFirst && exactOutFirst;
            uint128 amount;
            uint128 bound_;
            if (!held) {
                amount = uint128(
                    bound(uint256(keccak256(abi.encode(seed, i, "a"))), 1e6, exactOut ? uint256(1e18) : uint256(5e18))
                );
                bound_ = exactOut ? type(uint128).max : 0;
            }
            legs[i] = _mkLeg(edge, cur, exactOut, park, held, amount, bound_);
            cur = _otherSide(edge, cur);
        }
    }

    /// @notice Any successful route over the five-pool graph leaves the proxy holding zero of every
    /// token and zero ETH, and never touches an outsider or the attacker.
    function testFuzz_ledger_proxyEndsEmptyAfterAnyRoute(uint256 seed) public {
        SwapCalldata.Leg[] memory legs = _randomRoute(seed);

        uint256[16] memory before = _snapshot();
        (bool ok,) = _trySwap(user, legs);

        assertTrue(ok, "a valid route over the graph reverted");
        _assertProxyEmpty();
        // user is the only account that may have moved; everyone else is untouched
        assertEq(token1.balanceOf(attacker), before[10], "route touched the attacker (token1)");
        assertEq(evil.balanceOf(attacker), before[11], "route touched the attacker (evil)");
        assertEq(attacker.balance, before[12], "route touched the attacker (ETH)");
        assertEq(token0.balanceOf(outsider), before[13], "route touched an outsider (token0)");
        assertEq(token1.balanceOf(outsider), before[14], "route touched an outsider (token1)");
    }

    /// @notice A V3 output consumed by a later V4 leg is paid straight to the PoolManager: it is never
    /// transferred to the proxy, so TO_MANAGER routing leaves nothing in the proxy mid-call.
    function test_ledger_toManagerOutputNeverEntersProxy() public {
        // [V3 token1->evil PARK] (evil handed to the PoolManager) [V4 evil->token1 HELD]
        SwapCalldata.Leg memory leg0 = _v3In(address(token1), address(evil), 1e18, 0);
        leg0.park = true;
        SwapCalldata.Leg memory leg1 = _v4In(evilV4Key, _evilLtToken1(), 0, 0); // evil -> token1
        leg1.held = true;

        // evil is never transferred into the proxy: the pool pays it to the PoolManager, and the V4
        // leg spends it from PoolManager credit (no transfer at all)
        vm.expectCall(address(evil), abi.encodeWithSelector(HostileToken.transfer.selector, address(proxy)), 0);
        vm.expectCall(address(evil), abi.encodeWithSelector(HostileToken.transferFrom.selector, address(proxy)), 0);

        (bool ok,) = _trySwap(user, _legs(leg0, leg1));
        assertTrue(ok, "TO_MANAGER route reverted");
        _assertProxyEmpty();
    }

    /// @notice The flip side of the ledger invariant: a leg that parks an output nothing later spends
    /// reverts FundsLeftInProxy, and nothing moves. (Replaces the old `batchSwap` FundsLeftInProxy test
    /// on the single-call API.)
    function test_ledger_parkedButUnspent_revertsFundsLeftInProxy() public {
        SwapCalldata.Leg memory leg = _v3In(address(token0), address(token1), 1e18, 0);
        leg.park = true; // parked, and no later leg spends it

        uint256[16] memory before = _snapshot();
        (bool ok, bytes memory ret) = _trySwap(user, _legs(leg));

        assertFalse(ok, "parked-but-unspent did not revert");
        assertEq(_selector(ret), IProxyErrors.FundsLeftInProxy.selector, "wrong error for parked-but-unspent");
        _assertSnapshotEq(_snapshot(), before, "parked-but-unspent");
    }

    /// @notice A HELD leg with nothing parked of its input reverts NothingHeld (the HELD_BALANCE magic
    /// value's successor), moving nothing.
    function test_ledger_heldWithNothingParked_revertsNothingHeld() public {
        SwapCalldata.Leg memory leg = _v3In(address(token1), address(tokenC), 0, 0);
        leg.held = true; // spends what the call parked of token1 - but nothing is parked

        uint256[16] memory before = _snapshot();
        (bool ok, bytes memory ret) = _trySwap(user, _legs(leg));

        assertFalse(ok, "HELD with nothing parked did not revert");
        assertEq(_selector(ret), IProxyErrors.NothingHeld.selector, "wrong error for HELD with nothing parked");
        _assertSnapshotEq(_snapshot(), before, "HELD with nothing parked");
    }

    // ---------------------------------------------------------------------------------------------
    // 6. Zero-amount guards in the V3 HELD callback: credit covers it -> no proxy transfer; the
    //    proxy's own balance covers it -> no PoolManager take.
    // ---------------------------------------------------------------------------------------------

    /// @notice A HELD V3 leg whose input is fully covered by PoolManager credit pays with a single
    /// `take` and makes no transfer of its own: the only token1 transfer in the call is the take.
    function test_zeroGuard_heldV3FromCredit_makesNoProxyTransfer() public {
        // [V4 token0->token1 PARK] parks token1 as PoolManager credit; [V3 token1->token0 HELD] spends it
        SwapCalldata.Leg memory leg0 = _v4In(cleanKey, true, _u128(1e18), 0); // token0 -> token1
        leg0.park = true;
        SwapCalldata.Leg memory leg1 = _v3In(address(token1), address(token0), 0, 0); // token1 -> token0
        leg1.held = true;

        // Exactly one take (the HELD input, paid from credit) and exactly one token1 transfer (that
        // take's own transfer out of the PoolManager): the proxy never transfers token1 itself.
        vm.expectCall(address(manager), abi.encodeWithSelector(IPoolManagerMinimal.take.selector), 1);
        vm.expectCall(address(token1), abi.encodeWithSelector(token1.transfer.selector), 1);

        (bool ok,) = _trySwap(user, _legs(leg0, leg1));
        assertTrue(ok, "credit-covered HELD V3 leg reverted");
        _assertProxyEmpty();
    }

    /// @notice A HELD V3 leg whose input sits in the proxy (parked by an earlier V3 leg) pays with a
    /// plain transfer and makes no PoolManager take at all.
    function test_zeroGuard_heldV3FromProxy_makesNoTake() public {
        // [V3 token0->token1 PARK] keeps token1 in the proxy (next consumer is V3); [V3 token1->token0 HELD]
        SwapCalldata.Leg memory leg0 = _v3In(address(token0), address(token1), 1e18, 0);
        leg0.park = true;
        SwapCalldata.Leg memory leg1 = _v3In(address(token1), address(token0), 0, 0);
        leg1.held = true;

        // No V4 leg -> no unlock -> no PoolManager take anywhere in the call
        vm.expectCall(address(manager), abi.encodeWithSelector(IPoolManagerMinimal.take.selector), 0);

        (bool ok,) = _trySwap(user, _legs(leg0, leg1));
        assertTrue(ok, "proxy-covered HELD V3 leg reverted");
        _assertProxyEmpty();
    }

    // ---------------------------------------------------------------------------------------------
    // 7. Native ETH accounting (the entry point is payable).
    // ---------------------------------------------------------------------------------------------

    /// @notice A native-input V4 leg spends exactly its input from msg.value and refunds the rest to
    /// the caller.
    function test_native_inputSpendsMsgValueAndRefundsTheRest() public {
        SwapCalldata.Leg memory leg = _v4In(nativeKey, true, _u128(1e18), 0); // ETH -> token1
        uint256 ethBefore = user.balance;
        uint256 t1Before = token1.balanceOf(user);

        (bool ok,) = _trySwapValue(user, _legs(leg), 2e18);

        assertTrue(ok, "native input swap reverted");
        assertEq(ethBefore - user.balance, 1e18, "native input did not spend exactly msg.value's used part");
        assertGt(token1.balanceOf(user) - t1Before, 0, "no token1 received");
        _assertProxyEmpty();
    }

    /// @notice ETH force-fed to the proxy (it has no receive, so this models a selfdestruct/coinbase
    /// push) belongs to no one and is swept to the caller at the end of the next swap.
    function test_native_forceFedEthSweptToCaller() public {
        vm.deal(address(proxy), 3e18);
        SwapCalldata.Leg memory leg = _v3In(address(token0), address(token1), 1e18, 0);
        uint256 ethBefore = user.balance;

        (bool ok,) = _trySwapValue(user, _legs(leg), 0);

        assertTrue(ok, "swap over force-fed proxy reverted");
        assertEq(user.balance - ethBefore, 3e18, "force-fed ETH was not swept to the caller");
        _assertProxyEmpty();
    }

    /// @notice A V3-only call carrying msg.value spends none of it and refunds all of it.
    function test_native_v3OnlyCallRefundsAllValue() public {
        SwapCalldata.Leg memory leg = _v3In(address(token0), address(token1), 1e18, 0);
        uint256 ethBefore = user.balance;

        (bool ok,) = _trySwapValue(user, _legs(leg), 1e18);

        assertTrue(ok, "V3-only payable call reverted");
        assertEq(user.balance, ethBefore, "V3-only call did not refund all of msg.value");
        _assertProxyEmpty();
    }

    /// @notice A native-input V4 leg with too little msg.value (and no force-fed balance) reverts with
    /// NotEnoughEthSent, moving nothing.
    function test_native_shortMsgValue_revertsNotEnoughEthSent() public {
        SwapCalldata.Leg memory leg = _v4In(nativeKey, true, _u128(1e18), 0); // ETH -> token1
        uint256[16] memory before = _snapshot();

        (bool ok, bytes memory ret) = _trySwapValue(user, _legs(leg), 0);

        assertFalse(ok, "short msg.value did not revert");
        assertEq(_selector(ret), IProxyErrors.NotEnoughEthSent.selector, "wrong error for short msg.value");
        _assertSnapshotEq(_snapshot(), before, "short msg.value");
    }

    /// @notice The proxy has no `receive()`: every plain ETH transfer reverts, the PoolManager's
    /// included. (Replaces the old test that accepted ETH from the PoolManager.)
    function test_native_plainEthTransferAlwaysReverts() public {
        vm.deal(user, 1e18);
        vm.prank(user);
        (bool fromUser,) = address(proxy).call{value: 1e18}("");
        assertFalse(fromUser, "proxy accepted a plain ETH transfer from a user");

        vm.deal(address(manager), 1e18);
        vm.prank(address(manager));
        (bool fromManager,) = address(proxy).call{value: 1e18}("");
        assertFalse(fromManager, "proxy accepted a plain ETH transfer from the PoolManager");

        assertEq(address(proxy).balance, 0, "proxy retained force-sent ETH");
    }

    // ---------------------------------------------------------------------------------------------
    // 8. Callback guards.
    // ---------------------------------------------------------------------------------------------

    /// @notice `uniswapV3SwapCallback` from anyone but the pool the proxy is mid-swap with reverts
    /// UnexpectedCallback, whether the caller is an EOA-like contract or the attacker.
    function test_callback_v3FromStranger_reverts() public {
        CallbackIntruder intruder = new CallbackIntruder();
        vm.expectRevert(IProxyErrors.UnexpectedCallback.selector);
        intruder.fakeV3Callback(address(proxy), int256(1), int256(0), "");

        vm.prank(attacker);
        vm.expectRevert(IProxyErrors.UnexpectedCallback.selector);
        proxy.uniswapV3SwapCallback(int256(1), int256(0), "");
    }

    /// @notice A token that re-enters `uniswapV3SwapCallback` from inside its own transfer, mid-swap,
    /// is refused with UnexpectedCallback: the expected-pool slot was cleared the instant the genuine
    /// callback began, so no second callback is ever honoured (the proxy's transferFrom wrapper would
    /// surface the refusal as "STF", so the refusal itself is observed through the token's record).
    function test_callback_v3MidSwapFromToken_reverts() public {
        SwapCalldata.Leg memory leg = _v3In(address(evil), address(token1), 1e18, 0); // evil -> token1
        bytes memory payload =
            abi.encodeWithSignature("uniswapV3SwapCallback(int256,int256,bytes)", int256(0), int256(0), bytes(""));
        evil.arm(address(proxy), payload, false, true, false); // record the refusal; the swap completes

        (bool ok,) = _trySwap(user, _legs(leg));

        assertTrue(ok, "victim swap did not complete");
        assertEq(evil.fires(), 1, "the re-entrant callback never fired; the test proves nothing");
        assertFalse(evil.attackSucceeded(), "a mid-swap re-entrant V3 callback was honoured");
        assertEq(
            _selector(evil.attackReturn()),
            IProxyErrors.UnexpectedCallback.selector,
            "mid-swap re-entrant callback refused for the wrong reason"
        );
        _assertProxyEmpty();
    }

    /// @notice `unlockCallback` from anyone but the PoolManager reverts NotPoolManager.
    function test_callback_unlockFromNonManager_reverts() public {
        vm.prank(attacker);
        vm.expectRevert(IProxyErrors.NotPoolManager.selector);
        proxy.unlockCallback(bytes.concat(bytes1(0x01), new bytes(32)));
    }

    /// @notice An unlock carrying a tag that is neither SWAP nor LIQUIDITY reverts UnexpectedCallback,
    /// even when it genuinely comes from the PoolManager.
    function test_callback_unknownUnlockTag_reverts() public {
        vm.prank(address(manager));
        vm.expectRevert(IProxyErrors.UnexpectedCallback.selector);
        proxy.unlockCallback(bytes.concat(bytes1(0x03), new bytes(32)));
    }

    // ---------------------------------------------------------------------------------------------
    // 9. The transient lock holds for every caller, address(0) included.
    // ---------------------------------------------------------------------------------------------

    /// @notice A token that re-enters `swap` from inside its transfer, mid-swap, is refused with the
    /// OpenZeppelin reentrancy selector, and the victim swap completes normally.
    function test_lock_reentrantHookRefusedWithOzSelector() public {
        bytes memory inner =
            SwapCalldata.encode(block.timestamp, _legs(_v3In(address(token0), address(token1), 1e18, 0)));
        bytes memory payload = abi.encodeWithSignature("swap(bytes)", inner);
        evil.arm(address(proxy), payload, false, true, false); // record, let the victim finish

        SwapCalldata.Leg memory leg = _v3In(address(evil), address(token1), 1e18, 0); // evil -> token1
        uint256 t1Before = token1.balanceOf(user);

        (bool ok,) = _trySwap(user, _legs(leg));

        assertTrue(ok, "victim swap did not complete");
        assertEq(evil.fires(), 1, "the re-entrancy never fired; the test proves nothing");
        assertFalse(evil.attackSucceeded(), "the re-entrant swap was allowed");
        assertEq(
            _selector(evil.attackReturn()),
            IProxyErrors.ReentrancyGuardReentrantCall.selector,
            "re-entrancy failed for the wrong reason"
        );
        assertGt(token1.balanceOf(user) - t1Before, 0, "victim received no output");
        assertEq(token1.balanceOf(attacker), 0, "attacker gained token1");
        _assertProxyEmpty();
    }

    /// @notice The lock is set even when the entry point's caller is address(0) (an eth_call-style
    /// simulation): a hook that re-enters is still refused with the OpenZeppelin selector, proving the
    /// lock was armed although the caller's address is zero.
    function test_lock_holdsEvenForZeroSender() public {
        // Give address(0) the standing it needs so the swap would otherwise run
        bytes32 evilKey = proxy.v3Key(address(evilV3Pool));
        evil.mint(address(0), 100e18);
        vm.prank(address(0));
        evil.approve(address(proxy), type(uint256).max);
        _allow(address(0), evilKey, SWAP);

        bytes memory inner =
            SwapCalldata.encode(block.timestamp, _legs(_v3In(address(token0), address(token1), 1e18, 0)));
        bytes memory payload = abi.encodeWithSignature("swap(bytes)", inner);
        evil.arm(address(proxy), payload, false, true, false); // record the refusal; the swap completes

        SwapCalldata.Leg memory leg = _v3In(address(evil), address(token1), 1e18, 0);

        (bool ok,) = _trySwap(address(0), _legs(leg));

        assertTrue(ok, "swap by address(0) did not complete");
        assertEq(evil.fires(), 1, "the re-entrancy never fired; the test proves nothing");
        assertFalse(evil.attackSucceeded(), "re-entry was allowed for a zero-address caller");
        assertEq(
            _selector(evil.attackReturn()),
            IProxyErrors.ReentrancyGuardReentrantCall.selector,
            "the lock did not hold for a zero-address caller"
        );
        _assertProxyEmpty();
    }
}
