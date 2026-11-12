// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.24;

import "forge-std/Test.sol";

import {LobsterProxy} from "../src/LobsterProxy.sol";
import {PoolRegistry} from "../src/base/PoolRegistry.sol";
import {PositionRecorder, Range} from "../src/base/PositionRecorder.sol";
import {UniswapSwapProxy} from "../src/UniswapSwapProxy.sol";
import {UniswapV3MintProxy} from "../src/UniswapV3MintProxy.sol";
import {UniswapV4LiquidityProxy, V4LiquidityOp} from "../src/UniswapV4LiquidityProxy.sol";
import {PoolManagerBase} from "../src/base/PoolManagerBase.sol";
import {
    PoolKey,
    Currency,
    IHooks,
    IPoolManagerMinimal,
    ModifyLiquidityParams
} from "../src/interfaces/uniswapV4/IPoolManagerMinimal.sol";
import {MintParams, MintCallbackData} from "../src/interfaces/uniswapV3/IUniswapV3MintCallback.sol";
import {IUniswapV3FactoryMinimal} from "../src/interfaces/uniswapV3/IUniswapV3FactoryMinimal.sol";
import {IUniswapV3PoolMinimal} from "../src/interfaces/uniswapV3/IUniswapV3PoolMinimal.sol";
import {Operation} from "../src/interfaces/zodiac/IRoles.sol";
import {TickMath} from "../src/libraries/uniswapV3/TickMath.sol";
import {PoolAddress} from "../src/libraries/uniswapV3/PoolAddress.sol";
import {SwapCalldata} from "./helpers/SwapCalldata.sol";
import {MockRoles} from "./Mocks/zodiac/MockRoles.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
// `^0.8.0`, unlike UniswapV3Infra (`^0.8.28`), so a real V3 factory can share a 0.8.26 unit with
// LobsterProxy.
import {FACTORY_BYTECODE} from "./Mocks/uniswapV3/bytecodes/factory.sol";
// NOTE: solmate's mock, not test/Mocks/MockERC20.sol, which requires ^0.8.28.
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IProxyErrors} from "../src/interfaces/IProxyErrors.sol";

/// @notice The getters of LobsterProxy's public constants and immutables, for their selectors
interface IProxyGetters {
    function PERMISSION_MINT() external view returns (uint8);
    function PERMISSION_SWAP() external view returns (uint8);
    function POOL_MANAGER() external view returns (address);
    function UNI_V3_FACTORY() external view returns (address);
}

/// @notice A token that, the first time it is transferred to `trigger`, makes each of a list of calls
/// on the proxy, and records how each one ended and how much of the token the proxy held right then.
contract ReenterOnTransfer is MockERC20 {
    address public proxy;
    address public trigger;
    bool public armed;
    /// @notice The proxy's balance of this token when the hook fired, before the transfer firing it moved
    /// anything
    uint256 public proxyBalanceWhenFired;
    bytes[] internal _calls;
    bool[] internal _succeeded;
    bytes[] internal _returned;

    constructor() MockERC20("Reentrant", "RENT", 18) {}

    function arm(address _proxy, address _trigger, bytes[] memory calls) external {
        (proxy, trigger, armed) = (_proxy, _trigger, true);
        delete _calls;
        for (uint256 i = 0; i < calls.length; i++) {
            _calls.push(calls[i]);
        }
    }

    /// @notice How many calls the hook made
    function attempts() external view returns (uint256) {
        return _succeeded.length;
    }

    /// @notice How the `i`-th call ended: success, and its return or revert data
    function outcome(uint256 i) external view returns (bool, bytes memory) {
        return (_succeeded[i], _returned[i]);
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (armed && to == trigger) {
            armed = false;
            proxyBalanceWhenFired = balanceOf[proxy];
            for (uint256 i = 0; i < _calls.length; i++) {
                (bool ok, bytes memory ret) = proxy.call(_calls[i]);
                _succeeded.push(ok);
                _returned.push(ret);
            }
        }
        return super.transfer(to, amount);
    }
}

/// @notice LobsterProxy: deny by default, per-vault pool registry, outputs always go to the vault.
/// @dev This suite covers the V3 surface, the registry and bands, and walks the whole external ABI.
/// Swaps are `swap(bytes)` calls built with {SwapCalldata}; a single swap is a one-leg call. The V4
/// paths run against a real PoolManager in the V4 suites; here the PoolManager is a bare address that
/// no call in this suite may ever reach, which several tests assert.
contract LobsterProxyTest is Test {
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336; // 2**96, price = 1
    uint24 constant FEE = 3000; // the vault's pool
    uint24 constant OTHER_FEE = 500; // same tokens, a pool the vault never registers
    int24 constant TICK_SPACING = 60; // V4 legs: the hookless (token0, token1, FEE, 60) pool
    int24 constant RANGE = 6000; // a multiple of both tick spacings (60 and 10)
    uint8 constant MINT = 1;
    uint8 constant SWAP = 2;
    uint8 constant BOTH = 3;
    /// @dev The reason `check` gives a caller that is not a Roles modifier
    bytes32 constant NO_AVATAR = "No avatar";

    LobsterProxy lobster;
    address factory;
    address poolManager = makeAddr("poolManager");
    MockERC20 token0;
    MockERC20 token1;

    address vaultA = makeAddr("vaultA");
    address vaultB = makeAddr("vaultB");

    function setUp() public virtual {
        bytes memory code = FACTORY_BYTECODE;
        address f;
        assembly {
            f := create(0, add(code, 0x20), mload(code))
        }
        require(f != address(0), "v3 factory deployment failed");
        factory = f;

        // The V3 paths never touch the PoolManager, so any address will do here
        lobster = new LobsterProxy(factory, poolManager);

        token0 = new MockERC20("Token A", "TKA", 18);
        token1 = new MockERC20("Token B", "TKB", 18);
        if (address(token0) > address(token1)) (token0, token1) = (token1, token0);

        // Two pools on the same pair: the vault's (FEE) and one it never registers (OTHER_FEE)
        token0.mint(address(this), 100_000e18);
        token1.mint(address(this), 100_000e18);
        token0.approve(address(lobster), type(uint256).max);
        token1.approve(address(lobster), type(uint256).max);
        _createPoolWithLiquidity(address(token0), address(token1), FEE);
        _createPoolWithLiquidity(address(token0), address(token1), OTHER_FEE);

        address[2] memory vaults = [vaultA, vaultB];
        for (uint256 i = 0; i < 2; i++) {
            token0.mint(vaults[i], 10_000e18);
            token1.mint(vaults[i], 10_000e18);
            vm.startPrank(vaults[i]);
            token0.approve(address(lobster), type(uint256).max);
            token1.approve(address(lobster), type(uint256).max);
            vm.stopPrank();
            // Price bands allowing any price, so the registry checks are what these tests exercise.
            // A band grants nothing by itself: without PERMISSION_MINT a mint is still refused.
            _anyPrice(vaults[i], _key(FEE));
            _anyPrice(vaults[i], _key(OTHER_FEE));
        }
    }

    // ---------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------

    /// @dev The pool's liquidity comes from this contract, through the proxy like any vault's: it
    /// registers the pool for itself first. Vaults A and B are unaffected.
    function _createPoolWithLiquidity(address a, address b, uint24 fee) internal {
        address pool = IUniswapV3FactoryMinimal(factory).createPool(a, b, fee);
        IUniswapV3PoolMinimal(pool).initialize(SQRT_PRICE_1_1);
        _set(address(this), lobster.v3Key(pool), MINT);
        _anyPrice(address(this), lobster.v3Key(pool));
        (address t0, address t1) = a < b ? (a, b) : (b, a);
        lobster.mint(
            MintParams({
                token0: t0,
                token1: t1,
                fee: fee,
                tickLower: -RANGE,
                tickUpper: RANGE,
                amount0Desired: 1000e18,
                amount1Desired: 1000e18,
                amount0Min: 0,
                amount1Min: 0,
                recipient: address(this),
                deadline: block.timestamp
            })
        );
    }

    function _poolOf(address a, address b, uint24 fee) internal view returns (address) {
        return PoolAddress.computeAddress(factory, PoolAddress.getPoolKey(a, b, fee));
    }

    function _pool(uint24 fee) internal view returns (address) {
        return _poolOf(address(token0), address(token1), fee);
    }

    function _key(uint24 fee) internal view returns (bytes32) {
        return lobster.v3Key(_pool(fee));
    }

    function _set(address vault, bytes32 key, uint8 permissions) internal {
        bytes32[] memory pools = new bytes32[](1);
        pools[0] = key;
        uint8[] memory perms = new uint8[](1);
        perms[0] = permissions;
        vm.prank(vault);
        lobster.setPools(pools, perms);
    }

    /// @dev `vault`'s price band for `key` set to the whole tick range
    function _anyPrice(address vault, bytes32 key) internal {
        _bandOn(vault, key, TickMath.MIN_TICK, TickMath.MAX_TICK);
    }

    function _bandOn(address vault, bytes32 key, int24 minTick, int24 maxTick) internal {
        vm.prank(vault);
        lobster.setPriceBand(key, minTick, maxTick);
    }

    function _mintParams(uint24 fee, address to) internal view returns (MintParams memory) {
        return MintParams({
            token0: address(token0),
            token1: address(token1),
            fee: fee,
            tickLower: -600,
            tickUpper: 600,
            amount0Desired: 10e18,
            amount1Desired: 10e18,
            amount0Min: 0,
            amount1Min: 0,
            recipient: to,
            deadline: block.timestamp
        });
    }

    /// @dev A V3 leg on the (tokenIn, tokenOut, fee) pool. `amount` is amountIn, or amountOut with
    /// `exactOut`; `bound` is amountOutMinimum, or amountInMaximum with `exactOut`.
    function _v3(
        address tokenIn,
        address tokenOut,
        uint24 fee,
        bool exactOut,
        uint256 amount,
        uint256 bound
    )
        internal
        pure
        returns (SwapCalldata.Leg memory leg)
    {
        leg.tokenIn = tokenIn;
        leg.tokenOut = tokenOut;
        leg.fee = fee;
        leg.exactOut = exactOut;
        leg.amount = SafeCast.toUint128(amount);
        leg.bound = SafeCast.toUint128(bound);
    }

    /// @dev A V3 leg between token0 and token1
    function _v3Leg(
        bool zeroForOne,
        uint24 fee,
        bool exactOut,
        uint256 amount,
        uint256 bound
    )
        internal
        view
        returns (SwapCalldata.Leg memory)
    {
        (address tIn, address tOut) =
            zeroForOne ? (address(token0), address(token1)) : (address(token1), address(token0));
        return _v3(tIn, tOut, fee, exactOut, amount, bound);
    }

    /// @dev 1e18 in, no minimum out
    function _exactIn(bool zeroForOne, uint24 fee) internal view returns (SwapCalldata.Leg memory) {
        return _v3Leg(zeroForOne, fee, false, 1e18, 0);
    }

    /// @dev `amountOut` out, no maximum in
    function _exactOut(bool zeroForOne, uint24 fee, uint256 amountOut) internal view returns (SwapCalldata.Leg memory) {
        return _v3Leg(zeroForOne, fee, true, amountOut, type(uint128).max);
    }

    /// @dev A V4 leg of 1e18 on the hookless (tokenIn, tokenOut, FEE, TICK_SPACING) pool, without bounds
    function _v4Leg(
        address tokenIn,
        address tokenOut,
        bool exactOut
    )
        internal
        pure
        returns (SwapCalldata.Leg memory leg)
    {
        leg.v4 = true;
        leg.tokenIn = tokenIn;
        leg.tokenOut = tokenOut;
        leg.fee = FEE;
        leg.tickSpacing = TICK_SPACING;
        leg.exactOut = exactOut;
        leg.amount = 1e18;
        leg.bound = exactOut ? type(uint128).max : 0;
    }

    /// @dev `leg` as a HELD leg: its input is what earlier legs of the call parked
    function _held(SwapCalldata.Leg memory leg) internal pure returns (SwapCalldata.Leg memory) {
        leg.held = true;
        leg.amount = 0;
        return leg;
    }

    function _v4PoolKey(address c0, address c1) internal pure returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(0))
        });
    }

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

    /// @dev The calldata of `swap` running `legs`, with the current block as deadline
    function _swapCall(SwapCalldata.Leg[] memory legs) internal view returns (bytes memory) {
        return SwapCalldata.call(block.timestamp, legs);
    }

    /// @dev `who` calls `swap` running `legs`, with the current block as deadline
    function _swap(address who, SwapCalldata.Leg[] memory legs) internal returns (uint256[] memory) {
        vm.prank(who);
        return lobster.swap(SwapCalldata.encode(block.timestamp, legs));
    }

    /// @dev `who` calls `swap(data)`, which must revert with `reason`
    function _expectSwapRevert(address who, bytes memory data, bytes4 reason) internal {
        vm.prank(who);
        vm.expectRevert(reason);
        lobster.swap(data);
    }

    /// @dev Calldata for each of the four checked V3 entry points: mint, one-leg swaps, exact input and
    /// exact output, and mintWithRecording. Only the mints have a recipient (`to`); a swap leg cannot name
    /// one.
    function _calls(uint24 fee, address to) internal view returns (bytes[4] memory c) {
        c[0] = abi.encodeCall(UniswapV3MintProxy.mint, (_mintParams(fee, to)));
        c[1] = _swapCall(_legs(_exactIn(true, fee)));
        c[2] = _swapCall(_legs(_exactOut(true, fee, 1e18)));
        c[3] = abi.encodeCall(UniswapV3MintProxy.mintWithRecording, (_mintParams(fee, to)));
    }

    /// @dev Expects every checked entry point, called by `caller`, to revert with `reason`
    function _expectAllRevert(address caller, uint24 fee, address to, bytes4 reason) internal {
        bytes[4] memory c = _calls(fee, to);
        for (uint256 i = 0; i < c.length; i++) {
            vm.prank(caller);
            (bool ok, bytes memory ret) = address(lobster).call(c[i]);
            assertFalse(ok, string.concat("entry point ", vm.toString(i), " did not revert"));
            assertEq(ret, abi.encodeWithSelector(reason), string.concat("entry point ", vm.toString(i)));
        }
    }

    function _balances(address who) internal view returns (uint256[4] memory b) {
        address p = _pool(FEE);
        b[0] = token0.balanceOf(who);
        b[1] = token1.balanceOf(who);
        b[2] = token0.balanceOf(p);
        b[3] = token1.balanceOf(p);
    }

    function _assertUnchanged(
        uint256[4] memory before,
        uint256[4] memory afterwards,
        string memory what
    )
        internal
        pure
    {
        for (uint256 i = 0; i < 4; i++) {
            assertEq(afterwards[i], before[i], string.concat(what, ": balance ", vm.toString(i)));
        }
    }

    function _assertProxyHoldsNothing() internal view {
        assertEq(token0.balanceOf(address(lobster)), 0, "proxy kept token0");
        assertEq(token1.balanceOf(address(lobster)), 0, "proxy kept token1");
        assertEq(address(lobster).balance, 0, "proxy kept ETH");
    }

    /// @dev Runs one leg for `who` and checks that `who` paid and received exactly what the call
    /// reports: exact input pays `amount` and reports the output, exact output receives `amount` and
    /// reports the input. Returns the reported amount.
    function _swapAndCheckCaller(address who, SwapCalldata.Leg memory leg) internal returns (uint256 reported) {
        MockERC20 tIn = MockERC20(leg.tokenIn);
        MockERC20 tOut = MockERC20(leg.tokenOut);
        uint256 inBefore = tIn.balanceOf(who);
        uint256 outBefore = tOut.balanceOf(who);

        uint256[] memory amounts = _swap(who, _legs(leg));
        assertEq(amounts.length, 1, "one amount per leg");
        reported = amounts[0];

        uint256 amount = leg.amount;
        (uint256 paid, uint256 received) = leg.exactOut ? (reported, amount) : (amount, reported);
        assertEq(tIn.balanceOf(who), inBefore - paid, "the caller paid a different amount");
        assertEq(tOut.balanceOf(who), outBefore + received, "the caller received a different amount");
    }

    /// @dev The head of the `pool.swap` call a V3 leg makes: recipient, direction, amountSpecified (V3:
    /// positive is exact input) and sqrtPriceLimitX96. A prefix, for `vm.expectCall`.
    function _poolSwapCall(
        address to,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96
    )
        internal
        pure
        returns (bytes memory)
    {
        return
            abi.encodeWithSelector(
                IUniswapV3PoolMinimal.swap.selector, to, zeroForOne, amountSpecified, sqrtPriceLimitX96
            );
    }

    /// @dev LobsterProxy's whole external ABI, as `forge inspect LobsterProxy methodIdentifiers` lists
    /// it: 23 functions, and no receive or fallback
    function _abi() internal pure returns (bytes4[23] memory) {
        return [
            // fund-moving entry points (test_noUncheckedEntryPoints)
            UniswapSwapProxy.swap.selector,
            UniswapV3MintProxy.mint.selector,
            UniswapV4LiquidityProxy.modifyLiquidityV4.selector,
            UniswapV3MintProxy.mintWithRecording.selector,
            UniswapV4LiquidityProxy.modifyLiquidityV4WithRecording.selector,
            // admin: the caller's own entries (test_noUncheckedEntryPoints_adminFunctionsOnlyWriteTheCaller)
            PoolRegistry.setPools.selector,
            PoolRegistry.setPriceBand.selector,
            UniswapV4LiquidityProxy.setV4Roles.selector,
            // callbacks and the Roles condition (test_callbacksCannotBeForged)
            UniswapSwapProxy.uniswapV3SwapCallback.selector,
            UniswapV3MintProxy.uniswapV3MintCallback.selector,
            PoolManagerBase.unlockCallback.selector,
            UniswapV4LiquidityProxy.check.selector,
            // views (test_noUncheckedEntryPoints_viewsAreReadOnly)
            IProxyGetters.PERMISSION_MINT.selector,
            IProxyGetters.PERMISSION_SWAP.selector,
            IProxyGetters.POOL_MANAGER.selector,
            IProxyGetters.UNI_V3_FACTORY.selector,
            PoolRegistry.permissionsOf.selector,
            PoolRegistry.poolsOf.selector,
            PoolRegistry.priceBandOf.selector,
            PoolRegistry.v3Key.selector,
            PoolRegistry.v4Key.selector,
            UniswapV4LiquidityProxy.v4RolesOf.selector,
            PositionRecorder.rangesOf.selector
        ];
    }

    // ---------------------------------------------------------------------------
    // Deny by default
    // ---------------------------------------------------------------------------

    /// @notice A caller that registered nothing is refused by mint and by swap, exact input and output
    function test_unregisteredCaller_isDeniedEverywhere() public {
        _expectAllRevert(vaultB, FEE, vaultB, IProxyErrors.PoolNotAllowed.selector);
    }

    /// @notice Registering a pool grants nothing on another pool of the same pair
    function test_unregisteredPool_isDeniedEverywhere() public {
        _set(vaultA, _key(FEE), BOTH);
        _expectAllRevert(vaultA, OTHER_FEE, vaultA, IProxyErrors.PoolNotAllowed.selector);
    }

    /// @notice A registration belongs to the vault that made it: it grants another vault nothing, and
    /// another vault's writes never touch it
    function test_registrationIsPerVault() public {
        _set(vaultA, _key(FEE), BOTH);
        _expectAllRevert(vaultB, FEE, vaultB, IProxyErrors.PoolNotAllowed.selector);

        // vault B's own writes never touch vault A's entries
        _set(vaultB, _key(FEE), 0);
        assertEq(lobster.permissionsOf(vaultA, _key(FEE)), BOTH, "vault B changed vault A's entry");
        vm.startPrank(vaultA);
        lobster.mint(_mintParams(FEE, vaultA));
        lobster.swap(SwapCalldata.encode(block.timestamp, _legs(_exactIn(true, FEE))));
        vm.stopPrank();
    }

    /// @notice mint keeps its recipient field, and it must be the caller: another vault, an outsider,
    /// address(0), the proxy itself and a precompile are all refused. (A swap leg has no recipient
    /// field at all; see test_swap_outputsAlwaysGoToTheCaller.)
    function test_recipientMustBeTheCaller() public {
        _set(vaultA, _key(FEE), BOTH);
        address[5] memory others = [vaultB, makeAddr("someone"), address(0), address(lobster), address(2)];
        for (uint256 i = 0; i < others.length; i++) {
            vm.prank(vaultA);
            vm.expectRevert(IProxyErrors.RecipientMustBeCaller.selector);
            lobster.mint(_mintParams(FEE, others[i]));
        }
    }

    /// @notice mint checks its recipient before the registry, as specified
    function test_recipientIsCheckedBeforeTheRegistry() public {
        vm.prank(vaultB);
        vm.expectRevert(IProxyErrors.RecipientMustBeCaller.selector);
        lobster.mint(_mintParams(OTHER_FEE, vaultA));
    }

    /// @notice A swap leg has no recipient field, so its output can only reach the caller: for every
    /// kind of V3 leg (exact input or output, either direction, either pool, with a price limit the
    /// swap does not reach), alone, two in one call, or chained (a PARK leg whose output a later HELD
    /// leg spends), the vault pays and receives exactly what is reported, and none of the addresses the
    /// old recipient check refused (another vault, an outsider, address(0), the proxy, a precompile)
    /// gains or loses anything. (V4 legs need a real PoolManager: see the V4 suites.)
    function test_swap_outputsAlwaysGoToTheCaller() public {
        _set(vaultA, _key(FEE), SWAP);
        _set(vaultA, _key(OTHER_FEE), SWAP);
        address[5] memory others = [vaultB, makeAddr("someone"), address(0), address(lobster), address(2)];
        uint256[2][5] memory held;
        for (uint256 i = 0; i < others.length; i++) {
            held[i] = [token0.balanceOf(others[i]), token1.balanceOf(others[i])];
        }

        SwapCalldata.Leg[4] memory legs = [
            _exactIn(true, FEE),
            _exactOut(false, FEE, 1e18),
            _exactIn(false, OTHER_FEE),
            _exactOut(true, OTHER_FEE, 1e18)
        ];
        for (uint256 i = 0; i < legs.length; i++) {
            _swapAndCheckCaller(vaultA, legs[i]);
        }

        // PRICE_LIMIT legs, exact input and exact output, with limits far past where 1e18 moves the
        // price: the pool is given the limit and told to pay the caller, and each leg runs in full
        SwapCalldata.Leg memory limitIn = _exactIn(true, FEE);
        limitIn.sqrtPriceLimitX96 = TickMath.getSqrtRatioAtTick(-600);
        SwapCalldata.Leg memory limitOut = _exactOut(false, OTHER_FEE, 1e18);
        limitOut.sqrtPriceLimitX96 = TickMath.getSqrtRatioAtTick(600);
        vm.expectCall(_pool(FEE), _poolSwapCall(vaultA, true, 1e18, limitIn.sqrtPriceLimitX96), 1);
        _swapAndCheckCaller(vaultA, limitIn);
        vm.expectCall(_pool(OTHER_FEE), _poolSwapCall(vaultA, false, -1e18, limitOut.sqrtPriceLimitX96), 1);
        _swapAndCheckCaller(vaultA, limitOut);

        // two legs in one call: both outputs land at the caller
        uint256 t0 = token0.balanceOf(vaultA);
        uint256 t1 = token1.balanceOf(vaultA);
        uint256[] memory amounts = _swap(vaultA, _legs(_exactIn(true, FEE), _exactIn(false, OTHER_FEE)));
        assertEq(token0.balanceOf(vaultA), t0 - 1e18 + amounts[1], "two legs: token0");
        assertEq(token1.balanceOf(vaultA), t1 + amounts[0] - 1e18, "two legs: token1");

        // a V3 -> V3 chain: the first leg parks its output, the HELD leg spends exactly all of it, and
        // only the HELD leg's output reaches the caller
        SwapCalldata.Leg memory park = _exactIn(true, FEE);
        park.park = true;
        t0 = token0.balanceOf(vaultA);
        t1 = token1.balanceOf(vaultA);
        uint256 feePoolT1 = token1.balanceOf(_pool(FEE));
        uint256 otherPoolT1 = token1.balanceOf(_pool(OTHER_FEE));
        vm.expectCall(_pool(OTHER_FEE), abi.encodeWithSelector(IUniswapV3PoolMinimal.swap.selector, vaultA, false), 1);
        amounts = _swap(vaultA, _legs(park, _held(_exactIn(false, OTHER_FEE))));
        assertGt(amounts[0], 0, "chain: nothing was parked; test proves nothing");
        assertEq(token0.balanceOf(vaultA), t0 - 1e18 + amounts[1], "chain: token0");
        assertEq(token1.balanceOf(vaultA), t1, "chain: the parked output reached the caller");
        assertEq(token1.balanceOf(_pool(FEE)), feePoolT1 - amounts[0], "chain: the first leg paid out another amount");
        assertEq(
            token1.balanceOf(_pool(OTHER_FEE)), otherPoolT1 + amounts[0], "chain: the HELD leg spent another amount"
        );

        for (uint256 i = 0; i < others.length; i++) {
            assertEq(token0.balanceOf(others[i]), held[i][0], string.concat("token0 of other ", vm.toString(i)));
            assertEq(token1.balanceOf(others[i]), held[i][1], string.concat("token1 of other ", vm.toString(i)));
        }
        _assertProxyHoldsNothing();
    }

    /// @notice Fuzzed over the leg (pool, direction, exact input or output, size) and the outsider:
    /// only the caller pays and receives, exactly the reported amounts; an outsider holding both
    /// tokens with a standing approval to the proxy is never charged and never paid
    function testFuzz_swap_onlyTheCallerPaysAndReceives(
        address outsider,
        uint256 amount,
        bool zeroForOne,
        bool exactOut,
        bool otherFee
    )
        public
    {
        assumeNotForgeAddress(outsider);
        vm.assume(outsider != vaultA && outsider != address(lobster));
        vm.assume(outsider != _pool(FEE) && outsider != _pool(OTHER_FEE));
        token0.mint(outsider, 1_000e18);
        token1.mint(outsider, 1_000e18);
        vm.startPrank(outsider);
        token0.approve(address(lobster), type(uint256).max);
        token1.approve(address(lobster), type(uint256).max);
        vm.stopPrank();
        uint256 outsider0 = token0.balanceOf(outsider);
        uint256 outsider1 = token1.balanceOf(outsider);

        uint24 fee = otherFee ? OTHER_FEE : FEE;
        _set(vaultA, _key(fee), SWAP);
        amount = bound(amount, 1, 100e18);
        _swapAndCheckCaller(vaultA, _v3Leg(zeroForOne, fee, exactOut, amount, exactOut ? type(uint128).max : 0));

        assertEq(token0.balanceOf(outsider), outsider0, "the outsider's token0 moved");
        assertEq(token1.balanceOf(outsider), outsider1, "the outsider's token1 moved");
        _assertProxyHoldsNothing();
    }

    /// @notice PARK is the only way an output can stay with the proxy, and a call must spend what it
    /// parks: a parked output, exact input or exact output, that no later HELD leg spends reverts the
    /// whole call (`FundsLeftInProxy`), even when a later leg pays in the parked token from the vault
    function test_swap_parkedOutputMustBeSpent() public {
        _set(vaultA, _key(FEE), SWAP);
        SwapCalldata.Leg memory parkIn = _exactIn(true, FEE);
        parkIn.park = true;
        SwapCalldata.Leg memory parkOut = _exactOut(true, FEE, 1e18);
        parkOut.park = true;
        bytes[3] memory calls = [
            SwapCalldata.encode(block.timestamp, _legs(parkIn)),
            SwapCalldata.encode(block.timestamp, _legs(parkOut)),
            // the second leg spends token1 too, but the vault's own, not the parked output
            SwapCalldata.encode(block.timestamp, _legs(parkIn, _exactIn(false, FEE)))
        ];
        uint256[4] memory before = _balances(vaultA);

        for (uint256 i = 0; i < calls.length; i++) {
            _expectSwapRevert(vaultA, calls[i], IProxyErrors.FundsLeftInProxy.selector);
        }
        _assertUnchanged(before, _balances(vaultA), "a refused call moved funds");
        _assertProxyHoldsNothing();
    }

    /// @notice A registration with PERMISSION_MINT alone allows minting, not swapping
    function test_mintOnlyPool_cannotBeSwapped() public {
        _set(vaultA, _key(FEE), MINT);
        vm.startPrank(vaultA);
        lobster.mint(_mintParams(FEE, vaultA));
        vm.expectRevert(IProxyErrors.PoolNotAllowed.selector);
        lobster.swap(SwapCalldata.encode(block.timestamp, _legs(_exactIn(true, FEE))));
        vm.stopPrank();
    }

    /// @notice A registration with PERMISSION_SWAP alone allows swapping, not minting
    function test_swapOnlyPool_cannotBeMinted() public {
        _set(vaultA, _key(FEE), SWAP);
        vm.startPrank(vaultA);
        lobster.swap(SwapCalldata.encode(block.timestamp, _legs(_exactIn(true, FEE))));
        vm.expectRevert(IProxyErrors.PoolNotAllowed.selector);
        lobster.mint(_mintParams(FEE, vaultA));
        vm.stopPrank();
    }

    /// @notice One registration covers both directions of the pool
    function test_oneRegistration_swapsInBothDirections() public {
        _set(vaultA, _key(FEE), SWAP);
        uint256 t0 = token0.balanceOf(vaultA);
        uint256 t1 = token1.balanceOf(vaultA);

        uint256 out01 = _swap(vaultA, _legs(_exactIn(true, FEE)))[0]; // token0 -> token1
        uint256 out10 = _swap(vaultA, _legs(_exactIn(false, FEE)))[0]; // token1 -> token0

        assertEq(token0.balanceOf(vaultA), t0 - 1e18 + out10, "token0 flows");
        assertEq(token1.balanceOf(vaultA), t1 + out01 - 1e18, "token1 flows");
    }

    /// @notice The deadline is still enforced, by mint and by swap
    function test_deadlineIsStillEnforced() public {
        _set(vaultA, _key(FEE), BOTH);
        MintParams memory m = _mintParams(FEE, vaultA);
        m.deadline = block.timestamp - 1;
        bytes memory expired = SwapCalldata.encode(block.timestamp - 1, _legs(_exactIn(true, FEE)));

        vm.startPrank(vaultA);
        vm.expectRevert(IProxyErrors.TransactionTooOld.selector);
        lobster.mint(m);
        vm.expectRevert(IProxyErrors.TransactionTooOld.selector);
        lobster.swap(expired);
        vm.stopPrank();
    }

    /// @notice A swap call carries one deadline for all its legs: at exactly the deadline the whole call
    /// runs; one second past it nothing runs, not even the first leg (no pool is called at all)
    function test_swap_deadlineCoversTheWholeCall() public {
        _set(vaultA, _key(FEE), SWAP);
        _set(vaultA, _key(OTHER_FEE), SWAP);
        SwapCalldata.Leg[] memory legs = _legs(_exactIn(true, FEE), _exactIn(false, OTHER_FEE));

        uint256[] memory amounts = _swap(vaultA, legs); // deadline == block.timestamp
        assertEq(amounts.length, 2, "one amount per leg");
        assertGt(amounts[0], 0, "first leg did not run");
        assertGt(amounts[1], 0, "second leg did not run");

        vm.expectCall(_pool(FEE), "", 0);
        vm.expectCall(_pool(OTHER_FEE), "", 0);
        _expectSwapRevert(
            vaultA, SwapCalldata.encode(block.timestamp - 1, legs), IProxyErrors.TransactionTooOld.selector
        );
    }

    // ---------------------------------------------------------------------------
    // Registry
    // ---------------------------------------------------------------------------

    /// @notice A registration can be overwritten (not merged) and removed, and the listing follows
    function test_updateAndRemove() public {
        bytes32 p = _key(FEE);
        bytes memory swapData = SwapCalldata.encode(block.timestamp, _legs(_exactIn(true, FEE)));

        _set(vaultA, p, MINT);
        vm.startPrank(vaultA);
        lobster.mint(_mintParams(FEE, vaultA));
        vm.expectRevert(IProxyErrors.PoolNotAllowed.selector);
        lobster.swap(swapData);
        vm.stopPrank();

        _set(vaultA, p, SWAP); // overwrite, not merge
        vm.startPrank(vaultA);
        lobster.swap(swapData);
        vm.expectRevert(IProxyErrors.PoolNotAllowed.selector);
        lobster.mint(_mintParams(FEE, vaultA));
        vm.stopPrank();
        (bytes32[] memory pools, uint8[] memory perms) = lobster.poolsOf(vaultA);
        assertEq(pools.length, 1, "update duplicated the entry");
        assertEq(perms[0], SWAP);

        _set(vaultA, p, 0); // remove
        _expectAllRevert(vaultA, FEE, vaultA, IProxyErrors.PoolNotAllowed.selector);
        (pools,) = lobster.poolsOf(vaultA);
        assertEq(pools.length, 0, "removed pool still listed");
        assertEq(lobster.permissionsOf(vaultA, p), 0);
    }

    /// @notice Random add / update / remove sequences, including the same pool twice in one call:
    /// `poolsOf` and `permissionsOf` must always match a simple model, with no duplicates and no
    /// zero entries; every key keeps its own price band throughout, a removed key included, and so
    /// does the key a removal moves in the listing (swap-and-pop rewrites that other key's entry); and
    /// vault B, listing and bands, must never be affected.
    function testFuzz_poolsOf_staysConsistent(uint256 seed, uint256 rounds) public {
        // Two real V3 keys, an arbitrary V3-shaped key, and two V4-shaped keys. Keys are opaque to the
        // registry, so every key may get any combination of permissions.
        bytes32[5] memory candidates =
            [_key(FEE), _key(OTHER_FEE), bytes32(uint256(0x1111)), keccak256("v4 pool a"), keccak256("v4 pool b")];
        // A distinct band per key, so a band cleared, or copied from another key, is caught
        int24[2][5] memory bands = [
            [int24(-10), int24(10)],
            [int24(-20), int24(20)],
            [int24(-30), int24(30)],
            [int24(-40), int24(40)],
            [int24(-50), int24(50)]
        ];
        for (uint256 c = 0; c < 5; c++) {
            _bandOn(vaultA, candidates[c], bands[c][0], bands[c][1]);
        }
        uint8[5] memory model;
        _assertRegistryMatches(candidates, model, bands);

        uint256 n = bound(rounds, 1, 12);
        for (uint256 r = 0; r < n; r++) {
            uint256 k = bound(uint256(keccak256(abi.encode(seed, r))), 1, 4);
            bytes32[] memory pools = new bytes32[](k);
            uint8[] memory perms = new uint8[](k);
            for (uint256 j = 0; j < k; j++) {
                uint256 x = uint256(keccak256(abi.encode(seed, r, j)));
                uint256 c = x % 5;
                pools[j] = candidates[c];
                perms[j] = SafeCast.toUint8((x >> 8) % 4);
                model[c] = perms[j]; // applied in order: the last value for a key wins
            }
            vm.prank(vaultA);
            lobster.setPools(pools, perms);
            _assertRegistryMatches(candidates, model, bands);
        }

        (bytes32[] memory others,) = lobster.poolsOf(vaultB);
        assertEq(others.length, 0, "vault B was affected");
        // vault B's bands on the two real pools, as setUp set them
        for (uint256 c = 0; c < 2; c++) {
            (int24 lo, int24 hi) = lobster.priceBandOf(vaultB, candidates[c]);
            assertEq(lo, TickMath.MIN_TICK, "vault B's minTick was affected");
            assertEq(hi, TickMath.MAX_TICK, "vault B's maxTick was affected");
        }
    }

    /// @dev Vault A's registry matches the model, and each candidate still has its own band
    function _assertRegistryMatches(
        bytes32[5] memory candidates,
        uint8[5] memory model,
        int24[2][5] memory bands
    )
        internal
        view
    {
        (bytes32[] memory listed, uint8[] memory perms) = lobster.poolsOf(vaultA);
        uint256 expected;
        for (uint256 c = 0; c < 5; c++) {
            assertEq(lobster.permissionsOf(vaultA, candidates[c]), model[c], "permissionsOf");
            (int24 lo, int24 hi) = lobster.priceBandOf(vaultA, candidates[c]);
            assertEq(lo, bands[c][0], string.concat("minTick of key ", vm.toString(c)));
            assertEq(hi, bands[c][1], string.concat("maxTick of key ", vm.toString(c)));
            if (model[c] != 0) expected++;
        }
        assertEq(listed.length, expected, "poolsOf length");
        assertEq(perms.length, listed.length, "poolsOf arrays differ in length");
        for (uint256 i = 0; i < listed.length; i++) {
            bool found;
            for (uint256 c = 0; c < 5; c++) {
                if (candidates[c] == listed[i]) {
                    found = true;
                    assertEq(perms[i], model[c], "poolsOf permission");
                }
            }
            assertTrue(found, "poolsOf lists an unknown key");
            assertGt(perms[i], 0, "poolsOf lists a removed key");
            for (uint256 j = 0; j < i; j++) {
                assertTrue(listed[j] != listed[i], "poolsOf lists a key twice");
            }
        }
    }

    /// @notice Fuzzed: a key's permissions and its band share one storage slot but are written
    /// independently, in either order: setPriceBand never changes the permissions or the listing,
    /// setPools never changes the band, and removing a key keeps its band
    function testFuzz_registry_permissionsAndBandAreIndependent(
        bytes32 key,
        uint8 perms,
        int24 minTick,
        int24 maxTick,
        bool bandFirst
    )
        public
    {
        perms = SafeCast.toUint8(bound(uint256(perms), MINT, BOTH));
        minTick = SafeCast.toInt24(bound(int256(minTick), TickMath.MIN_TICK, TickMath.MAX_TICK - 1));
        maxTick = SafeCast.toInt24(bound(int256(maxTick), int256(minTick) + 1, TickMath.MAX_TICK));

        if (bandFirst) {
            _bandOn(vaultA, key, minTick, maxTick);
            _set(vaultA, key, perms);
        } else {
            _set(vaultA, key, perms);
            _bandOn(vaultA, key, minTick, maxTick);
        }
        _assertEntry(key, perms, minTick, maxTick, true);

        uint8 other = perms == BOTH ? SWAP : BOTH;
        _set(vaultA, key, other); // new permissions: the band stays
        _assertEntry(key, other, minTick, maxTick, true);

        _bandOn(vaultA, key, 0, 0); // band cleared: the permissions and the listing stay
        _assertEntry(key, other, 0, 0, true);

        _bandOn(vaultA, key, minTick, maxTick);
        _set(vaultA, key, 0); // removed: the listing drops it, the band stays
        _assertEntry(key, 0, minTick, maxTick, false);
    }

    function _assertEntry(bytes32 key, uint8 perms, int24 minTick, int24 maxTick, bool listed) internal view {
        assertEq(lobster.permissionsOf(vaultA, key), perms, "permissions");
        (int24 lo, int24 hi) = lobster.priceBandOf(vaultA, key);
        assertEq(lo, minTick, "minTick");
        assertEq(hi, maxTick, "maxTick");
        (bytes32[] memory keys, uint8[] memory p) = lobster.poolsOf(vaultA);
        assertEq(keys.length, listed ? 1 : 0, "listing");
        if (listed) {
            assertEq(keys[0], key, "listed key");
            assertEq(p[0], perms, "listed permissions");
        }
    }

    /// @notice Keys are not checked against the factory, and need not be: registering the key of an
    /// address where no V3 pool was deployed buys nothing, a leg on it reverts (`NotAPool`) instead of
    /// "swapping" against an empty account
    function test_swap_registeredKeyWithoutAPool_reverts() public {
        uint24[2] memory fees = [uint24(10_000), uint24(777)]; // an enabled tier never created; no tier
        uint256[4] memory before = _balances(vaultA);
        for (uint256 i = 0; i < fees.length; i++) {
            address noPool = _pool(fees[i]);
            assertEq(noPool.code.length, 0, "a pool exists there; test proves nothing");
            _set(vaultA, lobster.v3Key(noPool), SWAP);
            _anyPrice(vaultA, lobster.v3Key(noPool));
            _expectSwapRevert(
                vaultA,
                SwapCalldata.encode(block.timestamp, _legs(_exactIn(true, fees[i]))),
                IProxyErrors.NotAPool.selector
            );
        }
        _assertUnchanged(before, _balances(vaultA), "a refused swap moved funds");
    }

    /// @notice setPools refuses arrays of different lengths
    function test_setPools_lengthMismatch_reverts() public {
        bytes32[] memory pools = new bytes32[](2);
        uint8[] memory perms = new uint8[](1);
        vm.prank(vaultA);
        vm.expectRevert(IProxyErrors.LengthMismatch.selector);
        lobster.setPools(pools, perms);
    }

    /// @notice Fuzzed: any bit outside PERMISSION_MINT | PERMISSION_SWAP is refused
    function testFuzz_setPools_invalidBits_revert(uint8 bits) public {
        vm.assume(bits & ~BOTH != 0);
        bytes32[] memory pools = new bytes32[](1);
        pools[0] = _key(FEE);
        uint8[] memory perms = new uint8[](1);
        perms[0] = bits;
        vm.prank(vaultA);
        vm.expectRevert(IProxyErrors.InvalidPermissions.selector);
        lobster.setPools(pools, perms);
    }

    /// @notice One bad entry reverts the whole call: nothing before it is written
    function test_setPools_isAtomic() public {
        bytes32[] memory pools = new bytes32[](2);
        pools[0] = _key(FEE);
        pools[1] = _key(OTHER_FEE);
        uint8[] memory perms = new uint8[](2);
        perms[0] = BOTH;
        perms[1] = 4;
        vm.prank(vaultA);
        vm.expectRevert(IProxyErrors.InvalidPermissions.selector);
        lobster.setPools(pools, perms);

        assertEq(lobster.permissionsOf(vaultA, _key(FEE)), 0, "first entry was written");
        (bytes32[] memory listed,) = lobster.poolsOf(vaultA);
        assertEq(listed.length, 0);
    }

    /// @notice setPools emits one event per entry, removals included
    function test_setPools_emitsOneEventPerPool() public {
        bytes32[] memory pools = new bytes32[](2);
        pools[0] = _key(FEE);
        pools[1] = _key(OTHER_FEE);
        uint8[] memory perms = new uint8[](2);
        perms[0] = MINT;
        perms[1] = 0;

        vm.expectEmit(address(lobster));
        emit PoolRegistry.PoolPermissionsSet(vaultA, pools[0], MINT);
        vm.expectEmit(address(lobster));
        emit PoolRegistry.PoolPermissionsSet(vaultA, pools[1], 0);
        vm.prank(vaultA);
        lobster.setPools(pools, perms);
    }

    // ---------------------------------------------------------------------------
    // Happy paths: exactly the expected tokens move
    // ---------------------------------------------------------------------------

    /// @dev One balance went from `before` to `afterwards` by gaining `gain` and losing `loss`
    function _assertMoved(
        uint256 before,
        uint256 afterwards,
        uint256 gain,
        uint256 loss,
        string memory what
    )
        internal
        pure
    {
        assertEq(afterwards + loss, before + gain, what);
    }

    /// @notice A registered vault's mint and swap move exactly what they report: the vault pays the
    /// pool, the pool pays the vault, the position is the vault's, the proxy keeps nothing, and a
    /// V3-only swap never touches the PoolManager
    function test_happyPaths_moveExactlyTheReportedAmounts() public {
        _set(vaultA, _key(FEE), BOTH);
        uint256[4] memory b = _balances(vaultA); // vault token0, token1; pool token0, token1

        vm.prank(vaultA);
        (uint256 paid0, uint256 paid1) = lobster.mint(_mintParams(FEE, vaultA));
        uint256[4] memory a = _balances(vaultA);
        assertGt(paid0, 0);
        assertGt(paid1, 0);
        _assertMoved(b[0], a[0], 0, paid0, "mint: vault token0");
        _assertMoved(b[1], a[1], 0, paid1, "mint: vault token1");
        _assertMoved(b[2], a[2], paid0, 0, "mint: pool token0");
        _assertMoved(b[3], a[3], paid1, 0, "mint: pool token1");
        (uint128 liquidity,,,,) =
            IUniswapV3PoolMinimal(_pool(FEE)).positions(keccak256(abi.encodePacked(vaultA, int24(-600), int24(600))));
        assertGt(liquidity, 0, "the vault does not own the position");

        b = a;
        vm.expectCall(poolManager, "", 0); // a V3-only call opens no unlock, nor calls the PoolManager at all
        uint256[] memory amounts = _swap(vaultA, _legs(_exactIn(true, FEE)));
        a = _balances(vaultA);
        assertEq(amounts.length, 1, "one amount per leg");
        uint256 out = amounts[0];
        assertGt(out, 0);
        _assertMoved(b[0], a[0], 0, 1e18, "exactIn: vault token0");
        _assertMoved(b[1], a[1], out, 0, "exactIn: vault token1");
        _assertMoved(b[2], a[2], 1e18, 0, "exactIn: pool token0");
        _assertMoved(b[3], a[3], 0, out, "exactIn: pool token1");

        _assertProxyHoldsNothing();
    }

    // ---------------------------------------------------------------------------
    // No unchecked entry point
    // ---------------------------------------------------------------------------

    /// @notice Every fund-moving entry point of the new ABI (see `_abi`) is a checked one: a caller
    /// that registered nothing (vault B) is refused by `swap` for every kind of leg (V3 and V4, exact
    /// input and output, with a price limit, native ETH in and out with ETH attached, and PARK/HELD
    /// chains V3->V3, V4->V4 and V3->V4), by `mint` and `mintWithRecording`, and by `modifyLiquidityV4`
    /// and `modifyLiquidityV4WithRecording` (Roles not configured;
    /// then, once configured, an add on a pool it has no PERMISSION_MINT for), before anything runs:
    /// no pool or PoolManager is called and no token moves, not even inside the reverted calls. The
    /// rest of the ABI: the other test_noUncheckedEntryPoints_* tests and test_callbacksCannotBeForged.
    function test_noUncheckedEntryPoints() public {
        SwapCalldata.Leg memory limitIn = _exactIn(true, FEE);
        limitIn.sqrtPriceLimitX96 = TickMath.getSqrtRatioAtTick(-60);
        SwapCalldata.Leg memory limitOut = _exactOut(true, FEE, 1e18);
        limitOut.sqrtPriceLimitX96 = TickMath.getSqrtRatioAtTick(-60);
        SwapCalldata.Leg memory parkV3 = _exactIn(true, FEE);
        parkV3.park = true;
        SwapCalldata.Leg memory parkV4 = _v4Leg(address(token0), address(token1), false);
        parkV4.park = true;
        SwapCalldata.Leg memory heldV4 = _held(_v4Leg(address(token1), address(token0), false));

        SwapCalldata.Leg[][11] memory swaps;
        swaps[0] = _legs(_exactIn(true, FEE)); // V3 exact input
        swaps[1] = _legs(_exactOut(true, FEE, 1e18)); // V3 exact output
        swaps[2] = _legs(limitIn); // V3 exact input, price limit
        swaps[3] = _legs(limitOut); // V3 exact output, price limit
        swaps[4] = _legs(_v4Leg(address(token0), address(token1), false)); // V4 exact input
        swaps[5] = _legs(_v4Leg(address(token0), address(token1), true)); // V4 exact output
        swaps[6] = _legs(_v4Leg(address(0), address(token1), false)); // V4 native ETH in
        swaps[7] = _legs(_v4Leg(address(token1), address(0), false)); // V4 native ETH out
        swaps[8] = _legs(parkV3, _held(_exactIn(false, FEE))); // V3 -> V3 chain
        swaps[9] = _legs(parkV4, heldV4); // V4 -> V4 chain
        swaps[10] = _legs(parkV3, heldV4); // V3 -> V4 chain

        V4LiquidityOp[] memory add = new V4LiquidityOp[](1);
        add[0] = V4LiquidityOp({
            key: _v4PoolKey(address(token0), address(token1)),
            tickLower: -600,
            tickUpper: 600,
            liquidityDelta: 1e18,
            salt: bytes32(0),
            amount0Limit: type(uint128).max,
            amount1Limit: type(uint128).max
        });
        MockRoles rolesB = new MockRoles(vaultB, vaultB);

        vm.deal(vaultB, 10e18);
        uint256[4] memory beforeA = _balances(vaultA);
        uint256[4] memory beforeB = _balances(vaultB);
        // Nothing runs: no pool or PoolManager is called, no token transferred, even in a reverted frame
        vm.expectCall(_pool(FEE), "", 0);
        vm.expectCall(_pool(OTHER_FEE), "", 0);
        vm.expectCall(poolManager, "", 0);
        vm.expectCall(address(token0), abi.encodeWithSelector(IERC20.transferFrom.selector), 0);
        vm.expectCall(address(token1), abi.encodeWithSelector(IERC20.transferFrom.selector), 0);
        vm.expectCall(address(token0), abi.encodeWithSelector(IERC20.transfer.selector), 0);
        vm.expectCall(address(token1), abi.encodeWithSelector(IERC20.transfer.selector), 0);

        for (uint256 i = 0; i < swaps.length; i++) {
            vm.prank(vaultB);
            (bool ok, bytes memory ret) = address(lobster).call{value: 1e18}(_swapCall(swaps[i]));
            assertFalse(ok, string.concat("unchecked swap ", vm.toString(i)));
            assertEq(ret, abi.encodeWithSelector(IProxyErrors.PoolNotAllowed.selector), vm.toString(i));
        }

        vm.prank(vaultB);
        vm.expectRevert(IProxyErrors.PoolNotAllowed.selector);
        lobster.mint(_mintParams(FEE, vaultB));
        vm.prank(vaultB);
        vm.expectRevert(IProxyErrors.PoolNotAllowed.selector);
        lobster.mintWithRecording(_mintParams(FEE, vaultB));

        // V4 liquidity: refused before anything runs for a vault that has not configured its Roles
        // modifier, and then, configured, for an add on a pool it has no PERMISSION_MINT for (exits
        // need nothing; see LobsterV4Liquidity.t.sol)
        vm.prank(vaultB);
        vm.expectRevert(IProxyErrors.V4RolesNotSet.selector);
        lobster.modifyLiquidityV4{value: 1e18}(add, block.timestamp);
        vm.prank(vaultB);
        vm.expectRevert(IProxyErrors.V4RolesNotSet.selector);
        lobster.modifyLiquidityV4WithRecording{value: 1e18}(add, block.timestamp);
        vm.prank(vaultB);
        lobster.setV4Roles(address(rolesB), keccak256("vault B role"));
        vm.prank(vaultB);
        vm.expectRevert(IProxyErrors.PoolNotAllowed.selector);
        lobster.modifyLiquidityV4{value: 1e18}(add, block.timestamp);
        vm.prank(vaultB);
        vm.expectRevert(IProxyErrors.PoolNotAllowed.selector);
        lobster.modifyLiquidityV4WithRecording{value: 1e18}(add, block.timestamp);
        assertEq(lobster.rangesOf(vaultB, _key(FEE)).length, 0, "a refused mint recorded a range");
        assertEq(
            lobster.rangesOf(vaultB, keccak256(abi.encode(add[0].key))).length, 0, "a refused add recorded a range"
        );

        _assertUnchanged(beforeA, _balances(vaultA), "vault A");
        _assertUnchanged(beforeB, _balances(vaultB), "vault B");
        assertEq(vaultB.balance, 10e18, "vault B's ETH moved");
        _assertProxyHoldsNothing();
    }

    /// @notice The admin functions (setPools, setPriceBand, setV4Roles) write only the caller's own
    /// entries: whatever another vault or an outsider calls them with, vault A's permissions, listing,
    /// bands and Roles configuration are untouched (vault A's own modifier is refused to anyone else),
    /// and vault A can do exactly what it could before
    function test_noUncheckedEntryPoints_adminFunctionsOnlyWriteTheCaller() public {
        MockRoles rolesA = new MockRoles(vaultA, vaultA);
        bytes32 roleA = keccak256("vault A role");
        _set(vaultA, _key(FEE), BOTH);
        _bandOn(vaultA, _key(FEE), -600, 600);
        vm.prank(vaultA);
        lobster.setV4Roles(address(rolesA), roleA);

        bytes32[] memory keys = new bytes32[](2);
        keys[0] = _key(FEE);
        keys[1] = _key(OTHER_FEE);
        uint8[] memory perms = new uint8[](2);
        perms[0] = 0;
        perms[1] = BOTH;
        address[2] memory callers = [vaultB, makeAddr("attacker")];
        for (uint256 i = 0; i < callers.length; i++) {
            vm.startPrank(callers[i]);
            lobster.setPools(keys, perms);
            lobster.setPriceBand(_key(FEE), 0, 0);
            vm.expectRevert(IProxyErrors.RolesModifierNotTheVaults.selector);
            lobster.setV4Roles(address(rolesA), roleA);
            lobster.setV4Roles(address(0), bytes32(0));
            vm.stopPrank();
            // what it wrote is its own
            assertEq(lobster.permissionsOf(callers[i], _key(OTHER_FEE)), BOTH, "the caller's own entry");
        }

        assertEq(lobster.permissionsOf(vaultA, _key(FEE)), BOTH, "vault A's permissions");
        assertEq(lobster.permissionsOf(vaultA, _key(OTHER_FEE)), 0, "vault A gained a pool");
        (bytes32[] memory listed, uint8[] memory listedPerms) = lobster.poolsOf(vaultA);
        assertEq(listed.length, 1, "vault A's listing");
        assertEq(listed[0], _key(FEE), "vault A's listed key");
        assertEq(listedPerms[0], BOTH, "vault A's listed permissions");
        (int24 lo, int24 hi) = lobster.priceBandOf(vaultA, _key(FEE));
        assertEq(lo, -600, "vault A's band");
        assertEq(hi, 600, "vault A's band");
        (address rolesModifier, bytes32 roleKey) = lobster.v4RolesOf(vaultA);
        assertEq(rolesModifier, address(rolesA), "vault A's Roles modifier");
        assertEq(roleKey, roleA, "vault A's role key");

        vm.startPrank(vaultA);
        lobster.mint(_mintParams(FEE, vaultA));
        lobster.swap(SwapCalldata.encode(block.timestamp, _legs(_exactIn(true, FEE))));
        vm.stopPrank();
        _expectAllRevert(vaultA, OTHER_FEE, vaultA, IProxyErrors.PoolNotAllowed.selector);
    }

    /// @notice Everything else in the ABI is read-only: each view answers a static call from anyone,
    /// so none of them can write state or move funds
    function test_noUncheckedEntryPoints_viewsAreReadOnly() public {
        bytes[11] memory views = [
            abi.encodeCall(IProxyGetters.PERMISSION_MINT, ()),
            abi.encodeCall(IProxyGetters.PERMISSION_SWAP, ()),
            abi.encodeCall(IProxyGetters.POOL_MANAGER, ()),
            abi.encodeCall(IProxyGetters.UNI_V3_FACTORY, ()),
            abi.encodeCall(PoolRegistry.permissionsOf, (vaultA, _key(FEE))),
            abi.encodeCall(PoolRegistry.poolsOf, (vaultA)),
            abi.encodeCall(PoolRegistry.priceBandOf, (vaultA, _key(FEE))),
            abi.encodeCall(PoolRegistry.v3Key, (_pool(FEE))),
            abi.encodeCall(PoolRegistry.v4Key, (_v4PoolKey(address(token0), address(token1)))),
            abi.encodeCall(UniswapV4LiquidityProxy.v4RolesOf, (vaultA)),
            abi.encodeCall(PositionRecorder.rangesOf, (vaultA, _key(FEE)))
        ];
        vm.startPrank(makeAddr("attacker"));
        for (uint256 i = 0; i < views.length; i++) {
            (bool ok,) = address(lobster).staticcall(views[i]);
            assertTrue(ok, string.concat("view ", vm.toString(i), " does not answer a static call"));
        }
        vm.stopPrank();

        assertEq(lobster.PERMISSION_MINT(), MINT);
        assertEq(lobster.PERMISSION_SWAP(), SWAP);
        assertEq(address(lobster.POOL_MANAGER()), poolManager);
        assertEq(lobster.UNI_V3_FACTORY(), factory);
    }

    /// @notice The proxy has no receive and no fallback: plain ETH is refused from anyone, the
    /// PoolManager included, and the five swap entry points `swap` replaced (exactInputSingle,
    /// exactOutputSingle, exactInputSingleV4, exactOutputSingleV4, batchSwap) are gone: a vault's old
    /// call reverts without data and without effect, even with the pool registered
    function test_noUncheckedEntryPoints_noReceiveNoFallback() public {
        _set(vaultA, _key(FEE), SWAP); // so the old calls would have run
        address[3] memory senders = [vaultA, makeAddr("attacker"), poolManager];
        for (uint256 i = 0; i < senders.length; i++) {
            vm.deal(senders[i], 1e18);
            vm.prank(senders[i]);
            (bool sent, bytes memory ret) = address(lobster).call{value: 1e18}("");
            assertFalse(sent, string.concat("proxy accepted ETH from sender ", vm.toString(i)));
            assertEq(ret.length, 0, "plain ETH: unexpected revert data");
            assertEq(senders[i].balance, 1e18, "the sender's ETH moved");
        }
        assertEq(address(lobster).balance, 0, "proxy holds ETH");

        uint256 d = block.timestamp;
        bytes[] memory item = new bytes[](1);
        item[0] = abi.encodePacked(
            uint8(1),
            abi.encode(address(token0), address(token1), FEE, vaultA, d, uint256(1e18), uint256(0), uint160(0))
        );
        bytes[5] memory legacy = [
            abi.encodeWithSignature(
                "exactInputSingle((address,address,uint24,address,uint256,uint256,uint256,uint160))",
                address(token0),
                address(token1),
                FEE,
                vaultA,
                d,
                uint256(1e18),
                uint256(0),
                uint160(0)
            ),
            abi.encodeWithSignature(
                "exactOutputSingle((address,address,uint24,address,uint256,uint256,uint256,uint160))",
                address(token0),
                address(token1),
                FEE,
                vaultA,
                d,
                uint256(1e18),
                type(uint256).max,
                uint160(0)
            ),
            abi.encodeWithSignature(
                "exactInputSingleV4(((address,address,uint24,int24,address),bool,address,uint256,uint128,uint128,uint160))",
                address(token0),
                address(token1),
                FEE,
                TICK_SPACING,
                address(0),
                true,
                vaultA,
                d,
                uint128(1e18),
                uint128(0),
                uint160(0)
            ),
            abi.encodeWithSignature(
                "exactOutputSingleV4(((address,address,uint24,int24,address),bool,address,uint256,uint128,uint128,uint160))",
                address(token0),
                address(token1),
                FEE,
                TICK_SPACING,
                address(0),
                true,
                vaultA,
                d,
                uint128(1e18),
                type(uint128).max,
                uint160(0)
            ),
            abi.encodeWithSignature("batchSwap(bytes[])", item)
        ];
        uint256[4] memory before = _balances(vaultA);
        vm.expectCall(_pool(FEE), "", 0);
        for (uint256 i = 0; i < legacy.length; i++) {
            vm.prank(vaultA);
            (bool ok, bytes memory ret) = address(lobster).call(legacy[i]);
            assertFalse(ok, string.concat("removed entry point ", vm.toString(i), " still answers"));
            assertEq(ret.length, 0, string.concat("removed entry point ", vm.toString(i), ": revert data"));
        }
        _assertUnchanged(before, _balances(vaultA), "a removed entry point moved funds");
    }

    /// @notice Fuzzed: a call to any selector outside the ABI reverts without data, whatever its
    /// arguments and the ETH sent, so there is no fallback through which an unchecked call could run
    function testFuzz_noUncheckedEntryPoints_unknownSelectorsRevert(
        bytes4 selector,
        bytes memory args,
        uint96 value
    )
        public
    {
        bytes4[23] memory known = _abi();
        for (uint256 i = 0; i < known.length; i++) {
            vm.assume(selector != known[i]);
        }
        vm.deal(vaultA, value);
        vm.prank(vaultA);
        (bool ok, bytes memory ret) = address(lobster).call{value: value}(bytes.concat(selector, args));
        assertFalse(ok, "an unknown selector was answered");
        assertEq(ret.length, 0, "unexpected revert data");
        assertEq(vaultA.balance, value, "the caller's ETH moved");
    }

    // ---------------------------------------------------------------------------
    // Exact-output swaps
    // ---------------------------------------------------------------------------

    /// @notice An exact-output leg delivers exactly amountOut to the vault and reports what it paid
    function test_exactOutput_deliversExactlyAmountOut() public {
        _set(vaultA, _key(FEE), SWAP);
        uint256[4] memory before = _balances(vaultA);

        uint256[] memory amounts = _swap(vaultA, _legs(_exactOut(true, FEE, 1e18)));
        assertEq(amounts.length, 1, "one amount per leg");
        uint256 amountIn = amounts[0];

        uint256[4] memory afterSwap = _balances(vaultA);
        assertEq(afterSwap[1], before[1] + 1e18, "vault did not receive exactly amountOut");
        assertEq(before[0] - afterSwap[0], amountIn, "vault paid a different amount than reported");
        assertGt(amountIn, 1e18, "no fee paid at a 1:1 price");
        assertEq(token0.balanceOf(address(lobster)), 0, "proxy kept token0");
        assertEq(token1.balanceOf(address(lobster)), 0, "proxy kept token1");
    }

    /// @notice An exact-output leg's amountInMaximum is enforced
    function test_exactOutput_amountInMaximumIsEnforced() public {
        _set(vaultA, _key(FEE), SWAP);
        SwapCalldata.Leg memory leg = _exactOut(true, FEE, 1e18);
        leg.bound = 1e18; // less than the 1e18 plus fee the swap really costs
        _expectSwapRevert(
            vaultA, SwapCalldata.encode(block.timestamp, _legs(leg)), IProxyErrors.TooMuchRequested.selector
        );
    }

    /// @notice Without a price limit, an order the pool cannot fill in full reverts instead of
    /// spending `amountInMaximum` on a part of it
    function test_exactOutput_partialFillReverts() public {
        _set(vaultA, _key(FEE), SWAP);
        uint256[4] memory before = _balances(vaultA);

        _expectSwapRevert(
            vaultA,
            SwapCalldata.encode(block.timestamp, _legs(_exactOut(true, FEE, 5_000e18))), // the pool holds ~1,000
            IProxyErrors.TooLittleReceived.selector
        );

        uint256[4] memory afterAll = _balances(vaultA);
        for (uint256 i = 0; i < 4; i++) {
            assertEq(afterAll[i], before[i], "a refused swap moved funds");
        }
    }

    /// @notice A MINT-only registration does not allow exact-output swaps either
    function test_mintOnlyPool_cannotBeSwappedExactOut() public {
        _set(vaultA, _key(FEE), MINT);
        _expectSwapRevert(
            vaultA,
            SwapCalldata.encode(block.timestamp, _legs(_exactOut(true, FEE, 1e18))),
            IProxyErrors.PoolNotAllowed.selector
        );
    }

    /// @notice An exact-output leg of a multi-leg call is checked like a single swap: refused on a pool
    /// the vault did not register; once registered, the call runs, its exact output lands at the vault
    /// (a leg cannot name anyone else; vault B gets nothing) and the call reports the amount it paid.
    /// Each leg has its own pool, so each is checked on its own: the exact-output leg's pool pays out
    /// exactly amountOut and is paid exactly the reported input, the other pool exactly its own leg.
    function test_batch_exactOutputLegIsChecked() public {
        _set(vaultA, _key(FEE), SWAP);
        SwapCalldata.Leg[] memory legs = _legs(_exactIn(true, FEE), _exactOut(true, OTHER_FEE, 1e18));

        // unregistered pool
        _expectSwapRevert(vaultA, SwapCalldata.encode(block.timestamp, legs), IProxyErrors.PoolNotAllowed.selector);

        // registered: runs, pays the vault only, and returns the amount paid
        _set(vaultA, _key(OTHER_FEE), SWAP);
        uint256 before0 = token0.balanceOf(vaultA);
        uint256 before1 = token1.balanceOf(vaultA);
        uint256[4] memory b = _balances(vaultB);
        uint256[2] memory exactInPool = [token0.balanceOf(_pool(FEE)), token1.balanceOf(_pool(FEE))];
        uint256[2] memory exactOutPool = [token0.balanceOf(_pool(OTHER_FEE)), token1.balanceOf(_pool(OTHER_FEE))];
        uint256[] memory amounts = _swap(vaultA, legs);
        assertEq(amounts.length, 2, "one amount per leg");
        assertEq(token1.balanceOf(vaultA), before1 + amounts[0] + 1e18, "vault did not receive exactly amountOut");
        assertEq(token0.balanceOf(vaultA), before0 - 1e18 - amounts[1], "vault paid a different amount than reported");
        assertGt(amounts[1], 1e18, "the call did not report the amount paid");
        assertEq(token1.balanceOf(_pool(OTHER_FEE)), exactOutPool[1] - 1e18, "exact-output leg: not exactly amountOut");
        assertEq(
            token0.balanceOf(_pool(OTHER_FEE)), exactOutPool[0] + amounts[1], "exact-output leg: not the reported input"
        );
        assertEq(token0.balanceOf(_pool(FEE)), exactInPool[0] + 1e18, "exact-input leg: not exactly amountIn");
        assertEq(token1.balanceOf(_pool(FEE)), exactInPool[1] - amounts[0], "exact-input leg: not the reported output");
        assertEq(token0.balanceOf(vaultB), b[0], "vault B was paid");
        assertEq(token1.balanceOf(vaultB), b[1], "vault B was paid");
        _assertProxyHoldsNothing();
    }

    /// @dev A swap unlock written the way `swap` writes one ({UniswapSwapProxy-_unlockPayload}): SWAP_TAG |
    /// legs | msg.value << 1 | usesLedger | per leg, the pool's registry key and the caller's band word
    /// for it (minTick | maxTick << 24, 24 bits each) | the call's data. Here one exact-input leg on the
    /// FEE pool, with `vault`'s band for it, no ETH and nothing parked: with the lock held, the swap
    /// body would run that leg.
    function _swapUnlockPayload(address vault) internal view returns (bytes memory) {
        (int24 minTick, int24 maxTick) = lobster.priceBandOf(vault, _key(FEE));
        uint256 band =
            SafeCast.toUint256(int256(minTick) & 0xffffff) | (SafeCast.toUint256(int256(maxTick) & 0xffffff) << 24);
        return bytes.concat(
            bytes1(0x01),
            abi.encode(uint256(1), uint256(0), _key(FEE), band),
            SwapCalldata.encode(block.timestamp, _legs(_exactIn(true, FEE)))
        );
    }

    /// @notice The callbacks are the only fund-moving functions outside the lock, and none acts for
    /// anyone the proxy is not serving: the V3 swap callback is honoured only from the pool the proxy is
    /// calling at that moment, whatever mode its data names, so neither an attacker nor the genuine pool
    /// outside a swap can make it pay (the payer is the lock holder, never named in calldata); the mint
    /// callback only from the genuine pool and only while an entry point runs, for the lock holder, so
    /// outside one even the genuine pool is refused, whatever payer its data names; the unlock callback
    /// only from the PoolManager, whatever the tag, and from the PoolManager only for an unlock an entry
    /// point opened: outside any call it refuses a swap unlock, even a well-formed one for the pool vault
    /// A registered, with vault A's band, and a liquidity unlock and an unknown tag too; and the Roles
    /// condition `check` is a view. Nothing runs: no pool or PoolManager is called and no token moves,
    /// not even in a reverted frame. Vault A, with standing approvals, loses nothing.
    function test_callbacksCannotBeForged() public {
        _set(vaultA, _key(FEE), BOTH);
        address attacker = makeAddr("attacker");
        uint256[4] memory before = _balances(vaultA);
        vm.expectCall(_pool(FEE), "", 0);
        vm.expectCall(poolManager, "", 0);
        vm.expectCall(address(token0), abi.encodeWithSelector(IERC20.transferFrom.selector), 0);
        vm.expectCall(address(token1), abi.encodeWithSelector(IERC20.transferFrom.selector), 0);
        vm.expectCall(address(token0), abi.encodeWithSelector(IERC20.transfer.selector), 0);
        vm.expectCall(address(token1), abi.encodeWithSelector(IERC20.transfer.selector), 0);

        // uniswapV3SwapCallback data: tokenIn | mode | creditIn
        bytes[3] memory modes = [
            abi.encodePacked(address(token0), uint8(0), uint256(0)), // pay from the lock holder
            abi.encodePacked(address(token0), uint8(1), uint256(1e18)), // spend parked funds
            abi.encodePacked(address(token0), uint8(2), uint256(0)) // settle a hand-off with the PoolManager
        ];
        address[2] memory forgers = [attacker, _pool(FEE)];
        for (uint256 i = 0; i < forgers.length; i++) {
            for (uint256 j = 0; j < modes.length; j++) {
                vm.prank(forgers[i]);
                vm.expectRevert(IProxyErrors.UnexpectedCallback.selector);
                lobster.uniswapV3SwapCallback(1e18, -1e18, modes[j]);
            }
        }

        // uniswapV3MintCallback, its data naming as payer (the old layout, MintCallbackData) vault A,
        // which holds both tokens and approved the proxy. From an attacker: refused by the CREATE2
        // check, a bare require.
        PoolAddress.PoolKey memory poolKey = PoolAddress.getPoolKey(address(token0), address(token1), FEE);
        bytes memory payerVaultA = abi.encode(MintCallbackData({poolKey: poolKey, payer: vaultA}));
        vm.prank(attacker);
        (bool ok, bytes memory ret) =
            address(lobster).call(abi.encodeCall(UniswapV3MintProxy.uniswapV3MintCallback, (1e18, 1e18, payerVaultA)));
        assertFalse(ok, "a forged mint callback succeeded");
        assertEq(ret.length, 0, "a forged mint callback failed for an unexpected reason");
        // From the genuine pool, which passes that check, outside any call: no entry point holds the
        // lock, so there is no one to charge, with that data or with the data `mint` passes (the key)
        bytes[2] memory mintData = [payerVaultA, abi.encode(poolKey)];
        for (uint256 i = 0; i < mintData.length; i++) {
            vm.prank(_pool(FEE));
            vm.expectRevert(IProxyErrors.UnexpectedCallback.selector);
            lobster.uniswapV3MintCallback(1e18, 1e18, mintData[i]);
        }

        // unlockCallback: swap tag, liquidity tag, unknown tag, from anyone but the PoolManager
        bytes[3] memory unlocks = [
            bytes.concat(bytes1(0x01), new bytes(64)),
            bytes.concat(bytes1(0x02), abi.encode(new V4LiquidityOp[](0))),
            bytes(hex"03")
        ];
        for (uint256 i = 0; i < unlocks.length; i++) {
            vm.prank(attacker);
            vm.expectRevert(IProxyErrors.NotPoolManager.selector);
            lobster.unlockCallback(unlocks[i]);
        }
        // From the PoolManager itself outside any call, i.e. for an unlock the proxy did not open: a swap
        // unlock is refused before its payload is read (the well-formed one too), a liquidity unlock finds
        // no operation in progress, an unknown tag is refused
        bytes[4] memory managerUnlocks = [unlocks[0], _swapUnlockPayload(vaultA), unlocks[1], unlocks[2]];
        bytes4[4] memory refusals = [
            IProxyErrors.UnexpectedCallback.selector,
            IProxyErrors.UnexpectedCallback.selector,
            IProxyErrors.NoLiquidityOperation.selector,
            IProxyErrors.UnexpectedCallback.selector
        ];
        for (uint256 i = 0; i < managerUnlocks.length; i++) {
            vm.prank(poolManager);
            vm.expectRevert(refusals[i]);
            lobster.unlockCallback(managerUnlocks[i]);
        }

        // check: a view, which only ever answers a Roles modifier; to anyone else it says no
        bytes memory addLiquidity = abi.encodeCall(
            IPoolManagerMinimal.modifyLiquidity,
            (
                _v4PoolKey(address(token0), address(token1)),
                ModifyLiquidityParams({tickLower: -600, tickUpper: 600, liquidityDelta: 1e18, salt: bytes32(0)}),
                ""
            )
        );
        vm.startPrank(attacker);
        (bool allowed, bytes32 reason) =
            lobster.check(poolManager, 0, addLiquidity, uint8(Operation.Call), 0, 0, bytes12(0));
        vm.stopPrank();
        assertFalse(allowed, "check allowed a call for a non-modifier");
        assertEq(reason, NO_AVATAR);

        uint256[4] memory afterwards = _balances(vaultA);
        for (uint256 k = 0; k < 4; k++) {
            assertEq(afterwards[k], before[k], "a forged callback moved funds");
        }
    }

    // ---------------------------------------------------------------------------
    // Reentrancy
    // ---------------------------------------------------------------------------

    /// @dev A token whose transfer hook can re-enter the proxy, with a (token0, token) V3 pool that
    /// vault A registered for swaps at any price
    function _evilPool() internal returns (ReenterOnTransfer evil) {
        evil = new ReenterOnTransfer();
        evil.mint(address(this), 100_000e18);
        evil.approve(address(lobster), type(uint256).max);
        _createPoolWithLiquidity(address(token0), address(evil), FEE);
        bytes32 key = lobster.v3Key(_poolOf(address(token0), address(evil), FEE));
        _set(vaultA, key, SWAP);
        _anyPrice(vaultA, key);
    }

    /// @dev What a hostile token tries mid-call, and the revert data each attempt must end with: every
    /// function that moves funds or writes state hits the lock; each callback refuses it (it is not the
    /// pool being called, not a pool, not the PoolManager)
    function _reentryAttempts(address evil) internal view returns (bytes[] memory calls, bytes[] memory reverts) {
        bytes32[] memory keys = new bytes32[](1);
        keys[0] = bytes32(uint256(0xBEEF));
        uint8[] memory perms = new uint8[](1);
        perms[0] = BOTH;
        SwapCalldata.Leg memory spendParked = _held(_v3(evil, address(token0), FEE, false, 0, 0));
        bytes memory locked = abi.encodeWithSelector(IProxyErrors.ReentrancyGuardReentrantCall.selector);

        calls = new bytes[](11);
        reverts = new bytes[](11);
        calls[0] = abi.encodeCall(PoolRegistry.setPools, (keys, perms));
        calls[1] = abi.encodeCall(PoolRegistry.setPriceBand, (keys[0], TickMath.MIN_TICK, TickMath.MAX_TICK));
        calls[2] = abi.encodeCall(UniswapV4LiquidityProxy.setV4Roles, (address(0), bytes32(0)));
        calls[3] = _swapCall(_legs(spendParked));
        calls[4] = abi.encodeCall(UniswapV3MintProxy.mint, (_mintParams(FEE, evil)));
        calls[5] = abi.encodeCall(UniswapV4LiquidityProxy.modifyLiquidityV4, (new V4LiquidityOp[](0), block.timestamp));
        calls[6] = abi.encodeCall(UniswapV3MintProxy.mintWithRecording, (_mintParams(FEE, evil)));
        calls[7] = abi.encodeCall(
            UniswapV4LiquidityProxy.modifyLiquidityV4WithRecording, (new V4LiquidityOp[](0), block.timestamp)
        );
        for (uint256 i = 0; i < 8; i++) {
            reverts[i] = locked;
        }
        calls[8] = abi.encodeCall(
            UniswapSwapProxy.uniswapV3SwapCallback,
            (1e18, -1e18, abi.encodePacked(address(token0), uint8(0), uint256(0)))
        );
        reverts[8] = abi.encodeWithSelector(IProxyErrors.UnexpectedCallback.selector);
        calls[9] = abi.encodeCall(
            UniswapV3MintProxy.uniswapV3MintCallback,
            (
                1e18,
                1e18,
                abi.encode(
                    MintCallbackData({poolKey: PoolAddress.getPoolKey(address(token0), evil, FEE), payer: vaultA})
                )
            )
        );
        reverts[9] = ""; // CallbackValidation's bare require: not the pool
        calls[10] = abi.encodeCall(PoolManagerBase.unlockCallback, (bytes.concat(bytes1(0x01), new bytes(64))));
        reverts[10] = abi.encodeWithSelector(IProxyErrors.NotPoolManager.selector);
    }

    function _assertEveryAttemptFailed(ReenterOnTransfer evil, bytes[] memory reverts) internal view {
        assertEq(evil.attempts(), reverts.length, "the hook did not fire; test proves nothing");
        for (uint256 i = 0; i < reverts.length; i++) {
            (bool ok, bytes memory ret) = evil.outcome(i);
            assertFalse(ok, string.concat("reentrant call ", vm.toString(i), " succeeded"));
            assertEq(
                ret, reverts[i], string.concat("reentrant call ", vm.toString(i), " failed for an unexpected reason")
            );
        }
    }

    /// @notice `setPools` is covered by the reentrancy lock: a token delivered mid-swap cannot call it.
    /// The lock reverts with OpenZeppelin's `ReentrancyGuardReentrantCall`, selector for selector.
    function test_setPools_isCoveredByTheReentrancyLock() public {
        ReenterOnTransfer evil = _evilPool();
        (bytes[] memory calls,) = _reentryAttempts(address(evil));
        bytes[] memory setPoolsOnly = new bytes[](1);
        setPoolsOnly[0] = calls[0];
        evil.arm(address(lobster), vaultA, setPoolsOnly); // fires when the pool delivers EVIL to the vault

        _swap(vaultA, _legs(_v3(address(token0), address(evil), FEE, false, 1e18, 0)));

        assertGt(evil.balanceOf(vaultA), 0, "the swap did not deliver; test proves nothing");
        assertEq(evil.attempts(), 1, "the hook did not fire; test proves nothing");
        (bool attackSucceeded, bytes memory attackRevertData) = evil.outcome(0);
        assertFalse(attackSucceeded, "setPools ran during a swap");
        assertEq(
            attackRevertData,
            abi.encodeWithSelector(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector),
            "setPools failed for an unexpected reason"
        );
        assertEq(lobster.permissionsOf(address(evil), bytes32(uint256(0xBEEF))), 0, "the reentrant write landed");
    }

    /// @notice No entry point is reachable mid-swap: a token delivered to the vault in the middle of a
    /// swap calls every function that moves funds or writes state (swap, mint, modifyLiquidityV4, their
    /// recording variants, setPools, setPriceBand, setV4Roles) and each hits the lock; the three callbacks refuse it. The
    /// swap itself completes.
    function test_reentrancy_noEntryPointIsReachableMidSwap() public {
        ReenterOnTransfer evil = _evilPool();
        (bytes[] memory calls, bytes[] memory reverts) = _reentryAttempts(address(evil));
        evil.arm(address(lobster), vaultA, calls); // fires when the pool delivers EVIL to the vault

        uint256[] memory amounts = _swap(vaultA, _legs(_v3(address(token0), address(evil), FEE, false, 1e18, 0)));

        _assertEveryAttemptFailed(evil, reverts);
        assertGt(amounts[0], 0, "the swap did not deliver; test proves nothing");
        assertEq(evil.balanceOf(vaultA), amounts[0], "the vault did not receive the reported output");
        assertEq(lobster.permissionsOf(address(evil), bytes32(uint256(0xBEEF))), 0, "a reentrant write landed");
        (int24 lo, int24 hi) = lobster.priceBandOf(address(evil), bytes32(uint256(0xBEEF)));
        assertEq(lo, 0, "a reentrant band landed");
        assertEq(hi, 0, "a reentrant band landed");
    }

    /// @notice The lock is what guards parked funds: while the proxy holds a V3 output parked for a
    /// later leg, the token holding it can reach no entry point (in particular no `swap` whose HELD
    /// leg would spend that output) and can forge no callback; the call then completes and spends
    /// exactly what it parked. The token's hook fires inside the HELD leg's callback, as the proxy pays
    /// the pool with the output it parked, and records that the proxy holds exactly that output then.
    function test_reentrancy_parkedFundsAreLockedMidCall() public {
        ReenterOnTransfer evil = _evilPool();
        address evilPool = _poolOf(address(token0), address(evil), FEE);
        (bytes[] memory calls, bytes[] memory reverts) = _reentryAttempts(address(evil));
        evil.arm(address(lobster), evilPool, calls); // fires when the proxy pays the pool the EVIL it parked

        SwapCalldata.Leg memory park = _v3(address(token0), address(evil), FEE, false, 1e18, 0);
        park.park = true;
        SwapCalldata.Leg memory spend = _held(_v3(address(evil), address(token0), FEE, false, 0, 0));
        uint256 t0 = token0.balanceOf(vaultA);
        uint256 poolEvil = evil.balanceOf(evilPool);
        uint256[] memory amounts = _swap(vaultA, _legs(park, spend));

        _assertEveryAttemptFailed(evil, reverts);
        assertGt(amounts[0], 0, "nothing was parked; test proves nothing");
        assertEq(evil.proxyBalanceWhenFired(), amounts[0], "the hook fired while nothing was parked; proves nothing");
        assertEq(evil.balanceOf(evilPool), poolEvil, "the HELD leg did not spend exactly the parked output");
        assertEq(token0.balanceOf(vaultA), t0 - 1e18 + amounts[1], "the vault did not get the round trip");
        assertEq(evil.balanceOf(vaultA), 0, "the parked output reached the vault");
        assertEq(evil.balanceOf(address(lobster)), 0, "proxy kept the parked output");
        assertEq(token0.balanceOf(address(lobster)), 0, "proxy kept token0");
    }

    // ---------------------------------------------------------------------------
    // Price bands
    // ---------------------------------------------------------------------------

    function _tick(uint24 fee) internal view returns (int24 tick) {
        (, tick,,,,,) = IUniswapV3PoolMinimal(_pool(fee)).slot0();
    }

    function _band(address vault, int24 minTick, int24 maxTick) internal {
        _bandOn(vault, _key(FEE), minTick, maxTick);
    }

    /// @notice setPriceBand emits PriceBandSet and priceBandOf reads it back
    function test_priceBand_setEmitsAndReads() public {
        bytes32 key = _key(FEE);
        vm.expectEmit(true, true, false, true, address(lobster));
        emit PoolRegistry.PriceBandSet(vaultA, key, -1200, 800);
        _band(vaultA, -1200, 800);

        (int24 minTick, int24 maxTick) = lobster.priceBandOf(vaultA, key);
        assertEq(minTick, -1200);
        assertEq(maxTick, 800);
    }

    /// @notice Empty, inverted and out-of-range bands are refused
    function test_priceBand_invalidBandsRevert() public {
        bytes32 key = _key(FEE);
        int24[2][4] memory bad = [
            [int24(100), int24(100)], // empty
            [int24(100), int24(-100)], // inverted
            [TickMath.MIN_TICK - 1, int24(0)], // below Uniswap's range
            [int24(0), TickMath.MAX_TICK + 1] // above it
        ];
        for (uint256 i = 0; i < bad.length; i++) {
            vm.prank(vaultA);
            vm.expectRevert(IProxyErrors.InvalidPriceBand.selector);
            lobster.setPriceBand(key, bad[i][0], bad[i][1]);
        }
    }

    /// @notice A band is per vault and per pool
    function test_priceBand_isPerVaultAndPerPool() public {
        _band(vaultA, -10, 10);

        (int24 minTick, int24 maxTick) = lobster.priceBandOf(vaultA, _key(FEE));
        assertEq(minTick, -10);
        assertEq(maxTick, 10);
        // vault B's band on the same pool, and vault A's on another pool, are untouched
        (minTick, maxTick) = lobster.priceBandOf(vaultB, _key(FEE));
        assertEq(minTick, TickMath.MIN_TICK);
        assertEq(maxTick, TickMath.MAX_TICK);
        (minTick, maxTick) = lobster.priceBandOf(vaultA, _key(OTHER_FEE));
        assertEq(minTick, TickMath.MIN_TICK);
        assertEq(maxTick, TickMath.MAX_TICK);
    }

    /// @notice A registered pool without a band cannot be minted on
    function test_mint_withoutPriceBand_reverts() public {
        _set(vaultA, _key(FEE), MINT);
        _band(vaultA, 0, 0); // cleared, as if never set

        vm.prank(vaultA);
        vm.expectRevert(IProxyErrors.PriceBandNotSet.selector);
        lobster.mint(_mintParams(FEE, vaultA));
    }

    /// @notice mint checks the registry before the band
    function test_mint_registryIsCheckedBeforeTheBand() public {
        _band(vaultA, 0, 0);
        vm.prank(vaultA);
        vm.expectRevert(IProxyErrors.PoolNotAllowed.selector);
        lobster.mint(_mintParams(FEE, vaultA));
    }

    /// @notice mint is refused with the price just below or just above the band
    function test_mint_outsideBand_reverts() public {
        _set(vaultA, _key(FEE), MINT);
        int24 tick = _tick(FEE);

        _band(vaultA, tick + 1, tick + 100); // price just below the band
        vm.prank(vaultA);
        vm.expectRevert(IProxyErrors.PriceOutOfBand.selector);
        lobster.mint(_mintParams(FEE, vaultA));

        _band(vaultA, tick - 100, tick - 1); // price just above the band
        vm.prank(vaultA);
        vm.expectRevert(IProxyErrors.PriceOutOfBand.selector);
        lobster.mint(_mintParams(FEE, vaultA));
    }

    /// @notice Both band edges are inclusive for mint
    function test_mint_bandEdgesAreInclusive() public {
        _set(vaultA, _key(FEE), MINT);
        int24 tick = _tick(FEE);

        _band(vaultA, tick, tick + 1);
        vm.prank(vaultA);
        lobster.mint(_mintParams(FEE, vaultA));

        _band(vaultA, tick - 1, tick);
        vm.prank(vaultA);
        lobster.mint(_mintParams(FEE, vaultA));
    }

    /// @notice The scenario bands exist for: the price is pushed away, the vault's mint is refused, and
    /// it goes through again once the vault's owners move the band
    function test_mint_afterPriceMove_refusedUntilBandMoved() public {
        _set(vaultA, _key(FEE), BOTH);
        int24 start = _tick(FEE);
        _band(vaultA, start - 100, start + 100);

        // someone else's large swap moves the pool well past vault A's band (vault B allows any price)
        _set(vaultB, _key(FEE), SWAP);
        _swap(vaultB, _legs(_v3Leg(true, FEE, false, 200e18, 0)));
        int24 moved = _tick(FEE);
        assertLt(moved, start - 100, "swap did not leave the band");

        vm.prank(vaultA);
        vm.expectRevert(IProxyErrors.PriceOutOfBand.selector);
        lobster.mint(_mintParams(FEE, vaultA));

        _band(vaultA, moved - 100, moved + 100);
        vm.prank(vaultA);
        lobster.mint(_mintParams(FEE, vaultA));
    }

    // --- recording mints -------------------------------------------------------

    /// @dev The liquidity `owner` holds in the FEE pool over the range, as the pool itself reports it
    function _v3Liquidity(address owner, int24 lower, int24 upper) internal view returns (uint128 liquidity) {
        (liquidity,,,,) = IUniswapV3PoolMinimal(_pool(FEE)).positions(keccak256(abi.encodePacked(owner, lower, upper)));
    }

    function _mintWide(address vault, int24 lower, int24 upper) internal {
        MintParams memory p = _mintParams(FEE, vault);
        (p.tickLower, p.tickUpper) = (lower, upper);
        vm.prank(vault);
        lobster.mintWithRecording(p);
    }

    /// @dev The vault burns all its liquidity over the range on the FEE pool, directly, as it exits a V3
    /// position: the liquidity is gone, the tokens stay owed to it until it collects
    function _burnAll(address vault, int24 lower, int24 upper) internal {
        uint128 liquidity = _v3Liquidity(vault, lower, upper);
        vm.prank(vault);
        IUniswapV3PoolMinimal(_pool(FEE)).burn(lower, upper, liquidity);
    }

    function _collectAll(address vault, int24 lower, int24 upper) internal {
        vm.prank(vault);
        IUniswapV3PoolMinimal(_pool(FEE)).collect(vault, lower, upper, type(uint128).max, type(uint128).max);
    }

    /// @dev Exactly `expected` (lower, upper pairs), in any order, salt 0
    function _assertRanges(address vault, bytes32 key, int24[2][] memory expected, string memory what) internal view {
        Range[] memory ranges = lobster.rangesOf(vault, key);
        assertEq(ranges.length, expected.length, string.concat(what, ": number of ranges"));
        for (uint256 i = 0; i < expected.length; i++) {
            uint256 found = 0;
            for (uint256 j = 0; j < ranges.length; j++) {
                if (ranges[j].tickLower == expected[i][0] && ranges[j].tickUpper == expected[i][1]) found++;
            }
            assertEq(found, 1, string.concat(what, ": range ", vm.toString(i), " not listed exactly once"));
        }
        for (uint256 j = 0; j < ranges.length; j++) {
            assertEq(ranges[j].salt, bytes32(0), string.concat(what, ": a V3 range has no salt"));
        }
    }

    function _r(int24 lower, int24 upper) internal pure returns (int24[2][] memory r) {
        r = new int24[2][](1);
        r[0] = [lower, upper];
    }

    function _r(int24 l0, int24 u0, int24 l1, int24 u1) internal pure returns (int24[2][] memory r) {
        r = new int24[2][](2);
        (r[0], r[1]) = ([l0, u0], [l1, u1]);
    }

    function _r(int24 l0, int24 u0, int24 l1, int24 u1, int24 l2, int24 u2)
        internal
        pure
        returns (int24[2][] memory r)
    {
        r = new int24[2][](3);
        (r[0], r[1], r[2]) = ([l0, u0], [l1, u1], [l2, u2]);
    }

    function _noRecordingLogs(Vm.Log[] memory logs, string memory what) internal pure {
        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(logs[i].topics[0] != PositionRecorder.RangeRecorded.selector, string.concat(what, ": recorded"));
            assertTrue(logs[i].topics[0] != PositionRecorder.RangeDeleted.selector, string.concat(what, ": deleted"));
        }
    }

    /// @notice mintWithRecording mints exactly what mint mints, to the caller, and lists the range under
    /// the caller and the pool's registry key, emitting RangeRecorded
    function test_mintWithRecording_mintsLikeMintAndRecordsTheRange() public {
        _set(vaultA, _key(FEE), MINT);
        uint256 snap = vm.snapshotState();
        vm.prank(vaultA);
        (uint256 plain0, uint256 plain1) = lobster.mint(_mintParams(FEE, vaultA));
        uint128 plainLiquidity = _v3Liquidity(vaultA, -600, 600);
        vm.revertToStateAndDelete(snap);

        vm.expectEmit(true, true, false, true, address(lobster));
        emit PositionRecorder.RangeRecorded(vaultA, _key(FEE), -600, 600, bytes32(0));
        vm.prank(vaultA);
        (uint256 amount0, uint256 amount1) = lobster.mintWithRecording(_mintParams(FEE, vaultA));

        assertEq(amount0, plain0, "amount0 differs from mint");
        assertEq(amount1, plain1, "amount1 differs from mint");
        assertGt(plainLiquidity, 0, "test bug: nothing minted");
        assertEq(_v3Liquidity(vaultA, -600, 600), plainLiquidity, "the vault does not own the same position");
        _assertRanges(vaultA, _key(FEE), _r(-600, 600), "the range");
        _assertProxyHoldsNothing();
    }

    /// @notice A range is listed once, however often liquidity is added to it; another range on the same
    /// pool joins that pool's list, a range on another pool goes into that pool's list
    function test_mintWithRecording_eachRangeOnce_perPool() public {
        _set(vaultA, _key(FEE), MINT);
        _set(vaultA, _key(OTHER_FEE), MINT);

        vm.prank(vaultA);
        lobster.mintWithRecording(_mintParams(FEE, vaultA));
        uint128 once = _v3Liquidity(vaultA, -600, 600);
        vm.recordLogs();
        vm.prank(vaultA);
        lobster.mintWithRecording(_mintParams(FEE, vaultA)); // the same range again
        _noRecordingLogs(vm.getRecordedLogs(), "the same range again");
        _mintWide(vaultA, -1200, 1200);
        vm.prank(vaultA);
        lobster.mintWithRecording(_mintParams(OTHER_FEE, vaultA));

        assertEq(_v3Liquidity(vaultA, -600, 600), 2 * once, "the second mint did not add to the position");
        _assertRanges(vaultA, _key(FEE), _r(-600, 600, -1200, 1200), "FEE pool");
        _assertRanges(vaultA, _key(OTHER_FEE), _r(-600, 600), "OTHER_FEE pool");
    }

    /// @notice A recording mint deletes the ranges of that pool's list that are empty: no liquidity and
    /// nothing left to collect. A burnt range whose tokens are still owed stays; it goes once collected.
    /// A deleted range minted again is listed again.
    function test_mintWithRecording_deletesEmptyRangesOfThePool() public {
        _set(vaultA, _key(FEE), MINT);
        _mintWide(vaultA, -600, 600);
        _mintWide(vaultA, -1200, 1200);
        _mintWide(vaultA, -1800, 1800);

        _burnAll(vaultA, -600, 600); // burnt, not collected: tokens still owed
        _burnAll(vaultA, -1200, 1200);
        _collectAll(vaultA, -1200, 1200); // empty

        // Nothing is deleted until the next recording mint on the pool
        _assertRanges(vaultA, _key(FEE), _r(-600, 600, -1200, 1200, -1800, 1800), "before");

        vm.expectEmit(true, true, false, true, address(lobster));
        emit PositionRecorder.RangeDeleted(vaultA, _key(FEE), -1200, 1200, bytes32(0));
        vm.expectEmit(true, true, false, true, address(lobster));
        emit PositionRecorder.RangeRecorded(vaultA, _key(FEE), -2400, 2400, bytes32(0));
        _mintWide(vaultA, -2400, 2400);
        _assertRanges(vaultA, _key(FEE), _r(-600, 600, -1800, 1800, -2400, 2400), "the empty one deleted");

        // Collected: now empty, deleted by a mint to a range already listed, which is not listed twice
        _collectAll(vaultA, -600, 600);
        vm.recordLogs();
        _mintWide(vaultA, -1800, 1800);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 deleted = 0;
        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(logs[i].topics[0] != PositionRecorder.RangeRecorded.selector, "a listed range recorded again");
            if (logs[i].topics[0] == PositionRecorder.RangeDeleted.selector) deleted++;
        }
        assertEq(deleted, 1, "one RangeDeleted");
        _assertRanges(vaultA, _key(FEE), _r(-1800, 1800, -2400, 2400), "the collected one deleted");

        // Every listed range emptied: the next mint leaves only its own
        _burnAll(vaultA, -1800, 1800);
        _collectAll(vaultA, -1800, 1800);
        _burnAll(vaultA, -2400, 2400);
        _collectAll(vaultA, -2400, 2400);
        _mintWide(vaultA, -1200, 1200);
        _assertRanges(vaultA, _key(FEE), _r(-1200, 1200), "minted again after its deletion");
    }

    /// @notice A burnt range with only one token left to collect is not empty: either token keeps it.
    /// A range below the price holds only token1, one above it only token0.
    function test_mintWithRecording_keepsARangeOwingEitherToken() public {
        _set(vaultA, _key(FEE), MINT);
        int24 tick = _tick(FEE);
        int24 below = ((tick - 6000) / 60) * 60;
        int24 above = ((tick + 6000) / 60) * 60;
        _mintWide(vaultA, below - 600, below); // token1 only
        _mintWide(vaultA, above, above + 600); // token0 only
        _burnAll(vaultA, below - 600, below);
        _burnAll(vaultA, above, above + 600);

        (,,, uint128 owed0, uint128 owed1) =
            IUniswapV3PoolMinimal(_pool(FEE)).positions(keccak256(abi.encodePacked(vaultA, below - 600, below)));
        assertTrue(owed0 == 0 && owed1 > 0, "test bug: the range below owes more than token1");
        (,,, owed0, owed1) =
            IUniswapV3PoolMinimal(_pool(FEE)).positions(keccak256(abi.encodePacked(vaultA, above, above + 600)));
        assertTrue(owed0 > 0 && owed1 == 0, "test bug: the range above owes more than token0");

        _mintWide(vaultA, -600, 600);
        _assertRanges(vaultA, _key(FEE), _r(below - 600, below, above, above + 600, -600, 600), "still owed");

        _collectAll(vaultA, below - 600, below);
        _collectAll(vaultA, above, above + 600);
        _mintWide(vaultA, -600, 600);
        _assertRanges(vaultA, _key(FEE), _r(-600, 600), "collected");
    }

    /// @notice The cleanup only looks at the list it writes to: the caller's, on the pool minted on. Plain
    /// mint cleans up nothing.
    function test_mintWithRecording_cleansOnlyTheCallersListForThePool() public {
        _set(vaultA, _key(FEE), MINT);
        _set(vaultB, _key(FEE), MINT);
        _set(vaultA, _key(OTHER_FEE), MINT);
        _mintWide(vaultA, -600, 600);
        vm.prank(vaultA);
        lobster.mintWithRecording(_mintParams(OTHER_FEE, vaultA));
        _burnAll(vaultA, -600, 600);
        _collectAll(vaultA, -600, 600);

        vm.recordLogs();
        vm.prank(vaultA);
        lobster.mint(_mintParams(FEE, vaultA));
        _noRecordingLogs(vm.getRecordedLogs(), "plain mint");
        _mintWide(vaultB, -1200, 1200);
        vm.prank(vaultA);
        lobster.mintWithRecording(_mintParams(OTHER_FEE, vaultA));

        // vault A's empty range is still there: no recording mint of vault A on that pool since
        _assertRanges(vaultA, _key(FEE), _r(-600, 600), "vault A, FEE pool");
        _assertRanges(vaultB, _key(FEE), _r(-1200, 1200), "vault B, FEE pool");
        _assertRanges(vaultA, _key(OTHER_FEE), _r(-600, 600), "vault A, OTHER_FEE pool");
    }

    /// @notice A mint that fails records nothing, whatever the reason: no permission, no band, out of the
    /// band, a recipient other than the caller, slippage, an expired deadline
    function test_mintWithRecording_failedMintRecordsNothing() public {
        MintParams memory other = _mintParams(FEE, vaultB);
        MintParams memory slippage = _mintParams(FEE, vaultA);
        slippage.amount0Min = type(uint128).max;
        MintParams memory expired = _mintParams(FEE, vaultA);
        expired.deadline = block.timestamp - 1;

        vm.startPrank(vaultA);
        vm.expectRevert(IProxyErrors.PoolNotAllowed.selector);
        lobster.mintWithRecording(_mintParams(FEE, vaultA));
        vm.stopPrank();

        _set(vaultA, _key(FEE), MINT);
        int24 tick = _tick(FEE);
        _band(vaultA, tick + 1, tick + 100);
        vm.prank(vaultA);
        vm.expectRevert(IProxyErrors.PriceOutOfBand.selector);
        lobster.mintWithRecording(_mintParams(FEE, vaultA));
        _band(vaultA, 0, 0);
        vm.prank(vaultA);
        vm.expectRevert(IProxyErrors.PriceBandNotSet.selector);
        lobster.mintWithRecording(_mintParams(FEE, vaultA));

        _anyPrice(vaultA, _key(FEE));
        vm.startPrank(vaultA);
        vm.expectRevert(IProxyErrors.RecipientMustBeCaller.selector);
        lobster.mintWithRecording(other);
        vm.expectRevert(IProxyErrors.PriceSlippageCheck.selector);
        lobster.mintWithRecording(slippage);
        vm.expectRevert(IProxyErrors.TransactionTooOld.selector);
        lobster.mintWithRecording(expired);
        vm.stopPrank();

        assertEq(lobster.rangesOf(vaultA, _key(FEE)).length, 0, "a failed mint was recorded");
        assertEq(lobster.rangesOf(vaultB, _key(FEE)).length, 0, "the named recipient got a record");
    }

    /// @notice Plain mint records nothing; records belong to the vault that minted
    function test_mintWithRecording_onlyRecordsForTheCaller() public {
        _set(vaultA, _key(FEE), MINT);
        _set(vaultB, _key(FEE), MINT);

        vm.prank(vaultA);
        lobster.mint(_mintParams(FEE, vaultA));
        assertEq(lobster.rangesOf(vaultA, _key(FEE)).length, 0, "plain mint recorded");

        vm.prank(vaultB);
        lobster.mintWithRecording(_mintParams(FEE, vaultB));
        assertEq(lobster.rangesOf(vaultA, _key(FEE)).length, 0, "vault B's mint was recorded for vault A");
        assertEq(lobster.rangesOf(vaultB, _key(FEE)).length, 1, "vault B's record");
    }

    // --- swaps -----------------------------------------------------------------

    /// @notice A registered pool without a band cannot be swapped on, exact input or output: refused
    /// before anything runs, the pool is not even read
    function test_swap_withoutPriceBand_reverts() public {
        _set(vaultA, _key(FEE), SWAP);
        _band(vaultA, 0, 0);
        bytes[4] memory c = _calls(FEE, vaultA);
        vm.expectCall(_pool(FEE), "", 0);
        // c[1] = exact input, c[2] = exact output
        for (uint256 i = 1; i < 3; i++) {
            vm.prank(vaultA);
            (bool ok, bytes memory ret) = address(lobster).call(c[i]);
            assertFalse(ok, "swapped without a band");
            assertEq(ret, abi.encodeWithSelector(IProxyErrors.PriceBandNotSet.selector));
        }
    }

    /// @notice swap checks the registry before the band
    function test_swap_registryIsCheckedBeforeTheBand() public {
        _band(vaultA, 0, 0);
        _expectSwapRevert(
            vaultA,
            SwapCalldata.encode(block.timestamp, _legs(_exactIn(true, FEE))),
            IProxyErrors.PoolNotAllowed.selector
        );
    }

    /// @notice The price is already outside the band when the swap starts: refused before the pool
    /// is asked to swap
    function test_swap_startingOutsideBand_reverts() public {
        _set(vaultA, _key(FEE), SWAP);
        int24 tick = _tick(FEE);
        _band(vaultA, tick + 1, tick + 1000);
        bytes[4] memory c = _calls(FEE, vaultA);
        vm.expectCall(_pool(FEE), abi.encodeWithSelector(IUniswapV3PoolMinimal.swap.selector), 0);
        for (uint256 i = 1; i < 3; i++) {
            vm.prank(vaultA);
            (bool ok, bytes memory ret) = address(lobster).call(c[i]);
            assertFalse(ok, "swapped outside the band");
            assertEq(ret, abi.encodeWithSelector(IProxyErrors.PriceOutOfBand.selector));
        }
    }

    /// @notice The swap itself would push the price out of the band: refused, nothing moves
    function test_swap_endingOutsideBand_reverts() public {
        _set(vaultA, _key(FEE), SWAP);
        int24 tick = _tick(FEE);
        _band(vaultA, tick - 100, tick + 100);
        uint256[4] memory before = _balances(vaultA);

        // 200e18 in moves the price far below tick - 100
        _expectSwapRevert(
            vaultA,
            SwapCalldata.encode(block.timestamp, _legs(_v3Leg(true, FEE, false, 200e18, 0))),
            IProxyErrors.PriceOutOfBand.selector
        );
        _expectSwapRevert(
            vaultA,
            SwapCalldata.encode(block.timestamp, _legs(_exactOut(true, FEE, 150e18))),
            IProxyErrors.PriceOutOfBand.selector
        );

        uint256[4] memory afterAll = _balances(vaultA);
        for (uint256 i = 0; i < 4; i++) {
            assertEq(afterAll[i], before[i], "a refused swap moved funds");
        }
    }

    /// @notice Swaps that keep the price inside the band go through
    function test_swap_insideBand_succeeds() public {
        _set(vaultA, _key(FEE), SWAP);
        int24 tick = _tick(FEE);
        _band(vaultA, tick - 100, tick + 100);

        _swap(vaultA, _legs(_exactIn(true, FEE))); // 1e18: a few ticks at most
        _swap(vaultA, _legs(_exactOut(false, FEE, 1e18)));
        assertGe(_tick(FEE), tick - 100);
        assertLe(_tick(FEE), tick + 100);
    }

    /// @notice Both band edges are inclusive for swaps, as for mint, at tick 0, at a negative and at a
    /// positive tick (the band travels sign-extended through the call's plan): a swap starting and
    /// ending exactly on an edge goes through, a band one tick away from the price is refused
    function test_swap_bandEdgesAreInclusive() public {
        _set(vaultA, _key(FEE), SWAP);
        _set(vaultB, _key(FEE), SWAP);
        // token1 -> token0, small enough that the price rises without leaving its tick
        bytes memory tiny = SwapCalldata.encode(block.timestamp, _legs(_v3Leg(false, FEE, false, 1e9, 0)));

        for (uint256 round = 0; round < 3; round++) {
            if (round == 1) {
                _swap(vaultB, _legs(_v3Leg(true, FEE, false, 200e18, 0))); // to a negative tick
            } else if (round == 2) {
                _swap(vaultB, _legs(_v3Leg(false, FEE, false, 400e18, 0))); // back up, past 0, to a positive tick
            }
            int24 tick = _tick(FEE);
            if (round == 1) assertLt(tick, -100, "the price did not move down; test proves nothing");
            if (round == 2) assertGt(tick, 100, "the price did not move up; test proves nothing");

            _band(vaultA, tick, tick + 1); // the price is on the lower edge
            vm.prank(vaultA);
            lobster.swap(tiny);
            assertEq(_tick(FEE), tick, "the swap left its tick; test proves nothing");

            _band(vaultA, tick - 1, tick); // the price is on the upper edge
            vm.prank(vaultA);
            lobster.swap(tiny);
            assertEq(_tick(FEE), tick, "the swap left its tick; test proves nothing");

            _band(vaultA, tick + 1, tick + 2); // the price is one tick below the band
            _expectSwapRevert(vaultA, tiny, IProxyErrors.PriceOutOfBand.selector);
            _band(vaultA, tick - 2, tick - 1); // ...one tick above it
            _expectSwapRevert(vaultA, tiny, IProxyErrors.PriceOutOfBand.selector);
        }
    }

    /// @notice Fuzzed over the band, the starting price (tick 0, or a negative or a positive tick
    /// another vault's swap moved it to), the direction, the kind and the size of the leg: a swap goes
    /// through if and only if the pool's tick is inside the vault's band both before and after it, and
    /// a refused swap leaves the price where it was
    function testFuzz_swap_bandHoldsAtBothEnds(
        int24 lo,
        int24 hi,
        uint256 amount,
        bool zeroForOne,
        bool exactOut,
        bool moveFirst,
        bool moveUp
    )
        public
    {
        _set(vaultA, _key(FEE), SWAP);
        if (moveFirst) {
            _set(vaultB, _key(FEE), SWAP);
            // token0 in pushes the price down, to a negative tick; token1 in pushes it up, to a positive one
            _swap(vaultB, _legs(_v3Leg(!moveUp, FEE, false, 200e18, 0)));
            int24 moved = _tick(FEE);
            if (moveUp) assertGt(moved, 100, "the price did not move up; test proves nothing");
            else assertLt(moved, -100, "the price did not move down; test proves nothing");
        }
        int24 start = _tick(FEE);
        lo = SafeCast.toInt24(bound(int256(lo), int256(start) - 500, int256(start) + 500));
        hi = SafeCast.toInt24(bound(int256(hi), int256(lo) + 1, int256(start) + 501));
        amount = bound(amount, 1e15, 300e18);
        SwapCalldata.Leg memory leg = _v3Leg(zeroForOne, FEE, exactOut, amount, exactOut ? type(uint128).max : 0);
        bytes memory data = SwapCalldata.encode(block.timestamp, _legs(leg));
        _band(vaultA, lo, hi);

        vm.prank(vaultA);
        (bool ok, bytes memory ret) = address(lobster).call(abi.encodeCall(UniswapSwapProxy.swap, (data)));
        int24 end = _tick(FEE);
        bool startInside = start >= lo && start <= hi;
        if (ok) {
            assertTrue(startInside && end >= lo && end <= hi, "swapped with the price outside the band");
            return;
        }
        assertEq(ret, abi.encodeWithSelector(IProxyErrors.PriceOutOfBand.selector), "refused for another reason");
        assertEq(end, start, "a refused swap moved the price");

        // where the swap would have left the price: the same leg, with a band that allows any price
        _anyPrice(vaultA, _key(FEE));
        vm.prank(vaultA);
        lobster.swap(data);
        end = _tick(FEE);
        assertFalse(startInside && end >= lo && end <= hi, "refused although inside the band at both ends");
    }

    /// @notice A sandwich: the attacker pushes the price out of the vault's band first. The vault's
    /// swap is refused instead of trading at the manipulated price.
    function test_swap_afterManipulation_isRefused() public {
        _set(vaultA, _key(FEE), SWAP);
        int24 tick = _tick(FEE);
        _band(vaultA, tick - 100, tick + 100);

        // the attacker (vault B, any price allowed) front-runs
        _set(vaultB, _key(FEE), SWAP);
        _swap(vaultB, _legs(_v3Leg(true, FEE, false, 200e18, 0)));

        // the victim's swap, with no slippage protection of its own, is refused
        _expectSwapRevert(
            vaultA,
            SwapCalldata.encode(block.timestamp, _legs(_exactIn(true, FEE))),
            IProxyErrors.PriceOutOfBand.selector
        );
    }

    /// @notice Each leg of a multi-leg call is band-checked: the first leg stays inside the band, the
    /// second pushes the price out of it once it has run, and the whole call is undone
    function test_batch_legsAreBandChecked() public {
        _set(vaultA, _key(FEE), SWAP);
        int24 tick = _tick(FEE);
        _band(vaultA, tick - 100, tick + 100);

        SwapCalldata.Leg[] memory legs = _legs(_exactIn(true, FEE), _v3Leg(true, FEE, false, 200e18, 0));
        uint256[4] memory before = _balances(vaultA);

        // both legs run (the second is refused by the check after it), then everything is undone
        vm.expectCall(_pool(FEE), abi.encodeWithSelector(IUniswapV3PoolMinimal.swap.selector), 2);
        _expectSwapRevert(vaultA, SwapCalldata.encode(block.timestamp, legs), IProxyErrors.PriceOutOfBand.selector);

        uint256[4] memory afterAll = _balances(vaultA);
        for (uint256 i = 0; i < 4; i++) {
            assertEq(afterAll[i], before[i], "the batch's first leg was not undone");
        }
    }

    /// @notice Every leg of a call is checked before the first one runs: a later leg on a pool the vault
    /// never registered (V3 or V4, paid by the vault or HELD), on a registered pool without a band, or
    /// cut short, stops the call before any pool is called or the PoolManager unlocked
    function test_batch_everyLegIsCheckedBeforeAnyRuns() public {
        _set(vaultA, _key(FEE), SWAP);
        SwapCalldata.Leg memory first = _exactIn(true, FEE); // registered, with a band: would run
        SwapCalldata.Leg memory parked = _exactIn(true, FEE);
        parked.park = true;
        vm.expectCall(_pool(FEE), "", 0);
        vm.expectCall(_pool(OTHER_FEE), "", 0);
        vm.expectCall(poolManager, "", 0);

        bytes4 notAllowed = IProxyErrors.PoolNotAllowed.selector;
        uint256 d = block.timestamp;
        _expectSwapRevert(vaultA, SwapCalldata.encode(d, _legs(first, _exactIn(false, OTHER_FEE))), notAllowed);
        _expectSwapRevert(
            vaultA, SwapCalldata.encode(d, _legs(first, _v4Leg(address(token1), address(token0), false))), notAllowed
        );
        _expectSwapRevert(vaultA, SwapCalldata.encode(d, _legs(parked, _held(_exactIn(false, OTHER_FEE)))), notAllowed);
        _expectSwapRevert(
            vaultA,
            SwapCalldata.encode(d, _legs(parked, _held(_v4Leg(address(token1), address(token0), false)))),
            notAllowed
        );

        _set(vaultA, _key(OTHER_FEE), SWAP);
        _bandOn(vaultA, _key(OTHER_FEE), 0, 0);
        _expectSwapRevert(
            vaultA,
            SwapCalldata.encode(d, _legs(first, _exactIn(false, OTHER_FEE))),
            IProxyErrors.PriceBandNotSet.selector
        );

        // a second leg cut short after its first byte
        _expectSwapRevert(
            vaultA, bytes.concat(SwapCalldata.encode(d, _legs(first)), hex"00"), IProxyErrors.MalformedSwap.selector
        );
    }
}
