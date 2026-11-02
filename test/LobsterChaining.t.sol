// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.24;

import {VmSafe} from "forge-std/Vm.sol";
import {BatchSwapFixture} from "./helpers/BatchSwapFixture.sol";
import {SwapCalldata} from "./helpers/SwapCalldata.sol";
import {V4LiquidityOp} from "../src/UniswapV4LiquidityProxy.sol";
import {TickMath} from "../src/libraries/uniswapV3/TickMath.sol";
import {MintParams} from "../src/interfaces/uniswapV3/IUniswapV3MintCallback.sol";
import {IUniswapV3FactoryMinimal} from "../src/interfaces/uniswapV3/IUniswapV3FactoryMinimal.sol";
import {IUniswapV3PoolMinimal} from "../src/interfaces/uniswapV3/IUniswapV3PoolMinimal.sol";
import {PoolKey as ProxyPoolKey} from "../src/interfaces/uniswapV4/IPoolManagerMinimal.sol";
import {IProxyErrors} from "../src/interfaces/IProxyErrors.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IERC20Minimal} from "v4-core/src/interfaces/external/IERC20Minimal.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/// @notice A token that, the first time it is transferred to `trigger`, calls `target` with `attack`
/// and records what happened: before the transfer, or right after it with `afterTransfer` (once the
/// recipient's balance holds the amount). The call can carry ETH of the token's own, and the token
/// accepts ETH, so it can be paid a refund like any caller of a payable entry point.
contract ReentrantERC20 is MockERC20 {
    address public trigger;
    address public target;
    bytes public attack;
    bool public afterTransfer;
    /// @dev ETH sent with the attack, out of the token's own balance
    uint256 public attackValue;
    bool public armed;
    uint256 public attempts;
    bool public attackSucceeded;
    bytes public attackRevertData;
    /// @dev `target`'s ETH balance when the attack fired: what was within reach of the call
    uint256 public targetEthWhenFired;

    constructor() MockERC20("Reentrant", "RENT", 18) {}

    receive() external payable {}

    function arm(address _trigger, address _target, bytes calldata _attack, bool _afterTransfer) external {
        _arm(_trigger, _target, _attack, _afterTransfer, 0);
    }

    /// @dev As {arm}, the attack sending `_value` wei of the token's own ETH
    function armWithValue(
        address _trigger,
        address _target,
        bytes calldata _attack,
        bool _afterTransfer,
        uint256 _value
    )
        external
    {
        _arm(_trigger, _target, _attack, _afterTransfer, _value);
    }

    function transfer(address to, uint256 amount) public override returns (bool ok) {
        bool fire = armed && to == trigger;
        if (fire) armed = false;
        if (fire && !afterTransfer) _fire();
        ok = super.transfer(to, amount);
        if (fire && afterTransfer) _fire();
    }

    function _arm(
        address _trigger,
        address _target,
        bytes calldata _attack,
        bool _afterTransfer,
        uint256 _value
    )
        private
    {
        trigger = _trigger;
        target = _target;
        attack = _attack;
        afterTransfer = _afterTransfer;
        attackValue = _value;
        armed = true;
    }

    function _fire() private {
        attempts++;
        targetEthWhenFired = target.balance;
        (attackSucceeded, attackRevertData) = target.call{value: attackValue}(attack);
    }
}

/// @notice A token whose every transfer opens, and at once closes, a PoolManager unlock of its own
contract UnlockingERC20 is MockERC20 {
    IPoolManager public immutable POOL_MANAGER;

    constructor(IPoolManager poolManager) MockERC20("Unlocking", "UNLK", 18) {
        POOL_MANAGER = poolManager;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        POOL_MANAGER.unlock("");
        return super.transfer(to, amount);
    }

    function unlockCallback(bytes calldata) external pure returns (bytes memory) {
        return "";
    }
}

/// @notice Chaining inside LobsterProxy's `swap`: a PARK leg keeps its output for a later HELD leg of the
/// same call, which spends exactly what was parked. Every pool is registered for the user (the vault).
/// @dev The reference for every call is the same legs made as separate one-leg `swap` calls by the user:
/// every output delivered to the user, and every HELD leg given by hand, as its exact input, what the
/// earlier legs parked (as msg.value when it is ETH). A chained call must match it to the wei, leg by
/// leg and for every account involved (the user, an outsider, the PoolManager, both V3 pools, the
/// proxy), and leave the proxy holding nothing.
///
/// Where a parked output waits depends on the first later HELD leg of that token ({UniswapSwapProxy}):
///   V4 output                PoolManager credit, never transferred; a V3 leg spending it is paid by
///                            the PoolManager itself (`take` to the V3 pool)
///   V3 output, spent by V4   paid by the V3 pool straight to the PoolManager (`sync`, `settle`)
///   V3 output, spent by V3   the proxy's own balance: the only hand-off that puts tokens in the proxy
/// Every chained call checked against the reference is also checked against that rule, from the
/// storage writes it made to the proxy's token balances ({_expectedInProxy}, {_proxyHeld}).
///
/// Route graph (five pools, both versions, native ETH in the middle):
///   token0 --V3--  token1 --V3--  tokenC
///   token0 --V4--  token1 --V4--  ETH  --V4--  tokenC
contract LobsterChainingTest is BatchSwapFixture {
    uint8 constant E_V3_01 = 0; // V3 token0 <-> token1 (fixture pool)
    uint8 constant E_V3_1C = 1; // V3 token1 <-> tokenC
    uint8 constant E_V4_01 = 2; // V4 token0 <-> token1 (cleanKey)
    uint8 constant E_V4_E1 = 3; // V4 ETH    <-> token1 (nativeKey)
    uint8 constant E_V4_EC = 4; // V4 ETH    <-> tokenC (nativeKeyC)

    address constant ETH = address(0);
    /// @dev The leg's output stays with the proxy for a later HELD leg of the call (SwapFlags.PARK)
    bool constant PARKED = true;
    /// @dev The leg's output goes to the caller
    bool constant TO_CALLER = false;

    /// @dev What a call's legs did when made one by one, see {_reference}
    struct Reference {
        /// @dev Per leg, what the one-leg call returned
        uint256[] amounts;
        /// @dev Per leg, what the user paid for it
        uint256[] paid;
        /// @dev {_balances} after the last leg
        uint256[] balancesAfter;
    }

    MockERC20 public tokenC;
    IUniswapV3PoolMinimal public pool1C; // V3 token1 / tokenC
    ProxyPoolKey public nativeKeyC; // ETH / tokenC, no hook
    /// @dev Anyone but the vault. No leg can name it, so it must never receive anything.
    address public outsider = makeAddr("outsider");

    function setUp() public virtual override {
        super.setUp();

        tokenC = new MockERC20("Token C", "TKC", 18);
        tokenC.mint(address(this), 100_000e18);
        tokenC.approve(address(proxy), type(uint256).max);
        tokenC.approve(address(lpRouter), type(uint256).max);

        // V3 token1/tokenC at price 1
        IUniswapV3FactoryMinimal(v3Factory).createPool(address(token1), address(tokenC), FEE);
        pool1C = _v3PoolFor(address(token1), address(tokenC));
        pool1C.initialize(SQRT_PRICE_1_1);
        _mintV3(address(token1), address(tokenC));

        // V4 ETH/tokenC at price 1
        PoolKey memory k = _v4CoreKey(ETH, address(tokenC));
        manager.initialize(k, SQRT_PRICE_1_1);
        _addV4Liquidity(k, 10_000e18);
        nativeKeyC = _toProxyKey(k);

        tokenC.mint(user, 10_000e18);
        vm.prank(user);
        tokenC.approve(address(proxy), type(uint256).max);
        _allow(user, proxy.v3Key(address(pool1C)), SWAP);
        _allow(user, proxy.v4Key(nativeKeyC), SWAP);
    }

    // ---------------------------------------------------------------------------
    // Helpers: pools and legs
    // ---------------------------------------------------------------------------

    function _sorted(address a, address b) internal pure returns (address, address) {
        return a < b ? (a, b) : (b, a);
    }

    function _v3PoolFor(address a, address b) internal view returns (IUniswapV3PoolMinimal) {
        return IUniswapV3PoolMinimal(IUniswapV3FactoryMinimal(v3Factory).getPool(a, b, FEE));
    }

    /// @dev Wide liquidity (1000 of each) in a V3 pool, paid by this contract, which registers the pool
    /// for itself first
    function _mintV3(address a, address b) internal {
        (address t0, address t1) = _sorted(a, b);
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
                deadline: vm.getBlockTimestamp()
            })
        );
    }

    /// @dev A V3 token0/token1 mint of 1 each, to `to`
    function _mintParams(address to) internal view returns (MintParams memory) {
        return MintParams({
            token0: address(token0),
            token1: address(token1),
            fee: FEE,
            tickLower: -TICK_RANGE,
            tickUpper: TICK_RANGE,
            amount0Desired: 1e18,
            amount1Desired: 1e18,
            amount0Min: 0,
            amount1Min: 0,
            recipient: to,
            deadline: vm.getBlockTimestamp()
        });
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

    function _isV3(uint8 edge) internal pure returns (bool) {
        return edge == E_V3_01 || edge == E_V3_1C;
    }

    function _v4KeyOf(uint8 edge) internal view returns (ProxyPoolKey memory) {
        return edge == E_V4_01 ? cleanKey : edge == E_V4_E1 ? nativeKey : nativeKeyC;
    }

    /// @dev An exact-input leg over `edge`, paid by the caller. In V4, currency0 < currency1 (ETH is
    /// address(0)), so the direction is just `tokenIn < tokenOut`.
    function _in(
        uint8 edge,
        address tokenIn,
        uint256 amountIn,
        bool park
    )
        internal
        view
        returns (SwapCalldata.Leg memory leg)
    {
        address tokenOut = _otherSide(edge, tokenIn);
        if (_isV3(edge)) leg = _v3In(tokenIn, tokenOut, amountIn, 0);
        else leg = _v4In(_v4KeyOf(edge), tokenIn < tokenOut, _u128(amountIn), 0);
        leg.park = park;
    }

    /// @dev An exact-input leg over `edge` spending everything earlier legs of the call parked of
    /// `tokenIn` (HELD: it has no amount of its own)
    function _held(uint8 edge, address tokenIn, bool park) internal view returns (SwapCalldata.Leg memory leg) {
        leg = _in(edge, tokenIn, 0, park);
        leg.held = true;
    }

    /// @dev An exact-output leg over `edge`, paid by the caller
    function _out(
        uint8 edge,
        address tokenIn,
        uint256 amountOut,
        uint256 maxIn,
        bool park
    )
        internal
        view
        returns (SwapCalldata.Leg memory leg)
    {
        address tokenOut = _otherSide(edge, tokenIn);
        if (_isV3(edge)) leg = _v3Out(tokenIn, tokenOut, amountOut, maxIn);
        else leg = _v4Out(_v4KeyOf(edge), tokenIn < tokenOut, _u128(amountOut), _u128(maxIn));
        leg.park = park;
    }

    /// @dev An exact-input V3 leg between any two tokens (fee FEE)
    function _v3Leg(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        bool park
    )
        internal
        pure
        returns (SwapCalldata.Leg memory leg)
    {
        leg = _v3In(tokenIn, tokenOut, amountIn, 0);
        leg.park = park;
    }

    function _v3Held(address tokenIn, address tokenOut, bool park) internal pure returns (SwapCalldata.Leg memory leg) {
        leg = _v3Leg(tokenIn, tokenOut, 0, park);
        leg.held = true;
    }

    function _withLimit(
        SwapCalldata.Leg memory leg,
        uint160 sqrtPriceLimitX96
    )
        internal
        pure
        returns (SwapCalldata.Leg memory)
    {
        leg.sqrtPriceLimitX96 = sqrtPriceLimitX96;
        return leg;
    }

    function _batch(
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

    function _batch(
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

    /// @dev The `data` of `swap` running `legs`, due by the current block. Reads the timestamp through
    /// the cheatcode, as the snapshots taken by {_reference} require.
    function _packed(SwapCalldata.Leg[] memory legs) internal view returns (bytes memory) {
        return SwapCalldata.encode(vm.getBlockTimestamp(), legs);
    }

    /// @dev Full calldata of a `swap` running `legs`
    function _swapCall(SwapCalldata.Leg[] memory legs) internal view returns (bytes memory) {
        return abi.encodeCall(proxy.swap, (_packed(legs)));
    }

    /// @dev The msg.value a leg needs when the caller pays it: its native input, if any
    function _valueFor(SwapCalldata.Leg memory leg) internal pure returns (uint256) {
        if (leg.tokenIn != ETH || leg.held) return 0;
        return leg.exactOut ? leg.bound : leg.amount;
    }

    function _chainValue(SwapCalldata.Leg[] memory legs) internal pure returns (uint256 value) {
        for (uint256 i = 0; i < legs.length; i++) {
            value += _valueFor(legs[i]);
        }
    }

    function _anyV4(SwapCalldata.Leg[] memory legs) internal pure returns (bool) {
        for (uint256 i = 0; i < legs.length; i++) {
            if (legs[i].v4) return true;
        }
        return false;
    }

    /// @dev A random walk of `n` exact-input hops from `token`, the first one paying `amount`, each
    /// later one spending the previous output
    function _randomRoute(
        address token,
        uint256 n,
        uint256 amount,
        uint256 seed
    )
        internal
        view
        returns (SwapCalldata.Leg[] memory legs)
    {
        legs = new SwapCalldata.Leg[](n);
        for (uint256 i = 0; i < n; i++) {
            uint8 edge = _randomEdgeFrom(token, uint256(keccak256(abi.encode(seed, i))));
            bool last = i == n - 1;
            legs[i] = i == 0 ? _in(edge, token, amount, !last) : _held(edge, token, !last);
            token = _otherSide(edge, token);
        }
    }

    function _randomEdgeFrom(address token, uint256 r) internal view returns (uint8) {
        if (token == address(token0)) return [E_V3_01, E_V4_01][r % 2];
        if (token == address(token1)) return [E_V3_01, E_V3_1C, E_V4_01, E_V4_E1][r % 4];
        if (token == address(tokenC)) return [E_V3_1C, E_V4_EC][r % 2];
        return [E_V4_E1, E_V4_EC][r % 2]; // ETH
    }

    /// @dev A price limit one tick away from 1:1 in the direction of a token1 -> tokenC swap on pool1C
    function _oneTickAway1C() internal view returns (uint160) {
        return TickMath.getSqrtRatioAtTick(address(token1) < address(tokenC) ? int24(-1) : int24(1));
    }

    function _v3Tick(IUniswapV3PoolMinimal pool) internal view returns (int24 tick) {
        (, tick,,,,,) = pool.slot0();
    }

    function _v4Tick(ProxyPoolKey memory key) internal view returns (int24 tick) {
        (, tick,,) = StateLibrary.getSlot0(IPoolManager(address(manager)), PoolId.wrap(keccak256(abi.encode(key))));
    }

    /// @dev A band as the proxy packs it in its plan words: minTick | maxTick << 24, 24 bits each
    function _bandWord(int24 minTick, int24 maxTick) internal pure returns (uint256 band) {
        assembly ("memory-safe") {
            band := or(and(minTick, 0xffffff), shl(24, and(maxTick, 0xffffff)))
        }
    }

    /// @dev Lists `token` against token0: a 1:1 V3 pool with wide liquidity, registered for the user
    function _listAgainstToken0(MockERC20 token) internal {
        token.mint(address(this), 100_000e18);
        token.approve(address(proxy), type(uint256).max);
        token.approve(address(lpRouter), type(uint256).max);
        IUniswapV3FactoryMinimal(v3Factory).createPool(address(token0), address(token), FEE);
        _v3PoolFor(address(token0), address(token)).initialize(SQRT_PRICE_1_1);
        _mintV3(address(token0), address(token));
        _allow(user, proxy.v3Key(address(_v3PoolFor(address(token0), address(token)))), SWAP);
    }

    /// @dev A token calling back into the proxy when armed, listed against token0
    function _deployReentrantToken() internal returns (ReentrantERC20 evil) {
        evil = new ReentrantERC20();
        _listAgainstToken0(evil);
    }

    // ---------------------------------------------------------------------------
    // Helpers: the reference and the assertions
    // ---------------------------------------------------------------------------

    function _assets() internal view returns (address[4] memory) {
        return [address(token0), address(token1), address(tokenC), ETH];
    }

    function _assetIndex(address token) internal view returns (uint256) {
        address[4] memory assets = _assets();
        for (uint256 i = 0; i < 4; i++) {
            if (assets[i] == token) return i;
        }
        revert("unknown token");
    }

    function _holders() internal view returns (address[6] memory) {
        return [user, outsider, address(manager), address(v3Pool), address(pool1C), address(proxy)];
    }

    function _balanceOf(address token, address who) internal view returns (uint256) {
        return token == ETH ? who.balance : MockERC20(token).balanceOf(who);
    }

    /// @dev Everything a call could move: every asset of every account involved, the proxy included
    function _balances() internal view returns (uint256[] memory b) {
        address[6] memory holders = _holders();
        address[4] memory assets = _assets();
        b = new uint256[](24);
        for (uint256 h = 0; h < 6; h++) {
            for (uint256 a = 0; a < 4; a++) {
                b[4 * h + a] = _balanceOf(assets[a], holders[h]);
            }
        }
    }

    function _assertBalancesEq(uint256[] memory actual, uint256[] memory expected, string memory ctx) internal pure {
        string[6] memory holders = ["user", "outsider", "PoolManager", "V3 pool 0/1", "V3 pool 1/C", "proxy"];
        string[4] memory assets = ["token0", "token1", "tokenC", "ETH"];
        for (uint256 i = 0; i < expected.length; i++) {
            assertEq(actual[i], expected[i], string.concat(ctx, ": ", holders[i / 4], " ", assets[i % 4]));
        }
    }

    function _assertNothingParked() internal view {
        assertEq(token0.balanceOf(address(proxy)), 0, "proxy holds token0");
        assertEq(token1.balanceOf(address(proxy)), 0, "proxy holds token1");
        assertEq(tokenC.balanceOf(address(proxy)), 0, "proxy holds tokenC");
        assertEq(address(proxy).balance, 0, "proxy holds ETH");
    }

    /// @dev Expects exactly `count` PoolManager unlocks from here to the end of the test
    function _expectUnlocks(uint64 count) internal {
        vm.expectCall(address(manager), abi.encodeWithSelector(IPoolManager.unlock.selector), count);
    }

    /// @dev `swap(legs)` by the user, with `value`, must revert with `selector`
    function _assertSwapReverts(SwapCalldata.Leg[] memory legs, uint256 value, bytes4 selector) internal {
        bytes memory data = _packed(legs);
        vm.prank(user);
        vm.expectRevert(selector);
        proxy.swap{value: value}(data);
    }

    /// @dev The reference for a call: each leg as a one-leg `swap` by the user, delivering to the user. A
    /// HELD leg gets as exact input what earlier legs parked of its input token and later legs have not
    /// spent yet, all measured from the user's balances (as msg.value when it is ETH). Rewinds
    /// everything afterwards.
    function _reference(SwapCalldata.Leg[] memory legs) internal returns (Reference memory ref) {
        uint256 snap = vm.snapshotState();
        uint256[4] memory parked;
        ref.amounts = new uint256[](legs.length);
        ref.paid = new uint256[](legs.length);
        for (uint256 i = 0; i < legs.length; i++) {
            SwapCalldata.Leg memory one = abi.decode(abi.encode(legs[i]), (SwapCalldata.Leg));
            one.park = false;
            one.held = false;
            if (legs[i].held) one.amount = _u128(parked[_assetIndex(one.tokenIn)]);
            uint256 inBefore = _balanceOf(one.tokenIn, user);
            uint256 outBefore = _balanceOf(one.tokenOut, user);
            bytes memory data = _packed(_batch(one));
            vm.prank(user);
            ref.amounts[i] = proxy.swap{value: _valueFor(one)}(data)[0];
            ref.paid[i] = inBefore - _balanceOf(one.tokenIn, user);
            uint256 received = _balanceOf(one.tokenOut, user) - outBefore;
            if (legs[i].held) parked[_assetIndex(one.tokenIn)] -= ref.paid[i];
            if (legs[i].park) parked[_assetIndex(one.tokenOut)] += received;
        }
        for (uint256 t = 0; t < 4; t++) {
            assertEq(parked[t], 0, "test bug: the reference leaves parked funds unspent");
        }
        ref.balancesAfter = _balances();
        vm.revertToState(snap);
    }

    /// @dev Runs `legs` as one chained call by the user and requires it to match `ref`: the same amount
    /// for every leg and the same balances for every account; one unlock if a leg is V4, none
    /// otherwise; and each parked output waiting where {_expectedInProxy} says. `surplus` is ETH sent on
    /// top of what the call's native legs need, which must come back to the user.
    function _assertChainMatches(
        SwapCalldata.Leg[] memory legs,
        Reference memory ref,
        uint256 surplus
    )
        internal
        returns (uint256[] memory amounts)
    {
        _expectUnlocks(_anyV4(legs) ? 1 : 0);
        bytes memory data = _packed(legs);
        uint256 value = _chainValue(legs) + surplus;
        vm.startStateDiffRecording();
        vm.prank(user);
        amounts = proxy.swap{value: value}(data);
        VmSafe.AccountAccess[] memory accesses = vm.stopAndReturnStateDiff();

        assertEq(amounts.length, legs.length, "one amount per leg");
        for (uint256 i = 0; i < legs.length; i++) {
            assertEq(
                amounts[i], ref.amounts[i], string.concat("leg ", vm.toString(i), " differs from the one-leg calls")
            );
        }
        _assertBalancesEq(_balances(), ref.balancesAfter, "chained call vs one-leg calls");
        address[4] memory assets = _assets();
        for (uint256 t = 0; t < 3; t++) {
            assertEq(
                _proxyHeld(accesses, assets[t]),
                _expectedInProxy(legs, assets[t]),
                string.concat("wrong place for parked ", MockERC20(assets[t]).symbol())
            );
        }
    }

    /// @dev The central property: the chained call matches its one-leg reference and leaves the proxy
    /// empty
    function _assertChainMatchesManual(SwapCalldata.Leg[] memory legs) internal returns (uint256[] memory) {
        return _assertChainMatchesManual(legs, 0);
    }

    /// @dev The same, sending `surplus` ETH on top of what the call's native legs need
    function _assertChainMatchesManual(
        SwapCalldata.Leg[] memory legs,
        uint256 surplus
    )
        internal
        returns (uint256[] memory amounts)
    {
        amounts = _assertChainMatches(legs, _reference(legs), surplus);
        _assertNothingParked();
    }

    /// @dev The routing rule of {UniswapSwapProxy}: a V3 output waits in the proxy when the first later
    /// leg spending that token (HELD) is a V3 leg, or when none does; it goes straight to the PoolManager
    /// when that leg is a V4 one. V4 outputs never leave the PoolManager.
    function _expectedInProxy(SwapCalldata.Leg[] memory legs, address token) internal pure returns (bool) {
        for (uint256 i = 0; i < legs.length; i++) {
            if (legs[i].v4 || !legs[i].park || legs[i].tokenOut != token) continue;
            uint256 j = i + 1;
            while (j < legs.length && !(legs[j].held && legs[j].tokenIn == token)) j++;
            if (j == legs.length || !legs[j].v4) return true;
        }
        return false;
    }

    /// @dev Whether the recorded calls ever set the proxy's balance of `token` to a non-zero value (and
    /// kept the write)
    function _proxyHeld(VmSafe.AccountAccess[] memory accesses, address token) internal returns (bool) {
        bytes32 slot = _balanceSlot(token, address(proxy));
        for (uint256 i = 0; i < accesses.length; i++) {
            VmSafe.StorageAccess[] memory touched = accesses[i].storageAccesses;
            for (uint256 j = 0; j < touched.length; j++) {
                VmSafe.StorageAccess memory s = touched[j];
                if (s.account == token && s.slot == slot && s.isWrite && !s.reverted && s.newValue != bytes32(0)) {
                    return true;
                }
            }
        }
        return false;
    }

    /// @dev The storage slot holding `holder`'s balance in `token`: the one `balanceOf` reads
    function _balanceSlot(address token, address holder) internal returns (bytes32 slot) {
        vm.record();
        uint256 balance = MockERC20(token).balanceOf(holder);
        (bytes32[] memory reads,) = vm.accesses(token);
        vm.stopRecord();
        assertEq(reads.length, 1, "balanceOf reads one slot");
        slot = reads[0];
        assertEq(uint256(vm.load(token, slot)), balance, "that slot holds the balance");
    }

    /// @dev Whether the recorded calls include a call from `from` to `to` with `selector`
    function _called(
        VmSafe.AccountAccess[] memory accesses,
        address from,
        address to,
        bytes4 selector
    )
        internal
        pure
        returns (bool)
    {
        for (uint256 i = 0; i < accesses.length; i++) {
            if (accesses[i].accessor == from && accesses[i].account == to && _sig(accesses[i].data) == selector) {
                return true;
            }
        }
        return false;
    }

    /// @dev The first 4 bytes of `data` (zero when shorter), as `bytes4(data)` but without a cast
    function _sig(bytes memory data) internal pure returns (bytes4 sig) {
        if (data.length < 4) return sig;
        assembly ("memory-safe") {
            sig := and(mload(add(data, 0x20)), shl(224, 0xffffffff))
        }
    }

    // ---------------------------------------------------------------------------
    // Routes
    // ---------------------------------------------------------------------------

    /// @notice token0 -V3-> token1 -V3-> tokenC -V4-> ETH, one transaction, only the first amount fixed.
    /// token1 waits in the proxy for the second V3 leg, whose pool pays tokenC straight to the PoolManager.
    function test_chain_threeHopsEndingInNativeEth() public {
        SwapCalldata.Leg[] memory legs = _batch(
            _in(E_V3_01, address(token0), 1e18, PARKED),
            _held(E_V3_1C, address(token1), PARKED),
            _held(E_V4_EC, address(tokenC), TO_CALLER)
        );
        Reference memory ref = _reference(legs);
        vm.expectCall(address(tokenC), abi.encodeCall(IERC20Minimal.transfer, (address(manager), ref.amounts[1])), 1);

        uint256 ethBefore = recipient.balance;
        uint256[] memory amounts = _assertChainMatches(legs, ref, 0);
        _assertNothingParked();

        assertGt(amounts[2], 0, "no ETH out");
        assertEq(recipient.balance - ethBefore, amounts[2], "recipient did not get the final ETH");
    }

    /// @notice ETH as the intermediate: token1 -V4-> ETH (parked as credit) -V4-> tokenC
    function test_chain_nativeEthInTheMiddle() public {
        _assertChainMatchesManual(_batch(_in(E_V4_E1, address(token1), 1e18, PARKED), _held(E_V4_EC, ETH, TO_CALLER)));
    }

    /// @notice V4 -> V3 -> V3: an ERC20 parked as PoolManager credit, paid by the PoolManager to the first
    /// V3 pool, whose output waits in the proxy for the second
    function test_chain_crossesVersionsBothWays() public {
        _assertChainMatchesManual(
            _batch(
                _in(E_V4_01, address(token1), 1e18, PARKED), // -> token0
                _held(E_V3_01, address(token0), PARKED), // -> token1
                _held(E_V3_1C, address(token1), TO_CALLER) // -> tokenC
            )
        );
    }

    /// @notice Two independent chained routes in one call
    function test_chain_twoRoutesInOneBatch() public {
        _assertChainMatchesManual(
            _batch(
                _in(E_V3_01, address(token0), 1e18, PARKED), // route A: token0 -> token1
                _held(E_V3_1C, address(token1), TO_CALLER), //            -> tokenC
                _in(E_V4_EC, address(tokenC), 2e18, PARKED), // route B: tokenC -> ETH
                _held(E_V4_E1, ETH, TO_CALLER) //                         -> token1
            )
        );
    }

    /// @notice A random walk of 1-4 hops over all five pools, both versions, ETH in the middle or at
    /// the end, from a random starting token and amount. Each call also opens exactly one unlock if it has
    /// a V4 leg (none otherwise), and the proxy holds a token during it exactly when a V3 leg hands that
    /// token to another V3 leg.
    function testFuzz_randomRoute_matchesManualSequence(
        uint256 seed,
        uint256 hops,
        uint256 amount,
        uint8 start
    )
        public
    {
        address[3] memory starts = [address(token0), address(token1), address(tokenC)];
        _assertChainMatchesManual(_randomRoute(starts[start % 3], bound(hops, 1, 4), bound(amount, 1e15, 5e18), seed));
    }

    /// @notice The same random walk starting from native ETH, paid from msg.value with a random surplus,
    /// which comes back to the caller
    function testFuzz_randomRouteFromNativeEth_matchesManualSequence(
        uint256 seed,
        uint256 hops,
        uint256 amount,
        uint256 surplus
    )
        public
    {
        _assertChainMatchesManual(
            _randomRoute(ETH, bound(hops, 1, 4), bound(amount, 1e15, 5e18), seed), bound(surplus, 0, 10e18)
        );
    }

    /// @notice A split route merged into a V3 leg: token0 -> token1 on both versions, both outputs parked
    /// and spent together by one HELD leg, which spends exactly their sum. The V3 output waits in the
    /// proxy and the V4 one as credit: the PoolManager pays the credit to the V3 pool (`take`), the proxy
    /// the rest.
    function test_chain_mergesTwoParkedOutputs() public {
        SwapCalldata.Leg[] memory legs = _batch(
            _in(E_V3_01, address(token0), 1e18, PARKED),
            _in(E_V4_01, address(token0), 1e18, PARKED),
            _held(E_V3_1C, address(token1), TO_CALLER)
        );
        Reference memory ref = _reference(legs);
        assertEq(ref.paid[2], ref.amounts[0] + ref.amounts[1], "the reference spends the sum");
        // the PoolManager's `take` is a token1 transfer to the pool too: tell the two payments apart
        assertTrue(ref.amounts[0] != ref.amounts[1], "test needs two different amounts");
        vm.expectCall(
            address(manager),
            abi.encodeCall(IPoolManager.take, (Currency.wrap(address(token1)), address(pool1C), ref.amounts[1])),
            1
        );
        vm.expectCall(address(token1), abi.encodeCall(IERC20Minimal.transfer, (address(pool1C), ref.amounts[0])), 1);

        _assertChainMatches(legs, ref, 0);
        _assertNothingParked();
    }

    /// @notice An exact-output leg can park its exact amount for the next leg to spend: the HELD leg
    /// spends exactly the 2 token1 parked in the proxy, which pays them to the next pool
    function test_chain_exactOutputLegFeedsTheNext() public {
        SwapCalldata.Leg[] memory legs = _batch(
            _out(E_V3_01, address(token0), 2e18, type(uint256).max, PARKED), _held(E_V3_1C, address(token1), TO_CALLER)
        );
        Reference memory ref = _reference(legs);
        assertEq(ref.paid[1], 2e18, "the HELD leg spends exactly the 2 parked token1");
        vm.expectCall(address(token1), abi.encodeCall(IERC20Minimal.transfer, (address(pool1C), 2e18)), 1);

        _assertChainMatches(legs, ref, 0);
        _assertNothingParked();
    }

    /// @notice An exact-output V4 leg can open a chain: its exact output is parked as credit, and the
    /// HELD leg swaps exactly that, the 2 token1, on the PoolManager
    function test_v4Chain_openedByAnExactOutputLeg() public {
        SwapCalldata.Leg[] memory legs = _batch(
            _out(E_V4_01, address(token0), 2e18, type(uint256).max, PARKED), // exactly 2 token1 out
            _held(E_V4_E1, address(token1), TO_CALLER)
        );
        Reference memory ref = _reference(legs);
        assertEq(ref.paid[1], 2e18, "the HELD leg spends exactly the 2 parked token1");
        // token1 -> ETH, exact input (a negative amount), no price limit (V4's MAX_SQRT_PRICE is V3's
        // MAX_SQRT_RATIO)
        IPoolManager.SwapParams memory spend = IPoolManager.SwapParams({
            zeroForOne: false, amountSpecified: -2e18, sqrtPriceLimitX96: TickMath.MAX_SQRT_RATIO - 1
        });
        vm.expectCall(
            address(manager), abi.encodeCall(IPoolManager.swap, (_v4CoreKey(ETH, address(token1)), spend, "")), 1
        );

        _assertChainMatches(legs, ref, 0);
        _assertNothingParked();
    }

    /// @notice An exact-output V3 leg feeding a V4 leg: its pool pays exactly the amount out to the
    /// PoolManager, and the V4 leg spends exactly that
    function test_chain_exactOutputV3LegFeedsAV4Leg() public {
        SwapCalldata.Leg[] memory legs = _batch(
            _out(E_V3_01, address(token0), 2e18, type(uint256).max, PARKED), _held(E_V4_E1, address(token1), TO_CALLER)
        );
        Reference memory ref = _reference(legs);
        vm.expectCall(address(token1), abi.encodeCall(IERC20Minimal.transfer, (address(manager), 2e18)), 1);

        _assertChainMatches(legs, ref, 0);
        _assertNothingParked();
    }

    /// @notice An exact-output V4 leg feeding a V3 leg: the PoolManager pays exactly the amount out to the
    /// V3 pool
    function test_chain_exactOutputV4LegFeedsAV3Leg() public {
        SwapCalldata.Leg[] memory legs = _batch(
            _out(E_V4_01, address(token0), 2e18, type(uint256).max, PARKED), _held(E_V3_1C, address(token1), TO_CALLER)
        );
        Reference memory ref = _reference(legs);
        vm.expectCall(
            address(manager),
            abi.encodeCall(IPoolManager.take, (Currency.wrap(address(token1)), address(pool1C), 2e18)),
            1
        );

        _assertChainMatches(legs, ref, 0);
        _assertNothingParked();
    }

    // ---------------------------------------------------------------------------
    // Where parked funds wait: the hand-offs the routing treats specially
    // ---------------------------------------------------------------------------

    /// @notice V3 -> V4: the V3 pool pays its output straight to the PoolManager, which books it as the
    /// proxy's credit (synced before the swap, settled in the pool's callback), and the V4 leg spends that
    /// credit. token1 never reaches the proxy: no transfer to it, and its balance is never written.
    function test_v3ToV4_outputGoesStraightToThePoolManager() public {
        SwapCalldata.Leg[] memory legs =
            _batch(_in(E_V3_01, address(token0), 1e18, PARKED), _held(E_V4_E1, address(token1), TO_CALLER));
        Reference memory ref = _reference(legs);
        vm.expectCall(address(manager), abi.encodeCall(IPoolManager.sync, (Currency.wrap(address(token1)))), 1);
        vm.expectCall(address(token1), abi.encodeCall(IERC20Minimal.transfer, (address(manager), ref.amounts[0])), 1);
        vm.expectCall(address(manager), abi.encodeCall(IPoolManager.settle, ()), 1);
        vm.expectCall(address(token1), abi.encodeWithSelector(IERC20Minimal.transfer.selector, address(proxy)), 0);

        _assertChainMatches(legs, ref, 0);
        _assertNothingParked();
    }

    /// @notice V4 -> V3: the V4 output stays PoolManager credit, and the V3 pool spending it is paid by the
    /// PoolManager itself (`take` to the pool). token1 never reaches the proxy.
    function test_v4ToV3_poolManagerPaysTheV3Pool() public {
        SwapCalldata.Leg[] memory legs =
            _batch(_in(E_V4_01, address(token0), 1e18, PARKED), _held(E_V3_1C, address(token1), TO_CALLER));
        Reference memory ref = _reference(legs);
        vm.expectCall(
            address(manager),
            abi.encodeCall(IPoolManager.take, (Currency.wrap(address(token1)), address(pool1C), ref.amounts[0])),
            1
        );
        vm.expectCall(address(token1), abi.encodeWithSelector(IERC20Minimal.transfer.selector, address(proxy)), 0);

        _assertChainMatches(legs, ref, 0);
        _assertNothingParked();
    }

    /// @notice A split route merged into a V4 leg: token0 -> token1 on both versions, spent together by
    /// one V4 leg. Both outputs are credit, the V3 one paid by its pool straight to the PoolManager:
    /// token1 never reaches the proxy.
    function test_splitRoute_mergedIntoAV4Leg() public {
        SwapCalldata.Leg[] memory legs = _batch(
            _in(E_V3_01, address(token0), 1e18, PARKED),
            _in(E_V4_01, address(token0), 1e18, PARKED),
            _held(E_V4_E1, address(token1), TO_CALLER)
        );
        Reference memory ref = _reference(legs);
        vm.expectCall(address(token1), abi.encodeCall(IERC20Minimal.transfer, (address(manager), ref.amounts[0])), 1);
        vm.expectCall(address(token1), abi.encodeWithSelector(IERC20Minimal.transfer.selector, address(proxy)), 0);

        _assertChainMatches(legs, ref, 0);
        _assertNothingParked();
    }

    /// @notice A convergent route merged into a V3 leg: token1 produced on V4 (from token0) and on V3
    /// (from tokenC), spent together by one V3 leg: the PoolManager pays the V4 part to the pool, the
    /// proxy the V3 part it holds
    function test_convergentRoute_mergedIntoAV3Leg() public {
        SwapCalldata.Leg[] memory legs = _batch(
            _in(E_V4_01, address(token0), 1e18, PARKED),
            _in(E_V3_1C, address(tokenC), 1e18, PARKED),
            _held(E_V3_01, address(token1), TO_CALLER)
        );
        Reference memory ref = _reference(legs);
        assertTrue(ref.amounts[0] != ref.amounts[1], "test needs two different amounts to tell the payments apart");
        vm.expectCall(
            address(manager),
            abi.encodeCall(IPoolManager.take, (Currency.wrap(address(token1)), address(v3Pool), ref.amounts[0])),
            1
        );
        vm.expectCall(address(token1), abi.encodeCall(IERC20Minimal.transfer, (address(v3Pool), ref.amounts[1])), 1);

        _assertChainMatches(legs, ref, 0);
        _assertNothingParked();
    }

    /// @notice A convergent route merged into a V4 leg: token1 produced by two V3 pools (from token0 and
    /// from tokenC), each paid straight to the PoolManager, and spent together by one V4 leg
    function test_convergentRoute_twoV3OutputsMergedIntoAV4Leg() public {
        SwapCalldata.Leg[] memory legs = _batch(
            _in(E_V3_01, address(token0), 1e18, PARKED),
            _in(E_V3_1C, address(tokenC), 1e18, PARKED),
            _held(E_V4_E1, address(token1), TO_CALLER)
        );
        Reference memory ref = _reference(legs);
        vm.expectCall(address(manager), abi.encodeCall(IPoolManager.sync, (Currency.wrap(address(token1)))), 2);
        vm.expectCall(address(token1), abi.encodeWithSelector(IERC20Minimal.transfer.selector, address(manager)), 2);
        vm.expectCall(address(token1), abi.encodeWithSelector(IERC20Minimal.transfer.selector, address(proxy)), 0);

        _assertChainMatches(legs, ref, 0);
        _assertNothingParked();
    }

    /// @notice A V3-only HELD chain never calls the PoolManager at all (no unlock, no price read): the
    /// parked token1 waits in the proxy, as its balance writes show, and is gone by the end
    function test_v3OnlyChain_neverCallsThePoolManager() public {
        SwapCalldata.Leg[] memory legs =
            _batch(_in(E_V3_01, address(token0), 1e18, PARKED), _held(E_V3_1C, address(token1), TO_CALLER));
        assertTrue(_expectedInProxy(legs, address(token1)), "a V3 -> V3 hand-off goes through the proxy");
        Reference memory ref = _reference(legs);
        vm.expectCall(address(manager), "", 0);

        _assertChainMatches(legs, ref, 0);
        _assertNothingParked();
    }

    /// @notice KNOWN BEHAVIOUR: in a call with a V4 leg every leg runs inside the proxy's unlock, so a
    /// token whose own transfer opens a PoolManager unlock chains through V3 pools in a V3-only call, and
    /// cannot be traded in a call with a V4 leg (its transfer finds the PoolManager already unlocked)
    function test_tokenThatOpensAnUnlock_chainsOnlyInAV3OnlyCall() public {
        UnlockingERC20 unlk = new UnlockingERC20(IPoolManager(address(manager)));
        _listAgainstToken0(unlk);
        SwapCalldata.Leg memory buy = _v3Leg(address(token0), address(unlk), 1e18, PARKED);
        SwapCalldata.Leg memory sell = _v3Held(address(unlk), address(token0), TO_CALLER);

        bytes memory v3Only = _packed(_batch(buy, sell));
        vm.prank(user);
        uint256[] memory amounts = proxy.swap(v3Only);
        assertGt(amounts[1], 0, "the V3-only chain did not run");
        assertEq(unlk.balanceOf(address(proxy)), 0, "proxy holds UNLK");

        // The V3 pool's transfer of the token reverts inside the unlock; the pool reports it as "TF"
        bytes memory withV4 = _packed(_batch(buy, sell, _in(E_V4_01, address(token0), 1e17, TO_CALLER)));
        vm.prank(user);
        vm.expectRevert(bytes("TF"));
        proxy.swap(withV4);
    }

    // ---------------------------------------------------------------------------
    // Nothing may be left behind
    // ---------------------------------------------------------------------------

    /// @notice Whatever a call parks must be spent by its end
    function test_fundsLeftInProxy_revert() public {
        uint256[] memory before = _balances();

        // Parked, and nothing spends it
        _assertSwapReverts(
            _batch(_in(E_V3_01, address(token0), 1e18, PARKED)), 0, IProxyErrors.FundsLeftInProxy.selector
        );

        // Parked, but the next leg is paid by the caller instead of spending it
        _assertSwapReverts(
            _batch(_in(E_V3_01, address(token0), 1e18, PARKED), _in(E_V3_1C, address(token1), 1e17, TO_CALLER)),
            0,
            IProxyErrors.FundsLeftInProxy.selector
        );

        // Parked, then only partly spent: a price limit one tick away stops the next leg early
        _assertSwapReverts(
            _batch(
                _in(E_V3_01, address(token0), 1e18, PARKED),
                _withLimit(_held(E_V3_1C, address(token1), TO_CALLER), _oneTickAway1C())
            ),
            0,
            IProxyErrors.FundsLeftInProxy.selector
        );

        // Parked ETH, never spent
        _assertSwapReverts(
            _batch(_in(E_V4_E1, address(token1), 1e18, PARKED)), 0, IProxyErrors.FundsLeftInProxy.selector
        );

        _assertBalancesEq(_balances(), before, "a rejected call moved funds");
        _assertNothingParked();
    }

    /// @notice The same through the PoolManager: a V3 output paid to it for a V4 leg that stops early, V4
    /// credit a V3 leg only partly spends, and a V3 output parked in a call with a V4 leg that does not
    /// spend it
    function test_fundsLeftInProxy_everyHandOff_reverts() public {
        uint256[] memory before = _balances();

        // V3 -> PoolManager credit, partly spent: token1 -> ETH stops one tick away (oneForZero: price up)
        _assertSwapReverts(
            _batch(
                _in(E_V3_01, address(token0), 1e18, PARKED),
                _withLimit(_held(E_V4_E1, address(token1), TO_CALLER), TickMath.getSqrtRatioAtTick(1))
            ),
            0,
            IProxyErrors.FundsLeftInProxy.selector
        );

        // V4 credit, partly paid to a V3 pool
        _assertSwapReverts(
            _batch(
                _in(E_V4_01, address(token0), 1e18, PARKED),
                _withLimit(_held(E_V3_1C, address(token1), TO_CALLER), _oneTickAway1C())
            ),
            0,
            IProxyErrors.FundsLeftInProxy.selector
        );

        // A V3 output in the proxy, inside the unlock, that the V4 leg (paid by the caller) does not spend
        _assertSwapReverts(
            _batch(_in(E_V3_01, address(token0), 1e18, PARKED), _in(E_V4_01, address(token0), 1e18, TO_CALLER)),
            0,
            IProxyErrors.FundsLeftInProxy.selector
        );

        _assertBalancesEq(_balances(), before, "a rejected call moved funds");
        _assertNothingParked();
    }

    /// @notice A HELD leg needs something its own call parked, of its own input token
    function test_heldBalanceWithNothingHeld_reverts() public {
        _assertSwapReverts(_batch(_held(E_V3_1C, address(token1), TO_CALLER)), 0, IProxyErrors.NothingHeld.selector);
        _assertSwapReverts(_batch(_held(E_V4_EC, ETH, TO_CALLER)), 0, IProxyErrors.NothingHeld.selector);

        // What was parked was already spent by an earlier HELD leg
        _assertSwapReverts(
            _batch(
                _in(E_V3_01, address(token0), 1e18, PARKED),
                _held(E_V3_1C, address(token1), TO_CALLER),
                _held(E_V4_E1, address(token1), TO_CALLER)
            ),
            0,
            IProxyErrors.NothingHeld.selector
        );

        // Only another token is parked
        _assertSwapReverts(
            _batch(_in(E_V3_01, address(token0), 1e18, PARKED), _held(E_V3_1C, address(tokenC), TO_CALLER)),
            0,
            IProxyErrors.NothingHeld.selector
        );
    }

    /// @notice Tokens sent straight to the proxy, and ETH force-fed to it, are never spent by a HELD leg,
    /// which spends exactly what its own call parked (KNOWN BEHAVIOUR). Nor are they paid out: the
    /// end-of-call refund returns only what is left of the caller's own msg.value, so a call that sends
    /// no ETH gets none. Both stay in the proxy.
    function test_fundsSentToTheProxy_areNeverSpentByAHeldLeg() public {
        token1.mint(address(proxy), 5e18);
        vm.deal(address(proxy), 1e18);

        _assertSwapReverts(_batch(_held(E_V3_1C, address(token1), TO_CALLER)), 0, IProxyErrors.NothingHeld.selector);
        _assertSwapReverts(_batch(_held(E_V4_EC, ETH, TO_CALLER)), 0, IProxyErrors.NothingHeld.selector);

        // A chain spends exactly the token1 it parked, to the wei of the one-leg calls
        SwapCalldata.Leg[] memory legs =
            _batch(_in(E_V3_01, address(token0), 1e18, PARKED), _held(E_V3_1C, address(token1), TO_CALLER));
        Reference memory ref = _reference(legs);
        uint256 ethBefore = user.balance;
        _assertChainMatches(legs, ref, 0);

        assertEq(token1.balanceOf(address(proxy)), 5e18, "a HELD leg spent tokens its call did not park");
        assertEq(user.balance, ethBefore, "the force-fed ETH was paid to a caller that sent none");
        assertEq(address(proxy).balance, 1e18, "the force-fed ETH left the proxy");
    }

    /// @notice An exact-output leg cannot spend parked funds: HELD with EXACT_OUT is malformed, on either
    /// version, and the call is refused before anything runs
    function test_heldExactOutputLeg_isMalformed() public {
        SwapCalldata.Leg memory v3Spend = _held(E_V3_1C, address(token1), TO_CALLER);
        v3Spend.exactOut = true;
        v3Spend.bound = type(uint128).max;
        SwapCalldata.Leg memory v4Spend = _held(E_V4_E1, address(token1), TO_CALLER);
        v4Spend.exactOut = true;
        v4Spend.bound = type(uint128).max;

        _expectUnlocks(0);
        vm.expectCall(address(v3Pool), abi.encodeWithSelector(IUniswapV3PoolMinimal.swap.selector), 0);
        _assertSwapReverts(
            _batch(_in(E_V3_01, address(token0), 1e18, PARKED), v3Spend), 0, IProxyErrors.MalformedSwap.selector
        );
        _assertSwapReverts(
            _batch(_in(E_V3_01, address(token0), 1e18, PARKED), v4Spend), 0, IProxyErrors.MalformedSwap.selector
        );
    }

    /// @notice Every leg of a chain is checked before anything runs: a later leg's pool that is not
    /// registered, or has no band, refuses the call before the first leg moves anything
    function test_chain_laterLegNotAllowed_runsNothing() public {
        bytes32[] memory keys = new bytes32[](1);
        keys[0] = proxy.v4Key(nativeKeyC);
        uint8[] memory none = new uint8[](1);
        vm.prank(user);
        proxy.setPools(keys, none);
        bytes32 bandKey = proxy.v3Key(address(pool1C));
        vm.prank(user);
        proxy.setPriceBand(bandKey, 0, 0);
        uint256[] memory before = _balances();

        _expectUnlocks(0);
        vm.expectCall(address(v3Pool), abi.encodeWithSelector(IUniswapV3PoolMinimal.swap.selector), 0);
        _assertSwapReverts(
            _batch(
                _in(E_V3_01, address(token0), 1e18, PARKED),
                _held(E_V4_E1, address(token1), PARKED),
                _held(E_V4_EC, ETH, TO_CALLER)
            ),
            0,
            IProxyErrors.PoolNotAllowed.selector
        );
        _assertSwapReverts(
            _batch(_in(E_V3_01, address(token0), 1e18, PARKED), _held(E_V3_1C, address(token1), TO_CALLER)),
            0,
            IProxyErrors.PriceBandNotSet.selector
        );

        _assertBalancesEq(_balances(), before, "a refused call moved funds");
    }

    // ---------------------------------------------------------------------------
    // Native ETH rules
    // ---------------------------------------------------------------------------

    /// @notice A chain can start from native ETH (`swap` is payable): the input is paid from msg.value,
    /// the rest of which comes back to the caller. Less ETH than the input is refused.
    function test_chain_nativeInputIsPaidFromMsgValue() public {
        SwapCalldata.Leg[] memory legs =
            _batch(_in(E_V4_E1, ETH, 1e18, PARKED), _held(E_V3_1C, address(token1), TO_CALLER));

        _assertSwapReverts(legs, 1e18 - 1, IProxyErrors.NotEnoughEthSent.selector);
        _assertChainMatchesManual(legs, 0.5e18);
    }

    /// @notice A native-input leg paid by the caller never draws on ETH an earlier leg parked (what
    /// `NativeInputMustComeFromAPreviousSwap` guaranteed the old non-payable batch): without msg.value it
    /// cannot be paid, and with it the parked ETH is left unspent. Only a HELD leg spends parked ETH, and
    /// then msg.value comes back in full.
    function test_chain_nativeLegPaidByTheCaller_neverDrawsOnParkedEth() public {
        SwapCalldata.Leg[] memory legs =
            _batch(_in(E_V4_E1, address(token1), 1e18, PARKED), _in(E_V4_EC, ETH, 0.5e18, TO_CALLER));
        uint256[] memory before = _balances();

        _assertSwapReverts(legs, 0, IProxyErrors.NotEnoughEthSent.selector);
        _assertSwapReverts(legs, 0.5e18, IProxyErrors.FundsLeftInProxy.selector);
        _assertBalancesEq(_balances(), before, "a rejected call moved funds");

        _assertChainMatchesManual(
            _batch(_in(E_V4_E1, address(token1), 1e18, PARKED), _held(E_V4_EC, ETH, TO_CALLER)), 1e18
        );
    }

    /// @notice ETH force-fed to the proxy (a selfdestruct, a coinbase payment) belongs to no one. The
    /// native legs of a chain share one msg.value and never draw on that ETH, even where it would cover
    /// what msg.value lacks, down to the last wei; the caller gets back exactly what is left of its
    /// msg.value, and the force-fed ETH stays in the proxy.
    function test_chain_nativeLegs_neverDrawOnForceFedEth() public {
        vm.deal(address(proxy), 1e18);
        SwapCalldata.Leg[] memory legs = _batch(
            _in(E_V4_E1, ETH, 1e18, PARKED), // 1 ETH out of msg.value
            _held(E_V3_1C, address(token1), TO_CALLER),
            _in(E_V4_EC, ETH, 0.5e18, TO_CALLER) // 0.5 ETH out of what is left of it
        );
        uint256[] memory before = _balances();

        // The force-fed ETH would make up the rest of the first leg, or the last wei of the second
        _assertSwapReverts(legs, 0.5e18, IProxyErrors.NotEnoughEthSent.selector);
        _assertSwapReverts(legs, 1.5e18 - 1, IProxyErrors.NotEnoughEthSent.selector);
        _assertBalancesEq(_balances(), before, "a rejected call moved funds");

        uint256 ethBefore = user.balance;
        _assertChainMatches(legs, _reference(legs), 0.25e18);
        assertEq(ethBefore - user.balance, 1.5e18, "the caller did not pay exactly the native input");
        assertEq(address(proxy).balance, 1e18, "the force-fed ETH was spent or refunded");
    }

    /// @notice The proxy has no `receive`: every plain ETH transfer is refused, the PoolManager's
    /// included (parked ETH stays credit, native outputs are taken straight to the vault)
    function test_plainEthTransfersAreRejected_evenFromThePoolManager() public {
        vm.prank(user);
        (bool ok,) = address(proxy).call{value: 1e18}("");
        assertFalse(ok, "proxy accepted ETH from a user");

        vm.deal(address(manager), address(manager).balance + 1e18);
        vm.prank(address(manager));
        (ok,) = address(proxy).call{value: 1e18}("");
        assertFalse(ok, "proxy accepted ETH from the PoolManager");

        vm.prank(user);
        (ok,) = address(proxy).call{value: 1e18}(hex"00");
        assertFalse(ok, "proxy accepted ETH through a fallback");

        assertEq(address(proxy).balance, 0, "proxy holds ETH");
    }

    // ---------------------------------------------------------------------------
    // PARK means nothing outside a chain
    // ---------------------------------------------------------------------------

    /// @notice A one-leg call cannot keep its output: PARK alone reverts, on either version. `mint` still
    /// pays its caller only: neither the old ADDRESS_THIS value nor the proxy can be its recipient.
    function test_parkInASingleLegCall_reverts() public {
        _assertSwapReverts(
            _batch(_in(E_V3_01, address(token0), 1e18, PARKED)), 0, IProxyErrors.FundsLeftInProxy.selector
        );
        _assertSwapReverts(
            _batch(_in(E_V4_01, address(token0), 1e18, PARKED)), 0, IProxyErrors.FundsLeftInProxy.selector
        );

        address[2] memory notTheCaller = [address(2), address(proxy)]; // address(2): Chaining.ADDRESS_THIS
        for (uint256 i = 0; i < 2; i++) {
            MintParams memory params = _mintParams(notTheCaller[i]);
            vm.prank(user);
            vm.expectRevert(IProxyErrors.RecipientMustBeCaller.selector);
            proxy.mint(params);
        }
    }

    // ---------------------------------------------------------------------------
    // Reentrancy: neither parked funds nor the caller's ETH can be reached mid-call
    // ---------------------------------------------------------------------------

    /// @notice The victim's call parks token1 in the proxy, then swaps into a token that calls back into
    /// the proxy the moment the pool delivers it. The callback tries to run its own call spending the
    /// parked token1, from an account that registered the pool, so that no registry check stops it. The
    /// lock refuses it, and the victim's call completes normally. The lock is not the only guard here:
    /// a call's ledger is its own, so past the lock the re-entrant HELD leg would find nothing parked
    /// (NothingHeld), as for tokens sent to the proxy ({test_fundsSentToTheProxy_areNeverSpentByAHeldLeg}).
    function test_reentrantTokenCannotSpendParkedFunds() public {
        ReentrantERC20 evil = _deployReentrantToken();
        _allow(address(evil), proxy.v3Key(address(v3Pool)), SWAP);
        evil.arm(address(proxy), address(proxy), _swapCall(_batch(_held(E_V3_01, address(token1), TO_CALLER))), false);

        bytes memory victim = _packed(
            _batch(
                _in(E_V3_01, address(token0), 1e18, PARKED), // parks token1 in the proxy
                _v3Leg(address(token0), address(evil), 1e18, PARKED), // delivering EVIL triggers the attack
                _held(E_V3_1C, address(token1), TO_CALLER),
                _v3Held(address(evil), address(token0), TO_CALLER)
            )
        );
        vm.prank(user);
        uint256[] memory amounts = proxy.swap(victim);

        assertEq(evil.attempts(), 1, "the attack never fired; test proves nothing");
        assertFalse(evil.attackSucceeded(), "re-entrant call succeeded");
        assertEq(
            evil.attackRevertData(),
            abi.encodeWithSelector(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector),
            "re-entrant call failed for an unexpected reason"
        );
        assertEq(token0.balanceOf(address(evil)), 0, "attacker received parked funds");
        assertGt(amounts[2], 0, "the victim's chain did not spend its token1");
        assertEq(evil.balanceOf(address(proxy)), 0, "proxy holds EVIL");
        _assertNothingParked();
    }

    /// @notice The same attack while the parked funds are PoolManager credit: the victim's call parks
    /// token1 as V4 credit, and inside the same unlock a V3 leg delivers the re-entrant token to the proxy.
    /// Its callback tries to spend that credit: refused by the lock. Past the lock it would still fail:
    /// the PoolManager refuses a second unlock while the victim's is open (AlreadyUnlocked), and the
    /// re-entrant call's own ledger holds nothing.
    function test_reentrantTokenCannotSpendParkedCredit() public {
        ReentrantERC20 evil = _deployReentrantToken();
        _allow(address(evil), proxy.v4Key(nativeKey), SWAP);
        evil.arm(address(proxy), address(proxy), _swapCall(_batch(_held(E_V4_E1, address(token1), TO_CALLER))), false);

        bytes memory victim = _packed(
            _batch(
                _in(E_V4_01, address(token0), 1e18, PARKED), // parks token1 as credit
                _v3Leg(address(token0), address(evil), 1e18, PARKED), // delivering EVIL triggers the attack
                _v3Held(address(evil), address(token0), TO_CALLER),
                _held(E_V4_E1, address(token1), TO_CALLER)
            )
        );
        uint256 ethBefore = user.balance;
        vm.prank(user);
        uint256[] memory amounts = proxy.swap(victim);

        assertEq(evil.attempts(), 1, "the attack never fired; test proves nothing");
        assertFalse(evil.attackSucceeded(), "re-entrant call succeeded");
        assertEq(
            evil.attackRevertData(),
            abi.encodeWithSelector(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector),
            "re-entrant call failed for an unexpected reason"
        );
        assertEq(address(evil).balance, 0, "attacker received the parked credit");
        assertGt(amounts[3], 0, "the victim's chain did not spend its credit");
        assertEq(user.balance - ethBefore, amounts[3], "the victim did not get the ETH");
        assertEq(evil.balanceOf(address(proxy)), 0, "proxy holds EVIL");
        _assertNothingParked();
    }

    /// @notice What is left of the caller's msg.value sits in the proxy while its call runs, and two
    /// guards keep a re-entrant call from taking it. The victim sends 1.5 ETH, a V4 leg spends 1, and a
    /// later leg pays the re-entrant token to its pool from the proxy: the token's hook then makes its
    /// own call, `swap{value: 1}`, a V3-only call it is registered for, while the proxy holds the
    /// victim's other 0.5 ETH. The lock refuses it, and the victim gets the 0.5 ETH back. The second guard
    /// is exact accounting: the same call, made outside any call while the proxy holds ETH it was not
    /// sent, runs and gets back only its own msg.value. (When every refund paid out the proxy's whole
    /// balance, the lock alone kept the victim's ETH from the attacker.)
    function test_reentrantCallCannotSweepTheCallersEth() public {
        ReentrantERC20 evil = _deployReentrantToken();
        // The attacker's own call: a token0 -> token1 swap on a pool it registered, paid with its own
        // token0. It sends 1 wei that no leg spends, so its end-of-call refund runs.
        _allow(address(evil), proxy.v3Key(address(v3Pool)), SWAP);
        token0.mint(address(evil), 1e18);
        vm.prank(address(evil));
        token0.approve(address(proxy), type(uint256).max);
        vm.deal(address(evil), 1);
        bytes memory attack = _packed(_batch(_in(E_V3_01, address(token0), 1e15, TO_CALLER)));
        // Fired when the proxy pays EVIL to its pool, in the HELD leg's callback: the proxy has already
        // cleared the pool it expects there, so the victim's call would complete whatever the attack did
        evil.armWithValue(
            address(_v3PoolFor(address(token0), address(evil))),
            address(proxy),
            abi.encodeCall(proxy.swap, (attack)),
            false,
            1
        );

        bytes memory victim = _packed(
            _batch(
                _in(E_V4_E1, ETH, 1e18, TO_CALLER), // spends 1 of the 1.5 ETH sent
                _v3Leg(address(token0), address(evil), 1e18, PARKED),
                _v3Held(address(evil), address(token0), TO_CALLER) // its payment to the pool fires the attack
            )
        );
        uint256 victimEth = user.balance;
        uint256 managerEth = address(manager).balance;
        vm.prank(user);
        uint256[] memory amounts = proxy.swap{value: 1.5e18}(victim);

        assertEq(evil.attempts(), 1, "the attack never fired; test proves nothing");
        assertEq(evil.targetEthWhenFired(), 0.5e18, "the victim's ETH was not in the proxy; test proves nothing");
        assertFalse(evil.attackSucceeded(), "re-entrant call succeeded");
        assertEq(
            evil.attackRevertData(),
            abi.encodeWithSelector(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector),
            "re-entrant call failed for an unexpected reason"
        );
        assertEq(address(evil).balance, 1, "the attacker's ETH changed");
        assertEq(victimEth - user.balance, 1e18, "the victim did not pay exactly its native input");
        assertEq(address(manager).balance - managerEth, 1e18, "the PoolManager was not paid the native input");
        assertGt(amounts[0], 0, "the victim's native leg did not run");
        assertGt(amounts[2], 0, "the victim's chain did not complete");
        assertEq(evil.balanceOf(address(proxy)), 0, "proxy holds EVIL");
        _assertNothingParked();

        // The second guard, outside any call: ETH in the proxy that this call did not send stays there
        vm.deal(address(proxy), 0.5e18);
        vm.prank(address(evil));
        uint256[] memory got = proxy.swap{value: 1}(attack);

        assertGt(got[0], 0, "the attacker's call did not run; test proves nothing");
        assertEq(token1.balanceOf(address(evil)), got[0], "the attacker did not get its output");
        assertEq(address(evil).balance, 1, "the attacker got back more than its own msg.value");
        assertEq(address(proxy).balance, 0.5e18, "ETH the proxy held was paid to a caller that did not send it");
    }

    /// @notice The lock covers every entry point, not only `swap`, for the whole call: inside the
    /// PoolManager unlock as much as outside it. Each one is tried from a token's transfer hook in the
    /// middle of a chain, in a V3-only call and in a call with a V4 leg.
    function test_everyEntryPointIsLockedDuringACall() public {
        assertEq(
            IProxyErrors.ReentrancyGuardReentrantCall.selector,
            ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector,
            "not OpenZeppelin's selector"
        );
        ReentrantERC20 evil = _deployReentrantToken();

        bytes32[] memory keys = new bytes32[](1);
        keys[0] = proxy.v3Key(address(v3Pool));
        uint8[] memory perms = new uint8[](1);
        perms[0] = SWAP;
        bytes[] memory attacks = new bytes[](6);
        attacks[0] = _swapCall(_batch(_in(E_V3_01, address(token0), 1e18, TO_CALLER)));
        attacks[1] = abi.encodeCall(proxy.mint, (_mintParams(address(evil))));
        attacks[2] = abi.encodeCall(proxy.setPools, (keys, perms));
        attacks[3] = abi.encodeCall(proxy.setPriceBand, (keys[0], TickMath.MIN_TICK, TickMath.MAX_TICK));
        attacks[4] = abi.encodeCall(proxy.setV4Roles, (address(0), bytes32(0)));
        attacks[5] = abi.encodeCall(proxy.modifyLiquidityV4, (new V4LiquidityOp[](0), vm.getBlockTimestamp()));

        bytes[2] memory victims = [
            _packed(
                _batch(
                    _v3Leg(address(token0), address(evil), 1e18, PARKED),
                    _v3Held(address(evil), address(token0), TO_CALLER)
                )
            ),
            _packed(
                _batch(
                    _v3Leg(address(token0), address(evil), 1e18, PARKED),
                    _v3Held(address(evil), address(token0), TO_CALLER),
                    _in(E_V4_01, address(token0), 1e17, TO_CALLER)
                )
            )
        ];

        uint256 fired;
        for (uint256 a = 0; a < attacks.length; a++) {
            for (uint256 v = 0; v < 2; v++) {
                evil.arm(address(proxy), address(proxy), attacks[a], false);
                vm.prank(user);
                proxy.swap(victims[v]);
                fired++;

                string memory ctx = string.concat("entry point ", vm.toString(a), ", victim ", vm.toString(v));
                assertEq(evil.attempts(), fired, string.concat(ctx, ": the attack never fired"));
                assertFalse(evil.attackSucceeded(), string.concat(ctx, ": ran inside a call"));
                assertEq(
                    evil.attackRevertData(),
                    abi.encodeWithSelector(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector),
                    string.concat(ctx, ": was not locked")
                );
            }
        }
        _assertNothingParked();
    }

    /// @notice The V3 -> V4 hand-off syncs the PoolManager before the V3 swap and settles in the pool's
    /// callback. A token that settles the PoolManager itself in between (from its transfer hook, once the
    /// output has landed there) is credited the output instead of the proxy: the proxy's own settlement
    /// then comes up short and the whole call reverts with UnexpectedSettlement, so nobody gets anything.
    function test_v3ToV4HandOff_tokenThatSettlesFirst_cannotClaimTheOutput() public {
        ReentrantERC20 evil = _deployReentrantToken();
        (address c0, address c1) = _sorted(address(token0), address(evil));
        PoolKey memory k = _v4CoreKey(c0, c1);
        manager.initialize(k, SQRT_PRICE_1_1);
        _addV4Liquidity(k, 0);
        ProxyPoolKey memory evilKey = _toProxyKey(k);
        _allow(user, proxy.v4Key(evilKey), SWAP);

        SwapCalldata.Leg memory spend = _v4In(evilKey, address(evil) < address(token0), 0, 0);
        spend.held = true;
        bytes memory data = _packed(_batch(_v3Leg(address(token0), address(evil), 1e18, PARKED), spend));
        evil.arm(address(manager), address(manager), abi.encodeCall(IPoolManager.settle, ()), true);
        uint256[] memory before = _balances();

        vm.startStateDiffRecording();
        vm.prank(user);
        vm.expectRevert(IProxyErrors.UnexpectedSettlement.selector);
        proxy.swap(data);
        VmSafe.AccountAccess[] memory accesses = vm.stopAndReturnStateDiff();

        assertTrue(
            _called(accesses, address(evil), address(manager), IPoolManager.settle.selector),
            "the token never settled; test proves nothing"
        );
        _assertBalancesEq(_balances(), before, "a refused call moved funds");
        assertEq(evil.balanceOf(address(proxy)), 0, "proxy holds EVIL");
    }

    // ---------------------------------------------------------------------------
    // One unlock per call with a V4 leg
    // ---------------------------------------------------------------------------

    /// @notice V4 -> V4 -> V4, each spending what the previous parked: one unlock, and the intermediate
    /// tokens never reach the proxy (credit throughout)
    function test_v4Chain_runsInOneUnlock() public {
        SwapCalldata.Leg[] memory legs = _batch(
            _in(E_V4_01, address(token0), 1e18, PARKED),
            _held(E_V4_E1, address(token1), PARKED),
            _held(E_V4_EC, ETH, TO_CALLER)
        );
        Reference memory ref = _reference(legs);
        vm.expectCall(address(token1), abi.encodeWithSelector(IERC20Minimal.transfer.selector, address(proxy)), 0);

        _assertChainMatches(legs, ref, 0);
        _assertNothingParked();
    }

    /// @notice V4 legs that do not chain no longer get an unlock each: any call with a V4 leg opens exactly
    /// one, shared by every leg, here with a V4 output that a later V3 leg spends
    function test_unchainedV4Swaps_shareOneUnlock() public {
        _assertChainMatchesManual(
            _batch(
                _in(E_V4_01, address(token0), 1e18, TO_CALLER), // not parked
                _in(E_V4_01, address(token1), 1e18, PARKED), // parks token0...
                _in(E_V4_EC, address(tokenC), 1e18, TO_CALLER), // ...which this does not spend
                _held(E_V3_01, address(token0), TO_CALLER) // a V3 leg does, paid by the PoolManager
            )
        );
    }

    /// @notice A V3 leg between V4 legs no longer splits the unlock: V4 -> V3 -> V4 runs in one, and both
    /// hand-offs go through the PoolManager (it pays the V3 pool; the V3 pool pays it)
    function test_v3LegBetweenV4Legs_runsInTheSameUnlock() public {
        SwapCalldata.Leg[] memory legs = _batch(
            _in(E_V4_01, address(token1), 1e18, PARKED), // -> token0
            _held(E_V3_01, address(token0), PARKED), // -> token1
            _held(E_V4_E1, address(token1), TO_CALLER) // -> ETH
        );
        Reference memory ref = _reference(legs);
        vm.expectCall(
            address(manager),
            abi.encodeCall(IPoolManager.take, (Currency.wrap(address(token0)), address(v3Pool), ref.amounts[0])),
            1
        );
        vm.expectCall(address(token1), abi.encodeCall(IERC20Minimal.transfer, (address(manager), ref.amounts[1])), 1);

        _assertChainMatches(legs, ref, 0);
        _assertNothingParked();
    }

    /// @notice A chained V4 leg spends everything held: credit parked earlier in the call AND what an
    /// earlier V3 leg parked in the proxy itself. (The V3 output waits in the proxy because a V3 leg is
    /// the first to spend token1; that leg, stopped early by a price limit, is paid from credit only, so
    /// the V4 leg finds both and pays the proxy's part with sync / transfer / settle.)
    function test_v4Chain_spendsCreditAndProxyBalanceTogether() public {
        SwapCalldata.Leg[] memory legs = _batch(
            _in(E_V3_01, address(token0), 1e18, PARKED), // token1 parked in the proxy
            _in(E_V4_01, address(token0), 1e18, PARKED), // token1 parked as V4 credit
            _withLimit(_held(E_V3_1C, address(token1), TO_CALLER), _oneTickAway1C()), // spends part of the credit
            _held(E_V4_E1, address(token1), TO_CALLER) // spends the rest of the credit and the proxy's token1
        );
        Reference memory ref = _reference(legs);
        assertLt(ref.paid[2], ref.amounts[1], "test needs the third leg to stop inside the credit");
        vm.expectCall(
            address(manager),
            abi.encodeCall(IPoolManager.take, (Currency.wrap(address(token1)), address(pool1C), ref.paid[2])),
            1
        );
        vm.expectCall(address(manager), abi.encodeCall(IPoolManager.sync, (Currency.wrap(address(token1)))), 1);
        vm.expectCall(address(token1), abi.encodeCall(IERC20Minimal.transfer, (address(manager), ref.amounts[0])), 1);

        _assertChainMatches(legs, ref, 0);
        _assertNothingParked();
    }

    /// @notice A chained leg that stops early leaves credit behind: the end-of-call check refuses the call
    function test_v4Chain_partlySpent_reverts() public {
        uint256[] memory before = _balances();

        // token1 -> ETH with a limit one tick away (oneForZero pushes the price up) spends only part of the
        // parked token1
        _assertSwapReverts(
            _batch(
                _in(E_V4_01, address(token0), 1e18, PARKED),
                _withLimit(_held(E_V4_E1, address(token1), TO_CALLER), TickMath.getSqrtRatioAtTick(1))
            ),
            0,
            IProxyErrors.FundsLeftInProxy.selector
        );

        _assertBalancesEq(_balances(), before, "a rejected call moved funds");
    }

    /// @notice Forged swap-unlock data is refused like any other. The payload follows the proxy's own
    /// format (SWAP_TAG | legs | msg.value << 1 | usesLedger | plan words | data), whose plan could name
    /// any contract as a V3 leg's pool, with any band. Only the PoolManager may call `unlockCallback`, and
    /// even the PoolManager only while `swap` is running: outside it the payload never runs. Forged V3
    /// swap callbacks in the chain modes (pay from parked credit, settle a hand-off) are refused too: only
    /// the pool the proxy is calling right now may call it, and no call is running.
    function test_forgedChainCallbackIsRefused() public {
        address attacker = makeAddr("attacker");
        bytes memory forged = bytes.concat(
            bytes1(0x01), // SWAP_TAG
            abi.encode(
                uint256(1), // legs
                uint256(1), // msg.value << 1 | usesLedger: no ETH, uses the ledger
                uint256(uint160(attacker)), // the leg's "pool"
                _bandWord(TickMath.MIN_TICK, TickMath.MAX_TICK)
            ),
            _packed(_batch(_in(E_V3_01, address(token0), 1e18, TO_CALLER)))
        );
        // tokenIn | MODE_HELD + MODE_TO_MANAGER | credit available
        bytes memory callbackData = abi.encodePacked(address(token0), uint8(3), uint256(1e18));
        uint256[] memory before = _balances();

        address[2] memory callers = [attacker, user];
        for (uint256 i = 0; i < 2; i++) {
            vm.prank(callers[i]);
            vm.expectRevert(IProxyErrors.NotPoolManager.selector);
            proxy.unlockCallback(forged);
        }
        // The PoolManager itself, with no `swap` running: refused before the plan runs (its "pool" is
        // never called)
        vm.expectCall(attacker, "", 0);
        vm.prank(address(manager));
        vm.expectRevert(IProxyErrors.UnexpectedCallback.selector);
        proxy.unlockCallback(forged);
        address[2] memory pools = [attacker, address(v3Pool)];
        for (uint256 i = 0; i < 2; i++) {
            vm.prank(pools[i]);
            vm.expectRevert(IProxyErrors.UnexpectedCallback.selector);
            proxy.uniswapV3SwapCallback(1e18, -1e18, callbackData);
        }

        _assertBalancesEq(_balances(), before, "a forged callback moved funds");
    }

    // ---------------------------------------------------------------------------
    // Price bands inside a chain: every leg is checked before and after it runs
    // ---------------------------------------------------------------------------

    /// @notice The second leg of a chain would push its V4 pool out of the caller's band: the whole call
    /// reverts, whether its input was V4 credit or a V3 output paid to the PoolManager
    function test_v4Chain_legLeavingItsBand_revertsTheBatch() public {
        int24 tick = _v4Tick(nativeKey);
        bytes32 key = proxy.v4Key(nativeKey);
        vm.prank(user);
        proxy.setPriceBand(key, tick - 10, tick + 10);
        uint256[] memory before = _balances();

        _assertSwapReverts(
            _batch(_in(E_V4_01, address(token0), 50e18, PARKED), _held(E_V4_E1, address(token1), TO_CALLER)),
            0,
            IProxyErrors.PriceOutOfBand.selector
        );
        _assertSwapReverts(
            _batch(_in(E_V3_01, address(token0), 50e18, PARKED), _held(E_V4_E1, address(token1), TO_CALLER)),
            0,
            IProxyErrors.PriceOutOfBand.selector
        );

        _assertBalancesEq(_balances(), before, "the first leg was not undone");
        assertEq(_v4Tick(nativeKey), tick, "a refused leg moved the price");
    }

    /// @notice The same chain goes through once the band allows the move
    function test_v4Chain_legInsideItsBand_succeeds() public {
        int24 tick = _v4Tick(nativeKey);
        bytes32 key = proxy.v4Key(nativeKey);
        vm.prank(user);
        proxy.setPriceBand(key, tick - 1000, tick + 1000);

        _assertChainMatchesManual(
            _batch(_in(E_V4_01, address(token0), 1e18, PARKED), _held(E_V4_E1, address(token1), TO_CALLER))
        );
    }

    /// @notice The V3 leg of a chain would push its pool out of the caller's band: the whole call
    /// reverts, whether that leg was paid by the PoolManager (V4 credit) or by the proxy (V3 output)
    function test_v3ChainLeg_leavingItsBand_revertsTheBatch() public {
        int24 tick = _v3Tick(pool1C);
        bytes32 key = proxy.v3Key(address(pool1C));
        vm.prank(user);
        proxy.setPriceBand(key, tick - 10, tick + 10);
        uint256[] memory before = _balances();

        _assertSwapReverts(
            _batch(_in(E_V4_01, address(token0), 50e18, PARKED), _held(E_V3_1C, address(token1), TO_CALLER)),
            0,
            IProxyErrors.PriceOutOfBand.selector
        );
        _assertSwapReverts(
            _batch(_in(E_V3_01, address(token0), 50e18, PARKED), _held(E_V3_1C, address(token1), TO_CALLER)),
            0,
            IProxyErrors.PriceOutOfBand.selector
        );

        _assertBalancesEq(_balances(), before, "the first leg was not undone");
        assertEq(_v3Tick(pool1C), tick, "a refused leg moved the price");
    }

    /// @notice The same V4 -> V3 chain goes through once the band allows the move
    function test_v3ChainLeg_insideItsBand_succeeds() public {
        int24 tick = _v3Tick(pool1C);
        bytes32 key = proxy.v3Key(address(pool1C));
        vm.prank(user);
        proxy.setPriceBand(key, tick - 1000, tick + 1000);

        _assertChainMatchesManual(
            _batch(_in(E_V4_01, address(token0), 1e18, PARKED), _held(E_V3_1C, address(token1), TO_CALLER))
        );
    }

    /// @notice A later leg whose pool is already outside the caller's band when its turn comes reverts the
    /// whole call, undoing the legs that ran before it, on either version
    function test_chainedLegStartingOutsideItsBand_revertsTheBatch() public {
        int24 tick1C = _v3Tick(pool1C);
        bytes32 key1C = proxy.v3Key(address(pool1C));
        vm.prank(user);
        proxy.setPriceBand(key1C, tick1C + 100, tick1C + 200);
        int24 tickE1 = _v4Tick(nativeKey);
        bytes32 keyE1 = proxy.v4Key(nativeKey);
        vm.prank(user);
        proxy.setPriceBand(keyE1, tickE1 - 200, tickE1 - 100);
        uint256[] memory before = _balances();

        _assertSwapReverts(
            _batch(_in(E_V4_01, address(token0), 1e18, PARKED), _held(E_V3_1C, address(token1), TO_CALLER)),
            0,
            IProxyErrors.PriceOutOfBand.selector
        );
        _assertSwapReverts(
            _batch(_in(E_V3_01, address(token0), 1e18, PARKED), _held(E_V4_E1, address(token1), TO_CALLER)),
            0,
            IProxyErrors.PriceOutOfBand.selector
        );

        _assertBalancesEq(_balances(), before, "the first leg was not undone");
    }
}
