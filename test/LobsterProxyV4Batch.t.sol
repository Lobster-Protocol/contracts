// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.24;

import {VmSafe} from "forge-std/Vm.sol";

import {BatchSwapFixture} from "./helpers/BatchSwapFixture.sol";
import {SwapCalldata} from "./helpers/SwapCalldata.sol";
import {LobsterProxy} from "../src/LobsterProxy.sol";
import {UniswapSwapProxy} from "../src/UniswapSwapProxy.sol";
import {SwapFlags} from "../src/libraries/SwapFlags.sol";
import {TickMath} from "../src/libraries/uniswapV3/TickMath.sol";
import {MintParams} from "../src/interfaces/uniswapV3/IUniswapV3MintCallback.sol";
import {IUniswapV3FactoryMinimal} from "../src/interfaces/uniswapV3/IUniswapV3FactoryMinimal.sol";
import {IUniswapV3PoolMinimal} from "../src/interfaces/uniswapV3/IUniswapV3PoolMinimal.sol";
import {
    PoolKey as ProxyPoolKey,
    IHooks as ProxyIHooks,
    IPoolManagerMinimal
} from "../src/interfaces/uniswapV4/IPoolManagerMinimal.sol";

import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IProxyErrors} from "../src/interfaces/IProxyErrors.sol";

/// @notice LobsterProxy's V4 legs, alone (one-leg `swap` calls) and in multi-leg calls, against a
/// real V3 factory and a real V4 PoolManager. The vault is the fixture's `user`.
///
/// Route graph (five pools, both versions, native ETH in the middle):
///   token0 --V3--  token1 --V3--  tokenC
///   token0 --V4--  token1 --V4--  ETH  --V4--  tokenC
contract LobsterProxyV4BatchTest is BatchSwapFixture {
    using PoolIdLibrary for PoolKey;

    uint8 constant E_V3_01 = 0;
    uint8 constant E_V3_1C = 1;
    uint8 constant E_V4_01 = 2;
    uint8 constant E_V4_E1 = 3;
    uint8 constant E_V4_EC = 4;
    address constant ETH = address(0);
    bytes32 constant TRANSFER_TOPIC = keccak256("Transfer(address,address,uint256)");

    LobsterProxy lobster;
    MockERC20 tokenC;
    ProxyPoolKey nativeKeyC;
    address pool1C; // the V3 token1/tokenC pool
    address attacker = makeAddr("attacker");
    bytes32[5] keys; // registry key per edge

    function setUp() public override {
        super.setUp();
        lobster = proxy; // the fixture's LobsterProxy, under a name that reads as the subject here

        // A third token: V3 token1/tokenC and V4 ETH/tokenC
        tokenC = new MockERC20("Token C", "TKC", 18);
        tokenC.mint(address(this), 100_000e18);
        tokenC.approve(address(proxy), type(uint256).max);
        tokenC.approve(address(lpRouter), type(uint256).max);
        IUniswapV3FactoryMinimal(v3Factory).createPool(address(token1), address(tokenC), FEE);
        pool1C = address(_v3PoolFor(address(token1), address(tokenC)));
        IUniswapV3PoolMinimal(pool1C).initialize(SQRT_PRICE_1_1);
        (address a, address b) =
            address(token1) < address(tokenC) ? (address(token1), address(tokenC)) : (address(tokenC), address(token1));
        _allow(address(this), proxy.v3Key(pool1C), MINT);
        proxy.mint(
            MintParams({
                token0: a,
                token1: b,
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
        PoolKey memory kc = _v4CoreKey(ETH, address(tokenC));
        manager.initialize(kc, SQRT_PRICE_1_1);
        _addV4Liquidity(kc, 10_000e18);
        nativeKeyC = _toProxyKey(kc);

        // The vault: funded and approving the proxy for tokenC too
        tokenC.mint(user, 10_000e18);
        vm.prank(user);
        tokenC.approve(address(lobster), type(uint256).max);

        // Every pool registered for swaps
        keys[E_V3_01] = lobster.v3Key(address(v3Pool));
        keys[E_V3_1C] = lobster.v3Key(pool1C);
        keys[E_V4_01] = lobster.v4Key(cleanKey);
        keys[E_V4_E1] = lobster.v4Key(nativeKey);
        keys[E_V4_EC] = lobster.v4Key(nativeKeyC);
        for (uint256 i = 0; i < 5; i++) {
            _setKey(keys[i], SWAP);
        }
    }

    // ---------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------

    function _v3PoolFor(address x, address y) internal view returns (IUniswapV3PoolMinimal) {
        return IUniswapV3PoolMinimal(IUniswapV3FactoryMinimal(v3Factory).getPool(x, y, FEE));
    }

    function _setKey(bytes32 key, uint8 permissions) internal {
        bytes32[] memory k = new bytes32[](1);
        k[0] = key;
        uint8[] memory p = new uint8[](1);
        p[0] = permissions;
        vm.prank(user);
        lobster.setPools(k, p);
        // any price: these tests are about the registry, not bands
        vm.prank(user);
        lobster.setPriceBand(key, TickMath.MIN_TICK, TickMath.MAX_TICK);
    }

    function _edgeTokens(uint8 edge) internal view returns (address, address) {
        if (edge == E_V3_01 || edge == E_V4_01) return (address(token0), address(token1));
        if (edge == E_V3_1C) return (address(token1), address(tokenC));
        if (edge == E_V4_E1) return (ETH, address(token1));
        return (ETH, address(tokenC));
    }

    function _otherSide(uint8 edge, address tokenIn) internal view returns (address) {
        (address x, address y) = _edgeTokens(edge);
        require(tokenIn == x || tokenIn == y, "leg: token not on this edge");
        return tokenIn == x ? y : x;
    }

    /// @dev An exact-input leg over `edge`, paid by the caller; its output parked for a later leg of
    /// the same call (`park`) or sent to the caller. Every V4 pool here has the fixture's fee and
    /// tick spacing.
    function _leg(
        uint8 edge,
        address tokenIn,
        uint256 amountIn,
        bool park
    )
        internal
        view
        returns (SwapCalldata.Leg memory leg)
    {
        leg.v4 = edge != E_V3_01 && edge != E_V3_1C;
        leg.tokenIn = tokenIn;
        leg.tokenOut = _otherSide(edge, tokenIn);
        leg.fee = FEE;
        if (leg.v4) leg.tickSpacing = TICK_SPACING;
        leg.amount = SafeCast.toUint128(amountIn);
        leg.park = park;
    }

    /// @dev A HELD leg over `edge`: spends everything earlier legs of the call parked of `tokenIn`
    function _held(uint8 edge, address tokenIn, bool park) internal view returns (SwapCalldata.Leg memory leg) {
        leg = _leg(edge, tokenIn, 0, park);
        leg.held = true;
    }

    /// @dev token0 -V3-> token1 -V4-> ETH -V4-> tokenC -V3-> token1, every output but the last
    /// parked for the next leg, the last one to the vault
    function _route() internal view returns (SwapCalldata.Leg[] memory s, uint8[4] memory edges) {
        edges = [E_V3_01, E_V4_E1, E_V4_EC, E_V3_1C];
        s = new SwapCalldata.Leg[](4);
        s[0] = _leg(E_V3_01, address(token0), 1e18, true);
        s[1] = _held(E_V4_E1, address(token1), true);
        s[2] = _held(E_V4_EC, ETH, true);
        s[3] = _held(E_V3_1C, address(tokenC), false);
    }

    /// @dev The `data` argument of `swap` running `legs`, with the current block as deadline
    function _data(SwapCalldata.Leg[] memory legs) internal view returns (bytes memory) {
        return SwapCalldata.encode(vm.getBlockTimestamp(), legs);
    }

    function _who(address who) internal view returns (uint256[4] memory h) {
        h[0] = token0.balanceOf(who);
        h[1] = token1.balanceOf(who);
        h[2] = tokenC.balanceOf(who);
        h[3] = who.balance;
    }

    /// @dev The index of `token` in {_who}'s holdings
    function _slot(address token) internal view returns (uint256) {
        if (token == address(token0)) return 0;
        if (token == address(token1)) return 1;
        if (token == address(tokenC)) return 2;
        return 3; // ETH
    }

    function _assertUnchanged(uint256[4] memory before, address who, string memory ctx) internal view {
        uint256[4] memory nowHeld = _who(who);
        for (uint256 i = 0; i < 4; i++) {
            assertEq(nowHeld[i], before[i], ctx);
        }
    }

    function _assertNothingParked() internal view {
        uint256[4] memory p = _who(address(lobster));
        for (uint256 i = 0; i < 4; i++) {
            assertEq(p[i], 0, "proxy holds funds");
        }
    }

    function _expectUnlocks(uint64 count) internal {
        vm.expectCall(address(manager), abi.encodeWithSelector(IPoolManagerMinimal.unlock.selector), count);
    }

    /// @dev Neither V3 pool may be swapped on for the rest of the test
    function _expectNoV3Swap() internal {
        vm.expectCall(address(v3Pool), abi.encodeWithSelector(IUniswapV3PoolMinimal.swap.selector), 0);
        vm.expectCall(pool1C, abi.encodeWithSelector(IUniswapV3PoolMinimal.swap.selector), 0);
    }

    /// @dev Calls `swap(data)` as the vault and requires it to revert with exactly MalformedSwap
    function _expectMalformed(bytes memory data, string memory ctx) internal {
        vm.prank(user);
        (bool ok, bytes memory ret) = address(lobster).call(abi.encodeCall(UniswapSwapProxy.swap, (data)));
        assertFalse(ok, string.concat(ctx, ": accepted"));
        assertEq(ret, abi.encodeWithSelector(IProxyErrors.MalformedSwap.selector), string.concat(ctx, ": reason"));
    }

    /// @dev Hand-made `data`: header (current block as deadline), the token table, then raw `legs`
    function _withTable(address[] memory tokens, bytes memory legs) internal view returns (bytes memory data) {
        data = bytes.concat(bytes4(SafeCast.toUint32(vm.getBlockTimestamp())), bytes1(SafeCast.toUint8(tokens.length)));
        for (uint256 t = 0; t < tokens.length; t++) {
            data = bytes.concat(data, bytes20(tokens[t]));
        }
        data = bytes.concat(data, legs);
    }

    /// @dev `data[start:end]`, copied
    function _slice(bytes memory data, uint256 start, uint256 end) internal pure returns (bytes memory out) {
        out = new bytes(end - start);
        for (uint256 i = 0; i < out.length; i++) {
            out[i] = data[start + i];
        }
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

    /// @dev The depth of the first call to `callee` with `selector` among recorded `accesses`
    function _depthOfCall(
        VmSafe.AccountAccess[] memory accesses,
        address callee,
        bytes4 selector
    )
        internal
        pure
        returns (uint64)
    {
        for (uint256 i = 0; i < accesses.length; i++) {
            VmSafe.AccountAccess memory a = accesses[i];
            if (a.kind == VmSafe.AccountAccessKind.Call && a.account == callee && _sig(a.data) == selector) {
                return a.depth;
            }
        }
        revert("call not found");
    }

    /// @dev The first 4 bytes of `data` (zero when shorter), as `bytes4(data)` but without a cast
    function _sig(bytes memory data) internal pure returns (bytes4 sig) {
        if (data.length < 4) return sig;
        assembly ("memory-safe") {
            sig := and(mload(add(data, 0x20)), shl(224, 0xffffffff))
        }
    }

    // ---------------------------------------------------------------------------
    // Keys
    // ---------------------------------------------------------------------------

    /// @notice The registry keys are the pools' own identifiers: a V3 pool's address, and a V4 pool's
    /// PoolId exactly as the PoolManager computes it, native pools included
    function test_keysMatchHowPoolsAreIdentified() public view {
        assertEq(lobster.v3Key(address(v3Pool)), bytes32(uint256(uint160(address(v3Pool)))), "v3Key");
        assertEq(lobster.v3Key(pool1C), bytes32(uint256(uint160(pool1C))), "v3Key, token1/tokenC pool");
        PoolKey memory clean = _v4CoreKey(address(token0), address(token1));
        assertEq(lobster.v4Key(cleanKey), PoolId.unwrap(clean.toId()), "v4Key differs from the PoolManager's PoolId");
        PoolKey memory native = _v4CoreKey(ETH, address(token1));
        assertEq(lobster.v4Key(nativeKey), PoolId.unwrap(native.toId()), "v4Key, native pool");
        PoolKey memory nativeC = _v4CoreKey(ETH, address(tokenC));
        assertEq(lobster.v4Key(nativeKeyC), PoolId.unwrap(nativeC.toId()), "v4Key, native/tokenC pool");
    }

    /// @notice MINT on a V4 key means "may add liquidity" (modifyLiquidityV4). It is not SWAP:
    /// a MINT-only V4 pool still cannot be swapped on, alone or in a multi-leg call.
    function test_mintBitOnV4Key_isAcceptedButIsNotSwap() public {
        _setKey(keys[E_V4_01], MINT);
        assertEq(lobster.permissionsOf(user, keys[E_V4_01]), MINT);
        SwapCalldata.Leg[] memory oneLeg = _batch(_v4In(cleanKey, true, 1e18, 0));

        vm.prank(user);
        vm.expectRevert(IProxyErrors.PoolNotAllowed.selector);
        lobster.swap(_data(oneLeg));

        _setKey(keys[E_V4_01], MINT | SWAP);
        uint256[] memory amounts = _swapAs(user, oneLeg);
        assertEq(amounts.length, 1, "a one-leg call returns one amount");
        assertGt(amounts[0], 0, "the swap did not run");
    }

    // ---------------------------------------------------------------------------
    // Multi-leg calls: registered routes run, in one unlock
    // ---------------------------------------------------------------------------

    /// @notice V3 -> V4 -> V4 -> V3 with every pool registered: the whole route shares one unlock,
    /// the vault pays only the first input, and the final output lands in the vault. (That each leg
    /// matches the same swap made directly is LobsterChaining.t.sol's subject.)
    function test_chainedRoute_V3_V4_V4_V3_landsInTheVault() public {
        (SwapCalldata.Leg[] memory s,) = _route();
        uint256[4] memory before = _who(user); // token0, token1, tokenC, ETH

        _expectUnlocks(1);
        uint256[] memory amounts = _swapAs(user, s);

        uint256[4] memory nowHeld = _who(user);
        assertEq(before[0] - nowHeld[0], 1e18, "the vault paid more than the first input");
        assertEq(nowHeld[1], before[1] + amounts[3], "final output did not land in the vault");
        assertEq(nowHeld[2], before[2], "tokenC moved");
        assertEq(nowHeld[3], before[3], "ETH moved");
        _assertNothingParked();
    }

    /// @notice How the same route's parked outputs move (UniswapSwapProxy, ONE UNLOCK): the V3
    /// output that a V4 leg spends is paid by its pool straight to the PoolManager, the V4 outputs
    /// (ETH, then tokenC) stay there as credit, and the V3 leg that spends that credit is paid by the
    /// PoolManager straight to its pool. No token ever goes through the proxy, and nothing leaves the
    /// pools and the PoolManager but the final output, to the vault.
    function test_chainedRoute_handsOffThroughThePoolManager() public {
        (SwapCalldata.Leg[] memory s,) = _route();
        uint256 ethBefore = user.balance;

        vm.expectCall(address(v3Pool), abi.encodeWithSelector(IUniswapV3PoolMinimal.swap.selector, address(manager)), 1);
        vm.expectCall(pool1C, abi.encodeWithSelector(IUniswapV3PoolMinimal.swap.selector, user), 1);
        vm.expectCall(address(manager), abi.encodeWithSelector(IPoolManagerMinimal.take.selector), 1);
        vm.expectCall(
            address(manager), abi.encodeWithSelector(IPoolManagerMinimal.take.selector, address(tokenC), pool1C), 1
        );
        vm.recordLogs();
        _swapAs(user, s);

        _assertNoTransferInvolves(vm.getRecordedLogs(), address(lobster), "a token moved through the proxy");
        assertEq(user.balance, ethBefore, "the parked ETH left the PoolManager");
        _assertNothingParked();
    }

    /// @notice V4 -> V4 through native ETH: one unlock, the parked ETH never leaves the PoolManager,
    /// and the output lands in the vault
    function test_v4ToV4_sharesOneUnlock() public {
        SwapCalldata.Leg[] memory s = _batch(_leg(E_V4_E1, address(token1), 1e18, true), _held(E_V4_EC, ETH, false));
        uint256 cBefore = tokenC.balanceOf(user);
        uint256 ethBefore = user.balance;

        _expectUnlocks(1);
        uint256[] memory amounts = _swapAs(user, s);

        assertEq(tokenC.balanceOf(user), cBefore + amounts[1], "output did not land in the vault");
        assertEq(user.balance, ethBefore, "the parked ETH left the PoolManager");
        _assertNothingParked();
    }

    /// @notice A call with any V4 leg runs entirely inside exactly one PoolManager unlock, its V3 legs
    /// included, even when its V4 legs are unrelated (the old batchSwap gave each V4 swap that did not
    /// chain onto the previous one an unlock of its own)
    function test_anyV4Leg_runsTheWholeCallInOneUnlock() public {
        SwapCalldata.Leg[] memory s = new SwapCalldata.Leg[](3);
        s[0] = _leg(E_V4_01, address(token0), 1e18, false);
        s[1] = _leg(E_V3_1C, address(tokenC), 1e18, false);
        s[2] = _leg(E_V4_E1, address(token1), 1e18, false); // token1 -> ETH
        uint256[4] memory before = _who(user);

        _expectUnlocks(1);
        vm.startStateDiffRecording();
        uint256[] memory amounts = _swapAs(user, s);
        VmSafe.AccountAccess[] memory accesses = vm.stopAndReturnStateDiff();

        assertGt(
            _depthOfCall(accesses, pool1C, IUniswapV3PoolMinimal.swap.selector),
            _depthOfCall(accesses, address(manager), IPoolManagerMinimal.unlock.selector),
            "the V3 leg ran outside the unlock"
        );
        uint256[4] memory nowHeld = _who(user);
        assertEq(nowHeld[0], before[0] - 1e18, "token0");
        assertEq(nowHeld[1], before[1] + amounts[0] + amounts[1] - 1e18, "token1");
        assertEq(nowHeld[2], before[2] - 1e18, "tokenC");
        assertEq(nowHeld[3], before[3] + amounts[2], "ETH");
        _assertNothingParked();
    }

    /// @notice A call with only V3 legs, chained or not, never opens an unlock
    function test_v3OnlyCall_opensNoUnlock() public {
        SwapCalldata.Leg[] memory s =
            _batch(_leg(E_V3_01, address(token0), 1e18, true), _held(E_V3_1C, address(token1), false));
        uint256 cBefore = tokenC.balanceOf(user);

        _expectUnlocks(0);
        uint256[] memory amounts = _swapAs(user, s);

        assertEq(tokenC.balanceOf(user), cBefore + amounts[1], "output did not land in the vault");
        _assertNothingParked();
    }

    /// @notice A route can start in native ETH, paid from msg.value now that `swap` is payable:
    /// ETH -V4-> token1 -V3-> tokenC. The vault pays exactly the route's input and gets its change
    /// back; the parked token1 is PoolManager credit, paid by the PoolManager straight to the V3 pool.
    function test_routeFromNativeEth_isPaidFromMsgValue() public {
        SwapCalldata.Leg[] memory s = _batch(_leg(E_V4_E1, ETH, 1e18, true), _held(E_V3_1C, address(token1), false));
        uint256[4] memory before = _who(user);

        _expectUnlocks(1);
        vm.expectCall(
            address(manager), abi.encodeWithSelector(IPoolManagerMinimal.take.selector, address(token1), pool1C), 1
        );
        vm.prank(user);
        uint256[] memory amounts = lobster.swap{value: 3e18}(_data(s));

        uint256[4] memory nowHeld = _who(user);
        assertEq(before[3] - nowHeld[3], 1e18, "the vault paid other than the route's input");
        assertEq(nowHeld[2], before[2] + amounts[1], "final output did not land in the vault");
        assertEq(nowHeld[0], before[0], "token0 moved");
        assertEq(nowHeld[1], before[1], "token1 moved");
        _assertNothingParked();
    }

    /// @notice The native-input legs of a call share its msg.value: each is paid from what the legs
    /// before it left. Two legs of 1 ETH (ETH -> token1, ETH -> tokenC) each fit in 1.5 ETH alone, but
    /// not together: the call reverts NotEnoughEthSent, and ETH force-fed to the proxy does not make up
    /// the difference. With exactly 2 ETH both run and the vault gets no change back.
    function test_nativeInputLegs_shareOneMsgValueBudget() public {
        SwapCalldata.Leg[] memory s = _batch(_leg(E_V4_E1, ETH, 1e18, false), _leg(E_V4_EC, ETH, 1e18, false));
        uint256[2] memory strays = [uint256(0), 5e18];
        for (uint256 i = 0; i < strays.length; i++) {
            uint256 snap = vm.snapshotState();
            vm.deal(address(lobster), strays[i]);
            uint256[4] memory before = _who(user);

            // Each leg alone: paid out of 1.5 ETH, the rest refunded
            for (uint256 j = 0; j < s.length; j++) {
                uint256 legSnap = vm.snapshotState();
                vm.prank(user);
                lobster.swap{value: 1.5e18}(_data(_batch(s[j])));
                assertEq(user.balance + 1e18, before[3], "one leg: the vault paid other than its input");
                assertEq(address(lobster).balance, strays[i], "one leg: the stray ETH moved");
                vm.revertToState(legSnap);
            }

            // Both legs out of the same 1.5 ETH: the second finds 0.5 ETH left
            vm.prank(user);
            vm.expectRevert(IProxyErrors.NotEnoughEthSent.selector);
            lobster.swap{value: 1.5e18}(_data(s));
            _assertUnchanged(before, user, "a rejected call moved the vault's funds");
            assertEq(address(lobster).balance, strays[i], "rejected call: the stray ETH moved");

            // Exactly enough: both run, the whole msg.value is spent, nothing comes back
            vm.prank(user);
            uint256[] memory amounts = lobster.swap{value: 2e18}(_data(s));
            uint256[4] memory nowHeld = _who(user);
            assertEq(nowHeld[3] + 2e18, before[3], "the vault paid other than its msg.value, or got change");
            assertEq(nowHeld[1], before[1] + amounts[0], "token1 output");
            assertEq(nowHeld[2], before[2] + amounts[1], "tokenC output");
            assertEq(nowHeld[0], before[0], "token0 moved");
            _assertUnchanged(
                [uint256(0), 0, 0, strays[i]], address(lobster), "the proxy holds other than the stray ETH"
            );
            vm.revertToState(snap);
        }
    }

    // ---------------------------------------------------------------------------
    // Multi-leg calls: validation happens before anything runs
    // ---------------------------------------------------------------------------

    /// @notice One unregistered pool anywhere (each leg in turn: V3 first, V4 middle, V4 middle, V3 last)
    /// reverts the whole call before any swap: no balance change, no PoolManager unlock, no V3 swap
    function test_unregisteredPoolAnywhere_revertsBeforeAnythingRuns() public {
        (SwapCalldata.Leg[] memory s, uint8[4] memory edges) = _route();
        uint256[4] memory before = _who(user);

        _expectUnlocks(0);
        _expectNoV3Swap();
        for (uint256 i = 0; i < 4; i++) {
            uint256 snap = vm.snapshotState();
            _setKey(keys[edges[i]], 0);
            vm.prank(user);
            vm.expectRevert(IProxyErrors.PoolNotAllowed.selector);
            lobster.swap(_data(s));
            vm.revertToState(snap);
        }
        _assertUnchanged(before, user, "a rejected call moved the vault's funds");
    }

    /// @notice Same for a V4 last leg, and for a V4 first leg
    function test_unregisteredV4PoolAtEitherEnd_reverts() public {
        _expectUnlocks(0);
        _expectNoV3Swap();

        SwapCalldata.Leg[] memory s =
            _batch(_leg(E_V3_01, address(token0), 1e18, true), _held(E_V4_01, address(token1), false)); // V4 last
        _setKey(keys[E_V4_01], 0);
        vm.prank(user);
        vm.expectRevert(IProxyErrors.PoolNotAllowed.selector);
        lobster.swap(_data(s));

        s = _batch(_leg(E_V4_E1, address(token1), 1e18, true), _held(E_V4_EC, ETH, false)); // V4 first
        _setKey(keys[E_V4_E1], 0);
        vm.prank(user);
        vm.expectRevert(IProxyErrors.PoolNotAllowed.selector);
        lobster.swap(_data(s));
    }

    /// @notice Registered without a price band, anywhere on the route: refused the same way, before
    /// anything runs (a band is part of what every leg is validated for up front)
    function test_poolWithoutBandAnywhere_revertsBeforeAnythingRuns() public {
        (SwapCalldata.Leg[] memory s, uint8[4] memory edges) = _route();
        uint256[4] memory before = _who(user);

        _expectUnlocks(0);
        _expectNoV3Swap();
        for (uint256 i = 0; i < 4; i++) {
            uint256 snap = vm.snapshotState();
            vm.prank(user);
            lobster.setPriceBand(keys[edges[i]], 0, 0);
            vm.prank(user);
            vm.expectRevert(IProxyErrors.PriceBandNotSet.selector);
            lobster.swap(_data(s));
            vm.revertToState(snap);
        }
        _assertUnchanged(before, user, "a rejected call moved the vault's funds");
    }

    /// @notice A leg cannot name a recipient, so no leg of a call can pay anyone but the vault: on every
    /// leg of the route (V3 first, V4 middle, V4 middle, V3 last), the output that is not parked lands
    /// in the vault, and no transfer ever involves the attacker. Replaces the rejection of a foreign
    /// recipient (the attacker, the proxy) on any leg, which can no longer be encoded.
    function test_everyLegsOutput_landsInTheVault() public {
        address[4] memory outs = [address(token1), ETH, address(tokenC), address(token1)];
        for (uint256 i = 0; i < 4; i++) {
            // The route up to leg i, whose output then leaves the call
            (SwapCalldata.Leg[] memory route,) = _route();
            SwapCalldata.Leg[] memory s = new SwapCalldata.Leg[](i + 1);
            for (uint256 j = 0; j <= i; j++) {
                s[j] = route[j];
            }
            s[i].park = false;

            uint256 snap = vm.snapshotState();
            uint256[4] memory before = _who(user);
            vm.recordLogs();
            uint256[] memory amounts = _swapAs(user, s);
            VmSafe.Log[] memory logs = vm.getRecordedLogs();

            uint256 k = _slot(outs[i]);
            assertGt(amounts[i], 0, "no output");
            assertEq(_who(user)[k], before[k] + amounts[i], "the output did not land in the vault");
            assertEq(before[0] - token0.balanceOf(user), 1e18, "the vault paid other than the route's input");
            _assertNoTransferInvolves(logs, attacker, "a transfer involved the attacker");
            _assertUnchanged([uint256(0), 0, 0, 0], attacker, "the attacker received something");
            _assertNothingParked();
            vm.revertToState(snap);
        }
    }

    /// @notice A parked output can only leave the call to the vault: the HELD leg that spends it pays
    /// the vault, there being no recipient to point elsewhere; an output left parked is refused at the
    /// end, whether it sits in the proxy (V3) or is PoolManager credit (V4); and so is one only partly
    /// spent, by a HELD leg its price limit stopped early.
    function test_parkedOutputCanOnlyEndUpInTheVault() public {
        uint256[4] memory before = _who(user);

        uint256 snap = vm.snapshotState();
        uint256[] memory amounts =
            _swapAs(user, _batch(_leg(E_V3_01, address(token0), 1e18, true), _held(E_V4_E1, address(token1), false)));
        assertEq(user.balance, before[3] + amounts[1], "the parked output's proceeds did not land in the vault");
        _assertUnchanged([uint256(0), 0, 0, 0], attacker, "the attacker received something");
        _assertNothingParked();
        vm.revertToState(snap);

        // Never spent
        SwapCalldata.Leg[2] memory parkedOnly =
            [_leg(E_V3_01, address(token0), 1e18, true), _leg(E_V4_01, address(token0), 1e18, true)];
        for (uint256 i = 0; i < parkedOnly.length; i++) {
            vm.prank(user);
            vm.expectRevert(IProxyErrors.FundsLeftInProxy.selector);
            lobster.swap(_data(_batch(parkedOnly[i])));
        }

        // Partly spent: token1 parked in the proxy, spent by a V3 leg stopped a hair past the price
        (uint160 price1C,,,,,,) = IUniswapV3PoolMinimal(pool1C).slot0();
        SwapCalldata.Leg memory stopsEarly = _held(E_V3_1C, address(token1), false);
        stopsEarly.sqrtPriceLimitX96 =
            address(token1) < address(tokenC) ? price1C - price1C / 1e6 : price1C + price1C / 1e6;
        vm.prank(user);
        vm.expectRevert(IProxyErrors.FundsLeftInProxy.selector);
        lobster.swap(_data(_batch(_leg(E_V3_01, address(token0), 1e18, true), stopsEarly)));

        // ...or token1 paid to the PoolManager as credit, spent by a V4 leg stopped the same way
        (uint160 priceE1,,,) = StateLibrary.getSlot0(manager, PoolId.wrap(keys[E_V4_E1]));
        stopsEarly = _held(E_V4_E1, address(token1), false); // token1 -> ETH: the price goes up
        stopsEarly.sqrtPriceLimitX96 = priceE1 + priceE1 / 1e6;
        vm.prank(user);
        vm.expectRevert(IProxyErrors.FundsLeftInProxy.selector);
        lobster.swap(_data(_batch(_leg(E_V3_01, address(token0), 1e18, true), stopsEarly)));

        _assertUnchanged(before, user, "vault funds moved");
        _assertNothingParked();
    }

    /// @notice Random routes over a random subset of registered pools, from a random token (native ETH
    /// included, paid with msg.value plus some change), each leg's output parked for the next leg or
    /// sent to the vault: whenever a call succeeds, the proxy holds nothing, the attacker got nothing,
    /// and the vault's net change is exactly the route's input and its unparked outputs; whenever it
    /// fails, nothing moved. A leg can no longer name the attacker as recipient (the old third choice),
    /// so here the attacker is an outsider whose balances must never change.
    function testFuzz_randomRoutes_neverLeakOutsideTheVault(uint256 seed, uint8 hops, uint8 registered) public {
        for (uint256 i = 0; i < 5; i++) {
            if ((registered >> i) & 1 == 0) _setKey(keys[i], 0);
        }
        uint256 n = bound(hops, 1, 4);
        address token = [address(token0), address(token1), address(tokenC), ETH][seed % 4];
        uint256 amountIn = bound(uint256(keccak256(abi.encode(seed))), 1e15, 5e18);
        SwapCalldata.Leg[] memory s = new SwapCalldata.Leg[](n);
        for (uint256 i = 0; i < n; i++) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            uint8 edge = _edgeFrom(token, r);
            // A real route parks every output but the last; each leg deviates from that one time in eight
            bool park = (r >> 8) % 8 == 0 ? i == n - 1 : i != n - 1;
            s[i] = i == 0 ? _leg(edge, token, amountIn, park) : _held(edge, token, park);
            token = _otherSide(edge, token);
        }
        uint256 value = s[0].tokenIn == ETH ? amountIn + (seed >> 128) % 1e18 : 0;
        uint256[4] memory before = _who(user);

        vm.prank(user);
        (bool ok, bytes memory ret) = address(lobster).call{value: value}(_call(s));

        if (ok) {
            uint256[] memory amounts = abi.decode(ret, (uint256[]));
            int256[4] memory delta;
            delta[_slot(s[0].tokenIn)] -= SafeCast.toInt256(amountIn);
            for (uint256 i = 0; i < n; i++) {
                if (!s[i].park) delta[_slot(s[i].tokenOut)] += SafeCast.toInt256(amounts[i]);
            }
            uint256[4] memory nowHeld = _who(user);
            for (uint256 k = 0; k < 4; k++) {
                assertEq(
                    SafeCast.toInt256(nowHeld[k]) - SafeCast.toInt256(before[k]),
                    delta[k],
                    "the vault's net change is not the route's"
                );
            }
        } else {
            _assertUnchanged(before, user, "a failed call moved the vault's funds");
        }
        _assertUnchanged([uint256(0), 0, 0, 0], attacker, "the attacker received something");
        _assertNothingParked();
    }

    function _edgeFrom(address token, uint256 r) internal view returns (uint8) {
        if (token == address(token0)) return [E_V3_01, E_V4_01][r % 2];
        if (token == address(token1)) return [E_V3_01, E_V3_1C, E_V4_01, E_V4_E1][r % 4];
        if (token == address(tokenC)) return [E_V3_1C, E_V4_EC][r % 2];
        return [E_V4_E1, E_V4_EC][r % 2];
    }

    /// @notice Malformed data reverts in validation, before the unlock its V4 leg would open: empty
    /// data, an unknown flag after a V4 leg, a V4 leg cut short, and a V3 leg's fields under the V4
    /// flag (one tickSpacing short of a V4 leg). Replaces the empty item, the unknown swap type and
    /// the V4 item too short to decode.
    function test_malformedData_revertsInValidation() public {
        bytes memory v4Leg = SwapCalldata.encodeLeg(_leg(E_V4_01, address(token0), 1e18, false), 0, 1);
        bytes memory v3Leg = SwapCalldata.encodeLeg(_leg(E_V3_01, address(token0), 1e18, false), 0, 1);
        address[] memory two = new address[](2);
        (two[0], two[1]) = (address(token0), address(token1));

        _expectUnlocks(0);
        _expectNoV3Swap();
        _expectMalformed("", "empty data");
        _expectMalformed(_withTable(two, bytes.concat(v4Leg, hex"20")), "unknown flag after a V4 leg");
        _expectMalformed(_withTable(two, bytes.concat(v4Leg, _slice(v4Leg, 0, v4Leg.length - 1))), "V4 leg cut short");
        _expectMalformed(
            _withTable(two, bytes.concat(v4Leg, bytes1(SwapFlags.V4), _slice(v3Leg, 1, v3Leg.length))),
            "V3 leg fields under the V4 flag"
        );
    }

    // ---------------------------------------------------------------------------
    // One-leg V4 calls (the former single swaps)
    // ---------------------------------------------------------------------------

    /// @notice An unregistered V4 pool cannot be swapped on, and the call never opens an unlock
    function test_v4OneLeg_unregisteredPool_reverts() public {
        _setKey(keys[E_V4_01], 0);
        _expectUnlocks(0);
        vm.prank(user);
        vm.expectRevert(IProxyErrors.PoolNotAllowed.selector);
        lobster.swap(_data(_batch(_v4In(cleanKey, true, 1e18, 0))));
    }

    /// @notice A one-leg call's output is taken by the PoolManager straight to the caller: no
    /// recipient can be named, so neither an attacker nor the proxy can get it; and a lone parked
    /// output (the old `ADDRESS_THIS` recipient) has no later leg to spend it, so it is refused with
    /// FundsLeftInProxy. Replaces the rejection of those three recipients.
    function test_v4OneLeg_outputAlwaysGoesToTheCaller() public {
        uint256 t1Before = token1.balanceOf(user);

        vm.expectCall(
            address(manager), abi.encodeWithSelector(IPoolManagerMinimal.take.selector, address(token1), user), 1
        );
        uint256[] memory amounts = _swapAs(user, _batch(_v4In(cleanKey, true, 1e18, 0)));

        assertEq(amounts.length, 1, "a one-leg call returns one amount");
        assertEq(token1.balanceOf(user), t1Before + amounts[0], "output did not reach the vault");
        _assertUnchanged([uint256(0), 0, 0, 0], attacker, "the attacker received something");
        _assertNothingParked();

        SwapCalldata.Leg memory parked = _v4In(cleanKey, true, 1e18, 0);
        parked.park = true;
        vm.prank(user);
        vm.expectRevert(IProxyErrors.FundsLeftInProxy.selector);
        lobster.swap(_data(_batch(parked)));
    }

    /// @notice Native ETH in, with more ETH sent than needed: the vault pays exactly what the leg
    /// spent (`amountIn`, or for exact output the amount returned), gets the rest back, and receives
    /// the output
    function test_v4OneLeg_nativeInput_refundsTheVault() public {
        uint256 ethBefore = user.balance;
        uint256 t1Before = token1.balanceOf(user);

        vm.prank(user);
        uint256[] memory amounts = lobster.swap{value: 3e18}(_data(_batch(_v4In(nativeKey, true, 1e18, 0)))); // 1 ETH in

        assertEq(amounts.length, 1, "a one-leg call returns one amount");
        assertEq(ethBefore - user.balance, 1e18, "vault did not get its change back");
        assertEq(token1.balanceOf(user), t1Before + amounts[0], "output did not reach the vault");
        assertEq(address(lobster).balance, 0, "proxy kept ETH");

        // Exact output: the amount returned is what the vault paid
        ethBefore = user.balance;
        t1Before = token1.balanceOf(user);
        vm.prank(user);
        amounts = lobster.swap{value: 3e18}(_data(_batch(_v4Out(nativeKey, true, 1e18, 2e18))));

        assertEq(ethBefore - user.balance, amounts[0], "exact output: vault did not get its change back");
        assertEq(token1.balanceOf(user), t1Before + 1e18, "exact output: output did not reach the vault");
        assertEq(address(lobster).balance, 0, "proxy kept ETH");
    }

    /// @notice Native ETH out: the PoolManager pays the vault directly, the proxy keeps nothing
    function test_v4OneLeg_nativeOutput_paysTheVault() public {
        uint256 ethBefore = user.balance;
        uint256[] memory amounts = _swapAs(user, _batch(_v4In(nativeKey, false, 1e18, 0))); // token1 in, ETH out
        assertGt(amounts[0], 0);
        assertEq(user.balance, ethBefore + amounts[0], "ETH output did not reach the vault");
        assertEq(address(lobster).balance, 0, "proxy kept ETH");
    }

    /// @notice A hook cannot be encoded: a leg on a hooked pool's currencies, fee and tick spacing is
    /// a leg on the hookless pool. So registering the hooked pool's PoolId does not make it usable:
    /// with only that registered, the leg is refused (PoolNotAllowed), alone or in a multi-leg call,
    /// before any unlock. Replaces HooksNotSupported, which swap can no longer reach.
    function test_hookedPool_isUnreachableEvenIfRegistered() public {
        ProxyPoolKey memory hooked = cleanKey;
        hooked.hooks = ProxyIHooks(makeAddr("someHook"));
        bytes32 hookedId = lobster.v4Key(hooked);
        _setKey(hookedId, SWAP);
        _setKey(keys[E_V4_01], 0);
        assertEq(lobster.permissionsOf(user, hookedId), SWAP);
        assertTrue(hookedId != keys[E_V4_01], "fixture: the hooked pool has the hookless PoolId");

        SwapCalldata.Leg memory leg = _v4In(hooked, true, 1e18, 0); // the hooks field is not encoded
        _expectUnlocks(0);
        _expectNoV3Swap();
        vm.startPrank(user);
        vm.expectRevert(IProxyErrors.PoolNotAllowed.selector);
        lobster.swap(_data(_batch(leg)));
        vm.expectRevert(IProxyErrors.PoolNotAllowed.selector);
        lobster.swap(_data(_batch(_v3In(address(token0), address(token1), 1e18, 0), leg)));
        vm.stopPrank();
    }

    /// @notice The other side of the same rule: with the hookless pool registered, the same leg runs,
    /// on the hookless pool (the PoolManager is called with hooks = address(0)), whatever else the
    /// vault registered
    function test_v4Leg_alwaysTargetsTheHooklessPool() public {
        ProxyPoolKey memory hooked = cleanKey;
        hooked.hooks = ProxyIHooks(makeAddr("someHook"));
        _setKey(lobster.v4Key(hooked), SWAP);
        ProxyPoolKey memory hookless = cleanKey;

        vm.expectCall(address(manager), abi.encodeWithSelector(IPoolManagerMinimal.swap.selector, hookless), 1);
        uint256[] memory amounts = _swapAs(user, _batch(_v4In(hooked, true, 1e18, 0)));
        assertGt(amounts[0], 0, "the leg did not run");
    }
}
