// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.20;

import "forge-std/Test.sol";

import {LobsterProxy} from "../../src/LobsterProxy.sol";
import {UniswapBatchSwapProxy, SwapType} from "../../src/UniswapBatchSwapProxy.sol";
import {
    ExactInputSingleParams,
    ExactOutputSingleParams
} from "../../src/interfaces/uniswapV3/IUniswapV3SwapCallback.sol";
import {MintParams} from "../../src/interfaces/uniswapV3/IUniswapV3MintCallback.sol";
import {V4ExactInputSingleParams, V4ExactOutputSingleParams} from "../../src/interfaces/uniswapV4/IUnlockCallback.sol";
import {IUniswapV3FactoryMinimal} from "../../src/interfaces/uniswapV3/IUniswapV3FactoryMinimal.sol";
import {IUniswapV3PoolMinimal} from "../../src/interfaces/uniswapV3/IUniswapV3PoolMinimal.sol";
// The proxy deliberately uses its own vendored types, so they are distinct from v4-core's even
// though they are ABI-identical. Alias them to keep the two worlds visibly separate.
import {
    PoolKey as ProxyPoolKey,
    Currency as ProxyCurrency,
    IHooks as ProxyIHooks
} from "../../src/interfaces/uniswapV4/IPoolManagerMinimal.sol";
import {BatchSwapCalls} from "./BatchSwapCalls.sol";
import {Chaining} from "../../src/libraries/Chaining.sol";
import {TickMath} from "../../src/libraries/uniswapV3/TickMath.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
// `^0.8.0`, unlike UniswapV3Infra (`^0.8.28`), so a real V3 factory can share this 0.8.26 unit
// with the real V4 PoolManager.
import {FACTORY_BYTECODE} from "../Mocks/uniswapV3/bytecodes/factory.sol";

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolManagerDeployer} from "../Mocks/uniswapV4/PoolManagerDeployer.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";

// NOTE: solmate's mock, not test/Mocks/MockERC20.sol. v4-core's PoolManager pins `pragma =0.8.26`
// and the repo mock requires ^0.8.28, which makes the two impossible to compile together.
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/// @notice Shared fixture for the LobsterProxy swap suites: a real V3 factory and a real V4
/// PoolManager side by side, two tokens with a V3 pool and a V4 pool between them, a native-ETH V4
/// pool, a funded user (the vault) with standing approvals and every pool registered, and helpers to
/// build batch items and compare a batch with the same swaps made one by one.
/// @dev Abstract so suites inherit the setup without inheriting each other's tests.
abstract contract BatchSwapFixture is Test {
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336; // 2**96, price = 1
    uint24 constant FEE = 3000;
    int24 constant TICK_SPACING = 60;
    int24 constant TICK_RANGE = TICK_SPACING * 100;
    uint256 constant V4_LIQUIDITY = 1000e18;
    uint8 constant MINT = 1; // PoolRegistry.PERMISSION_MINT
    uint8 constant SWAP = 2; // PoolRegistry.PERMISSION_SWAP

    /// @dev A real v4-core PoolManager, deployed from its committed 0.8.26 creation code (see
    /// test/Mocks/uniswapV4/PoolManagerDeployer.sol) and used through its interface
    IPoolManager public manager;
    PoolModifyLiquidityTest public lpRouter;
    LobsterProxy public proxy;
    address public v3Factory;
    IUniswapV3PoolMinimal public v3Pool;

    MockERC20 public token0;
    MockERC20 public token1;

    ProxyPoolKey public cleanKey; // token0 / token1, no hook
    ProxyPoolKey public nativeKey; // ETH / token1, no hook

    address public user = makeAddr("user");
    /// @notice Where outputs go. LobsterProxy only ever pays its caller, so this is the user
    /// itself; the name keeps assertions reading as "delivered to the recipient".
    address public recipient = user;

    function setUp() public virtual {
        manager = IPoolManager(PoolManagerDeployer.deploy(address(this)));
        lpRouter = new PoolModifyLiquidityTest(IPoolManager(address(manager)));
        v3Factory = _deployV3Factory();
        proxy = new LobsterProxy(v3Factory, address(manager));

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
        _allow(address(this), proxy.v3Key(address(v3Pool)), MINT);
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

        // ...and every pool registered for swaps, so the suites exercise the swap logic itself
        _allow(user, proxy.v3Key(address(v3Pool)), SWAP);
        _allow(user, proxy.v4Key(cleanKey), SWAP);
        _allow(user, proxy.v4Key(nativeKey), SWAP);
    }

    /// @dev Registers `key` with `permissions` in `who`'s own registry entries, with a price band that
    /// allows any price: these suites test swapping and batching, not bands (see the band tests)
    function _allow(address who, bytes32 key, uint8 permissions) internal {
        bytes32[] memory keys = new bytes32[](1);
        keys[0] = key;
        uint8[] memory perms = new uint8[](1);
        perms[0] = permissions;
        vm.prank(who);
        proxy.setPools(keys, perms);
        vm.prank(who);
        proxy.setPriceBand(key, TickMath.MIN_TICK, TickMath.MAX_TICK);
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

    /// @dev The fixture adds native V4 liquidity, and the router refunds unused ETH to this contract
    receive() external payable {}
}
