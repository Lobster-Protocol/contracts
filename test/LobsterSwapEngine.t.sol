// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.24;

import {BatchSwapFixture} from "./helpers/BatchSwapFixture.sol";
import {SwapCalldata} from "./helpers/SwapCalldata.sol";
import {SwapFlags} from "../src/libraries/SwapFlags.sol";
import {MintParams, MintCallbackData} from "../src/interfaces/uniswapV3/IUniswapV3MintCallback.sol";
import {IUniswapV3FactoryMinimal} from "../src/interfaces/uniswapV3/IUniswapV3FactoryMinimal.sol";
import {IUniswapV3PoolMinimal} from "../src/interfaces/uniswapV3/IUniswapV3PoolMinimal.sol";
import {PoolKey as ProxyPoolKey, IPoolManagerMinimal} from "../src/interfaces/uniswapV4/IPoolManagerMinimal.sol";
import {TickMath} from "../src/libraries/uniswapV3/TickMath.sol";
import {PoolAddress} from "../src/libraries/uniswapV3/PoolAddress.sol";
import {IProxyErrors} from "../src/interfaces/IProxyErrors.sol";

import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
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

/// @notice Charges `feeBps` on transfers to `taxed` only: a token whose fee depends on the recipient
/// (pools exempt, say), so it delivers less into the proxy than out of it
contract InboundTaxedToken is MockERC20 {
    address public taxed;
    uint256 public feeBps;

    constructor() MockERC20("Inbound taxed", "ITX", 18) {}

    function setTax(address to, uint256 bps) external {
        taxed = to;
        feeBps = bps;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        _move(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        _move(from, to, amount);
        return true;
    }

    function _move(address from, address to, uint256 amount) private {
        uint256 fee = to == taxed ? amount * feeBps / 10_000 : 0;
        balanceOf[from] -= amount;
        balanceOf[to] += amount - fee;
        totalSupply -= fee;
        emit Transfer(from, to, amount - fee);
    }
}

/// @notice A token whose transfers run outside code: each time it is moved it makes the next scheduled
/// call, and bubbles its revert
contract ScheduledHookToken is MockERC20 {
    address[] internal callees;
    bytes[] internal payloads;
    uint256 public fired;

    constructor() MockERC20("Hooked", "HKD", 18) {}

    function schedule(address[] calldata newCallees, bytes[] calldata newPayloads) external {
        delete callees;
        delete payloads;
        for (uint256 i = 0; i < newCallees.length; i++) {
            callees.push(newCallees[i]);
            payloads.push(newPayloads[i]);
        }
        fired = 0;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        _fire();
        return super.transfer(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        _fire();
        return super.transferFrom(from, to, amount);
    }

    function _fire() private {
        if (fired >= callees.length) return;
        uint256 i = fired++;
        (bool ok, bytes memory ret) = callees[i].call(payloads[i]);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }
}

/// @notice Trades on a V4 pool while someone else holds the PoolManager unlocked, without paying: it
/// front-runs with an unpaid swap, then, called again later in the same unlock, swaps back and takes
/// the surplus, leaving none of its deltas open
contract PoolManagerSandwicher {
    IPoolManager internal immutable MANAGER;
    PoolKey internal key;
    address internal profitTo;
    uint256 internal token1Paid;
    uint256 internal token0Got;

    constructor(IPoolManager manager) {
        MANAGER = manager;
    }

    function setKey(PoolKey calldata newKey, address to) external {
        key = newKey;
        profitTo = to;
    }

    /// @dev token1 -> token0, the victim's direction, exact input `amount`
    function frontRun(uint256 amount) external {
        BalanceDelta delta = MANAGER.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: false,
                amountSpecified: -SafeCast.toInt256(amount),
                sqrtPriceLimitX96: TickMath.MAX_SQRT_RATIO - 1
            }),
            ""
        );
        token1Paid = SafeCast.toUint256(-int256(delta.amount1()));
        token0Got = SafeCast.toUint256(int256(delta.amount0()));
    }

    /// @dev Sells the token0 back and takes the token1 surplus
    function backRun() external {
        BalanceDelta delta = MANAGER.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -SafeCast.toInt256(token0Got),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_RATIO + 1
            }),
            ""
        );
        MANAGER.take(key.currency1, profitTo, SafeCast.toUint256(int256(delta.amount1())) - token1Paid);
    }
}

/// @notice Adversarial suite for the mechanisms the swap-engine rewrite introduced: the one-unlock
/// hand-off of V3 outputs to the PoolManager (sync/settle/take), the memory ledger and its
/// end-of-call zero check, the packed-calldata validation, native-ETH accounting (msg.value is the
/// only budget, force-fed ETH is inert), the callback guards (including callbacks delivered when no
/// entry point is running) and the transient lock. Built on the five-pool graph of
/// {LobsterProxyGasTest}, plus a hostile token with a V3 and a V4 pool against token1 for the
/// settle-hijack cases.
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

    /// @dev {PoolManagerBase}'s tag of a swap unlock
    bytes1 constant SWAP_TAG = 0x01;
    /// @dev {UniswapSwapProxy}'s plan word bit (private there): this V3 leg's parked output goes to the
    /// PoolManager. {test_forgedSwapUnlock_payloadIsTheProxysOwn} proves the value matches.
    uint256 constant TO_MANAGER = 1 << 48;

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

    /// @dev The proxy holds no token and exactly `eth` (what was force-fed to it)
    function _assertProxyHoldsOnlyEth(uint256 eth) internal view {
        assertEq(token0.balanceOf(address(proxy)), 0, "proxy retained token0");
        assertEq(token1.balanceOf(address(proxy)), 0, "proxy retained token1");
        assertEq(tokenC.balanceOf(address(proxy)), 0, "proxy retained tokenC");
        assertEq(evil.balanceOf(address(proxy)), 0, "proxy retained evil");
        assertEq(address(proxy).balance, eth, "the proxy's force-fed ETH was spent or refunded");
    }

    /// @dev The victim (the user: every pool registered, every token approved to the proxy), the
    /// attacker, an outsider, the proxy and the PoolManager
    function _everyone() internal view returns (address[] memory accounts) {
        accounts = new address[](5);
        accounts[0] = user;
        accounts[1] = attacker;
        accounts[2] = outsider;
        accounts[3] = address(proxy);
        accounts[4] = address(manager);
    }

    /// @dev Every asset the engine could move (token0, token1, tokenC, evil, ETH), for each account
    function _balancesOf(address[] memory accounts) internal view returns (uint256[] memory b) {
        b = new uint256[](5 * accounts.length);
        for (uint256 i = 0; i < accounts.length; i++) {
            address a = accounts[i];
            b[5 * i] = token0.balanceOf(a);
            b[5 * i + 1] = token1.balanceOf(a);
            b[5 * i + 2] = tokenC.balanceOf(a);
            b[5 * i + 3] = evil.balanceOf(a);
            b[5 * i + 4] = a.balance;
        }
    }

    function _assertBalancesEq(uint256[] memory a, uint256[] memory b, string memory ctx) internal pure {
        assertEq(a.length, b.length, string.concat(ctx, ": balance lists differ"));
        for (uint256 i = 0; i < a.length; i++) {
            assertEq(a[i], b[i], string.concat(ctx, ": balance ", vm.toString(i), " moved"));
        }
    }

    /// @dev `swap(encode(now, legs))` as a low-level call by `who`, so the caller sees the raw revert.
    /// The deadline is read with vm.getBlockTimestamp(), so it holds across vm.revertToState.
    function _trySwap(address who, SwapCalldata.Leg[] memory legs) internal returns (bool ok, bytes memory ret) {
        bytes memory data = _call(legs);
        vm.prank(who);
        (ok, ret) = address(proxy).call(data);
    }

    function _trySwapValue(
        address who,
        SwapCalldata.Leg[] memory legs,
        uint256 value
    )
        internal
        returns (bool ok, bytes memory ret)
    {
        bytes memory data = _call(legs);
        vm.prank(who);
        (ok, ret) = address(proxy).call{value: value}(data);
    }

    function _selector(bytes memory ret) internal pure returns (bytes4 sel) {
        if (ret.length < 4) return sel;
        assembly ("memory-safe") {
            sel := and(mload(add(ret, 0x20)), shl(224, 0xffffffff))
        }
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
        _assertMalformed(_header(SafeCast.toUint32(block.timestamp), 0), "header only");

        // Rule: the token table fits in the data
        _assertMalformed(
            bytes.concat(_header(SafeCast.toUint32(block.timestamp), 5), hex"00112233445566778899"),
            "token table does not fit"
        );

        // Rule: there is at least one leg (data must extend past the token table)
        _assertMalformed(
            bytes.concat(
                _header(SafeCast.toUint32(block.timestamp), 2), bytes20(address(token0)), bytes20(address(token1))
            ),
            "no legs"
        );

        bytes memory table = bytes.concat(
            _header(SafeCast.toUint32(block.timestamp), 2), bytes20(address(token0)), bytes20(address(token1))
        );

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
            bytes.concat(_header(SafeCast.toUint32(block.timestamp), 2), bytes20(address(0)), bytes20(address(token1)));
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
        uint8 delta = SafeCast.toUint8(1 + (seed >> 8) % 255);
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
                amount = SafeCast.toUint128(
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
    // 7. Native ETH accounting (the entry point is payable). Native input is paid from msg.value only,
    //    one budget shared by every leg of the call, and only what is left of it is refunded: ETH
    //    force-fed to the proxy is neither spent nor refunded.
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

    /// @dev The user's call of `legs` sending `value` reverts NotEnoughEthSent and moves nothing
    function _assertNotEnoughEthSent(SwapCalldata.Leg[] memory legs, uint256 value, string memory ctx) internal {
        uint256[16] memory before = _snapshot();
        (bool ok, bytes memory ret) = _trySwapValue(user, legs, value);
        assertFalse(ok, string.concat(ctx, ": the native input was paid"));
        assertEq(
            ret, abi.encodeWithSelector(IProxyErrors.NotEnoughEthSent.selector), string.concat(ctx, ": wrong error")
        );
        _assertSnapshotEq(_snapshot(), before, ctx);
    }

    /// @notice ETH force-fed to the proxy (it has no `receive`, so vm.deal models a selfdestruct or a
    /// coinbase payment) belongs to no one and is inert. It never pays a native leg: an exact-input leg
    /// sent no ETH or one wei less than its input, and an exact-output leg sent no ETH or one wei less
    /// than it costs, revert NotEnoughEthSent while the proxy holds 50 times what they need. It is never
    /// refunded: a caller gets back exactly its msg.value minus what its legs spent, a call that sent no
    /// ETH gets none, and the proxy keeps the force-fed amount throughout. (Replaces
    /// `test_native_forceFedEthSweptToCaller`: native input is now paid from msg.value only.)
    function test_native_forceFedEthIsInert() public {
        uint256 forceFed = 50e18;
        vm.deal(address(proxy), forceFed);
        SwapCalldata.Leg[] memory exactIn = _legs(_v4In(nativeKey, true, _u128(1e18), 0)); // ETH -> token1
        SwapCalldata.Leg[] memory exactOut = _legs(_v4Out(nativeKey, true, _u128(1e18), type(uint128).max));

        // What the exact-output leg costs at the current price, from a run that is then rewound
        uint256 snap = vm.snapshotState();
        (bool ok, bytes memory ret) = _trySwapValue(user, exactOut, 2e18);
        assertTrue(ok, "pricing run reverted");
        uint256 cost = abi.decode(ret, (uint256[]))[0];
        assertTrue(vm.revertToState(snap), "pricing run not rewound");
        assertGt(cost, 1e18, "an exact-output leg costs more than its output at a 1:1 price with a fee");

        // Never spent: every wei of a native leg's input must come from msg.value
        _assertNotEnoughEthSent(exactIn, 0, "exact input, no msg.value");
        _assertNotEnoughEthSent(exactIn, 1e18 - 1, "exact input, one wei short");
        _assertNotEnoughEthSent(exactOut, 0, "exact output, no msg.value");
        _assertNotEnoughEthSent(exactOut, cost - 1, "exact output, one wei short");

        // Never refunded: the caller gets back exactly what its legs left of its msg.value
        uint256 ethBefore = user.balance;
        (ok,) = _trySwapValue(user, exactOut, cost);
        assertTrue(ok, "exact output sent exactly its cost reverted");
        assertEq(user.balance, ethBefore - cost, "a call that spent all its msg.value got ETH back");
        _assertProxyHoldsOnlyEth(forceFed);

        ethBefore = user.balance;
        (ok,) = _trySwapValue(user, exactIn, 3e18);
        assertTrue(ok, "exact input sent spare msg.value reverted");
        assertEq(user.balance, ethBefore - 1e18, "the caller got back other than its unspent msg.value");
        _assertProxyHoldsOnlyEth(forceFed);

        // The old sweep's own call, V3 only: sent no ETH, gets none; sent some, gets exactly that back
        SwapCalldata.Leg[] memory v3Only = _legs(_v3In(address(token0), address(token1), 1e18, 0));
        ethBefore = user.balance;
        (ok,) = _trySwapValue(user, v3Only, 0);
        assertTrue(ok, "V3-only call over a force-fed proxy reverted");
        assertEq(user.balance, ethBefore, "a call that sent no ETH was paid the force-fed ETH");
        (ok,) = _trySwapValue(user, v3Only, 1e18);
        assertTrue(ok, "payable V3-only call over a force-fed proxy reverted");
        assertEq(user.balance, ethBefore, "a V3-only call got back other than its msg.value");
        _assertProxyHoldsOnlyEth(forceFed);
    }

    /// @notice ETH force-fed to the proxy cannot block a caller that cannot receive ETH (before exact
    /// native accounting, one force-fed wei made every call it made revert "STE"): a call with no
    /// msg.value sends it no ETH, nor does one whose msg.value is spent to the wei. Only change it is
    /// really owed is sent, and the proxy keeps the force-fed wei.
    function test_native_forceFedEthCannotBlockACallerThatRefusesEth() public {
        address refuser = makeAddr("refuser");
        vm.etch(refuser, hex"60006000fd"); // revert(0, 0) on any call, a plain ETH transfer included
        token0.mint(refuser, 10e18);
        vm.prank(refuser);
        assertTrue(token0.approve(address(proxy), type(uint256).max));
        _allow(refuser, proxy.v3Key(address(v3Pool)), SWAP);
        _allow(refuser, proxy.v4Key(cleanKey), SWAP);
        _allow(refuser, proxy.v4Key(nativeKey), SWAP);
        vm.deal(refuser, 2e18);
        vm.deal(address(proxy), 1); // the griefer's whole cost
        SwapCalldata.Leg[] memory v3Only = _legs(_v3In(address(token0), address(token1), 1e18, 0));

        // The premise: change the refuser is owed cannot be delivered to it
        (bool ok, bytes memory ret) = _trySwapValue(refuser, v3Only, 1e18);
        assertFalse(ok, "the refuser accepted its change: the test proves nothing");
        assertEq(ret, abi.encodeWithSignature("Error(string)", "STE"), "change refused for the wrong reason");

        (ok,) = _trySwapValue(refuser, v3Only, 0);
        assertTrue(ok, "force-fed ETH blocked a V3-only call that sent no ETH");
        (ok,) = _trySwapValue(refuser, _legs(_v4In(cleanKey, true, _u128(1e18), 0)), 0);
        assertTrue(ok, "force-fed ETH blocked a V4 call that sent no ETH");
        (ok,) = _trySwapValue(refuser, _legs(_v4In(nativeKey, true, _u128(1e18), 0)), 1e18);
        assertTrue(ok, "force-fed ETH blocked a call that spent all its msg.value");

        assertEq(refuser.balance, 1e18, "the refuser paid other than its native leg's input");
        _assertProxyHoldsOnlyEth(1);
    }

    /// @notice ETH pushed into the proxy during a call, which only code the call itself runs can do
    /// (here the input token's hook; a selfdestruct on chain), is not the caller's msg.value, so no leg
    /// can spend it, but it is counted as change and refunded to that call's caller. ETH force-fed
    /// between calls stays in the proxy.
    function test_native_ethArrivingMidCall_isRefundedToThatCaller() public {
        vm.deal(address(proxy), 2e18); // force-fed between calls
        // Mid-call, the hook raises the proxy's balance by 1e18 (vm.deal sets a balance)
        evil.arm(address(vm), abi.encodeCall(vm.deal, (address(proxy), 3e18)), false, true, false);
        uint256 ethBefore = user.balance;

        (bool ok,) = _trySwap(user, _legs(_v3In(address(evil), address(token1), 1e18, 0)));

        assertTrue(ok, "swap reverted");
        assertEq(evil.fires(), 1, "the hook never fired; the test proves nothing");
        assertTrue(evil.attackSucceeded(), "the mid-call deposit did not happen");
        assertEq(user.balance, ethBefore + 1e18, "ETH that arrived mid-call was not refunded to the caller");
        _assertProxyHoldsOnlyEth(2e18);
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

    /// @notice Native-input legs share one budget, the call's msg.value. Three legs of 1e18 sent
    /// 3e18 - 1, while the proxy holds 10e18 of force-fed ETH, revert NotEnoughEthSent: each leg alone fits
    /// in msg.value and the proxy's balance covers all three, but the first two drew the budget down (two
    /// settlements of exactly 1e18 ran, in the reverted frame) and the third found 1e18 - 1 left. Sent
    /// their exact total, the same legs run and the caller pays exactly that.
    function test_native_legsShareOneBudget_totalAboveMsgValueReverts() public {
        vm.deal(address(proxy), 10e18);
        SwapCalldata.Leg[] memory legs = _legs(
            _v4In(nativeKey, true, _u128(1e18), 0), // ETH -> token1
            _v4In(nativeKeyC, true, _u128(1e18), 0), // ETH -> tokenC
            _v4In(nativeKey, true, _u128(1e18), 0) // ETH -> token1
        );

        // Two settlements of 1e18 in the short call, before its third leg runs out (counted in the
        // reverted frame), then three in the funded one
        vm.expectCall(address(manager), 1e18, abi.encodeWithSelector(IPoolManagerMinimal.settle.selector), 5);
        _assertNotEnoughEthSent(legs, 3e18 - 1, "three legs of 1e18, one wei short in total");

        uint256 ethBefore = user.balance;
        (bool ok,) = _trySwapValue(user, legs, 3e18);
        assertTrue(ok, "three legs sent exactly their total reverted");
        assertEq(user.balance, ethBefore - 3e18, "the caller paid other than its legs' native input");
        _assertProxyHoldsOnlyEth(10e18);
    }

    /// @notice Only the native legs the caller pays draw on its msg.value. In [V4 ETH->token1 1e18]
    /// [V4 token1->ETH 1e18 PARK][V4 ETH->tokenC HELD][V4 ETH->tokenC 1e18], the HELD leg spends the ETH
    /// the call parked: 2e18 - 1 reverts NotEnoughEthSent at the last leg, and 2e18 is exactly enough, with
    /// no change. The 7e18 force-fed to the proxy is untouched either way.
    function test_native_heldNativeLegDrawsNothingFromMsgValue() public {
        vm.deal(address(proxy), 7e18);
        SwapCalldata.Leg[] memory legs = new SwapCalldata.Leg[](4);
        legs[0] = _v4In(nativeKey, true, _u128(1e18), 0); // ETH -> token1, from msg.value
        legs[1] = _v4In(nativeKey, false, _u128(1e18), 0); // token1 -> ETH, parked as credit
        legs[1].park = true;
        legs[2] = _v4In(nativeKeyC, true, 0, 0); // ETH -> tokenC, from that credit
        legs[2].held = true;
        legs[3] = _v4In(nativeKeyC, true, _u128(1e18), 0); // ETH -> tokenC, from msg.value

        _assertNotEnoughEthSent(legs, 2e18 - 1, "two paid native legs, one wei short in total");

        uint256 ethBefore = user.balance;
        (bool ok,) = _trySwapValue(user, legs, 2e18);
        assertTrue(ok, "the paid native legs' exact total reverted");
        assertEq(user.balance, ethBefore - 2e18, "the HELD native leg drew on msg.value, or change was sent");
        _assertProxyHoldsOnlyEth(7e18);
    }

    /// @dev One native-input V4 leg paid from msg.value, ETH -> token1 or ETH -> tokenC, exact input or
    /// exact output, of a random size
    function _randomNativeLeg(uint256 seed, uint256 i) internal view returns (SwapCalldata.Leg memory) {
        uint256 r = uint256(keccak256(abi.encode(seed, i, "native")));
        ProxyPoolKey memory key = r & 1 == 0 ? nativeKey : nativeKeyC;
        uint128 amount = _u128(bound(r >> 8, 1e6, 2e18));
        return (r >> 1) & 1 == 0 ? _v4In(key, true, amount, 0) : _v4Out(key, true, amount, type(uint128).max);
    }

    /// @dev 1-4 native-input legs paid from msg.value, rotated among an optional ERC20 V3 leg that spends
    /// no ETH, and optionally wrapped in a native credit round trip, [V4 token1->ETH PARK] then, later,
    /// [V4 ETH->tokenC HELD]: a native leg paid from what the call parked, never from msg.value
    function _randomNativeRoute(uint256 seed) internal view returns (SwapCalldata.Leg[] memory legs) {
        uint256 natives = bound(seed, 1, 4);
        bool withV3 = (seed >> 8) & 1 == 1;
        bool withCredit = (seed >> 9) & 1 == 1;
        uint256 middle = natives + (withV3 ? 1 : 0);
        SwapCalldata.Leg[] memory mid = new SwapCalldata.Leg[](middle);
        uint256 rotation = bound(seed >> 16, 0, middle - 1);
        for (uint256 i = 0; i < middle; i++) {
            mid[(i + rotation) % middle] =
                i < natives ? _randomNativeLeg(seed, i) : _v3In(address(token0), address(token1), 1e18, 0);
        }
        if (!withCredit) return mid;

        SwapCalldata.Leg memory sell = _v4In(nativeKey, false, _u128(1e18), 0); // token1 -> ETH, parked
        sell.park = true;
        SwapCalldata.Leg memory spend = _v4In(nativeKeyC, true, 0, 0); // ETH -> tokenC, from that credit
        spend.held = true;
        uint256 parkAt = bound(seed >> 32, 0, middle);
        uint256 heldAt = bound(seed >> 48, parkAt + 1, middle + 1);
        legs = new SwapCalldata.Leg[](middle + 2);
        uint256 next = 0;
        for (uint256 at = 0; at < middle + 2; at++) {
            if (at == parkAt) legs[at] = sell;
            else if (at == heldAt) legs[at] = spend;
            else legs[at] = mid[next++];
        }
    }

    /// @dev The native input `legs` paid from msg.value, given the call's returned amounts: an exact-input
    /// leg pays its amount, an exact-output leg what it returned; HELD legs pay from parked funds
    function _nativePaidFromValue(
        SwapCalldata.Leg[] memory legs,
        uint256[] memory amounts
    )
        internal
        pure
        returns (uint256 paid)
    {
        for (uint256 i = 0; i < legs.length; i++) {
            if (legs[i].tokenIn != ETH || legs[i].held) continue;
            paid += legs[i].exactOut ? amounts[i] : legs[i].amount;
        }
    }

    /// @notice The native budget is the caller's own msg.value, whatever the proxy holds. Over random
    /// native-input routes (mixed with an ERC20 leg and a HELD native leg paid from parked ETH), a random
    /// msg.value and a random force-fed balance: the native input is measured where it lands, the
    /// PoolManager, and matches what the legs report; a call sent at least that runs and costs the caller
    /// exactly that; a call sent less reverts NotEnoughEthSent and costs nothing; and the proxy holds the
    /// force-fed amount after every call.
    function testFuzz_native_budgetIsTheCallersMsgValueOnly(uint256 seed, uint256 value, uint256 forceFed) public {
        SwapCalldata.Leg[] memory legs = _randomNativeRoute(seed);
        forceFed = bound(forceFed, 0, 1_000_000e18);
        vm.deal(address(proxy), forceFed);
        vm.deal(user, 1000e18);

        // The route's native input, from a generously funded run that is then rewound
        uint256 snap = vm.snapshotState();
        uint256 userEth = user.balance;
        uint256 managerEth = address(manager).balance;
        (bool ok, bytes memory ret) = _trySwapValue(user, legs, 100e18);
        assertTrue(ok, "a valid native route reverted");
        assertGe(address(manager).balance, managerEth, "funded run: the PoolManager paid out ETH");
        uint256 need = address(manager).balance - managerEth;
        assertGt(need, 0, "the route has no native input: the test proves nothing");
        assertEq(need, _nativePaidFromValue(legs, abi.decode(ret, (uint256[]))), "PoolManager got other ETH");
        assertEq(user.balance, userEth - need, "funded run: the caller paid other than its native input");
        _assertProxyHoldsOnlyEth(forceFed);
        assertTrue(vm.revertToState(snap), "funded run not rewound");

        // msg.value: one wei short, exactly enough, or anywhere up to twice the need
        uint256 mode = (seed >> 128) % 4;
        if (mode == 0) value = need - 1;
        else if (mode == 1) value = need;
        else value = bound(value, 0, 2 * need);

        userEth = user.balance;
        managerEth = address(manager).balance;
        (ok, ret) = _trySwapValue(user, legs, value);
        if (value >= need) {
            assertTrue(ok, "msg.value covers the native input, yet the call reverted");
            assertEq(user.balance, userEth - need, "the caller paid other than its native input");
            assertEq(address(manager).balance, managerEth + need, "the PoolManager got other than the native input");
        } else {
            assertFalse(ok, "msg.value is short of the native input, yet the call ran");
            assertEq(
                ret, abi.encodeWithSelector(IProxyErrors.NotEnoughEthSent.selector), "short msg.value: wrong error"
            );
            assertEq(user.balance, userEth, "a reverted call cost the caller ETH");
            assertEq(address(manager).balance, managerEth, "a reverted call paid the PoolManager");
        }
        _assertProxyHoldsOnlyEth(forceFed);
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

    /// @notice The lock also counts as held for the checks that require a lock holder when the caller is
    /// address(0): its V4 swap (the swap unlock requires the lock) and its mint (the mint callback pays
    /// the lock holder) both run, and it pays exactly for each.
    function test_lock_zeroSender_v4SwapAndMintStillRun() public {
        token0.mint(address(0), 100e18);
        token1.mint(address(0), 100e18);
        vm.startPrank(address(0));
        assertTrue(token0.approve(address(proxy), type(uint256).max));
        assertTrue(token1.approve(address(proxy), type(uint256).max));
        vm.stopPrank();
        _allow(address(0), proxy.v4Key(cleanKey), SWAP);
        _allow(address(0), proxy.v3Key(address(v3Pool)), MINT);

        uint256 t0 = token0.balanceOf(address(0));
        uint256 t1 = token1.balanceOf(address(0));
        (bool ok, bytes memory ret) = _trySwap(address(0), _legs(_v4In(cleanKey, true, _u128(1e17), 0)));
        assertTrue(ok, "a V4 swap by address(0) reverted");
        uint256[] memory amounts = abi.decode(ret, (uint256[]));
        assertGt(amounts[0], 0, "no V4 output");
        assertEq(token0.balanceOf(address(0)), t0 - 1e17, "address(0) did not pay its V4 input");
        assertEq(token1.balanceOf(address(0)), t1 + amounts[0], "address(0) did not get its V4 output");

        MintParams memory params = MintParams({
            token0: address(token0),
            token1: address(token1),
            fee: FEE,
            tickLower: -TICK_RANGE,
            tickUpper: TICK_RANGE,
            amount0Desired: 1e18,
            amount1Desired: 1e18,
            amount0Min: 0,
            amount1Min: 0,
            recipient: address(0),
            deadline: vm.getBlockTimestamp()
        });
        t0 = token0.balanceOf(address(0));
        t1 = token1.balanceOf(address(0));
        vm.prank(address(0));
        (uint256 amount0, uint256 amount1) = proxy.mint(params);
        assertGt(amount0 + amount1, 0, "nothing minted");
        assertEq(token0.balanceOf(address(0)), t0 - amount0, "address(0) did not pay its mint's token0");
        assertEq(token1.balanceOf(address(0)), t1 - amount1, "address(0) did not pay its mint's token1");
        _assertProxyEmpty();
    }

    // ---------------------------------------------------------------------------------------------
    // 10. Callbacks when no entry point is running. A swap unlock and a V3 mint callback act only for
    //     the entry point holding the lock: delivered by the genuine PoolManager or pool when none is
    //     running, they revert UnexpectedCallback before touching anything, whatever their data says.
    // ---------------------------------------------------------------------------------------------

    /// @dev Expects that nothing a swap or a mint does happens from here on (calls in reverted frames
    /// count too): no V3 price read or swap, no PoolManager price read, swap, sync, settle or take, no
    /// token transfer
    function _expectNothingRuns() internal {
        address[3] memory pools =
            [address(v3Pool), address(_v3PoolFor(address(token1), address(tokenC))), address(evilV3Pool)];
        for (uint256 i = 0; i < pools.length; i++) {
            vm.expectCall(pools[i], abi.encodeWithSelector(IUniswapV3PoolMinimal.slot0.selector), 0);
            vm.expectCall(pools[i], abi.encodeWithSelector(IUniswapV3PoolMinimal.swap.selector), 0);
        }
        bytes4[5] memory managerCalls = [
            IPoolManagerMinimal.extsload.selector,
            IPoolManagerMinimal.swap.selector,
            IPoolManagerMinimal.sync.selector,
            IPoolManagerMinimal.settle.selector,
            IPoolManagerMinimal.take.selector
        ];
        for (uint256 i = 0; i < managerCalls.length; i++) {
            vm.expectCall(address(manager), abi.encodeWithSelector(managerCalls[i]), 0);
        }
        address[4] memory tokens = [address(token0), address(token1), address(tokenC), address(evil)];
        for (uint256 i = 0; i < tokens.length; i++) {
            vm.expectCall(tokens[i], abi.encodeWithSelector(token0.transfer.selector), 0);
            vm.expectCall(tokens[i], abi.encodeWithSelector(token0.transferFrom.selector), 0);
        }
    }

    /// @dev A plan band word, as the registry returns it: minTick | maxTick << 24, 24 bits each
    function _bandWord(int24 minTick, int24 maxTick) internal pure returns (uint256 band) {
        assembly ("memory-safe") {
            band := or(and(minTick, 0xffffff), shl(24, and(maxTick, 0xffffff)))
        }
    }

    /// @dev The registry key of a leg's pool: the V3 pool's address, or the hookless V4 pool's PoolId
    function _registryKey(SwapCalldata.Leg memory leg) internal view returns (bytes32) {
        if (!leg.v4) return proxy.v3Key(address(_v3PoolFor(leg.tokenIn, leg.tokenOut)));
        return proxy.v4Key(_toProxyKey(_v4CoreKey(_lo(leg.tokenIn, leg.tokenOut), _hi(leg.tokenIn, leg.tokenOut))));
    }

    /// @dev A swap unlock payload laid out as {UniswapSwapProxy} writes its own: SWAP_TAG | legs |
    /// word 1 (msg.value << 1 | usesLedger) | per leg, the registry key and the band word | swap data.
    /// The plan words come from `vault`'s registry, so they name its registered pools and its bands; bit
    /// i of `toManager` sets TO_MANAGER on leg i.
    function _swapUnlockPayload(
        address vault,
        SwapCalldata.Leg[] memory legs,
        uint256 word1,
        uint256 toManager
    )
        internal
        view
        returns (bytes memory)
    {
        bytes memory words;
        for (uint256 i = 0; i < legs.length; i++) {
            bytes32 key = _registryKey(legs[i]);
            (int24 minTick, int24 maxTick) = proxy.priceBandOf(vault, key);
            uint256 band = _bandWord(minTick, maxTick);
            if ((toManager >> i) & 1 != 0) band |= TO_MANAGER;
            words = bytes.concat(words, key, bytes32(band));
        }
        return bytes.concat(
            SWAP_TAG, bytes32(legs.length), bytes32(word1), words, SwapCalldata.encode(vm.getBlockTimestamp(), legs)
        );
    }

    /// @dev The victim's route, one of everything a swap unlock carries: [V3 token0->token1 PARK], its
    /// output handed to the PoolManager (TO_MANAGER), [V4 token1->ETH HELD PARK] parking ETH,
    /// [V4 ETH->tokenC HELD] spending it, and [V4 ETH->token1 0.5e18] paid from msg.value
    function _victimRoute() internal view returns (SwapCalldata.Leg[] memory legs) {
        legs = new SwapCalldata.Leg[](4);
        legs[0] = _v3In(address(token0), address(token1), 1e18, 0);
        legs[0].park = true;
        legs[1] = _v4In(nativeKey, false, 0, 0); // token1 -> ETH
        legs[1].held = true;
        legs[1].park = true;
        legs[2] = _v4In(nativeKeyC, true, 0, 0); // ETH -> tokenC
        legs[2].held = true;
        legs[3] = _v4In(nativeKey, true, _u128(0.5e18), 0); // ETH -> token1
    }

    /// @dev The victim's route as a swap unlock with `word1`, TO_MANAGER on its V3 leg as the proxy sets it
    function _victimPayload(uint256 word1) internal view returns (bytes memory) {
        return _swapUnlockPayload(user, _victimRoute(), word1, 1);
    }

    /// @dev Swap unlock payloads an attacker could craft, each naming the victim's registered pools and
    /// bands in its plan words, while the proxy holds `forceFed` of force-fed ETH
    function _forgedSwapPayloads(uint256 forceFed) internal view returns (bytes[] memory payloads) {
        payloads = new bytes[](9);
        // The tag alone, and a body of zero legs (which, before the lock check, ran and returned)
        payloads[0] = bytes.concat(SWAP_TAG);
        payloads[1] = bytes.concat(SWAP_TAG, new bytes(64));
        // Byte for byte the victim's own call sending 1e18 ({test_forgedSwapUnlock_payloadIsTheProxysOwn}),
        // then its legs budgeted with every wei the proxy holds, and with every bit of word 1 set
        payloads[2] = _victimPayload((1e18 << 1) | 1);
        payloads[3] = _victimPayload((forceFed << 1) | 1);
        payloads[4] = _victimPayload(type(uint256).max);
        // One native leg spending all the force-fed ETH, budgeted for exactly that, no ledger (without the
        // lock check, delivered while a third party holds the PoolManager unlocked, it runs and spends it all)
        payloads[5] = _swapUnlockPayload(user, _legs(_v4In(nativeKey, true, _u128(forceFed), 0)), forceFed << 1, 0);
        // HELD from the first leg with nothing parked, and TO_MANAGER on every leg
        SwapCalldata.Leg memory heldV3 = _v3In(address(token1), address(tokenC), 0, 0);
        heldV3.held = true;
        heldV3.park = true;
        SwapCalldata.Leg memory heldV4 = _v4In(nativeKeyC, false, 0, 0); // tokenC -> ETH
        heldV4.held = true;
        payloads[6] = _swapUnlockPayload(user, _legs(heldV3, heldV4), (forceFed << 1) | 1, 3);
        // A V3 exact-output leg on the victim's pool, its output marked for the PoolManager
        payloads[7] =
            _swapUnlockPayload(user, _legs(_v3Out(address(token0), address(token1), 1e18, type(uint256).max)), 0, 1);
        // A legs word that would overflow every size the body computes
        payloads[8] = bytes.concat(SWAP_TAG, bytes32(type(uint256).max), bytes32(type(uint256).max));
    }

    /// @dev Delivers `payload` to the proxy's `unlockCallback` as the PoolManager, outside any `swap`:
    /// with the PoolManager locked (a direct call), or unlocked by a third party, this contract, which
    /// forges the callback from inside its own unlock ({unlockCallback}), so V4 legs could trade
    function _forgeSwapUnlock(bytes memory payload, bool managerUnlocked) internal returns (bool, bytes memory) {
        if (managerUnlocked) return abi.decode(manager.unlock(payload), (bool, bytes));
        bytes memory callData = abi.encodeCall(proxy.unlockCallback, (payload));
        vm.prank(address(manager));
        return address(proxy).call(callData);
    }

    /// @notice Not a test: the third party's own unlock callback for {_forgeSwapUnlock}. It delivers
    /// `payload` to the proxy as the PoolManager would, and records the answer rather than bubbling it,
    /// so that its own unlock closes.
    function unlockCallback(bytes calldata payload) external returns (bytes memory) {
        assertEq(msg.sender, address(manager), "unlockCallback: not the PoolManager");
        bytes memory callData = abi.encodeCall(proxy.unlockCallback, (payload));
        vm.prank(address(manager));
        (bool ok, bytes memory ret) = address(proxy).call(callData);
        return abi.encode(ok, ret);
    }

    /// @notice The PoolManager calls `unlockCallback` only on whoever called `unlock`, with that caller's
    /// data, so on-chain only the proxy's own `swap` reaches the swap body. Even so, SWAP_TAG payloads the
    /// PoolManager delivers outside any `swap` (vm.prank) are refused with UnexpectedCallback before they
    /// touch anything, whatever they carry: the victim's registered pools and bands as plan words,
    /// TO_MANAGER bits, HELD legs, native legs, a msg.value budget in word 1 up to every bit set while the
    /// proxy holds force-fed ETH, sizes that would overflow; and whether the PoolManager is locked or
    /// unlocked by a third party, where V4 legs could trade. No price is read, no pool, PoolManager or
    /// token call is made, and no balance of the victim, the attacker, an outsider, the proxy or the
    /// PoolManager moves.
    function test_forgedSwapUnlock_outsideASwap_revertsUnexpectedCallback() public {
        uint256 forceFed = 5e18;
        vm.deal(address(proxy), forceFed);
        bytes[] memory payloads = _forgedSwapPayloads(forceFed);
        address[] memory everyone = _everyone();
        uint256[] memory before = _balancesOf(everyone);

        _expectNothingRuns();
        for (uint256 i = 0; i < payloads.length; i++) {
            for (uint256 m = 0; m < 2; m++) {
                string memory ctx = string.concat(
                    "forged payload ",
                    vm.toString(i),
                    m == 0 ? ", PoolManager locked" : ", PoolManager unlocked by a third party"
                );
                (bool ok, bytes memory ret) = _forgeSwapUnlock(payloads[i], m == 1);
                assertFalse(ok, string.concat(ctx, ": the swap body ran"));
                assertEq(
                    ret,
                    abi.encodeWithSelector(IProxyErrors.UnexpectedCallback.selector),
                    string.concat(ctx, ": refused for the wrong reason")
                );
            }
        }
        _assertBalancesEq(_balancesOf(everyone), before, "forged swap unlock");
    }

    /// @notice The forged payloads are the real thing: for the victim's route the builder writes, byte for
    /// byte, the payload the proxy itself passes to `unlock` and receives in `unlockCallback` when the
    /// victim calls `swap` with 1e18 (plan words from its registry, TO_MANAGER on the V3 leg, word 1 =
    /// 1e18 << 1 | 1), and inside that call, with the lock held, the same payload runs every leg.
    function test_forgedSwapUnlock_payloadIsTheProxysOwn() public {
        bytes memory payload = _victimPayload((1e18 << 1) | 1);
        vm.expectCall(address(manager), abi.encodeCall(IPoolManagerMinimal.unlock, (payload)), 1);
        vm.expectCall(address(proxy), abi.encodeCall(proxy.unlockCallback, (payload)), 1);
        uint256 ethBefore = user.balance;
        uint256 tokenCBefore = tokenC.balanceOf(user);

        (bool ok,) = _trySwapValue(user, _victimRoute(), 1e18);

        assertTrue(ok, "the victim's own route reverted");
        assertEq(user.balance, ethBefore - 0.5e18, "the native leg's input or the change is wrong");
        assertGt(tokenC.balanceOf(user), tokenCBefore, "the HELD native leg delivered nothing");
        _assertProxyEmpty();
    }

    /// @notice Whatever word 1 (msg.value << 1 | usesLedger) and the TO_MANAGER bits of a forged swap
    /// unlock say, however much ETH was force-fed to the proxy, and whether the PoolManager is locked or
    /// not, the PoolManager delivering it outside a `swap` gets UnexpectedCallback: nothing runs, nothing
    /// moves.
    function testFuzz_forgedSwapUnlock_anyBudgetOrBits_reverts(
        uint256 word1,
        uint256 toManager,
        uint256 forceFed,
        bool managerUnlocked
    )
        public
    {
        forceFed = bound(forceFed, 0, 1_000_000e18);
        vm.deal(address(proxy), forceFed);
        bytes memory payload = _swapUnlockPayload(user, _victimRoute(), word1, toManager);
        address[] memory everyone = _everyone();
        uint256[] memory before = _balancesOf(everyone);

        _expectNothingRuns();
        (bool ok, bytes memory ret) = _forgeSwapUnlock(payload, managerUnlocked);

        assertFalse(ok, "a forged swap unlock ran");
        assertEq(ret, abi.encodeWithSelector(IProxyErrors.UnexpectedCallback.selector), "refused for the wrong reason");
        _assertBalancesEq(_balancesOf(everyone), before, "forged swap unlock");
    }

    /// @notice A V3 pool calls `uniswapV3MintCallback` only on the caller of its `mint`, which only the
    /// proxy's `mint` entry point makes. Even so, the genuine pool itself (vm.prank) calling it outside any
    /// entry point is refused with UnexpectedCallback, whatever its data names as payer: the old
    /// MintCallbackData naming the victim, who approved the proxy for every token, or the bare pool key
    /// the proxy now passes; on each of the three V3 pools and for any amounts owed. No token moves; the
    /// victim, the pools and everyone else are untouched. The same data from anyone else fails one step
    /// earlier, at the pool check (CallbackValidation, empty revert data): the pool itself is refused by
    /// the lock check alone.
    function test_mintCallback_genuinePoolOutsideAnyCall_revertsUnexpectedCallback() public {
        IUniswapV3PoolMinimal[3] memory pools = [v3Pool, _v3PoolFor(address(token1), address(tokenC)), evilV3Pool];
        address[] memory accounts = new address[](8);
        address[] memory everyone = _everyone();
        for (uint256 i = 0; i < 5; i++) {
            accounts[i] = everyone[i];
        }
        for (uint256 p = 0; p < 3; p++) {
            accounts[5 + p] = address(pools[p]);
        }
        uint256[] memory before = _balancesOf(accounts);

        _expectNothingRuns();
        for (uint256 p = 0; p < 3; p++) {
            PoolAddress.PoolKey memory key =
                PoolAddress.PoolKey({token0: pools[p].token0(), token1: pools[p].token1(), fee: FEE});
            bytes[2] memory data = [abi.encode(MintCallbackData({poolKey: key, payer: user})), abi.encode(key)];
            for (uint256 d = 0; d < 2; d++) {
                string memory ctx = string.concat("pool ", vm.toString(p), d == 0 ? ", payer named" : ", pool key");
                for (uint256 k = 0; k < 4; k++) {
                    uint256 owed0 = k == 0 || k == 2 ? 1e18 : 0;
                    uint256 owed1 = k == 1 || k == 2 ? 1e18 : 0;
                    bytes memory callData = abi.encodeCall(proxy.uniswapV3MintCallback, (owed0, owed1, data[d]));
                    vm.prank(address(pools[p]));
                    (bool ok, bytes memory ret) = address(proxy).call(callData);
                    assertFalse(ok, string.concat(ctx, ": the genuine pool was paid outside any call"));
                    assertEq(
                        ret,
                        abi.encodeWithSelector(IProxyErrors.UnexpectedCallback.selector),
                        string.concat(ctx, ": refused for the wrong reason")
                    );
                }
                bytes memory fromAttacker = abi.encodeCall(proxy.uniswapV3MintCallback, (1e18, 1e18, data[d]));
                vm.prank(attacker);
                (bool okAttacker, bytes memory retAttacker) = address(proxy).call(fromAttacker);
                assertFalse(okAttacker, string.concat(ctx, ": a non-pool caller was paid"));
                assertEq(retAttacker.length, 0, string.concat(ctx, ": a non-pool caller passed the pool check"));
            }
        }
        _assertBalancesEq(_balancesOf(accounts), before, "mint callback outside any call");
    }

    /// @notice Not a test: the hostile token's callee in
    /// {test_mintCallback_forgedMidCall_paidByTheLockHolderNotTheNamedPayer}. It delivers a mint callback
    /// to the proxy as `pool` would (vm.prank), from wherever it is called.
    function forgeMintCallbackFromPool(address pool, uint256 owed0, uint256 owed1, bytes calldata data) external {
        vm.prank(pool);
        proxy.uniswapV3MintCallback(owed0, owed1, data);
    }

    /// @notice A payer named in mint callback data never pays. A genuine-pool mint callback (vm.prank)
    /// forged from inside the attacker's own `swap`, by a hostile input token's hook (recorded, not
    /// bubbled: the proxy's transfer wrapper would mask it), names the victim as payer in the old
    /// MintCallbackData. Whether the proxy honours it (paid by the lock holder, the attacker) or refuses
    /// it (`UnexpectedCallback`), the victim, who approved the proxy for that token, pays nothing.
    function test_mintCallback_forgedMidCall_paidByTheLockHolderNotTheNamedPayer() public {
        // The attacker: registered on the evil/token1 V3 pool, holding evil and token0, both approved
        evil.mint(attacker, 10e18);
        token0.mint(attacker, 10e18);
        vm.startPrank(attacker);
        assertTrue(evil.approve(address(proxy), type(uint256).max));
        assertTrue(token0.approve(address(proxy), type(uint256).max));
        vm.stopPrank();
        _allow(attacker, proxy.v3Key(address(evilV3Pool)), SWAP);

        PoolAddress.PoolKey memory key =
            PoolAddress.PoolKey({token0: address(token0), token1: address(token1), fee: FEE});
        bytes memory namingVictim = abi.encode(MintCallbackData({poolKey: key, payer: user}));
        bytes memory forge = abi.encodeCall(this.forgeMintCallbackFromPool, (address(v3Pool), 1e18, 0, namingVictim));
        evil.arm(address(this), forge, false, true, false); // fires as the attacker pays its V3 pool
        uint256 victimT0 = token0.balanceOf(user);
        uint256 victimT1 = token1.balanceOf(user);
        uint256 attackerT0 = token0.balanceOf(attacker);
        uint256 poolT0 = token0.balanceOf(address(v3Pool));

        (bool ok,) = _trySwap(attacker, _legs(_v3In(address(evil), address(token1), 1e18, 0)));

        assertTrue(ok, "the attacker's swap did not complete");
        assertEq(evil.fires(), 1, "the forged callback never fired; the test proves nothing");
        assertEq(token0.balanceOf(user), victimT0, "the payer named in the callback data paid");
        assertEq(token1.balanceOf(user), victimT1, "the victim's token1 moved");
        if (evil.attackSucceeded()) {
            assertEq(token0.balanceOf(attacker), attackerT0 - 1e18, "the lock holder did not pay the callback");
            assertEq(token0.balanceOf(address(v3Pool)), poolT0 + 1e18, "the pool was not paid what it was owed");
        } else {
            assertEq(
                _selector(evil.attackReturn()),
                IProxyErrors.UnexpectedCallback.selector,
                "the forged callback was refused for the wrong reason"
            );
            assertEq(token0.balanceOf(attacker), attackerT0, "a refused callback charged the attacker");
            assertEq(token0.balanceOf(address(v3Pool)), poolT0, "a refused callback paid the pool");
        }
        _assertProxyEmpty();
    }

    // ---------------------------------------------------------------------------------------------
    // 11. Documented limits (KNOWN BEHAVIOURS in UniswapSwapProxy and SwapFlags), pinned: what the
    //     engine does with duplicate table entries, a token taxed on its way into the proxy, and a
    //     token whose transfers run outside code inside the call's PoolManager unlock.
    // ---------------------------------------------------------------------------------------------

    /// @dev A V3 HELD leg, raw (flags | in | out | fee | bound)
    function _heldV3LegBytes(uint8 inIdx, uint8 outIdx) internal pure returns (bytes memory) {
        return bytes.concat(bytes1(SwapFlags.HELD), bytes1(inIdx), bytes1(outIdx), bytes3(FEE), bytes16(0));
    }

    /// @notice KNOWN BEHAVIOUR (SwapFlags): parked amounts are kept per token-table index. With token1
    /// listed twice, a HELD leg reading one index does not see what was parked under the other
    /// (NothingHeld), and spending only one of the two leaves the other parked (FundsLeftInProxy);
    /// each index spent by its own HELD leg runs. Every case that would not spend everything reverts.
    function test_limit_duplicateTableEntries_areSeparateBalances() public {
        bytes memory table = bytes.concat(
            _header(SafeCast.toUint32(vm.getBlockTimestamp()), 3),
            bytes20(address(token0)),
            bytes20(address(token1)),
            bytes20(address(token1))
        );
        bytes memory parkUnder1 = _v3LegBytes(SwapFlags.PARK, 0, 1, 1e18, 0);
        bytes memory parkUnder2 = _v3LegBytes(SwapFlags.PARK, 0, 2, 1e18, 0);

        (bool ok, bytes memory ret) = _trySwapRaw(user, bytes.concat(table, parkUnder1, _heldV3LegBytes(2, 0)));
        assertFalse(ok, "a HELD leg spent what another index parked");
        assertEq(_selector(ret), IProxyErrors.NothingHeld.selector, "not NothingHeld");

        (ok, ret) = _trySwapRaw(user, bytes.concat(table, parkUnder1, parkUnder2, _heldV3LegBytes(1, 0)));
        assertFalse(ok, "one HELD leg spent both indices");
        assertEq(_selector(ret), IProxyErrors.FundsLeftInProxy.selector, "not FundsLeftInProxy");

        uint256 t0 = token0.balanceOf(user);
        (ok, ret) = _trySwapRaw(
            user, bytes.concat(table, parkUnder1, parkUnder2, _heldV3LegBytes(1, 0), _heldV3LegBytes(2, 0))
        );
        assertTrue(ok, "spending each index from its own HELD leg reverted");
        uint256[] memory amounts = abi.decode(ret, (uint256[]));
        assertEq(token0.balanceOf(user), t0 - 2e18 + amounts[2] + amounts[3], "the user's token0 is off");
        _assertProxyEmpty();
    }

    /// @notice KNOWN BEHAVIOUR (UniswapSwapProxy): a V3 output parked in the proxy is recorded as the
    /// pool reports it. With a token that delivers less into the proxy than out of it (a fee on
    /// transfers to the proxy only), the HELD leg pays the next pool the reported amount out of the
    /// proxy's balance: with nothing else there the call reverts, and with tokens sent to the proxy
    /// outside any call, which belong to no one, exactly the fee comes out of them.
    function test_limit_inboundTaxedToken_handOffDrawsTheFeeFromStrays() public {
        InboundTaxedToken tax = new InboundTaxedToken();
        tax.mint(address(this), 100_000e18);
        assertTrue(tax.approve(address(proxy), type(uint256).max));
        IUniswapV3FactoryMinimal(v3Factory).createPool(address(tax), address(token1), FEE);
        _v3PoolFor(address(tax), address(token1)).initialize(SQRT_PRICE_1_1);
        _mintV3(address(tax), address(token1));
        _allow(user, proxy.v3Key(address(_v3PoolFor(address(tax), address(token1)))), SWAP);
        tax.setTax(address(proxy), 100); // 1%, on transfers into the proxy only

        SwapCalldata.Leg memory buy = _v3In(address(token1), address(tax), 1e18, 0);
        buy.park = true;
        SwapCalldata.Leg memory sell = _v3In(address(tax), address(token1), 0, 0);
        sell.held = true;

        (bool ok, bytes memory ret) = _trySwap(user, _legs(buy, sell));
        assertFalse(ok, "the hand-off paid out more than arrived");
        assertEq(ret, abi.encodeWithSignature("Error(string)", "ST"), "reverted for the wrong reason");

        tax.setTax(address(0), 0);
        assertTrue(tax.transfer(address(proxy), 5e18)); // sent to the proxy outside any call
        tax.setTax(address(proxy), 100);
        (ok, ret) = _trySwap(user, _legs(buy, sell));
        assertTrue(ok, "the hand-off reverted with strays to draw on");
        uint256 fee = abi.decode(ret, (uint256[]))[0] / 100;
        assertGt(fee, 0, "no fee charged: the test proves nothing");
        assertEq(tax.balanceOf(address(proxy)), 5e18 - fee, "the strays did not cover exactly the fee");
    }

    /// @notice KNOWN BEHAVIOUR (UniswapSwapProxy): with a V4 leg, every leg runs inside the proxy's
    /// unlock, so a traded token whose transfers run outside code can trade on the PoolManager for the
    /// rest of the call without paying until later in it. Here its first transfer front-runs the vault's
    /// V4 leg with an unpaid swap and its second closes the position at a profit: without a bound the
    /// vault gets less. The vault's protection is the leg's bound: with it set to the unattacked output,
    /// the same attack reverts the call (TooLittleReceived) and the attacker gets nothing.
    function test_limit_hookTokenInsideTheUnlock_isStoppedByTheLegsBound() public {
        ScheduledHookToken hooked = new ScheduledHookToken();
        hooked.mint(address(this), 100_000e18);
        assertTrue(hooked.approve(address(proxy), type(uint256).max));
        IUniswapV3FactoryMinimal(v3Factory).createPool(address(hooked), address(token1), FEE);
        _v3PoolFor(address(hooked), address(token1)).initialize(SQRT_PRICE_1_1);
        _mintV3(address(hooked), address(token1));
        hooked.mint(user, 100e18);
        vm.prank(user);
        assertTrue(hooked.approve(address(proxy), type(uint256).max));
        _allow(user, proxy.v3Key(address(_v3PoolFor(address(hooked), address(token1)))), SWAP);

        PoolManagerSandwicher sandwicher = new PoolManagerSandwicher(manager);
        address profit = makeAddr("sandwich profit");
        sandwicher.setKey(_v4CoreKey(address(token0), address(token1)), profit);
        address[] memory callees = new address[](2);
        callees[0] = address(sandwicher);
        callees[1] = address(sandwicher);
        bytes[] memory payloads = new bytes[](2);
        payloads[0] = abi.encodeCall(PoolManagerSandwicher.frontRun, (100e18));
        payloads[1] = abi.encodeCall(PoolManagerSandwicher.backRun, ());

        // hooked -> token1 (the vault pays hooked: first hook), the victim V4 leg token1 -> token0, then
        // token1 -> hooked (the pool delivers hooked: second hook)
        SwapCalldata.Leg[] memory legs = _legs(
            _v3In(address(hooked), address(token1), 1e18, 0),
            _v4In(cleanKey, false, 100e18, 0),
            _v3In(address(token1), address(hooked), 1e17, 0)
        );

        uint256 snap = vm.snapshotState();
        (bool ok, bytes memory ret) = _trySwap(user, legs);
        assertTrue(ok, "the unattacked call reverted");
        uint256 unattacked = abi.decode(ret, (uint256[]))[1];
        assertTrue(vm.revertToState(snap));

        snap = vm.snapshotState();
        hooked.schedule(callees, payloads);
        (ok, ret) = _trySwap(user, legs);
        assertTrue(ok, "the attacked call reverted");
        assertEq(hooked.fired(), 2, "the hooks did not both fire");
        assertLt(abi.decode(ret, (uint256[]))[1], unattacked, "the attack did not cost the vault anything");
        assertGt(token1.balanceOf(profit), 0, "the attacker made no profit");
        assertTrue(vm.revertToState(snap));

        legs[1].bound = SafeCast.toUint128(unattacked);
        hooked.schedule(callees, payloads);
        (ok, ret) = _trySwap(user, legs);
        assertFalse(ok, "the vault received less than its bound");
        assertEq(_selector(ret), IProxyErrors.TooLittleReceived.selector, "reverted for the wrong reason");
        assertEq(hooked.fired(), 0, "the attack's effects survived the revert");
        assertEq(token1.balanceOf(profit), 0, "the attacker profited");
    }
}
