// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.20;

import {BatchSwapFixture} from "./helpers/BatchSwapFixture.sol";
import {SwapCalldata} from "./helpers/SwapCalldata.sol";
import {TickMath} from "../src/libraries/uniswapV3/TickMath.sol";
import {IProxyErrors} from "../src/interfaces/IProxyErrors.sol";
import {PoolKey as ProxyPoolKey} from "../src/interfaces/uniswapV4/IPoolManagerMinimal.sol";

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {DeltaReturningHook} from "v4-core/src/test/DeltaReturningHook.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @notice LobsterProxy's V4 single swaps against a real PoolManager. A single swap is a one-leg `swap`
/// call ({SwapCalldata}); the suite covers exact input and output, native ETH in and out with refunds,
/// slippage bounds, the deadline, price bands, and why hooked pools are out of reach. The user (the
/// vault) has registered every pool, including the hooked one, so it is the proxy's own logic that is
/// under test here, not the registry.
/// @dev On the shared {BatchSwapFixture} (hookless token0/token1 and ETH/token1 V4 pools), plus a hooked
/// pool on the same currencies, fee and tickSpacing as `cleanKey`: initialized, with real liquidity, and
/// with a DeltaReturningHook attached.
contract LobsterV4SwapTest is BatchSwapFixture {
    DeltaReturningHook public hook;
    /// @dev token0 / token1, same fee and tickSpacing as `cleanKey`, DeltaReturningHook attached
    ProxyPoolKey public hookedKey;
    address public attacker = makeAddr("attacker");

    function setUp() public override {
        super.setUp();

        // A v4 hook's ADDRESS encodes which callbacks it implements, so it has to be placed at an
        // address whose low bits match its permissions.
        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
                | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
        address hookAddr = address(uint160(0x4444 << 144) | flags);
        deployCodeTo("DeltaReturningHook.sol:DeltaReturningHook", abi.encode(IPoolManager(address(manager))), hookAddr);
        hook = DeltaReturningHook(hookAddr);

        PoolKey memory hooked = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(hookAddr)
        });
        manager.initialize(hooked, SQRT_PRICE_1_1);
        _addV4Liquidity(hooked, 0);
        hookedKey = _toProxyKey(hooked);

        // The hook needs its own funds to settle any negative delta it creates
        token0.mint(address(hook), 100_000e18);
        token1.mint(address(hook), 100_000e18);

        // The vault registers the hooked pool too, with any price allowed, like the fixture's pools
        _allow(user, proxy.v4Key(hookedKey), SWAP);
    }

    // ---------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------

    /// @dev The `data` of a `swap` call running `legs`, with the current block as deadline
    function _data(SwapCalldata.Leg[] memory legs) internal view returns (bytes memory) {
        return SwapCalldata.encode(block.timestamp, legs);
    }

    /// @dev `swap` running `legs` for `user`, with `value` wei attached
    function _swapWithValue(SwapCalldata.Leg[] memory legs, uint256 value) internal returns (uint256[] memory) {
        vm.prank(user);
        return proxy.swap{value: value}(_data(legs));
    }

    /// @dev Sets `user`'s permissions for `key`; 0 de-registers it (its band stays as it is)
    function _register(ProxyPoolKey memory key, uint8 permissions) internal {
        bytes32[] memory keys = new bytes32[](1);
        keys[0] = proxy.v4Key(key);
        uint8[] memory perms = new uint8[](1);
        perms[0] = permissions;
        vm.prank(user);
        proxy.setPools(keys, perms);
    }

    function _setBand(ProxyPoolKey memory key, int24 minTick, int24 maxTick) internal {
        bytes32 k = proxy.v4Key(key);
        vm.prank(user);
        proxy.setPriceBand(k, minTick, maxTick);
    }

    function _id(ProxyPoolKey memory key) internal pure returns (PoolId) {
        return PoolId.wrap(keccak256(abi.encode(key)));
    }

    /// @dev The pool's state, read independently of the proxy with v4-core's StateLibrary
    function _tickOf(ProxyPoolKey memory key) internal view returns (int24 tick) {
        (, tick,,) = StateLibrary.getSlot0(manager, _id(key));
    }

    function _sqrtPriceOf(ProxyPoolKey memory key) internal view returns (uint160 sqrtPriceX96) {
        (sqrtPriceX96,,,) = StateLibrary.getSlot0(manager, _id(key));
    }

    /// @dev From here to the end of the test: exactly `count` PoolManager unlocks
    function _expectUnlocks(uint64 count) internal {
        vm.expectCall(address(manager), abi.encodeWithSelector(IPoolManager.unlock.selector), count);
    }

    /// @dev From here to the end of the test: no unlock and no V4 swap at all
    function _expectNothingRuns() internal {
        _expectUnlocks(0);
        vm.expectCall(address(manager), abi.encodeWithSelector(IPoolManager.swap.selector), 0);
    }

    /// @dev From here to the end of the test: the hook is never called
    function _expectHookNeverCalled() internal {
        vm.expectCall(address(hook), abi.encodeWithSelector(IHooks.beforeSwap.selector), 0);
        vm.expectCall(address(hook), abi.encodeWithSelector(IHooks.afterSwap.selector), 0);
    }

    /// @dev `who`'s ETH, token0 and token1, indexed as {_slot}
    function _balances(address who) internal view returns (uint256[3] memory b) {
        b = [who.balance, token0.balanceOf(who), token1.balanceOf(who)];
    }

    /// @dev Index of `token` in {_balances}
    function _slot(address token) internal view returns (uint256) {
        if (token == address(0)) return 0;
        return token == address(token0) ? 1 : 2;
    }

    function _assertBalancesEq(uint256[3] memory a, uint256[3] memory b, string memory who) internal pure {
        for (uint256 i = 0; i < 3; i++) {
            assertEq(a[i], b[i], string.concat(who, ": balance ", vm.toString(i), " moved"));
        }
    }

    /// @dev A vault of its own: funded, with standing approvals, both hookless V4 pools registered
    function _newVault(address vault) internal {
        token0.mint(vault, 100e18);
        token1.mint(vault, 100e18);
        vm.deal(vault, 100e18);
        vm.startPrank(vault);
        token0.approve(address(proxy), type(uint256).max);
        token1.approve(address(proxy), type(uint256).max);
        vm.stopPrank();
        _allow(vault, proxy.v4Key(cleanKey), SWAP);
        _allow(vault, proxy.v4Key(nativeKey), SWAP);
    }

    /// @dev One V4 single swap of a random kind, direction and size, with the msg.value it needs: exact
    /// input, exact output, ETH in (exact input or output, with change to refund), ETH out
    function _randomV4Swap(uint256 seed) internal view returns (SwapCalldata.Leg memory leg, uint256 value) {
        uint256 kind = seed % 5;
        bool zeroForOne = (seed >> 8) & 1 == 1;
        uint128 amount = SafeCast.toUint128(bound(seed >> 16, 1e6, 10e18));
        if (kind == 0) return (_v4In(cleanKey, zeroForOne, amount, 0), 0);
        if (kind == 1) return (_v4Out(cleanKey, zeroForOne, amount, type(uint128).max), 0);
        if (kind == 2) return (_v4In(nativeKey, true, amount, 0), amount + bound(seed >> 144, 0, 1e18));
        if (kind == 3) return (_v4Out(nativeKey, true, amount, type(uint128).max), 2 * uint256(amount));
        return (_v4In(nativeKey, false, amount, 0), 0);
    }

    // ---------------------------------------------------------------------------
    // Happy path: a single swap is a one-leg call, inside exactly one unlock
    // ---------------------------------------------------------------------------

    /// @notice Exact input: the caller pays exactly `amountIn`, straight to the PoolManager, and receives
    /// the output, straight from it; one amount is returned, and the proxy keeps nothing
    function test_swap_v4ExactIn_swapsAndPaysFromCaller() public {
        uint256 balBefore = token0.balanceOf(user);
        uint256 outBefore = token1.balanceOf(user);
        _expectUnlocks(1);
        vm.expectCall(address(token0), abi.encodeCall(token0.transferFrom, (user, address(manager), 1e18)), 1);
        vm.expectCall(
            address(manager),
            abi.encodeWithSelector(IPoolManager.take.selector, Currency.wrap(address(token1)), user),
            1
        );

        uint256[] memory amounts = _swapAs(user, _batch(_v4In(cleanKey, true, 1e18, 0)));

        assertEq(amounts.length, 1, "one amount per leg");
        uint256 amountOut = amounts[0];
        assertGt(amountOut, 0, "no output");
        assertEq(token1.balanceOf(user) - outBefore, amountOut, "caller did not receive the output");
        assertEq(balBefore - token0.balanceOf(user), 1e18, "input pulled != amountIn");
        _assertProxyHoldsNothing();
    }

    /// @notice Exact output: the caller receives exactly `amountOut` and pays what is returned, at most
    /// `amountInMaximum`
    function test_swap_v4ExactOut_deliversExactOutput() public {
        uint256 balBefore = token0.balanceOf(user);
        uint256 outBefore = token1.balanceOf(user);
        _expectUnlocks(1);

        uint256[] memory amounts = _swapAs(user, _batch(_v4Out(cleanKey, true, 1e18, 2e18)));

        assertEq(amounts.length, 1, "one amount per leg");
        uint256 amountIn = amounts[0];
        assertEq(token1.balanceOf(user) - outBefore, 1e18, "caller did not get the exact output");
        assertEq(balBefore - token0.balanceOf(user), amountIn, "input accounting mismatch");
        assertLe(amountIn, 2e18, "exceeded amountInMaximum");
        _assertProxyHoldsNothing();
    }

    // ---------------------------------------------------------------------------
    // Hooked pools are out of reach: a leg cannot name a hook
    // ---------------------------------------------------------------------------

    /// @notice A leg cannot encode a hook, so a swap on the hooked pool's currencies, fee and tickSpacing
    /// targets the hookless pool. `hookedKey` is a fully initialized pool with real liquidity that the
    /// vault registered, so this proves its registration authorizes nothing: with the hookless pool
    /// de-registered the swap is refused before anything runs.
    function test_swap_v4ExactIn_cannotReachAHookedPool() public {
        _register(cleanKey, 0);
        uint256 balBefore = token0.balanceOf(user);
        uint160 hookedPrice = _sqrtPriceOf(hookedKey);
        _expectNothingRuns();
        _expectHookNeverCalled();

        vm.prank(user);
        vm.expectRevert(IProxyErrors.PoolNotAllowed.selector);
        proxy.swap(_data(_batch(_v4In(hookedKey, true, 1e18, 0))));

        assertEq(token0.balanceOf(user), balBefore, "caller lost funds");
        assertEq(_sqrtPriceOf(hookedKey), hookedPrice, "the hooked pool was traded");
    }

    /// @notice Same for exact output
    function test_swap_v4ExactOut_cannotReachAHookedPool() public {
        _register(cleanKey, 0);
        uint256 balBefore = token0.balanceOf(user);
        uint160 hookedPrice = _sqrtPriceOf(hookedKey);
        _expectNothingRuns();
        _expectHookNeverCalled();

        vm.prank(user);
        vm.expectRevert(IProxyErrors.PoolNotAllowed.selector);
        proxy.swap(_data(_batch(_v4Out(hookedKey, true, 1e18, 2e18))));

        assertEq(token0.balanceOf(user), balBefore, "caller lost funds");
        assertEq(_sqrtPriceOf(hookedKey), hookedPrice, "the hooked pool was traded");
    }

    /// @notice The hostile-hook attack hooked pools were refused for: `hookDeltaUnspecified` from
    /// afterSwap is an unbounded int128 applied straight to the swap's "unspecified" currency, which for
    /// an exact-input swap is the OUTPUT, so a hook can keep what the swapper should receive. Proven
    /// unreachable: with only the hooked pool registered the swap is refused, and with the hookless pool
    /// registered too the swap runs there, the hook is never called and the output arrives whole.
    function test_hostileHookCannotSkimTheOutput() public {
        hook.setDeltaUnspecifiedAfterSwap(5e18); // would take 5 token1 out of the swapper's output
        uint256 t0Before = token0.balanceOf(user);
        uint256 t1Before = token1.balanceOf(user);
        uint160 hookedPrice = _sqrtPriceOf(hookedKey);
        uint160 cleanPrice = _sqrtPriceOf(cleanKey);
        _expectHookNeverCalled();

        // amountOutMinimum is deliberately zero here: the registry, not the slippage bound, is what has
        // to stop this
        _register(cleanKey, 0);
        vm.prank(user);
        vm.expectRevert(IProxyErrors.PoolNotAllowed.selector);
        proxy.swap(_data(_batch(_v4In(hookedKey, true, 1e18, 0))));
        assertEq(token0.balanceOf(user), t0Before, "victim paid");
        assertEq(token1.balanceOf(user), t1Before, "victim's balance changed");

        _register(cleanKey, SWAP);
        uint256 amountOut = _swapAs(user, _batch(_v4In(hookedKey, true, 1e18, 0)))[0];
        assertGt(amountOut, 0, "no output");
        assertEq(token1.balanceOf(user) - t1Before, amountOut, "output not delivered whole");
        assertEq(t0Before - token0.balanceOf(user), 1e18, "input pulled != amountIn");
        assertEq(_sqrtPriceOf(hookedKey), hookedPrice, "the hooked pool was traded");
        assertLt(_sqrtPriceOf(cleanKey), cleanPrice, "the swap did not run on the hookless pool");
        _assertProxyHoldsNothing();
    }

    /// @notice Hooked pools must be out of reach even when the hook is entirely benign, so that support
    /// is a deliberate decision rather than a function of what the hook happens to do: a registered
    /// hooked pool with a passive hook authorizes no swap either
    function test_rejectsHookedPoolEvenWhenHookIsPassive() public {
        hook.setDeltaSpecified(0);
        hook.setDeltaUnspecifiedBeforeSwap(0);
        hook.setDeltaUnspecifiedAfterSwap(0);
        _register(cleanKey, 0);
        _expectNothingRuns();
        _expectHookNeverCalled();

        vm.prank(user);
        vm.expectRevert(IProxyErrors.PoolNotAllowed.selector);
        proxy.swap(_data(_batch(_v4In(hookedKey, true, 1e18, 0))));
        vm.prank(user);
        vm.expectRevert(IProxyErrors.PoolNotAllowed.selector);
        proxy.swap(_data(_batch(_v4Out(hookedKey, true, 1e18, 2e18))));
    }

    /// @notice Hooked pools used to be refused for being hooked, whatever their band. Now no leg reaches
    /// them, so their registry entries, bands included, never decide anything: a swap on the same
    /// currencies, fee and tickSpacing is checked against the hookless pool's entry only
    function test_v4Swap_hookedPoolsEntryIsNeverConsulted() public {
        // The hooked pool's band cleared: irrelevant, the swap runs on the hookless pool
        _setBand(hookedKey, 0, 0);
        uint256 amountOut = _swapAs(user, _batch(_v4In(hookedKey, true, 1e18, 0)))[0];
        assertGt(amountOut, 0, "the hooked pool's band blocked a hookless swap");

        // The hooked pool's band wide open, the hookless pool's cleared: refused, for the hookless one
        _setBand(hookedKey, TickMath.MIN_TICK, TickMath.MAX_TICK);
        _setBand(cleanKey, 0, 0);
        vm.prank(user);
        vm.expectRevert(IProxyErrors.PriceBandNotSet.selector);
        proxy.swap(_data(_batch(_v4In(hookedKey, true, 1e18, 0))));
    }

    // ---------------------------------------------------------------------------
    // Slippage bounds
    // ---------------------------------------------------------------------------

    /// @notice Exact input below `amountOutMinimum` reverts
    function test_swap_v4ExactIn_revertsWhenOutputBelowMinimum() public {
        vm.prank(user);
        vm.expectRevert(IProxyErrors.TooLittleReceived.selector);
        proxy.swap(_data(_batch(_v4In(cleanKey, true, 1e18, 2e18)))); // unreachable minimum
    }

    /// @notice Exact output costing more than `amountInMaximum` reverts
    function test_swap_v4ExactOut_revertsWhenInputAboveMaximum() public {
        vm.prank(user);
        vm.expectRevert(IProxyErrors.TooMuchRequested.selector);
        proxy.swap(_data(_batch(_v4Out(cleanKey, true, 1e18, 0.5e18)))); // impossibly tight
    }

    // ---------------------------------------------------------------------------
    // Price limits: without one, exact output fills completely or not at all
    // ---------------------------------------------------------------------------

    /// @notice Without a price limit, an exact-output leg the pool cannot fill in full reverts instead of
    /// charging for a partial fill, in both directions (each runs to its own default limit)
    function test_swap_v4ExactOut_withoutPriceLimit_partialFillReverts() public {
        uint256[6] memory before = _holdings();

        // The pool's only position holds about 259e18 of each token: 300e18 cannot be delivered
        vm.prank(user);
        vm.expectRevert(IProxyErrors.TooLittleReceived.selector);
        proxy.swap(_data(_batch(_v4Out(cleanKey, true, 300e18, type(uint128).max))));
        vm.prank(user);
        vm.expectRevert(IProxyErrors.TooLittleReceived.selector);
        proxy.swap(_data(_batch(_v4Out(cleanKey, false, 300e18, type(uint128).max))));

        _assertHoldingsEq(_holdings(), before, "caller paid for a partial fill");
    }

    /// @notice With a price limit the caller has bounded the price, so a partial fill up to it is a
    /// legitimate outcome: the swap stops exactly at the limit, and the caller receives what the pool
    /// delivered and pays what is returned
    function test_swap_v4ExactOut_withPriceLimit_deliversAPartialFill() public {
        uint160 limit = TickMath.getSqrtRatioAtTick(-100);
        SwapCalldata.Leg memory leg = _v4Out(cleanKey, true, 300e18, type(uint128).max);
        leg.sqrtPriceLimitX96 = limit;
        uint256 in0 = token0.balanceOf(user);
        uint256 out1 = token1.balanceOf(user);

        uint256 amountIn = _swapAs(user, _batch(leg))[0];

        uint256 delivered = token1.balanceOf(user) - out1;
        assertGt(delivered, 0, "nothing delivered");
        assertLt(delivered, 300e18, "expected a partial fill up to the price limit");
        assertEq(in0 - token0.balanceOf(user), amountIn, "caller paid != returned amountIn");
        assertEq(_sqrtPriceOf(cleanKey), limit, "the swap did not stop at the price limit");
        _assertProxyHoldsNothing();
    }

    /// @notice Exact input stopped by its price limit: the caller pays only what the pool took, not the
    /// whole `amountIn`
    function test_swap_v4ExactIn_withPriceLimit_paysOnlyWhatThePoolTook() public {
        uint160 limit = TickMath.getSqrtRatioAtTick(-100);
        SwapCalldata.Leg memory leg = _v4In(cleanKey, true, 300e18, 0);
        leg.sqrtPriceLimitX96 = limit;
        uint256 in0 = token0.balanceOf(user);
        uint256 out1 = token1.balanceOf(user);

        uint256 amountOut = _swapAs(user, _batch(leg))[0];

        uint256 paid = in0 - token0.balanceOf(user);
        assertGt(paid, 0, "nothing paid");
        assertLt(paid, 300e18, "charged the whole amountIn for a partial fill");
        assertEq(token1.balanceOf(user) - out1, amountOut, "caller did not receive the output");
        assertEq(_sqrtPriceOf(cleanKey), limit, "the swap did not stop at the price limit");
        _assertProxyHoldsNothing();
    }

    // ---------------------------------------------------------------------------
    // Access control, deadline
    // ---------------------------------------------------------------------------

    /// @notice Only the PoolManager may call `unlockCallback`, so a forged swap unlock is refused before
    /// its payload is read; and the PoolManager itself is only answered for the proxy's two kinds of
    /// unlock
    function test_unlockCallback_revertsForNonPoolManager() public {
        vm.prank(user);
        vm.expectRevert(IProxyErrors.NotPoolManager.selector);
        proxy.unlockCallback("");

        // Tagged as a swap unlock (SWAP_TAG 0x01), carrying a swap's data
        bytes memory forged = bytes.concat(bytes1(0x01), _data(_batch(_v4In(cleanKey, true, 1e18, 0))));
        vm.prank(attacker);
        vm.expectRevert(IProxyErrors.NotPoolManager.selector);
        proxy.unlockCallback(forged);

        // Neither SWAP_TAG nor LIQUIDITY_TAG
        vm.prank(address(manager));
        vm.expectRevert(IProxyErrors.UnexpectedCallback.selector);
        proxy.unlockCallback(hex"03");
    }

    /// @notice The deadline is one uint32 for the whole call: past it, exact input and exact output alike
    /// revert before anything runs; at exactly the deadline the call runs
    function test_swapsRevertPastDeadline() public {
        vm.warp(1_700_000_000);
        _expectUnlocks(1); // the last call only

        vm.prank(user);
        vm.expectRevert(IProxyErrors.TransactionTooOld.selector);
        proxy.swap(SwapCalldata.encode(block.timestamp - 1, _batch(_v4In(cleanKey, true, 1e18, 0))));
        vm.prank(user);
        vm.expectRevert(IProxyErrors.TransactionTooOld.selector);
        proxy.swap(SwapCalldata.encode(block.timestamp - 1, _batch(_v4Out(cleanKey, true, 1e18, 2e18))));

        vm.prank(user);
        proxy.swap(SwapCalldata.encode(block.timestamp, _batch(_v4In(cleanKey, true, 1e18, 0))));
    }

    // ---------------------------------------------------------------------------
    // No recipient: outputs go to the caller, never anywhere else
    // ---------------------------------------------------------------------------

    /// @notice Replaces the zero-recipient rejection: there is no recipient to name. Whoever calls
    /// `swap` pays the input and receives the output, for every kind of V4 single swap (exact input,
    /// exact output, ETH in with change, ETH out); another vault, an outsider, address(0) and the proxy
    /// never receive anything
    function testFuzz_swap_outputGoesToTheCallerOnly(address caller, uint256 seed) public {
        assumeUnusedAddress(caller);
        vm.assume(caller != user && caller != attacker);
        _newVault(caller);
        (SwapCalldata.Leg memory leg, uint256 value) = _randomV4Swap(seed);
        uint256[3] memory callerBefore = _balances(caller);
        uint256[3] memory userBefore = _balances(user);
        uint256[3] memory attackerBefore = _balances(attacker);
        uint256[3] memory zeroBefore = _balances(address(0));

        vm.prank(caller);
        uint256 amount = proxy.swap{value: value}(_data(_batch(leg)))[0];

        (uint256 paid, uint256 received) = leg.exactOut ? (amount, uint256(leg.amount)) : (uint256(leg.amount), amount);
        uint256[3] memory callerAfter = _balances(caller);
        (uint256 i, uint256 o) = (_slot(leg.tokenIn), _slot(leg.tokenOut));
        assertEq(callerBefore[i] - callerAfter[i], paid, "caller paid != the leg's input");
        assertEq(callerAfter[o] - callerBefore[o], received, "caller did not receive the output");
        assertEq(callerAfter[3 - i - o], callerBefore[3 - i - o], "caller's third balance moved");
        _assertBalancesEq(_balances(user), userBefore, "another vault");
        _assertBalancesEq(_balances(attacker), attackerBefore, "outsider");
        _assertBalancesEq(_balances(address(0)), zeroBefore, "address(0)");
        _assertProxyHoldsNothing();
    }

    /// @notice Replaces the proxy-as-recipient rejection (an output sent to the proxy could never leave
    /// it): the only way an output stays with the proxy is PARK, and a parked output that no later leg
    /// spends reverts the call, for exact input, exact output and native output alike. The caller pays
    /// nothing and the proxy ends up holding nothing.
    function test_swap_outputCannotBeLeftInTheProxy() public {
        SwapCalldata.Leg[] memory legs = new SwapCalldata.Leg[](3);
        legs[0] = _v4In(cleanKey, true, 1e18, 0);
        legs[1] = _v4Out(cleanKey, true, 1e18, 2e18);
        legs[2] = _v4In(nativeKey, false, 1e18, 0); // token1 in, ETH out
        uint256[6] memory before = _holdings();

        for (uint256 i = 0; i < legs.length; i++) {
            legs[i].park = true;
            vm.prank(user);
            vm.expectRevert(IProxyErrors.FundsLeftInProxy.selector);
            proxy.swap(_data(_batch(legs[i])));
        }

        _assertHoldingsEq(_holdings(), before, "refused swaps");
        _assertProxyHoldsNothing();
    }

    // ---------------------------------------------------------------------------
    // Native ETH
    // ---------------------------------------------------------------------------

    /// @notice More ETH sent than `amountIn`: the swap spends exactly `amountIn` and the rest comes back
    function test_swap_v4NativeIn_refundsUnspentEth() public {
        uint256 ethBefore = user.balance;
        uint256 outBefore = token1.balanceOf(user);

        uint256 amountOut = _swapWithValue(_batch(_v4In(nativeKey, true, 1e18, 0)), 2e18)[0];

        assertGt(amountOut, 0, "no output");
        assertEq(token1.balanceOf(user) - outBefore, amountOut, "caller did not get the output");
        assertEq(ethBefore - user.balance, 1e18, "unspent ETH was not refunded");
        assertEq(address(proxy).balance, 0, "proxy retained ETH");
    }

    /// @notice Native as the swap OUTPUT: the PoolManager pays it straight to the caller (`take`), never
    /// through the proxy. The other native tests only cover native as input.
    function test_swap_v4NativeOut_paysTheCallerInEth() public {
        uint256 ethBefore = user.balance;
        uint256 tokenBefore = token1.balanceOf(user);
        vm.expectCall(
            address(manager), abi.encodeWithSelector(IPoolManager.take.selector, Currency.wrap(address(0)), user), 1
        );

        uint256 amountOut = _swapAs(user, _batch(_v4In(nativeKey, false, 1e18, 0)))[0]; // token1 in, ETH out

        assertGt(amountOut, 0, "no output");
        assertEq(user.balance - ethBefore, amountOut, "caller did not receive ETH");
        assertEq(tokenBefore - token1.balanceOf(user), 1e18, "input pulled != amountIn");
        assertEq(address(proxy).balance, 0, "proxy retained ETH");
    }

    /// @notice Exactly `amountIn` sent: all of it is spent and none is left in the proxy
    function test_swap_v4NativeIn_leavesNoEthBehind() public {
        uint256 ethBefore = user.balance;

        _swapWithValue(_batch(_v4In(nativeKey, true, 1e18, 0)), 1e18);

        assertEq(ethBefore - user.balance, 1e18, "spent != amountIn");
        assertEq(address(proxy).balance, 0, "proxy retained ETH");
    }

    /// @notice Exact output paid in ETH: the swap spends what it costs, and the rest of msg.value comes
    /// back
    function test_swap_v4NativeInExactOut_refundsUnspentEth() public {
        uint256 ethBefore = user.balance;
        uint256 outBefore = token1.balanceOf(user);

        uint256 amountIn = _swapWithValue(_batch(_v4Out(nativeKey, true, 1e18, 2e18)), 2e18)[0];

        assertEq(token1.balanceOf(user) - outBefore, 1e18, "caller did not get the output");
        assertEq(ethBefore - user.balance, amountIn, "unspent ETH was not refunded");
        assertEq(address(proxy).balance, 0, "proxy retained ETH");
    }

    /// @notice Native input is paid from msg.value: sending less than the leg costs reverts, exact input
    /// and exact output alike, and the caller keeps its ETH
    function test_swap_v4NativeIn_withoutEnoughEth_reverts() public {
        uint256 ethBefore = user.balance;

        vm.prank(user);
        vm.expectRevert(IProxyErrors.NotEnoughEthSent.selector);
        proxy.swap{value: 1e18 - 1}(_data(_batch(_v4In(nativeKey, true, 1e18, 0))));
        vm.prank(user);
        vm.expectRevert(IProxyErrors.NotEnoughEthSent.selector);
        proxy.swap(_data(_batch(_v4Out(nativeKey, true, 1e18, 2e18))));

        assertEq(user.balance, ethBefore, "caller lost ETH");
        assertEq(address(proxy).balance, 0, "proxy retained ETH");
    }

    /// @notice KNOWN BEHAVIOUR (see UniswapSwapProxy): the proxy's whole ETH balance goes back to the
    /// caller at the end of every call. That is msg.value no leg spent, on a call with no native leg too,
    /// and ETH force-fed to the proxy, which belongs to no one; force-fed ETH can also pay a native input.
    function test_swap_refundsEveryWeiTheProxyHolds_forceFedIncluded() public {
        uint256 ethBefore = user.balance;

        // msg.value on a call that spends no ETH: refunded whole
        _swapWithValue(_batch(_v4In(cleanKey, true, 1e18, 0)), 1e18);
        assertEq(user.balance, ethBefore, "unspent msg.value kept");

        // ETH force-fed to the proxy (a selfdestruct, a coinbase payment): swept to the next caller
        vm.deal(address(proxy), 3e18);
        _swapWithValue(_batch(_v4In(cleanKey, true, 1e18, 0)), 0);
        assertEq(user.balance - ethBefore, 3e18, "force-fed ETH not swept to the caller");

        // ...even when it pays the caller's native input
        vm.deal(address(proxy), 1e18);
        uint256 amountOut = _swapWithValue(_batch(_v4In(nativeKey, true, 0.4e18, 0)), 0)[0];
        assertGt(amountOut, 0, "no output");
        assertEq(user.balance - ethBefore, 3.6e18, "force-fed ETH: input not paid from it, or rest not swept");
        assertEq(address(proxy).balance, 0, "proxy retained ETH");
    }

    // ---------------------------------------------------------------------------
    // Price bands: every V4 swap needs the pool's price inside the caller's band, before and after
    // ---------------------------------------------------------------------------

    /// @notice No band, no swap: refused before anything runs
    function test_v4Swap_withoutPriceBand_reverts() public {
        _setBand(cleanKey, 0, 0);
        _expectNothingRuns();

        vm.prank(user);
        vm.expectRevert(IProxyErrors.PriceBandNotSet.selector);
        proxy.swap(_data(_batch(_v4In(cleanKey, true, 1e18, 0))));
    }

    /// @notice A pool already priced outside the band cannot be traded, exact input or exact output
    function test_v4Swap_startingOutsideBand_reverts() public {
        int24 tick = _tickOf(cleanKey);
        _setBand(cleanKey, tick + 1, tick + 1000);

        vm.prank(user);
        vm.expectRevert(IProxyErrors.PriceOutOfBand.selector);
        proxy.swap(_data(_batch(_v4In(cleanKey, true, 1e18, 0))));
        vm.prank(user);
        vm.expectRevert(IProxyErrors.PriceOutOfBand.selector);
        proxy.swap(_data(_batch(_v4Out(cleanKey, true, 1e18, 2e18))));
    }

    /// @notice A swap that would leave the price outside the band is refused: nothing is paid and the
    /// price stays where it was
    function test_v4Swap_endingOutsideBand_reverts() public {
        int24 tick = _tickOf(cleanKey);
        _setBand(cleanKey, tick - 100, tick + 100);
        uint256 before0 = token0.balanceOf(user);

        vm.prank(user);
        vm.expectRevert(IProxyErrors.PriceOutOfBand.selector);
        proxy.swap(_data(_batch(_v4In(cleanKey, true, 200e18, 0)))); // far past tick - 100

        assertEq(token0.balanceOf(user), before0, "a refused swap was paid");
        assertEq(_tickOf(cleanKey), tick, "a refused swap moved the price");
    }

    /// @notice Inside the band before and after: the swap goes through
    function test_v4Swap_insideBand_succeeds() public {
        int24 tick = _tickOf(cleanKey);
        _setBand(cleanKey, tick - 100, tick + 100);

        uint256 amountOut = _swapAs(user, _batch(_v4In(cleanKey, true, 1e18, 0)))[0];

        assertGt(amountOut, 0, "no output");
        assertGe(_tickOf(cleanKey), tick - 100, "ended outside the band");
    }
}
