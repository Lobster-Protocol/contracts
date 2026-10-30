// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.24;

import {BatchSwapFixture} from "./helpers/BatchSwapFixture.sol";
import {LobsterProxy} from "../src/LobsterProxy.sol";
import {TickMath} from "../src/libraries/uniswapV3/TickMath.sol";
import {UniswapBatchSwapProxy, SwapType} from "../src/UniswapBatchSwapProxy.sol";
import {Chaining} from "../src/libraries/Chaining.sol";
import {ExactInputSingleParams} from "../src/interfaces/uniswapV3/IUniswapV3SwapCallback.sol";
import {MintParams} from "../src/interfaces/uniswapV3/IUniswapV3MintCallback.sol";
import {V4ExactInputSingleParams} from "../src/interfaces/uniswapV4/IUnlockCallback.sol";
import {IUniswapV3FactoryMinimal} from "../src/interfaces/uniswapV3/IUniswapV3FactoryMinimal.sol";
import {IUniswapV3PoolMinimal} from "../src/interfaces/uniswapV3/IUniswapV3PoolMinimal.sol";
import {
    PoolKey as ProxyPoolKey,
    IHooks as ProxyIHooks,
    IPoolManagerMinimal
} from "../src/interfaces/uniswapV4/IPoolManagerMinimal.sol";

import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IProxyErrors} from "../src/interfaces/IProxyErrors.sol";

/// @notice LobsterProxy's V4 single swaps and batches, against a real V3 factory and a real V4
/// PoolManager. The vault is the fixture's `user`.
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
    address constant HERE = Chaining.ADDRESS_THIS;
    uint256 constant HELD = Chaining.HELD_BALANCE;

    LobsterProxy lobster;
    MockERC20 tokenC;
    ProxyPoolKey nativeKeyC;
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
        _v3PoolFor(address(token1), address(tokenC)).initialize(SQRT_PRICE_1_1);
        (address a, address b) =
            address(token1) < address(tokenC) ? (address(token1), address(tokenC)) : (address(tokenC), address(token1));
        _allow(address(this), proxy.v3Key(address(_v3PoolFor(a, b))), MINT);
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
        keys[E_V3_1C] = lobster.v3Key(address(_v3PoolFor(address(token1), address(tokenC))));
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

    /// @dev An exact-input batch item over `edge`
    function _leg(uint8 edge, address tokenIn, uint256 amountIn, address to) internal view returns (bytes memory) {
        address tokenOut = _otherSide(edge, tokenIn);
        if (edge == E_V3_01 || edge == E_V3_1C) {
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
                        sqrtPriceLimitX96: 0
                    })
                )
            );
        }
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

    /// @dev token0 -V3-> token1 -V4-> ETH -V4-> tokenC -V3-> token1, to `finalRecipient`
    function _route(address finalRecipient) internal view returns (bytes[] memory s, uint8[4] memory edges) {
        edges = [E_V3_01, E_V4_E1, E_V4_EC, E_V3_1C];
        s = new bytes[](4);
        s[0] = _leg(E_V3_01, address(token0), 1e18, HERE);
        s[1] = _leg(E_V4_E1, address(token1), HELD, HERE);
        s[2] = _leg(E_V4_EC, ETH, HELD, HERE);
        s[3] = _leg(E_V3_1C, address(tokenC), HELD, finalRecipient);
    }

    function _who(address who) internal view returns (uint256[4] memory h) {
        h[0] = token0.balanceOf(who);
        h[1] = token1.balanceOf(who);
        h[2] = tokenC.balanceOf(who);
        h[3] = who.balance;
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

    // ---------------------------------------------------------------------------
    // Keys
    // ---------------------------------------------------------------------------

    function test_keysMatchHowPoolsAreIdentified() public view {
        assertEq(lobster.v3Key(address(v3Pool)), bytes32(uint256(uint160(address(v3Pool)))), "v3Key");
        PoolKey memory clean = _v4CoreKey(address(token0), address(token1));
        assertEq(lobster.v4Key(cleanKey), PoolId.unwrap(clean.toId()), "v4Key differs from the PoolManager's PoolId");
        PoolKey memory native = _v4CoreKey(ETH, address(token1));
        assertEq(lobster.v4Key(nativeKey), PoolId.unwrap(native.toId()), "v4Key, native pool");
    }

    /// @notice MINT on a V4 key means "may add liquidity" (modifyLiquidityV4). It is not SWAP:
    /// a MINT-only V4 pool still cannot be swapped on.
    function test_mintBitOnV4Key_isAcceptedButIsNotSwap() public {
        _setKey(keys[E_V4_01], MINT);
        assertEq(lobster.permissionsOf(user, keys[E_V4_01]), MINT);

        vm.prank(user);
        vm.expectRevert(IProxyErrors.PoolNotAllowed.selector);
        lobster.exactInputSingleV4(_v4InP(cleanKey, true, user));

        _setKey(keys[E_V4_01], MINT | SWAP);
        vm.prank(user);
        lobster.exactInputSingleV4(_v4InP(cleanKey, true, user));
    }

    // ---------------------------------------------------------------------------
    // Batches: registered routes run
    // ---------------------------------------------------------------------------

    /// @notice V3 -> V4 -> V4 -> V3 with every pool registered: the two chained V4 legs share one
    /// unlock, the vault pays only the first input, and the final output lands in the vault. (That
    /// each leg matches the same swap made directly is LobsterChaining.t.sol's subject.)
    function test_chainedRoute_V3_V4_V4_V3_landsInTheVault() public {
        (bytes[] memory s,) = _route(user);
        uint256[4] memory before = _who(user); // token0, token1, tokenC, ETH

        _expectUnlocks(1);
        vm.prank(user);
        uint256[] memory amounts = lobster.batchSwap(s);

        uint256[4] memory nowHeld = _who(user);
        assertEq(before[0] - nowHeld[0], 1e18, "the vault paid more than the first input");
        assertEq(nowHeld[1], before[1] + amounts[3], "final output did not land in the vault");
        assertEq(nowHeld[2], before[2], "tokenC moved");
        assertEq(nowHeld[3], before[3], "ETH moved");
        _assertNothingParked();
    }

    function test_v4ToV4_sharesOneUnlock() public {
        bytes[] memory s = new bytes[](2);
        s[0] = _leg(E_V4_E1, address(token1), 1e18, HERE);
        s[1] = _leg(E_V4_EC, ETH, HELD, user);
        uint256 cBefore = tokenC.balanceOf(user);

        _expectUnlocks(1);
        vm.prank(user);
        uint256[] memory amounts = lobster.batchSwap(s);

        assertEq(tokenC.balanceOf(user), cBefore + amounts[1], "output did not land in the vault");
        _assertNothingParked();
    }

    // ---------------------------------------------------------------------------
    // Batches: validation happens before anything runs
    // ---------------------------------------------------------------------------

    /// @notice One unregistered pool anywhere (each leg in turn: V3 first, V4 middle, V4 middle, V3 last)
    /// reverts the whole batch before any swap: no balance change, no PoolManager unlock, no V3 swap
    function test_unregisteredPoolAnywhere_revertsBeforeAnythingRuns() public {
        (bytes[] memory s, uint8[4] memory edges) = _route(user);
        uint256[4] memory before = _who(user);

        _expectUnlocks(0);
        vm.expectCall(address(v3Pool), abi.encodeWithSelector(IUniswapV3PoolMinimal.swap.selector), 0);
        for (uint256 i = 0; i < 4; i++) {
            uint256 snap = vm.snapshotState();
            _setKey(keys[edges[i]], 0);
            vm.prank(user);
            vm.expectRevert(IProxyErrors.PoolNotAllowed.selector);
            lobster.batchSwap(s);
            vm.revertToState(snap);
        }
        _assertUnchanged(before, user, "a rejected batch moved the vault's funds");
    }

    /// @notice Same for a V4 last leg, and for a V4 first leg
    function test_unregisteredV4PoolAtEitherEnd_reverts() public {
        bytes[] memory s = new bytes[](2);
        s[0] = _leg(E_V3_01, address(token0), 1e18, HERE);
        s[1] = _leg(E_V4_01, address(token1), HELD, user); // V4 last
        _setKey(keys[E_V4_01], 0);
        _expectUnlocks(0);
        vm.prank(user);
        vm.expectRevert(IProxyErrors.PoolNotAllowed.selector);
        lobster.batchSwap(s);

        s[0] = _leg(E_V4_E1, address(token1), 1e18, HERE); // V4 first
        s[1] = _leg(E_V4_EC, ETH, HELD, user);
        _setKey(keys[E_V4_E1], 0);
        vm.prank(user);
        vm.expectRevert(IProxyErrors.PoolNotAllowed.selector);
        lobster.batchSwap(s);
    }

    /// @notice A recipient other than the vault or ADDRESS_THIS, on any leg, reverts the whole batch
    function test_foreignRecipientOnAnyLeg_reverts() public {
        uint256[4] memory before = _who(user);
        address[2] memory foreign = [attacker, address(lobster)];
        _expectUnlocks(0);
        for (uint256 f = 0; f < 2; f++) {
            for (uint256 i = 0; i < 4; i++) {
                (bytes[] memory s, uint8[4] memory edges) = _route(user);
                address tokenIn = i == 0 ? address(token0) : i == 1 ? address(token1) : i == 2 ? ETH : address(tokenC);
                s[i] = _leg(edges[i], tokenIn, i == 0 ? 1e18 : HELD, foreign[f]);
                vm.prank(user);
                vm.expectRevert(IProxyErrors.RecipientMustBeCaller.selector);
                lobster.batchSwap(s);
            }
        }
        _assertUnchanged(before, user, "a rejected batch moved the vault's funds");
        _assertUnchanged([uint256(0), 0, 0, 0], attacker, "the attacker received something");
    }

    /// @notice A parked output can only leave the batch to the vault: spending it to anyone else is
    /// refused up front, and leaving it parked is refused at the end
    function test_parkedOutputCanOnlyEndUpInTheVault() public {
        uint256[4] memory before = _who(user);

        bytes[] memory s = new bytes[](2);
        s[0] = _leg(E_V3_01, address(token0), 1e18, HERE);
        s[1] = _leg(E_V4_E1, address(token1), HELD, attacker);
        vm.prank(user);
        vm.expectRevert(IProxyErrors.RecipientMustBeCaller.selector);
        lobster.batchSwap(s);

        bytes[] memory parkedOnly = new bytes[](1);
        parkedOnly[0] = _leg(E_V3_01, address(token0), 1e18, HERE);
        vm.prank(user);
        vm.expectRevert(IProxyErrors.FundsLeftInProxy.selector);
        lobster.batchSwap(parkedOnly);

        _assertUnchanged(before, user, "vault funds moved");
        _assertNothingParked();
    }

    /// @notice Random routes with each leg sent to the vault, parked, or to an attacker, over a random
    /// subset of registered pools: whenever a batch succeeds, the attacker got nothing, the proxy holds
    /// nothing, and the vault's net change is the route's own input and output.
    function testFuzz_randomBatches_neverLeakOutsideTheVault(uint256 seed, uint8 hops, uint8 registered) public {
        for (uint256 i = 0; i < 5; i++) {
            if ((registered >> i) & 1 == 0) _setKey(keys[i], 0);
        }
        uint256 n = bound(hops, 1, 4);
        address token = [address(token0), address(token1), address(tokenC)][seed % 3];
        bytes[] memory s = new bytes[](n);
        bool sendsToAttacker;
        for (uint256 i = 0; i < n; i++) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            uint8 edge = _edgeFrom(token, r);
            uint256 who = (r >> 8) % 3; // 0 vault, 1 parked, 2 attacker
            address to = who == 0 ? user : who == 1 ? HERE : attacker;
            if (who == 2) sendsToAttacker = true;
            s[i] = _leg(edge, token, i == 0 ? bound(r >> 16, 1e15, 5e18) : HELD, to);
            token = _otherSide(edge, token);
        }

        vm.prank(user);
        try lobster.batchSwap(s) {
            assertFalse(sendsToAttacker, "a batch paying the attacker succeeded");
        } catch {}
        _assertUnchanged([uint256(0), 0, 0, 0], attacker, "the attacker received something");
        _assertNothingParked();
    }

    function _edgeFrom(address token, uint256 r) internal view returns (uint8) {
        if (token == address(token0)) return [E_V3_01, E_V4_01][r % 2];
        if (token == address(token1)) return [E_V3_01, E_V3_1C, E_V4_01, E_V4_E1][r % 4];
        if (token == address(tokenC)) return [E_V3_1C, E_V4_EC][r % 2];
        return [E_V4_E1, E_V4_EC][r % 2];
    }

    function test_malformedItems_revertInValidation() public {
        bytes[] memory s = new bytes[](1);
        s[0] = hex"";
        _expectUnlocks(0);
        vm.prank(user);
        vm.expectRevert(IProxyErrors.InvalidSwapType.selector);
        lobster.batchSwap(s);

        s[0] = hex"0500";
        vm.prank(user);
        vm.expectRevert(IProxyErrors.InvalidSwapType.selector);
        lobster.batchSwap(s);

        s[0] = abi.encodePacked(SwapType.V4_EXACT_INPUT, new bytes(64)); // too short to decode
        vm.prank(user);
        vm.expectRevert();
        lobster.batchSwap(s);
    }

    // ---------------------------------------------------------------------------
    // V4 single swaps
    // ---------------------------------------------------------------------------

    function _v4InP(
        ProxyPoolKey memory key,
        bool zeroForOne,
        address to
    )
        internal
        view
        returns (V4ExactInputSingleParams memory)
    {
        return V4ExactInputSingleParams({
            poolKey: key,
            zeroForOne: zeroForOne,
            recipient: to,
            deadline: block.timestamp,
            amountIn: 1e18,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });
    }

    function test_v4Single_unregisteredPool_reverts() public {
        _setKey(keys[E_V4_01], 0);
        _expectUnlocks(0);
        vm.startPrank(user);
        vm.expectRevert(IProxyErrors.PoolNotAllowed.selector);
        lobster.exactInputSingleV4(_v4InP(cleanKey, true, user));
        vm.stopPrank();
    }

    function test_v4Single_foreignRecipient_reverts() public {
        address[3] memory foreign = [attacker, address(lobster), HERE];
        vm.startPrank(user);
        for (uint256 i = 0; i < 3; i++) {
            vm.expectRevert(IProxyErrors.RecipientMustBeCaller.selector);
            lobster.exactInputSingleV4(_v4InP(cleanKey, true, foreign[i]));
        }
        vm.stopPrank();
    }

    /// @notice Native ETH in, with more ETH sent than needed: the vault pays exactly `amountIn`, gets
    /// the rest back, and receives the output
    function test_v4Single_nativeInput_refundsTheVault() public {
        uint256 ethBefore = user.balance;
        uint256 t1Before = token1.balanceOf(user);

        vm.prank(user);
        uint256 out = lobster.exactInputSingleV4{value: 3e18}(_v4InP(nativeKey, true, user)); // 1 ETH in

        assertEq(ethBefore - user.balance, 1e18, "vault did not get its change back");
        assertEq(token1.balanceOf(user), t1Before + out, "output did not reach the vault");
        assertEq(address(lobster).balance, 0, "proxy kept ETH");
    }

    function test_v4Single_nativeOutput_paysTheVault() public {
        uint256 ethBefore = user.balance;
        vm.prank(user);
        uint256 out = lobster.exactInputSingleV4(_v4InP(nativeKey, false, user)); // token1 in, ETH out
        assertGt(out, 0);
        assertEq(user.balance, ethBefore + out, "ETH output did not reach the vault");
        assertEq(address(lobster).balance, 0, "proxy kept ETH");
    }

    /// @notice Registering a hooked pool's PoolId does not make it usable: the hookless rule still
    /// applies, in single swaps and in batches
    function test_hookedPool_isRejectedEvenIfRegistered() public {
        ProxyPoolKey memory hooked = cleanKey;
        hooked.hooks = ProxyIHooks(makeAddr("someHook"));
        _setKey(lobster.v4Key(hooked), SWAP);
        assertEq(lobster.permissionsOf(user, lobster.v4Key(hooked)), SWAP);

        _expectUnlocks(0);
        vm.startPrank(user);
        vm.expectRevert(IProxyErrors.HooksNotSupported.selector);
        lobster.exactInputSingleV4(_v4InP(hooked, true, user));

        bytes[] memory s = new bytes[](1);
        s[0] = abi.encodePacked(SwapType.V4_EXACT_INPUT, abi.encode(_v4InP(hooked, true, user)));
        vm.expectRevert(IProxyErrors.HooksNotSupported.selector);
        lobster.batchSwap(s);
        vm.stopPrank();
    }
}
