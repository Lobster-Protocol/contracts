// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.20;

import "forge-std/Test.sol";

import {LobsterProxy} from "../src/LobsterProxy.sol";
import {TickMath} from "../src/libraries/uniswapV3/TickMath.sol";
import {V4ExactInputSingleParams, V4ExactOutputSingleParams} from "../src/interfaces/uniswapV4/IUnlockCallback.sol";
// The proxy deliberately uses its own vendored types, so they are distinct from v4-core's even
// though they are ABI-identical. Alias them to keep the two worlds visibly separate.
import {
    PoolKey as ProxyPoolKey,
    Currency as ProxyCurrency,
    IHooks as ProxyIHooks
} from "../src/interfaces/uniswapV4/IPoolManagerMinimal.sol";

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolManagerDeployer} from "./Mocks/uniswapV4/PoolManagerDeployer.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {DeltaReturningHook} from "v4-core/src/test/DeltaReturningHook.sol";

// NOTE: solmate's mock, not test/Mocks/MockERC20.sol. v4-core's PoolManager pins `pragma =0.8.26`
// and the repo mock requires ^0.8.28, which makes the two impossible to compile together.
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IProxyErrors} from "../src/interfaces/IProxyErrors.sol";

/// @notice LobsterProxy's V4 single swaps against a real PoolManager: hook rejection, slippage,
/// access control, native ETH. The user (the vault) has registered all three pools, including the
/// hooked one, so it is the proxy's own checks that are under test here, not the registry.
contract LobsterV4SwapTest is Test {
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336; // 2**96, price = 1
    uint24 constant FEE = 3000;
    int24 constant TICK_SPACING = 60;
    uint256 constant LIQUIDITY = 1000e18;

    /// @dev A real v4-core PoolManager, deployed from its committed 0.8.26 creation code (see
    /// test/Mocks/uniswapV4/PoolManagerDeployer.sol) and used through its interface
    IPoolManager public manager;
    PoolModifyLiquidityTest public lpRouter;
    LobsterProxy public proxy;
    DeltaReturningHook public hook;

    MockERC20 public token0;
    MockERC20 public token1;

    PoolKey public cleanKey; // no hook
    PoolKey public hookedKey; // DeltaReturningHook attached
    PoolKey public nativeKey; // ETH / token1, no hook

    address public user = makeAddr("user");
    /// @dev LobsterProxy only ever pays its caller, so the recipient is the user itself
    address public recipient = user;

    function setUp() public {
        manager = IPoolManager(PoolManagerDeployer.deploy(address(this)));
        lpRouter = new PoolModifyLiquidityTest(IPoolManager(address(manager)));
        proxy = new LobsterProxy(makeAddr("v3Factory"), address(manager));

        token0 = new MockERC20("Token A", "TKA", 18);
        token1 = new MockERC20("Token B", "TKB", 18);
        if (address(token0) > address(token1)) (token0, token1) = (token1, token0);

        // A v4 hook's ADDRESS encodes which callbacks it implements, so it has to be placed at an
        // address whose low bits match its permissions.
        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
                | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
        address hookAddr = address(uint160(0x4444 << 144) | flags);
        deployCodeTo("DeltaReturningHook.sol:DeltaReturningHook", abi.encode(IPoolManager(address(manager))), hookAddr);
        hook = DeltaReturningHook(hookAddr);

        cleanKey = _key(address(token0), address(token1), IHooks(address(0)));
        hookedKey = _key(address(token0), address(token1), IHooks(hookAddr));
        nativeKey = _key(address(0), address(token1), IHooks(address(0)));

        manager.initialize(cleanKey, SQRT_PRICE_1_1);
        manager.initialize(hookedKey, SQRT_PRICE_1_1);
        manager.initialize(nativeKey, SQRT_PRICE_1_1);

        token0.mint(address(this), 100_000e18);
        token1.mint(address(this), 100_000e18);
        token0.approve(address(lpRouter), type(uint256).max);
        token1.approve(address(lpRouter), type(uint256).max);
        vm.deal(address(this), 100_000e18);

        _addLiquidity(cleanKey, 0);
        _addLiquidity(hookedKey, 0);
        _addLiquidity(nativeKey, 10_000e18);

        // The hook needs its own funds to settle any negative delta it creates
        token0.mint(address(hook), 100_000e18);
        token1.mint(address(hook), 100_000e18);

        // The victim: funded, and with the unlimited approval a router realistically receives
        token0.mint(user, 10_000e18);
        token1.mint(user, 10_000e18);
        vm.deal(user, 100e18);
        vm.startPrank(user);
        token0.approve(address(proxy), type(uint256).max);
        token1.approve(address(proxy), type(uint256).max);
        bytes32[] memory keys = new bytes32[](3);
        keys[0] = proxy.v4Key(_toProxyKey(cleanKey));
        keys[1] = proxy.v4Key(_toProxyKey(hookedKey));
        keys[2] = proxy.v4Key(_toProxyKey(nativeKey));
        uint8[] memory swapOnly = new uint8[](3);
        swapOnly[0] = swapOnly[1] = swapOnly[2] = 2; // PERMISSION_SWAP
        proxy.setPools(keys, swapOnly);
        // Any price allowed, so these tests exercise the swap logic; bands have their own tests
        for (uint256 i = 0; i < keys.length; i++) {
            proxy.setPriceBand(keys[i], TickMath.MIN_TICK, TickMath.MAX_TICK);
        }
        vm.stopPrank();
    }

    // ---------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------

    function _key(address c0, address c1, IHooks hooks_) internal pure returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: hooks_
        });
    }

    function _addLiquidity(PoolKey memory key, uint256 value) internal {
        lpRouter.modifyLiquidity{value: value}(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -TICK_SPACING * 100,
                tickUpper: TICK_SPACING * 100,
                // forge-lint: disable-next-line(unsafe-typecast)
                liquidityDelta: int256(LIQUIDITY),
                salt: bytes32(0)
            }),
            ""
        );
    }

    /// @dev Bridge v4-core's PoolKey into the proxy's identically-shaped vendored type
    function _toProxyKey(PoolKey memory key) internal pure returns (ProxyPoolKey memory) {
        return ProxyPoolKey({
            currency0: ProxyCurrency.wrap(Currency.unwrap(key.currency0)),
            currency1: ProxyCurrency.wrap(Currency.unwrap(key.currency1)),
            fee: key.fee,
            tickSpacing: key.tickSpacing,
            hooks: ProxyIHooks(address(key.hooks))
        });
    }

    function _exactIn(
        PoolKey memory key,
        uint128 amountIn,
        uint128 minOut
    )
        internal
        pure
        returns (V4ExactInputSingleParams memory)
    {
        return V4ExactInputSingleParams({
            poolKey: _toProxyKey(key),
            zeroForOne: true,
            recipient: address(0), // overwritten by caller
            deadline: 0, // overwritten by caller
            amountIn: amountIn,
            amountOutMinimum: minOut,
            sqrtPriceLimitX96: 0
        });
    }

    function _exactOut(
        PoolKey memory key,
        uint128 amountOut,
        uint128 maxIn
    )
        internal
        pure
        returns (V4ExactOutputSingleParams memory)
    {
        return V4ExactOutputSingleParams({
            poolKey: _toProxyKey(key),
            zeroForOne: true,
            recipient: address(0),
            deadline: 0,
            amountOut: amountOut,
            amountInMaximum: maxIn,
            sqrtPriceLimitX96: 0
        });
    }

    // ---------------------------------------------------------------------------
    // Happy path
    // ---------------------------------------------------------------------------

    function test_exactInputSingleV4_swapsAndPaysFromCaller() public {
        V4ExactInputSingleParams memory p = _exactIn(cleanKey, 1e18, 0);
        p.recipient = recipient;
        p.deadline = block.timestamp;

        uint256 balBefore = token0.balanceOf(user);
        uint256 outBefore = token1.balanceOf(recipient);

        vm.prank(user);
        uint256 amountOut = proxy.exactInputSingleV4(p);

        assertGt(amountOut, 0, "no output");
        assertEq(token1.balanceOf(recipient) - outBefore, amountOut, "recipient did not receive output");
        assertEq(balBefore - token0.balanceOf(user), 1e18, "input pulled != amountIn");
        assertEq(token0.balanceOf(address(proxy)), 0, "proxy retained token0");
        assertEq(token1.balanceOf(address(proxy)), 0, "proxy retained token1");
    }

    // ---------------------------------------------------------------------------
    // Hooked pools are rejected
    // ---------------------------------------------------------------------------

    /// @dev `hookedKey` is a fully initialized pool with real liquidity, so these prove the proxy
    /// refuses a *working* hooked pool rather than merely failing on a nonexistent one.
    function test_exactInputSingleV4_rejectsHookedPool() public {
        V4ExactInputSingleParams memory p = _exactIn(hookedKey, 1e18, 0);
        p.recipient = recipient;
        p.deadline = block.timestamp;

        uint256 balBefore = token0.balanceOf(user);

        vm.prank(user);
        vm.expectRevert(IProxyErrors.HooksNotSupported.selector);
        proxy.exactInputSingleV4(p);

        assertEq(token0.balanceOf(user), balBefore, "caller lost funds");
    }

    /// @notice The hostile-hook attack this rejection exists to prevent: `hookDeltaUnspecified` from
    /// afterSwap is an unbounded int128 applied straight to the swap's "unspecified" currency, which
    /// for an exact-input swap is the OUTPUT, so a hook can keep what the swapper should receive.
    /// Proven here to be unreachable through the proxy.
    function test_hostileHookCannotSkimTheOutput() public {
        hook.setDeltaUnspecifiedAfterSwap(5e18); // would take 5 token1 out of the swapper's output

        V4ExactInputSingleParams memory p = _exactIn(hookedKey, 1e18, 0);
        p.recipient = recipient;
        p.deadline = block.timestamp;

        uint256 t0Before = token0.balanceOf(user);
        uint256 t1Before = token1.balanceOf(user);

        // Note amountOutMinimum is deliberately zero here: the rejection, not the slippage bound, is
        // what has to stop this.
        vm.prank(user);
        vm.expectRevert(IProxyErrors.HooksNotSupported.selector);
        proxy.exactInputSingleV4(p);

        assertEq(token0.balanceOf(user), t0Before, "victim paid");
        assertEq(token1.balanceOf(user), t1Before, "victim's balance changed");
    }

    /// @notice The proxy must reject a hooked pool even when the hook is entirely benign, so that
    /// support is a deliberate decision rather than a function of what the hook happens to do.
    function test_rejectsHookedPoolEvenWhenHookIsPassive() public {
        hook.setDeltaSpecified(0);
        hook.setDeltaUnspecifiedBeforeSwap(0);
        hook.setDeltaUnspecifiedAfterSwap(0);

        V4ExactInputSingleParams memory p = _exactIn(hookedKey, 1e18, 0);
        p.recipient = recipient;
        p.deadline = block.timestamp;

        vm.prank(user);
        vm.expectRevert(IProxyErrors.HooksNotSupported.selector);
        proxy.exactInputSingleV4(p);
    }

    // ---------------------------------------------------------------------------
    // Slippage bounds
    // ---------------------------------------------------------------------------

    function test_exactInputSingleV4_revertsWhenOutputBelowMinimum() public {
        V4ExactInputSingleParams memory p = _exactIn(cleanKey, 1e18, 2e18); // unreachable minimum
        p.recipient = recipient;
        p.deadline = block.timestamp;

        vm.prank(user);
        vm.expectRevert(IProxyErrors.TooLittleReceived.selector);
        proxy.exactInputSingleV4(p);
    }

    // ---------------------------------------------------------------------------
    // Access control
    // ---------------------------------------------------------------------------

    function test_unlockCallback_revertsForNonPoolManager() public {
        vm.prank(user);
        vm.expectRevert(IProxyErrors.NotPoolManager.selector);
        proxy.unlockCallback("");
    }

    function test_swapsRevertPastDeadline() public {
        V4ExactInputSingleParams memory p = _exactIn(cleanKey, 1e18, 0);
        p.recipient = recipient;
        p.deadline = block.timestamp - 1;

        vm.prank(user);
        vm.expectRevert(IProxyErrors.TransactionTooOld.selector);
        proxy.exactInputSingleV4(p);

        V4ExactOutputSingleParams memory q = _exactOut(cleanKey, 1e18, 2e18);
        q.recipient = recipient;
        q.deadline = block.timestamp - 1;
        vm.prank(user);
        vm.expectRevert(IProxyErrors.TransactionTooOld.selector);
        proxy.exactOutputSingleV4(q);
    }

    function test_swapsRevertOnZeroRecipient() public {
        V4ExactInputSingleParams memory p = _exactIn(cleanKey, 1e18, 0);
        p.recipient = address(0);
        p.deadline = block.timestamp;

        vm.prank(user);
        vm.expectRevert();
        proxy.exactInputSingleV4(p);
    }

    /// @dev An ERC20 output sent to the proxy could never leave it. Refused up front: the recipient must
    /// be the caller.
    function test_swapsRejectTheProxyAsRecipient() public {
        uint256 balBefore = token0.balanceOf(user);

        V4ExactInputSingleParams memory exactIn = _exactIn(cleanKey, 1e18, 0);
        exactIn.recipient = address(proxy);
        exactIn.deadline = block.timestamp;
        vm.prank(user);
        vm.expectRevert(IProxyErrors.RecipientMustBeCaller.selector);
        proxy.exactInputSingleV4(exactIn);

        V4ExactOutputSingleParams memory exactOut = _exactOut(cleanKey, 1e18, 2e18);
        exactOut.recipient = address(proxy);
        exactOut.deadline = block.timestamp;
        vm.prank(user);
        vm.expectRevert(IProxyErrors.RecipientMustBeCaller.selector);
        proxy.exactOutputSingleV4(exactOut);

        V4ExactInputSingleParams memory nativeOut = _exactIn(nativeKey, 1e18, 0);
        nativeOut.zeroForOne = false; // token1 in, ETH out
        nativeOut.recipient = address(proxy);
        nativeOut.deadline = block.timestamp;
        vm.prank(user);
        vm.expectRevert(IProxyErrors.RecipientMustBeCaller.selector);
        proxy.exactInputSingleV4(nativeOut);

        assertEq(token0.balanceOf(user), balBefore, "caller paid");
        assertEq(token1.balanceOf(address(proxy)), 0, "tokens reached the proxy");
    }

    // ---------------------------------------------------------------------------
    // Native ETH
    // ---------------------------------------------------------------------------

    /// @dev More ETH sent than `amountIn`: the swap spends exactly `amountIn` and the rest comes back
    function test_exactInputSingleV4_native_refundsUnspentEth() public {
        V4ExactInputSingleParams memory p = _exactIn(nativeKey, 1e18, 0); // ETH in
        p.recipient = recipient;
        p.deadline = block.timestamp;

        uint256 ethBefore = user.balance;
        uint256 outBefore = token1.balanceOf(recipient);

        vm.prank(user);
        uint256 amountOut = proxy.exactInputSingleV4{value: 2e18}(p);

        assertEq(token1.balanceOf(recipient) - outBefore, amountOut, "recipient did not get output");
        assertEq(ethBefore - user.balance, 1e18, "unspent ETH was not refunded");
        assertEq(address(proxy).balance, 0, "proxy retained ETH");
    }

    /// @dev Native as the swap OUTPUT, i.e. the `take` path sending ETH out of the PoolManager.
    /// The other native tests only cover native as input.
    function test_exactInputSingleV4_nativeOutput_paysRecipientInEth() public {
        V4ExactInputSingleParams memory p = _exactIn(nativeKey, 1e18, 0);
        p.zeroForOne = false; // token1 in, native out
        p.recipient = recipient;
        p.deadline = block.timestamp;

        uint256 ethBefore = recipient.balance;
        uint256 tokenBefore = token1.balanceOf(user);

        vm.prank(user);
        uint256 amountOut = proxy.exactInputSingleV4(p);

        assertGt(amountOut, 0, "no output");
        assertEq(recipient.balance - ethBefore, amountOut, "recipient did not receive ETH");
        assertEq(tokenBefore - token1.balanceOf(user), 1e18, "input pulled != amountIn");
        assertEq(address(proxy).balance, 0, "proxy retained ETH");
    }

    function test_exactInputSingleV4_native_leavesNoEthBehind() public {
        V4ExactInputSingleParams memory p = _exactIn(nativeKey, 1e18, 0);
        p.recipient = recipient;
        p.deadline = block.timestamp;

        uint256 ethBefore = user.balance;

        vm.prank(user);
        proxy.exactInputSingleV4{value: 1e18}(p);

        assertEq(ethBefore - user.balance, 1e18, "spent != amountIn");
        assertEq(address(proxy).balance, 0, "proxy retained ETH");
    }

    receive() external payable {}

    // ---------------------------------------------------------------------------
    // Exact output
    // ---------------------------------------------------------------------------

    function test_exactOutputSingleV4_deliversExactOutput() public {
        V4ExactOutputSingleParams memory p = _exactOut(cleanKey, 1e18, 2e18);
        p.recipient = recipient;
        p.deadline = block.timestamp;

        uint256 balBefore = token0.balanceOf(user);
        uint256 outBefore = token1.balanceOf(recipient);

        vm.prank(user);
        uint256 amountIn = proxy.exactOutputSingleV4(p);

        assertEq(token1.balanceOf(recipient) - outBefore, 1e18, "recipient did not get exact output");
        assertEq(balBefore - token0.balanceOf(user), amountIn, "input accounting mismatch");
        assertLe(amountIn, 2e18, "exceeded amountInMaximum");
    }

    function test_exactOutputSingleV4_rejectsHookedPool() public {
        V4ExactOutputSingleParams memory p = _exactOut(hookedKey, 1e18, 2e18);
        p.recipient = recipient;
        p.deadline = block.timestamp;

        vm.prank(user);
        vm.expectRevert(IProxyErrors.HooksNotSupported.selector);
        proxy.exactOutputSingleV4(p);
    }

    function test_exactOutputSingleV4_revertsWhenInputAboveMaximum() public {
        V4ExactOutputSingleParams memory p = _exactOut(cleanKey, 1e18, 0.5e18); // impossibly tight
        p.recipient = recipient;
        p.deadline = block.timestamp;

        vm.prank(user);
        vm.expectRevert(IProxyErrors.TooMuchRequested.selector);
        proxy.exactOutputSingleV4(p);
    }

    function test_exactOutputSingleV4_native_refundsUnspentEth() public {
        V4ExactOutputSingleParams memory p = _exactOut(nativeKey, 1e18, 2e18);
        p.recipient = recipient;
        p.deadline = block.timestamp;

        uint256 ethBefore = user.balance;
        uint256 outBefore = token1.balanceOf(recipient);

        vm.prank(user);
        uint256 amountIn = proxy.exactOutputSingleV4{value: 2e18}(p);

        assertEq(token1.balanceOf(recipient) - outBefore, 1e18, "recipient did not get output");
        assertEq(ethBefore - user.balance, amountIn, "unspent ETH was not refunded");
        assertEq(address(proxy).balance, 0, "proxy retained ETH");
    }

    // ---------------------------------------------------------------------------
    // Price bands: every V4 swap needs the pool's price inside the caller's band, before and after
    // ---------------------------------------------------------------------------

    function _tickOf(PoolKey memory key) internal view returns (int24 tick) {
        (, tick,,) = StateLibrary.getSlot0(manager, PoolId.wrap(keccak256(abi.encode(key))));
    }

    function _setBand(PoolKey memory key, int24 minTick, int24 maxTick) internal {
        bytes32 k = proxy.v4Key(_toProxyKey(key));
        vm.prank(user);
        proxy.setPriceBand(k, minTick, maxTick);
    }

    function test_v4Swap_withoutPriceBand_reverts() public {
        _setBand(cleanKey, 0, 0);
        V4ExactInputSingleParams memory p = _exactIn(cleanKey, 1e18, 0);
        p.recipient = user;
        p.deadline = block.timestamp;
        vm.prank(user);
        vm.expectRevert(IProxyErrors.PriceBandNotSet.selector);
        proxy.exactInputSingleV4(p);
    }

    function test_v4Swap_startingOutsideBand_reverts() public {
        int24 tick = _tickOf(cleanKey);
        _setBand(cleanKey, tick + 1, tick + 1000);

        V4ExactInputSingleParams memory p = _exactIn(cleanKey, 1e18, 0);
        p.recipient = user;
        p.deadline = block.timestamp;
        vm.prank(user);
        vm.expectRevert(IProxyErrors.PriceOutOfBand.selector);
        proxy.exactInputSingleV4(p);

        V4ExactOutputSingleParams memory q = _exactOut(cleanKey, 1e18, 2e18);
        q.recipient = user;
        q.deadline = block.timestamp;
        vm.prank(user);
        vm.expectRevert(IProxyErrors.PriceOutOfBand.selector);
        proxy.exactOutputSingleV4(q);
    }

    function test_v4Swap_endingOutsideBand_reverts() public {
        int24 tick = _tickOf(cleanKey);
        _setBand(cleanKey, tick - 100, tick + 100);
        uint256 before0 = token0.balanceOf(user);

        V4ExactInputSingleParams memory p = _exactIn(cleanKey, 200e18, 0); // far past tick - 100
        p.recipient = user;
        p.deadline = block.timestamp;
        vm.prank(user);
        vm.expectRevert(IProxyErrors.PriceOutOfBand.selector);
        proxy.exactInputSingleV4(p);

        assertEq(token0.balanceOf(user), before0, "a refused swap was paid");
        assertEq(_tickOf(cleanKey), tick, "a refused swap moved the price");
    }

    function test_v4Swap_insideBand_succeeds() public {
        int24 tick = _tickOf(cleanKey);
        _setBand(cleanKey, tick - 100, tick + 100);

        V4ExactInputSingleParams memory p = _exactIn(cleanKey, 1e18, 0);
        p.recipient = user;
        p.deadline = block.timestamp;
        vm.prank(user);
        uint256 out = proxy.exactInputSingleV4(p);
        assertGt(out, 0);
        assertGe(_tickOf(cleanKey), tick - 100);
    }

    /// @notice Hooked pools are refused for being hooked, whatever their band
    function test_v4Swap_hookCheckComesBeforeTheBand() public {
        _setBand(hookedKey, 0, 0);
        V4ExactInputSingleParams memory p = _exactIn(hookedKey, 1e18, 0);
        p.recipient = user;
        p.deadline = block.timestamp;
        vm.prank(user);
        vm.expectRevert(IProxyErrors.HooksNotSupported.selector);
        proxy.exactInputSingleV4(p);
    }
}
