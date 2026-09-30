// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.20;

import "forge-std/Test.sol";

import {UniswapProxy} from "../src/UniswapProxy.sol";
import {UniswapBatchSwapProxy, SwapType} from "../src/UniswapBatchSwapProxy.sol";
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
import {BatchSwapCalls} from "./helpers/BatchSwapCalls.sol";
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

/// @notice `batchSwap`: V3 and V4 swaps in one atomic transaction.
/// @dev Runs against a real V3 factory and a real V4 PoolManager side by side, so a single batch can
/// cross both versions. The central property: a batch is exactly equivalent to making the same swaps
/// one by one from the same account, except that it is all-or-nothing.
contract UniswapProxyBatchSwapTest is Test {
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

        // --- V3: one 1:1 pool, liquidity added through the proxy itself
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
    // Helpers: fixture
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

    // ---------------------------------------------------------------------------
    // Helpers: batch items, i.e. `abi.encodePacked(uint8 swapType, abi.encode(params))`
    // ---------------------------------------------------------------------------

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
        return abi.encodePacked(
            SwapType.V3_EXACT_INPUT,
            abi.encode(
                ExactInputSingleParams({
                    tokenIn: tokenIn,
                    tokenOut: tokenOut,
                    fee: FEE,
                    recipient: recipient,
                    deadline: block.timestamp,
                    amountIn: amountIn,
                    amountOutMinimum: minOut,
                    sqrtPriceLimitX96: 0
                })
            )
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
        return abi.encodePacked(
            SwapType.V3_EXACT_OUTPUT,
            abi.encode(
                ExactOutputSingleParams({
                    tokenIn: tokenIn,
                    tokenOut: tokenOut,
                    fee: FEE,
                    recipient: recipient,
                    deadline: block.timestamp,
                    amountOut: amountOut,
                    amountInMaximum: maxIn,
                    sqrtPriceLimitX96: 0
                })
            )
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
        return abi.encodePacked(
            SwapType.V4_EXACT_INPUT,
            abi.encode(
                V4ExactInputSingleParams({
                    poolKey: key,
                    zeroForOne: zeroForOne,
                    recipient: recipient,
                    deadline: block.timestamp,
                    amountIn: amountIn,
                    amountOutMinimum: minOut,
                    sqrtPriceLimitX96: 0
                })
            )
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
        return abi.encodePacked(
            SwapType.V4_EXACT_OUTPUT,
            abi.encode(
                V4ExactOutputSingleParams({
                    poolKey: key,
                    zeroForOne: zeroForOne,
                    recipient: recipient,
                    deadline: block.timestamp,
                    amountOut: amountOut,
                    amountInMaximum: maxIn,
                    sqrtPriceLimitX96: 0
                })
            )
        );
    }

    function _batch(bytes memory a) internal pure returns (bytes[] memory swaps) {
        swaps = new bytes[](1);
        swaps[0] = a;
    }

    function _batch(bytes memory a, bytes memory b) internal pure returns (bytes[] memory swaps) {
        swaps = new bytes[](2);
        swaps[0] = a;
        swaps[1] = b;
    }

    /// @dev One of the four swap types, on a random pool, direction and size. Sizes stay well inside
    /// every pool's liquidity even when six swaps in a row push the same way, so failures would come
    /// from the batching, not from running a pool dry. On the native V4 pool ETH is only ever the
    /// output, because a batch cannot pay ETH in.
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
    // Helpers: assertions
    // ---------------------------------------------------------------------------

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

    /// @dev The central property, as a reusable check. Runs each swap as a direct call to its
    /// single-swap entry point from `user`, rewinds, runs them again as one batch, and requires the
    /// two to agree:
    /// - every swap succeeds alone => the batch succeeds, with the same amounts and balances;
    /// - some swap fails alone     => the batch fails with that swap's revert data and changes nothing.
    function _assertBatchMatchesOneByOne(bytes[] memory swaps)
        internal
        returns (bool succeeded, uint256[] memory amounts)
    {
        // Reference run
        uint256 snap = vm.snapshotState();
        uint256[] memory expected = new uint256[](swaps.length);
        bytes memory firstError;
        succeeded = true;
        for (uint256 i = 0; i < swaps.length; i++) {
            vm.prank(user);
            (bool ok, bytes memory ret) = address(proxy).call(BatchSwapCalls.toDirectCall(swaps[i]));
            if (!ok) {
                succeeded = false;
                firstError = ret;
                break;
            }
            expected[i] = abi.decode(ret, (uint256));
        }
        uint256[6] memory expectedAfter = _holdings();
        uint256 expectedProxyEth = address(proxy).balance;
        vm.revertToState(snap);

        // Batched run
        uint256[6] memory before = _holdings();
        vm.prank(user);
        (bool batchOk, bytes memory batchRet) =
            address(proxy).call(abi.encodeCall(UniswapBatchSwapProxy.batchSwap, (swaps)));

        if (!succeeded) {
            assertFalse(batchOk, "batch succeeded although one of its swaps fails alone");
            assertEq(batchRet, firstError, "batch failed with a different reason than the failing swap");
            _assertHoldingsEq(_holdings(), before, "failed batch");
            return (false, amounts);
        }

        assertTrue(batchOk, "batch failed although every swap succeeds alone");
        amounts = abi.decode(batchRet, (uint256[]));
        assertEq(amounts.length, swaps.length, "one amount per swap");
        for (uint256 i = 0; i < swaps.length; i++) {
            assertEq(amounts[i], expected[i], "batched amount differs from the direct call");
        }
        _assertHoldingsEq(_holdings(), expectedAfter, "batch vs one-by-one");
        assertEq(address(proxy).balance, expectedProxyEth, "proxy ETH differs from one-by-one");
    }

    // ---------------------------------------------------------------------------
    // Batch == the same swaps one by one
    // ---------------------------------------------------------------------------

    /// @notice The defining property: a batch of V3 and V4 swaps, both exact-in and exact-out, has
    /// exactly the effect of the same four swaps made one by one — same amounts, same balances.
    function test_mixedV3AndV4Batch_matchesSameSwapsMadeOneByOne() public {
        bytes[] memory swaps = new bytes[](4);
        swaps[0] = _v3In(address(token0), address(token1), 1e18, 0);
        swaps[1] = _v4In(cleanKey, false, 1e18, 0); // token1 -> token0
        swaps[2] = _v3Out(address(token1), address(token0), 0.5e18, type(uint256).max);
        swaps[3] = _v4Out(cleanKey, true, 0.5e18, type(uint128).max); // token0 -> token1

        uint256[6] memory before = _holdings();

        (bool succeeded, uint256[] memory amounts) = _assertBatchMatchesOneByOne(swaps);
        assertTrue(succeeded, "fixture: every swap should succeed");

        // amounts[i] is what swap i's single-swap entry point returns
        assertEq(token1.balanceOf(recipient) - before[4], amounts[0] + 0.5e18, "token1 delivered");
        assertEq(token0.balanceOf(recipient) - before[3], amounts[1] + 0.5e18, "token0 delivered");
        assertEq(before[0] - token0.balanceOf(user), 1e18 + amounts[3], "token0 paid by caller");
        assertEq(before[1] - token1.balanceOf(user), 1e18 + amounts[2], "token1 paid by caller");
        _assertProxyHoldsNothing();
    }

    /// @notice The same property over random batches: any length up to six, any mix of the four swap
    /// types, pools, directions and sizes, including the native pool paying out ETH.
    function testFuzz_randomBatch_matchesSameSwapsMadeOneByOne(uint256 seed, uint256 length) public {
        uint256 n = bound(length, 1, 6);
        bytes[] memory swaps = new bytes[](n);
        for (uint256 i = 0; i < n; i++) {
            swaps[i] = _randomSwap(uint256(keccak256(abi.encode(seed, i))));
        }

        _assertBatchMatchesOneByOne(swaps);
    }

    function test_allFourSwapTypesAreBatchable() public {
        bytes[] memory swaps = new bytes[](4);
        swaps[0] = _v3In(address(token0), address(token1), 1e18, 0);
        swaps[1] = _v3Out(address(token0), address(token1), 1e18, type(uint256).max);
        swaps[2] = _v4In(cleanKey, true, 1e18, 0);
        swaps[3] = _v4Out(cleanKey, true, 1e18, type(uint128).max);

        vm.prank(user);
        uint256[] memory amounts = proxy.batchSwap(swaps);

        for (uint256 i = 0; i < amounts.length; i++) {
            assertGt(amounts[i], 0, "swap did not execute");
        }
        _assertProxyHoldsNothing();
    }

    function test_emptyBatch_isANoOp() public {
        uint256[6] memory before = _holdings();

        vm.prank(user);
        uint256[] memory amounts = proxy.batchSwap(new bytes[](0));

        assertEq(amounts.length, 0, "amounts for an empty batch");
        _assertHoldingsEq(_holdings(), before, "empty batch");
    }

    // ---------------------------------------------------------------------------
    // Atomicity and error reporting
    // ---------------------------------------------------------------------------

    /// @notice A failing swap undoes the swaps before it, including their effect on pool prices, and
    /// the caller sees the failing swap's own revert reason.
    function test_failingSwap_revertsWholeBatchWithItsReason() public {
        bytes[] memory swaps = _batch(
            _v3In(address(token0), address(token1), 1e18, 0),
            _v4In(cleanKey, true, 1e18, 2e18) // unreachable minimum
        );

        uint256[6] memory before = _holdings();
        uint160 priceBefore = _v3Price();

        vm.prank(user);
        vm.expectRevert(bytes("Too little received"));
        proxy.batchSwap(swaps);

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
        proxy.batchSwap(_batch(validSwap, _v4In(hooked, true, 1e18, 0)));

        // Each swap's own deadline is still enforced
        bytes memory expired = abi.encodePacked(
            SwapType.V3_EXACT_INPUT,
            abi.encode(
                ExactInputSingleParams({
                    tokenIn: address(token1),
                    tokenOut: address(token0),
                    fee: FEE,
                    recipient: recipient,
                    deadline: block.timestamp - 1,
                    amountIn: 1e18,
                    amountOutMinimum: 0,
                    sqrtPriceLimitX96: 0
                })
            )
        );
        vm.prank(user);
        vm.expectRevert(bytes("Transaction too old"));
        proxy.batchSwap(_batch(validSwap, expired));

        // So is the exact-output bound
        vm.prank(user);
        vm.expectRevert(bytes("Too much requested"));
        proxy.batchSwap(_batch(validSwap, _v3Out(address(token1), address(token0), 1e18, 1)));

        _assertHoldingsEq(_holdings(), before, "rejected batches");
    }

    // ---------------------------------------------------------------------------
    // Malformed batches
    // ---------------------------------------------------------------------------

    /// @notice An item whose first byte is not a known swap type is refused, and refusing it undoes
    /// the valid swap placed before it. Includes 0x00, so a zeroed item is never read as a swap.
    function test_invalidSwapTypeIsRejected() public {
        bytes memory validSwap = _v3In(address(token0), address(token1), 1e18, 0);
        bytes memory validParams = new bytes(validSwap.length - 1);
        for (uint256 i = 0; i < validParams.length; i++) {
            validParams[i] = validSwap[i + 1];
        }

        bytes[] memory invalid = new bytes[](4);
        invalid[0] = ""; // no type byte at all
        invalid[1] = abi.encodePacked(uint8(0x00), validParams);
        invalid[2] = abi.encodePacked(uint8(0x05), validParams);
        invalid[3] = abi.encodePacked(uint8(0xff), validParams);

        uint256[6] memory before = _holdings();
        uint160 priceBefore = _v3Price();

        for (uint256 i = 0; i < invalid.length; i++) {
            vm.prank(user);
            vm.expectRevert(bytes("Invalid swap type"));
            proxy.batchSwap(_batch(validSwap, invalid[i]));
        }

        _assertHoldingsEq(_holdings(), before, "rejected batches");
        assertEq(_v3Price(), priceBefore, "a rejected batch moved the pool");
    }

    /// @notice Every byte value outside the four swap types is refused, whatever follows it.
    function testFuzz_anyUnknownSwapTypeIsRejected(uint8 swapType, bytes calldata params) public {
        vm.assume(swapType == 0 || swapType > SwapType.V4_EXACT_OUTPUT);
        uint256[6] memory before = _holdings();

        vm.prank(user);
        vm.expectRevert(bytes("Invalid swap type"));
        proxy.batchSwap(_batch(_v3In(address(token0), address(token1), 1e18, 0), abi.encodePacked(swapType, params)));

        _assertHoldingsEq(_holdings(), before, "rejected batch");
    }

    /// @notice A known swap type followed by params too short for it fails to decode, and the batch
    /// reverts. Here V3 params (8 words) under the V4 type (11 words).
    function test_truncatedParamsRevert() public {
        bytes memory v3Swap = _v3In(address(token0), address(token1), 1e18, 0);
        bytes memory v3Params = new bytes(v3Swap.length - 1);
        for (uint256 i = 0; i < v3Params.length; i++) {
            v3Params[i] = v3Swap[i + 1];
        }
        uint256[6] memory before = _holdings();

        vm.prank(user);
        vm.expectRevert();
        proxy.batchSwap(_batch(v3Swap, abi.encodePacked(SwapType.V4_EXACT_INPUT, v3Params)));

        _assertHoldingsEq(_holdings(), before, "malformed batch");
    }

    // ---------------------------------------------------------------------------
    // Native ETH
    // ---------------------------------------------------------------------------

    /// @notice `batchSwap` is not payable, so a batch never carries ETH of its own.
    function test_batchSwapRejectsEth() public {
        bytes memory payload =
            abi.encodeCall(UniswapBatchSwapProxy.batchSwap, (_batch(_v4In(nativeKey, true, 1e18, 0))));
        uint256 ethBefore = user.balance;

        vm.prank(user);
        (bool ok,) = address(proxy).call{value: 1e18}(payload);

        assertFalse(ok, "batchSwap accepted ETH");
        assertEq(user.balance, ethBefore, "caller lost ETH");
        _assertProxyHoldsNothing();
    }

    /// @notice Paying native ETH inside a batch fails: the proxy has nothing to settle with. Holds
    /// while the proxy carries no balance, which is its normal state (see the stranded-ETH test).
    function test_nativeInputV4SwapCannotBePaidInBatch() public {
        uint256[6] memory before = _holdings();

        vm.prank(user);
        vm.expectRevert();
        proxy.batchSwap(_batch(_v3In(address(token0), address(token1), 1e18, 0), _v4In(nativeKey, true, 1e18, 0)));

        _assertHoldingsEq(_holdings(), before, "failed native batch");
    }

    /// @notice Receiving native ETH works, because the PoolManager pays the recipient directly and the
    /// proxy never touches the ETH.
    function test_nativeOutputV4SwapWorksInBatch() public {
        uint256 ethBefore = recipient.balance;

        vm.prank(user);
        uint256[] memory amounts = proxy.batchSwap(
            _batch(
                _v3In(address(token0), address(token1), 1e18, 0),
                _v4In(nativeKey, false, 1e18, 0) // token1 in, ETH out
            )
        );

        assertGt(amounts[1], 0, "no ETH output");
        assertEq(recipient.balance - ethBefore, amounts[1], "recipient did not receive ETH");
        _assertProxyHoldsNothing();
    }

    /// @notice ETH stranded in the proxy (via selfdestruct or coinbase; there is no `receive`) is a
    /// known pre-existing quirk of the single-swap V4 entry points, whose refund hands it to the
    /// caller. A batch never refunds, so it never hands stranded ETH to anyone. A native-input swap
    /// in a batch can still settle from it, exactly as a direct call with no `msg.value` can.
    function test_strandedEth_isNeverSweptByABatch() public {
        vm.deal(address(proxy), 5e18);
        uint256 userEthBefore = user.balance;

        // Swaps that do not involve ETH leave the stranded balance alone
        vm.prank(user);
        proxy.batchSwap(_batch(_v3In(address(token0), address(token1), 1e18, 0), _v4In(cleanKey, true, 1e18, 0)));
        assertEq(address(proxy).balance, 5e18, "a batch swept the stranded ETH");
        assertEq(user.balance, userEthBefore, "the caller received stranded ETH");

        // A native-input swap settles from it, and the rest stays put
        uint256 recipientToken1Before = token1.balanceOf(recipient);
        vm.prank(user);
        uint256[] memory amounts = proxy.batchSwap(_batch(_v4In(nativeKey, true, 1e18, 0)));
        assertEq(address(proxy).balance, 4e18, "native swap did not settle from the stranded balance");
        assertEq(token1.balanceOf(recipient) - recipientToken1Before, amounts[0], "native swap output");
        assertEq(user.balance, userEthBefore, "the caller received stranded ETH");
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
        proxy.batchSwap(_batch(_v3In(address(token0), address(token1), 1e18, 0), _v4In(cleanKey, true, 1e18, 0)));

        // With one, the outsider's batch debits the outsider
        vm.startPrank(outsider);
        token0.approve(address(proxy), type(uint256).max);
        proxy.batchSwap(_batch(_v3In(address(token0), address(token1), 1e18, 0), _v4In(cleanKey, true, 1e18, 0)));
        vm.stopPrank();

        assertEq(token0.balanceOf(outsider), 8e18, "outsider was not the payer");
        assertEq(token0.balanceOf(user), userBefore[0], "user's token0 moved");
        assertEq(token1.balanceOf(user), userBefore[1], "user's token1 moved");
    }

    receive() external payable {}
}
