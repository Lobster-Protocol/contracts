// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.20;

import "forge-std/Test.sol";

import {UniswapProxy} from "../src/UniswapProxy.sol";
import {Multicall} from "../src/base/Multicall.sol";
import {UniswapV3MintProxy} from "../src/UniswapV3MintProxy.sol";
import {UniswapV3SwapProxy} from "../src/UniswapV3SwapProxy.sol";
import {UniswapV4SwapProxy} from "../src/UniswapV4SwapProxy.sol";
import {ExactInputSingleParams, ExactOutputSingleParams} from "../src/interfaces/uniswapV3/IUniswapV3SwapCallback.sol";
import {MintParams} from "../src/interfaces/uniswapV3/IUniswapV3MintCallback.sol";
import {V4ExactInputSingleParams, V4ExactOutputSingleParams} from "../src/interfaces/uniswapV4/IUnlockCallback.sol";
import {IUniswapV3FactoryMinimal} from "../src/interfaces/uniswapV3/IUniswapV3FactoryMinimal.sol";
import {IUniswapV3PoolMinimal} from "../src/interfaces/uniswapV3/IUniswapV3PoolMinimal.sol";
// The proxy deliberately uses its own vendored types, so they are distinct from v4-core's even
// though they are ABI-identical. Alias them to keep the two worlds visibly separate.
import {
    PoolKey as ProxyPoolKey,
    Currency as ProxyCurrency,
    IHooks as ProxyIHooks
} from "../src/interfaces/uniswapV4/IPoolManagerMinimal.sol";
// `^0.8.0`, unlike UniswapV3Infra (`^0.8.28`), so a real V3 factory can share this 0.8.26 unit
// with the real V4 PoolManager.
import {FACTORY_BYTECODE} from "./Mocks/uniswapV3/bytecodes/factory.sol";

import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";

// NOTE: solmate's mock, not test/Mocks/MockERC20.sol. v4-core's PoolManager pins `pragma =0.8.26`
// and the repo mock requires ^0.8.28, which makes the two impossible to compile together.
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/// @notice `multicall`: batching V3 and V4 swaps into one atomic transaction.
/// @dev Runs against a real V3 factory and a real V4 PoolManager side by side, so a single batch can
/// cross both versions. The central property: a batch is exactly equivalent to making the same
/// calls one by one from the same account, except that it is all-or-nothing.
contract UniswapProxyMulticallTest is Test {
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336; // 2**96, price = 1
    uint24 constant FEE = 3000;
    int24 constant TICK_SPACING = 60;
    int24 constant TICK_RANGE = TICK_SPACING * 100;
    uint256 constant V4_LIQUIDITY = 1000e18;

    PoolManager public manager;
    PoolModifyLiquidityTest public lpRouter;
    UniswapProxy public proxy;
    address public v3Factory;
    IUniswapV3PoolMinimal public v3Pool;

    MockERC20 public token0;
    MockERC20 public token1;

    ProxyPoolKey public cleanKey; // token0 / token1, no hook
    ProxyPoolKey public nativeKey; // ETH / token1, no hook

    address public user = makeAddr("user");
    address public recipient = makeAddr("recipient");

    function setUp() public {
        manager = new PoolManager(address(this));
        lpRouter = new PoolModifyLiquidityTest(IPoolManager(address(manager)));
        v3Factory = _deployV3Factory();
        proxy = new UniswapProxy(v3Factory, address(manager));

        token0 = new MockERC20("Token A", "TKA", 18);
        token1 = new MockERC20("Token B", "TKB", 18);
        if (address(token0) > address(token1)) (token0, token1) = (token1, token0);

        token0.mint(address(this), 100_000e18);
        token1.mint(address(this), 100_000e18);
        vm.deal(address(this), 100_000e18);

        // --- V3: one 1:1 pool, liquidity added through the proxy itself (unbatched)
        v3Pool = IUniswapV3PoolMinimal(
            IUniswapV3FactoryMinimal(v3Factory).createPool(address(token0), address(token1), FEE)
        );
        v3Pool.initialize(SQRT_PRICE_1_1);

        token0.approve(address(proxy), type(uint256).max);
        token1.approve(address(proxy), type(uint256).max);
        proxy.mint(
            MintParams({
                token0: address(token0),
                token1: address(token1),
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

        // --- V4: a token/token pool and a native/token pool, both hookless
        PoolKey memory clean = _v4CoreKey(address(token0), address(token1));
        PoolKey memory native = _v4CoreKey(address(0), address(token1));
        manager.initialize(clean, SQRT_PRICE_1_1);
        manager.initialize(native, SQRT_PRICE_1_1);

        token0.approve(address(lpRouter), type(uint256).max);
        token1.approve(address(lpRouter), type(uint256).max);
        _addV4Liquidity(clean, 0);
        _addV4Liquidity(native, 10_000e18);

        cleanKey = _toProxyKey(clean);
        nativeKey = _toProxyKey(native);

        // --- The batching account: funded, with the unlimited approval a router realistically gets
        token0.mint(user, 10_000e18);
        token1.mint(user, 10_000e18);
        vm.deal(user, 100e18);
        vm.startPrank(user);
        token0.approve(address(proxy), type(uint256).max);
        token1.approve(address(proxy), type(uint256).max);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------

    function _deployV3Factory() internal returns (address factory) {
        bytes memory code = FACTORY_BYTECODE;
        assembly {
            factory := create(0, add(code, 0x20), mload(code))
        }
        require(factory != address(0), "v3 factory deployment failed");
    }

    function _v4CoreKey(address c0, address c1) internal pure returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(0))
        });
    }

    function _addV4Liquidity(PoolKey memory key, uint256 value) internal {
        lpRouter.modifyLiquidity{value: value}(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -TICK_RANGE,
                tickUpper: TICK_RANGE,
                // forge-lint: disable-next-line(unsafe-typecast)
                liquidityDelta: int256(V4_LIQUIDITY),
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

    function _v3In(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minOut
    )
        internal
        view
        returns (bytes memory)
    {
        return abi.encodeCall(
            UniswapV3SwapProxy.exactInputSingle,
            (ExactInputSingleParams({
                    tokenIn: tokenIn,
                    tokenOut: tokenOut,
                    fee: FEE,
                    recipient: recipient,
                    deadline: block.timestamp,
                    amountIn: amountIn,
                    amountOutMinimum: minOut,
                    sqrtPriceLimitX96: 0
                }))
        );
    }

    function _v3Out(
        address tokenIn,
        address tokenOut,
        uint256 amountOut,
        uint256 maxIn
    )
        internal
        view
        returns (bytes memory)
    {
        return abi.encodeCall(
            UniswapV3SwapProxy.exactOutputSingle,
            (ExactOutputSingleParams({
                    tokenIn: tokenIn,
                    tokenOut: tokenOut,
                    fee: FEE,
                    recipient: recipient,
                    deadline: block.timestamp,
                    amountOut: amountOut,
                    amountInMaximum: maxIn,
                    sqrtPriceLimitX96: 0
                }))
        );
    }

    function _v4In(
        ProxyPoolKey memory key,
        bool zeroForOne,
        uint128 amountIn,
        uint128 minOut
    )
        internal
        view
        returns (bytes memory)
    {
        return abi.encodeCall(
            UniswapV4SwapProxy.exactInputSingleV4,
            (V4ExactInputSingleParams({
                    poolKey: key,
                    zeroForOne: zeroForOne,
                    recipient: recipient,
                    deadline: block.timestamp,
                    amountIn: amountIn,
                    amountOutMinimum: minOut,
                    sqrtPriceLimitX96: 0
                }))
        );
    }

    function _v4Out(
        ProxyPoolKey memory key,
        bool zeroForOne,
        uint128 amountOut,
        uint128 maxIn
    )
        internal
        view
        returns (bytes memory)
    {
        return abi.encodeCall(
            UniswapV4SwapProxy.exactOutputSingleV4,
            (V4ExactOutputSingleParams({
                    poolKey: key,
                    zeroForOne: zeroForOne,
                    recipient: recipient,
                    deadline: block.timestamp,
                    amountOut: amountOut,
                    amountInMaximum: maxIn,
                    sqrtPriceLimitX96: 0
                }))
        );
    }

    function _batch(bytes memory a) internal pure returns (bytes[] memory calls) {
        calls = new bytes[](1);
        calls[0] = a;
    }

    function _batch(bytes memory a, bytes memory b) internal pure returns (bytes[] memory calls) {
        calls = new bytes[](2);
        calls[0] = a;
        calls[1] = b;
    }

    /// @dev Everything a batch could move: both tokens and ETH, for the caller and the recipient.
    function _holdings() internal view returns (uint256[6] memory h) {
        h[0] = token0.balanceOf(user);
        h[1] = token1.balanceOf(user);
        h[2] = user.balance;
        h[3] = token0.balanceOf(recipient);
        h[4] = token1.balanceOf(recipient);
        h[5] = recipient.balance;
    }

    function _assertHoldingsEq(uint256[6] memory a, uint256[6] memory b, string memory ctx) internal pure {
        for (uint256 i = 0; i < 6; i++) {
            assertEq(a[i], b[i], string.concat(ctx, ": holding ", vm.toString(i), " differs"));
        }
    }

    function _assertProxyHoldsNothing() internal view {
        assertEq(token0.balanceOf(address(proxy)), 0, "proxy retained token0");
        assertEq(token1.balanceOf(address(proxy)), 0, "proxy retained token1");
        assertEq(address(proxy).balance, 0, "proxy retained ETH");
    }

    function _v3Price() internal view returns (uint160 sqrtPriceX96) {
        (sqrtPriceX96,,,,,,) = v3Pool.slot0();
    }

    /// @dev The central property, as a reusable check. Runs `calls` one transaction at a time from
    /// `user`, rewinds, runs them again as one batch, and requires the two to agree:
    /// - every call succeeds alone => the batch succeeds, with the same return values and balances;
    /// - some call fails alone     => the batch fails with that call's revert data and changes nothing.
    function _assertBatchMatchesOneByOne(bytes[] memory calls)
        internal
        returns (bool succeeded, bytes[] memory results)
    {
        // Reference run
        uint256 snap = vm.snapshotState();
        bytes[] memory expected = new bytes[](calls.length);
        bytes memory firstError;
        succeeded = true;
        for (uint256 i = 0; i < calls.length; i++) {
            vm.prank(user);
            (bool ok, bytes memory ret) = address(proxy).call(calls[i]);
            if (!ok) {
                succeeded = false;
                firstError = ret;
                break;
            }
            expected[i] = ret;
        }
        uint256[6] memory expectedAfter = _holdings();
        uint256 expectedProxyEth = address(proxy).balance;
        vm.revertToState(snap);

        // Batched run
        uint256[6] memory before = _holdings();
        vm.prank(user);
        (bool batchOk, bytes memory batchRet) = address(proxy).call(abi.encodeCall(Multicall.multicall, (calls)));

        if (!succeeded) {
            assertFalse(batchOk, "batch succeeded although one of its calls fails alone");
            assertEq(batchRet, firstError, "batch failed with a different reason than the failing call");
            _assertHoldingsEq(_holdings(), before, "failed batch");
            return (false, results);
        }

        assertTrue(batchOk, "batch failed although every call succeeds alone");
        results = abi.decode(batchRet, (bytes[]));
        assertEq(results.length, calls.length, "one result per call");
        for (uint256 i = 0; i < calls.length; i++) {
            assertEq(results[i], expected[i], "batched result differs from the direct call");
        }
        _assertHoldingsEq(_holdings(), expectedAfter, "batch vs one-by-one");
        assertEq(address(proxy).balance, expectedProxyEth, "proxy ETH differs from one-by-one");
    }

    /// @dev One of the four swap entry points, on a random pool, direction and size. Sizes stay well
    /// inside every pool's liquidity even when six swaps in a row push the same way, so failures
    /// would come from the batching, not from running a pool dry. On the native V4 pool ETH is only
    /// ever the output, because a batch cannot pay ETH in.
    function _randomSwap(uint256 r) internal view returns (bytes memory) {
        uint256 kind = r % 4;
        bool zeroForOne = (r >> 8) & 1 == 1;
        uint128 amount = uint128(bound(r >> 16, 1e6, 10e18));

        if (kind < 2) {
            (address tokenIn, address tokenOut) =
                zeroForOne ? (address(token0), address(token1)) : (address(token1), address(token0));
            return
                kind == 0 ? _v3In(tokenIn, tokenOut, amount, 0) : _v3Out(tokenIn, tokenOut, amount, type(uint256).max);
        }

        bool native = (r >> 128) & 1 == 1;
        ProxyPoolKey memory key = native ? nativeKey : cleanKey;
        if (native) zeroForOne = false;
        return kind == 2 ? _v4In(key, zeroForOne, amount, 0) : _v4Out(key, zeroForOne, amount, type(uint128).max);
    }

    // ---------------------------------------------------------------------------
    // Happy path
    // ---------------------------------------------------------------------------

    /// @notice The defining property: a batch of V3 and V4 swaps, both exact-in and exact-out, has
    /// exactly the effect of the same four calls made one by one — same return values, same balances.
    function test_mixedV3AndV4Batch_matchesSameCallsMadeOneByOne() public {
        bytes[] memory calls = new bytes[](4);
        calls[0] = _v3In(address(token0), address(token1), 1e18, 0);
        calls[1] = _v4In(cleanKey, false, 1e18, 0); // token1 -> token0
        calls[2] = _v3Out(address(token1), address(token0), 0.5e18, type(uint256).max);
        calls[3] = _v4Out(cleanKey, true, 0.5e18, type(uint128).max); // token0 -> token1

        uint256[6] memory before = _holdings();

        (bool succeeded, bytes[] memory results) = _assertBatchMatchesOneByOne(calls);
        assertTrue(succeeded, "fixture: every swap should succeed");

        // And the results decode to what each entry point returns
        uint256 v3Out = abi.decode(results[0], (uint256));
        uint256 v4Out = abi.decode(results[1], (uint256));
        uint256 v3In = abi.decode(results[2], (uint256));
        uint256 v4In = abi.decode(results[3], (uint256));

        assertEq(token1.balanceOf(recipient) - before[4], v3Out + 0.5e18, "token1 delivered");
        assertEq(token0.balanceOf(recipient) - before[3], v4Out + 0.5e18, "token0 delivered");
        assertEq(before[0] - token0.balanceOf(user), 1e18 + v4In, "token0 paid by caller");
        assertEq(before[1] - token1.balanceOf(user), 1e18 + v3In, "token1 paid by caller");
        _assertProxyHoldsNothing();
    }

    /// @notice The same property over random batches: any length up to six, any mix of the four
    /// entry points, pools, directions and sizes, including the native pool paying out ETH.
    function testFuzz_randomSwapBatch_matchesSameCallsMadeOneByOne(uint256 seed, uint256 length) public {
        uint256 n = bound(length, 1, 6);
        bytes[] memory calls = new bytes[](n);
        for (uint256 i = 0; i < n; i++) {
            calls[i] = _randomSwap(uint256(keccak256(abi.encode(seed, i))));
        }

        _assertBatchMatchesOneByOne(calls);
    }

    function test_emptyBatch_isANoOp() public {
        uint256[6] memory before = _holdings();

        vm.prank(user);
        bytes[] memory results = proxy.multicall(new bytes[](0));

        assertEq(results.length, 0, "results for an empty batch");
        _assertHoldingsEq(_holdings(), before, "empty batch");
    }

    // ---------------------------------------------------------------------------
    // Atomicity and error reporting
    // ---------------------------------------------------------------------------

    /// @notice A failing swap undoes the swaps before it, including their effect on pool prices, and
    /// the caller sees the failing swap's own revert reason.
    function test_failingSwap_revertsWholeBatchWithItsReason() public {
        bytes[] memory calls = _batch(
            _v3In(address(token0), address(token1), 1e18, 0),
            _v4In(cleanKey, true, 1e18, 2e18) // unreachable minimum
        );

        uint256[6] memory before = _holdings();
        uint160 priceBefore = _v3Price();

        vm.prank(user);
        vm.expectRevert(bytes("Too little received"));
        proxy.multicall(calls);

        _assertHoldingsEq(_holdings(), before, "reverted batch");
        assertEq(_v3Price(), priceBefore, "first swap's price impact survived the revert");
    }

    /// @notice Batching does not bypass any per-swap check. Each still runs, with its own message.
    function test_perSwapChecksStillApplyInsideBatch() public {
        bytes memory validSwap = _v3In(address(token0), address(token1), 1e18, 0);
        uint256[6] memory before = _holdings();

        // Hooked V4 pools are still refused
        ProxyPoolKey memory hooked = cleanKey;
        hooked.hooks = ProxyIHooks(makeAddr("someHook"));
        vm.prank(user);
        vm.expectRevert(bytes("Hooks not supported"));
        proxy.multicall(_batch(validSwap, _v4In(hooked, true, 1e18, 0)));

        // Each swap's own deadline is still enforced
        bytes memory expired = abi.encodeCall(
            UniswapV3SwapProxy.exactInputSingle,
            (ExactInputSingleParams({
                    tokenIn: address(token1),
                    tokenOut: address(token0),
                    fee: FEE,
                    recipient: recipient,
                    deadline: block.timestamp - 1,
                    amountIn: 1e18,
                    amountOutMinimum: 0,
                    sqrtPriceLimitX96: 0
                }))
        );
        vm.prank(user);
        vm.expectRevert(bytes("Transaction too old"));
        proxy.multicall(_batch(validSwap, expired));

        // So is the exact-output bound
        vm.prank(user);
        vm.expectRevert(bytes("Too much requested"));
        proxy.multicall(_batch(validSwap, _v3Out(address(token1), address(token0), 1e18, 1)));

        _assertHoldingsEq(_holdings(), before, "rejected batches");
    }

    // ---------------------------------------------------------------------------
    // Only swaps can be batched
    // ---------------------------------------------------------------------------

    /// @notice Every non-swap selector is refused, and refusing it also undoes the valid swap placed
    /// before it in the same batch.
    function test_nonSwapCallsAreRejected() public {
        bytes[] memory refused = new bytes[](9);
        refused[0] = abi.encodeCall(
            UniswapV3MintProxy.mint,
            (MintParams({
                    token0: address(token0),
                    token1: address(token1),
                    fee: FEE,
                    tickLower: -TICK_RANGE,
                    tickUpper: TICK_RANGE,
                    amount0Desired: 1e18,
                    amount1Desired: 1e18,
                    amount0Min: 0,
                    amount1Min: 0,
                    recipient: user,
                    deadline: block.timestamp
                }))
        );
        refused[1] = abi.encodeCall(UniswapV3SwapProxy.uniswapV3SwapCallback, (int256(1), int256(0), ""));
        refused[2] = abi.encodeCall(UniswapV3MintProxy.uniswapV3MintCallback, (1, 0, ""));
        refused[3] = abi.encodeCall(UniswapV4SwapProxy.unlockCallback, (""));
        refused[4] = abi.encodeCall(Multicall.multicall, (new bytes[](0)));
        refused[5] = abi.encodeWithSelector(proxy.UNI_V3_FACTORY.selector);
        refused[6] = abi.encodeWithSelector(bytes4(0xdeadbeef));
        refused[7] = hex"414bf3"; // a truncated `exactInputSingle` selector
        refused[8] = "";

        bytes memory validSwap = _v3In(address(token0), address(token1), 1e18, 0);
        uint256[6] memory before = _holdings();
        uint160 priceBefore = _v3Price();

        for (uint256 i = 0; i < refused.length; i++) {
            vm.prank(user);
            vm.expectRevert(bytes("Not batchable"));
            proxy.multicall(_batch(validSwap, refused[i]));
        }

        _assertHoldingsEq(_holdings(), before, "rejected batches");
        assertEq(_v3Price(), priceBefore, "a rejected batch moved the pool");
    }

    /// @notice The allowlist is exact: any selector other than the four swaps is refused, whatever
    /// arguments follow it, and refusing it undoes the valid swap placed before it.
    function testFuzz_anyNonSwapSelectorIsRejected(bytes4 selector, bytes calldata args) public {
        vm.assume(
            selector != UniswapV3SwapProxy.exactInputSingle.selector
                && selector != UniswapV3SwapProxy.exactOutputSingle.selector
                && selector != UniswapV4SwapProxy.exactInputSingleV4.selector
                && selector != UniswapV4SwapProxy.exactOutputSingleV4.selector
        );
        uint256[6] memory before = _holdings();

        vm.prank(user);
        vm.expectRevert(bytes("Not batchable"));
        proxy.multicall(_batch(_v3In(address(token0), address(token1), 1e18, 0), bytes.concat(selector, args)));

        _assertHoldingsEq(_holdings(), before, "rejected batch");
    }

    function test_allFourSwapEntryPointsAreBatchable() public {
        bytes[] memory calls = new bytes[](4);
        calls[0] = _v3In(address(token0), address(token1), 1e18, 0);
        calls[1] = _v3Out(address(token0), address(token1), 1e18, type(uint256).max);
        calls[2] = _v4In(cleanKey, true, 1e18, 0);
        calls[3] = _v4Out(cleanKey, true, 1e18, type(uint128).max);

        vm.prank(user);
        bytes[] memory results = proxy.multicall(calls);

        for (uint256 i = 0; i < results.length; i++) {
            assertGt(abi.decode(results[i], (uint256)), 0, "swap did not execute");
        }
    }

    // ---------------------------------------------------------------------------
    // Native ETH
    // ---------------------------------------------------------------------------

    /// @notice `multicall` is not payable, so no batch can carry ETH that its elements would each see.
    function test_multicallRejectsEth() public {
        bytes memory payload = abi.encodeCall(Multicall.multicall, (_batch(_v4In(nativeKey, true, 1e18, 0))));
        uint256 ethBefore = user.balance;

        vm.prank(user);
        (bool ok,) = address(proxy).call{value: 1e18}(payload);

        assertFalse(ok, "multicall accepted ETH");
        assertEq(user.balance, ethBefore, "caller lost ETH");
        _assertProxyHoldsNothing();
    }

    /// @notice Paying native ETH inside a batch fails: `msg.value` is 0, so the proxy has nothing to
    /// settle with. Holds while the proxy carries no balance, which is its normal state (see the
    /// stranded-ETH tests in test/fork/integration/V4Swap.t.sol for what happens when it does).
    function test_nativeInputV4SwapCannotBePaidInBatch() public {
        uint256[6] memory before = _holdings();

        vm.prank(user);
        vm.expectRevert();
        proxy.multicall(_batch(_v3In(address(token0), address(token1), 1e18, 0), _v4In(nativeKey, true, 1e18, 0)));

        _assertHoldingsEq(_holdings(), before, "failed native batch");
    }

    /// @notice Receiving native ETH works, because the PoolManager pays the recipient directly and the
    /// proxy never touches the ETH.
    function test_nativeOutputV4SwapWorksInBatch() public {
        uint256 ethBefore = recipient.balance;

        vm.prank(user);
        bytes[] memory results = proxy.multicall(
            _batch(
                _v3In(address(token0), address(token1), 1e18, 0),
                _v4In(nativeKey, false, 1e18, 0) // token1 in, ETH out
            )
        );

        uint256 ethOut = abi.decode(results[1], (uint256));
        assertGt(ethOut, 0, "no ETH output");
        assertEq(recipient.balance - ethBefore, ethOut, "recipient did not receive ETH");
        _assertProxyHoldsNothing();
    }

    /// @notice ETH stranded in the proxy (via selfdestruct or coinbase; there is no `receive`) is a
    /// known pre-existing quirk: the next V4 caller can spend it or is refunded it. This pins down
    /// that batching does not make it worse — the batch behaves exactly like the same direct calls.
    function test_strandedEth_batchBehavesLikeTheSameDirectCalls() public {
        vm.deal(address(proxy), 5e18);
        uint256 userEthBefore = user.balance;

        bytes[] memory calls = new bytes[](3);
        calls[0] = _v3In(address(token0), address(token1), 1e18, 0);
        calls[1] = _v4In(nativeKey, true, 1e18, 0); // native in, paid from the stranded balance
        calls[2] = _v4In(cleanKey, true, 1e18, 0);

        (bool succeeded,) = _assertBatchMatchesOneByOne(calls);
        assertTrue(succeeded, "fixture: every swap should succeed");

        // Exactly as for direct calls: the native swap spends 1e18 of the stranded ETH and the
        // first refund sweep hands the caller the remainder. Nothing is left behind.
        assertEq(user.balance - userEthBefore, 4e18, "caller did not receive the unspent stranded ETH");
        assertEq(address(proxy).balance, 0, "proxy still holds ETH");
    }

    // ---------------------------------------------------------------------------
    // Payer authority
    // ---------------------------------------------------------------------------

    /// @notice A batch pays from whoever submits it, never from another account's standing approval.
    function test_batchAlwaysPaysFromItsCaller() public {
        address outsider = makeAddr("outsider");
        token0.mint(outsider, 10e18);
        uint256[6] memory userBefore = _holdings();

        // Without an approval of their own, the outsider's batch cannot reach the user's allowance
        vm.prank(outsider);
        vm.expectRevert();
        proxy.multicall(_batch(_v3In(address(token0), address(token1), 1e18, 0), _v4In(cleanKey, true, 1e18, 0)));

        // With one, the outsider's batch debits the outsider
        vm.startPrank(outsider);
        token0.approve(address(proxy), type(uint256).max);
        proxy.multicall(_batch(_v3In(address(token0), address(token1), 1e18, 0), _v4In(cleanKey, true, 1e18, 0)));
        vm.stopPrank();

        assertEq(token0.balanceOf(outsider), 8e18, "outsider was not the payer");
        assertEq(token0.balanceOf(user), userBefore[0], "user's token0 moved");
        assertEq(token1.balanceOf(user), userBefore[1], "user's token1 moved");
    }

    receive() external payable {}
}
