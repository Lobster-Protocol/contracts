// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.20;

import "forge-std/Test.sol";
import {UniswapV3ProxyHarness} from "./Mocks/UniswapV3ProxyHarness.sol";
import {LobsterProxy} from "../src/LobsterProxy.sol";
import {SwapCalldata} from "./helpers/SwapCalldata.sol";
import {SwapFlags} from "../src/libraries/SwapFlags.sol";
import {
    MintParams,
    MintCallbackData,
    IUniswapV3MintCallback
} from "../src/interfaces/uniswapV3/IUniswapV3MintCallback.sol";
import {IUniswapV3SwapCallback} from "../src/interfaces/uniswapV3/IUniswapV3SwapCallback.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "./Mocks/MockERC20.sol";
import {IUniswapV3PoolMinimal} from "../src/interfaces/uniswapV3/IUniswapV3PoolMinimal.sol";
import {UniswapV3Infra} from "./Mocks/uniswapV3/UniswapV3Infra.sol";
import {IUniswapV3FactoryMinimal} from "../src/interfaces/uniswapV3/IUniswapV3FactoryMinimal.sol";
import {IPoolManagerMinimal} from "../src/interfaces/uniswapV4/IPoolManagerMinimal.sol";
import {PoolManagerDeployer} from "./Mocks/uniswapV4/PoolManagerDeployer.sol";
import {LiquidityAmounts} from "../src/libraries/uniswapV3/LiquidityAmounts.sol";
import {TickMath} from "../src/libraries/uniswapV3/TickMath.sol";
import {PoolAddress} from "../src/libraries/uniswapV3/PoolAddress.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IProxyErrors} from "../src/interfaces/IProxyErrors.sol";

/// @notice A token that, the first time a pool pays it out, calls `target` with `forgedCall` before
/// transferring: mid-swap, while the proxy waits for the pool's callback. Optionally it makes the
/// call as `impersonating` (through the cheatcode), to stand for any other address.
contract CallbackForgingToken is MockERC20 {
    Vm private constant VM = Vm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    address public target;
    address public impersonating;
    bytes public forgedCall;
    bool public attempted;
    bool public forgerySucceeded;
    bytes public forgeryRevertData;

    function arm(address target_, bytes calldata forgedCall_, address impersonating_) external {
        target = target_;
        forgedCall = forgedCall_;
        impersonating = impersonating_;
    }

    function transfer(address to, uint256 value) public override returns (bool) {
        if (target != address(0) && !attempted) {
            attempted = true;
            if (impersonating != address(0)) VM.prank(impersonating);
            (bool ok, bytes memory ret) = target.call(forgedCall);
            forgerySucceeded = ok;
            forgeryRevertData = ret;
        }
        return super.transfer(to, value);
    }
}

/// @notice Stands in (through `vm.etch`) for a pool that calls the swap callback a second time during
/// the same swap, which no pool deployed by the canonical factory does. It takes exact input only and
/// pays nothing out, and records how the second callback went.
contract DoubleCallbackPool {
    bool public secondCallbackSucceeded;
    bytes public secondCallbackRevertData;

    function slot0() external pure returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (2 ** 96, 0, 0, 1, 1, 0, true);
    }

    function swap(
        address,
        bool,
        int256 amountSpecified,
        uint160,
        bytes calldata data
    )
        external
        returns (int256 amount0, int256 amount1)
    {
        IUniswapV3SwapCallback(msg.sender).uniswapV3SwapCallback(amountSpecified, 0, data);
        try IUniswapV3SwapCallback(msg.sender).uniswapV3SwapCallback(amountSpecified, 0, data) {
            secondCallbackSucceeded = true;
        } catch (bytes memory reason) {
            secondCallbackRevertData = reason;
        }
        return (amountSpecified, 0);
    }
}

/// @notice A contract account with no receive and no fallback, so it cannot be sent plain ETH, as a
/// vault or smart account may well be written. It calls `swap` itself, with the ETH it is given.
contract NoEthReceiver {
    function swap(LobsterProxy lobster, bytes calldata data) external payable returns (uint256[] memory) {
        return lobster.swap{value: msg.value}(data);
    }
}

/// @notice The Uniswap V3 mechanics of the proxy, against a real V3 factory and real pools.
/// @dev Two contracts under test, split the way the code is:
/// - mints go through {UniswapV3ProxyHarness}: the mint body and callback without the registry, so any
///   pool and any recipient but address(0) and the harness itself. The callback charges the account
///   holding the harness's lock, the caller of `mint`, never a payer named in its data;
/// - swaps go through {LobsterProxy-swap}, as one-leg calls built with {SwapCalldata} (two legs where a
///   property needs PARK and HELD). The swapping accounts register every pool they use with
///   PERMISSION_SWAP and a band that allows any price: registry and band rules have their own suite
///   (LobsterProxy.t.sol), this one tests what a V3 leg does. The proxy is deployed on the same factory
///   and on a real PoolManager, which V3 legs never use.
/// The old single-swap entry points took a recipient, uint256 amounts and a uint256 deadline. A leg has
/// no recipient (the output goes to the caller), its amounts are 128-bit fields and the deadline is a
/// uint32 in the call's header: the recipient and amount-wrapping tests are replaced by tests of the
/// guarantees that took their place.
contract UniswapV3ProxyTest is Test {
    UniswapV3ProxyHarness public proxy;
    LobsterProxy public lobster;
    address public manager;
    IUniswapV3FactoryMinimal public factory;
    MockERC20 public token0;
    MockERC20 public token1;
    IUniswapV3PoolMinimal public pool;

    address public user = makeAddr("user");
    /// @notice An outsider: the recipient of the mint tests' positions, and the address the old swap
    /// tests sent outputs to. A swap leg cannot name it, so the swap tests check it never receives.
    address public recipient = makeAddr("recipient");

    uint24 constant FEE = 3000;
    int24 constant TICK_LOWER = -60;
    int24 constant TICK_UPPER = 60;
    int24 constant TICK_LOWER_WIDE = -6000;
    int24 constant TICK_UPPER_WIDE = 6000;
    uint256 constant AMOUNT_DESIRED = 1000e18;
    uint256 constant AMOUNT_MIN = 900e18;
    uint256 constant SWAP_AMOUNT = 10e18;
    /// @dev PoolRegistry.PERMISSION_SWAP
    uint8 constant SWAP = 2;
    /// @dev No token0 / token1 pool was ever created at this fee
    uint24 constant UNCREATED_FEE = 10000;
    /// @dev What a forged swap callback claims the pool is owed
    int256 constant FORGED_AMOUNT = 1e18;

    function setUp() public {
        token0 = new MockERC20();
        token1 = new MockERC20();

        if (address(token0) > address(token1)) {
            (token0, token1) = (token1, token0);
        }

        UniswapV3Infra uniswapV3 = new UniswapV3Infra();
        (IUniswapV3FactoryMinimal factory_,,,) = uniswapV3.deploy();
        factory = factory_;

        uint160 initialSqrtPriceX96 = 2 ** 96; // 1:1 price

        pool = uniswapV3.createPoolAndInitialize(factory, address(token0), address(token1), FEE, initialSqrtPriceX96);

        proxy = new UniswapV3ProxyHarness(address(factory));
        manager = PoolManagerDeployer.deploy(address(this));
        lobster = new LobsterProxy(address(factory), manager);

        vm.deal(user, 10_000 ether);
        token0.mint(user, AMOUNT_DESIRED * 10);
        token1.mint(user, AMOUNT_DESIRED * 10);

        vm.startPrank(user);
        token0.approve(address(proxy), type(uint256).max);
        token1.approve(address(proxy), type(uint256).max);
        token0.approve(address(lobster), type(uint256).max);
        token1.approve(address(lobster), type(uint256).max);
        vm.stopPrank();

        _allow(user, address(pool));
    }

    // ---------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------

    /// @dev Mirrors the proxy's liquidity + amount computation so we can assert exact expected values
    function _computeExpectedMintAmounts(
        int24 tickLower,
        int24 tickUpper,
        uint256 amount0Desired,
        uint256 amount1Desired
    )
        internal
        view
        returns (uint128 liquidity, uint256 expectedAmount0, uint256 expectedAmount1)
    {
        (uint160 sqrtPriceX96,,,,,,) = pool.slot0();
        uint160 sqrtRatioAX96 = TickMath.getSqrtRatioAtTick(tickLower);
        uint160 sqrtRatioBX96 = TickMath.getSqrtRatioAtTick(tickUpper);

        liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96, sqrtRatioAX96, sqrtRatioBX96, amount0Desired, amount1Desired
        );

        (expectedAmount0, expectedAmount1) =
            LiquidityAmounts.getAmountsForLiquidity(sqrtPriceX96, sqrtRatioAX96, sqrtRatioBX96, liquidity);
    }

    /// @dev Mints wide-range liquidity so swaps have depth; returns actual amounts used
    function _mintDefaultLiquidity() internal returns (uint256 amount0, uint256 amount1) {
        MintParams memory params = MintParams({
            token0: address(token0),
            token1: address(token1),
            fee: FEE,
            tickLower: TICK_LOWER_WIDE,
            tickUpper: TICK_UPPER_WIDE,
            amount0Desired: AMOUNT_DESIRED,
            amount1Desired: AMOUNT_DESIRED,
            amount0Min: 0,
            amount1Min: 0,
            recipient: user,
            deadline: vm.getBlockTimestamp() + 3600
        });

        vm.prank(user);
        (amount0, amount1) = proxy.mintUnchecked(params);
    }

    /// @dev Registers the V3 pool at `v3Pool` (deployed or not) for `who`'s swaps, with a price band
    /// that allows any price
    function _allow(address who, address v3Pool) internal {
        bytes32 key = lobster.v3Key(v3Pool);
        bytes32[] memory keys = new bytes32[](1);
        keys[0] = key;
        uint8[] memory permissions = new uint8[](1);
        permissions[0] = SWAP;
        vm.prank(who);
        lobster.setPools(keys, permissions);
        vm.prank(who);
        lobster.setPriceBand(key, TickMath.MIN_TICK, TickMath.MAX_TICK);
    }

    /// @dev The CREATE2 address of the V3 pool of `tokenA`, `tokenB` and `fee`, deployed or not
    function _v3PoolAddress(address tokenA, address tokenB, uint24 fee) internal view returns (address) {
        return PoolAddress.computeAddress(address(factory), PoolAddress.getPoolKey(tokenA, tokenB, fee));
    }

    /// @dev An exact-input V3 leg on the FEE pool, without a price limit
    function _exactIn(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOutMinimum
    )
        internal
        pure
        returns (SwapCalldata.Leg memory leg)
    {
        leg.tokenIn = tokenIn;
        leg.tokenOut = tokenOut;
        leg.fee = FEE;
        leg.amount = SafeCast.toUint128(amountIn);
        leg.bound = SafeCast.toUint128(amountOutMinimum);
    }

    /// @dev An exact-output V3 leg on the FEE pool, without a price limit
    function _exactOut(
        address tokenIn,
        address tokenOut,
        uint256 amountOut,
        uint256 amountInMaximum
    )
        internal
        pure
        returns (SwapCalldata.Leg memory leg)
    {
        leg = _exactIn(tokenIn, tokenOut, amountOut, amountInMaximum);
        leg.exactOut = true;
    }

    /// @dev `leg` with a price limit (the PRICE_LIMIT flag)
    function _limited(
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

    function _one(SwapCalldata.Leg memory leg) internal pure returns (SwapCalldata.Leg[] memory legs) {
        legs = new SwapCalldata.Leg[](1);
        legs[0] = leg;
    }

    function _two(
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

    /// @dev The `data` of a one-leg `swap`, valid for an hour
    function _data(SwapCalldata.Leg memory leg) internal view returns (bytes memory) {
        return SwapCalldata.encode(vm.getBlockTimestamp() + 3600, _one(leg));
    }

    /// @dev Hand-written `data`: the header (valid for an hour, two tokens), the token table
    /// [token0, token1] and then `legs`, byte for byte
    function _rawData(bytes memory legs) internal view returns (bytes memory) {
        return bytes.concat(
            bytes4(SafeCast.toUint32(vm.getBlockTimestamp() + 3600)),
            bytes1(0x02),
            bytes20(address(token0)),
            bytes20(address(token1)),
            legs
        );
    }

    /// @dev `who` runs `leg` as a one-leg `swap`; returns its single amount
    function _swap(address who, SwapCalldata.Leg memory leg) internal returns (uint256) {
        return _swapData(who, _data(leg));
    }

    /// @dev `who` calls `swap(data)` for a one-leg call; returns its single amount
    function _swapData(address who, bytes memory data) internal returns (uint256) {
        vm.prank(who);
        uint256[] memory amounts = lobster.swap(data);
        assertEq(amounts.length, 1, "a one-leg swap returns one amount");
        return amounts[0];
    }

    /// @dev `who` calls `swap(data)`, which must revert with exactly `reason`
    function _expectSwapRevert(address who, bytes memory data, bytes memory reason) internal {
        vm.prank(who);
        vm.expectRevert(reason);
        lobster.swap(data);
    }

    function _proxyError(bytes4 selector) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(selector);
    }

    /// @dev A `require(..., reason)` revert: TransferHelper's ("STF"), the V3 pool's ("SPL", "AS")
    function _stringError(string memory reason) internal pure returns (bytes memory) {
        return abi.encodeWithSignature("Error(string)", reason);
    }

    /// @dev Swap callback data in the proxy's own format (tokenIn | mode | credit), asking it to pay
    /// `tokenIn` from the account holding its lock, as a plain leg does
    function _callbackData(address tokenIn) internal pure returns (bytes memory) {
        return abi.encodePacked(tokenIn, bytes1(0), uint256(0));
    }

    /// @dev The head of the `pool.swap` call a leg must make: recipient, direction, amountSpecified
    /// (V3: positive is exact input), sqrtPriceLimitX96. A prefix, for `vm.expectCall`.
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

    function _assertProxyHoldsNothing() internal view {
        assertEq(token0.balanceOf(address(lobster)), 0, "proxy holds token0");
        assertEq(token1.balanceOf(address(lobster)), 0, "proxy holds token1");
        assertEq(address(lobster).balance, 0, "proxy holds ETH");
    }

    /// @dev Executes a one-leg exact-input swap via snapshot, returns the result without persisting state
    function _probeExactInput(address tokenIn, address tokenOut, uint256 amountIn)
        internal
        returns (uint256 amountOut)
    {
        uint256 snap = vm.snapshotState();
        amountOut = _swap(user, _exactIn(tokenIn, tokenOut, amountIn, 0));
        vm.revertToState(snap);
    }

    /// @dev Executes a one-leg exact-output swap via snapshot, returns the amountIn without persisting state
    function _probeExactOutput(
        address tokenIn,
        address tokenOut,
        uint256 amountOut
    )
        internal
        returns (uint256 amountIn)
    {
        uint256 snap = vm.snapshotState();
        amountIn = _swap(user, _exactOut(tokenIn, tokenOut, amountOut, type(uint128).max));
        vm.revertToState(snap);
    }

    // ===========================================================================
    // CONSTRUCTOR
    // ===========================================================================

    /// @notice The mint harness derives pools from the factory it was built with
    function testConstructor() public view {
        assertEq(proxy.UNI_V3_FACTORY(), address(factory));
    }

    /// @notice The swapping proxy is built on the same factory, so the pool address it derives for a
    /// leg is the one the factory deployed, and on a real PoolManager
    function testLobsterProxyConstructor() public view {
        assertEq(lobster.UNI_V3_FACTORY(), address(factory));
        assertEq(address(lobster.POOL_MANAGER()), manager);
        assertEq(lobster.PERMISSION_SWAP(), SWAP, "SWAP is not PoolRegistry.PERMISSION_SWAP");
        assertEq(_v3PoolAddress(address(token0), address(token1), FEE), address(pool), "CREATE2 derivation differs");
    }

    // ===========================================================================
    // MINT -- happy paths
    // ===========================================================================

    /// @notice A narrow mint charges its caller exactly the computed amounts and creates the expected
    /// position for the recipient
    function testMintSuccess() public {
        uint256 t0Before = token0.balanceOf(user);
        uint256 t1Before = token1.balanceOf(user);

        (uint128 expectedLiq, uint256 expectedAmt0, uint256 expectedAmt1) =
            _computeExpectedMintAmounts(TICK_LOWER, TICK_UPPER, AMOUNT_DESIRED, AMOUNT_DESIRED);

        MintParams memory params = MintParams({
            token0: address(token0),
            token1: address(token1),
            fee: FEE,
            tickLower: TICK_LOWER,
            tickUpper: TICK_UPPER,
            amount0Desired: AMOUNT_DESIRED,
            amount1Desired: AMOUNT_DESIRED,
            amount0Min: AMOUNT_MIN,
            amount1Min: AMOUNT_MIN,
            recipient: recipient,
            deadline: block.timestamp + 3600
        });

        vm.prank(user);
        (uint256 amount0, uint256 amount1) = proxy.mintUnchecked(params);

        // Amounts match the precomputed expectation (rounding tolerance of 1 wei)
        assertApproxEqAbs(amount0, expectedAmt0, 1, "amount0 should match expected");
        assertApproxEqAbs(amount1, expectedAmt1, 1, "amount1 should match expected");

        // At 1:1 price with symmetric ticks, amounts should be nearly equal
        assertApproxEqAbs(amount0, amount1, 2, "amounts should be nearly equal at 1:1 price");

        // Exact balance accounting
        assertEq(token0.balanceOf(user), t0Before - amount0);
        assertEq(token1.balanceOf(user), t1Before - amount1);

        // Pool received exactly those tokens
        assertEq(token0.balanceOf(address(pool)), amount0);
        assertEq(token1.balanceOf(address(pool)), amount1);

        // Liquidity was created in the pool at the expected position
        bytes32 posKey = keccak256(abi.encodePacked(address(recipient), TICK_LOWER, TICK_UPPER));
        (uint128 posLiq,,,,) = pool.positions(posKey);
        assertEq(posLiq, expectedLiq, "position liquidity should match expected");
    }

    /// @notice A wide mint: same exact accounting and position
    function testMintWideTicks() public {
        uint256 t0Before = token0.balanceOf(user);
        uint256 t1Before = token1.balanceOf(user);

        (uint128 expectedLiq, uint256 expectedAmt0, uint256 expectedAmt1) =
            _computeExpectedMintAmounts(TICK_LOWER_WIDE, TICK_UPPER_WIDE, AMOUNT_DESIRED, AMOUNT_DESIRED);

        MintParams memory params = MintParams({
            token0: address(token0),
            token1: address(token1),
            fee: FEE,
            tickLower: TICK_LOWER_WIDE,
            tickUpper: TICK_UPPER_WIDE,
            amount0Desired: AMOUNT_DESIRED,
            amount1Desired: AMOUNT_DESIRED,
            amount0Min: 0,
            amount1Min: 0,
            recipient: recipient,
            deadline: block.timestamp + 3600
        });

        vm.prank(user);
        (uint256 amount0, uint256 amount1) = proxy.mintUnchecked(params);

        assertApproxEqAbs(amount0, expectedAmt0, 1);
        assertApproxEqAbs(amount1, expectedAmt1, 1);
        assertEq(token0.balanceOf(user), t0Before - amount0);
        assertEq(token1.balanceOf(user), t1Before - amount1);

        bytes32 posKey = keccak256(abi.encodePacked(address(recipient), TICK_LOWER_WIDE, TICK_UPPER_WIDE));
        (uint128 posLiq,,,,) = pool.positions(posKey);
        assertEq(posLiq, expectedLiq);
    }

    /// @notice The caller, who pays, may mint to itself
    function testMintToSelfAsRecipient() public {
        (uint128 expectedLiq, uint256 expectedAmt0, uint256 expectedAmt1) =
            _computeExpectedMintAmounts(TICK_LOWER, TICK_UPPER, AMOUNT_DESIRED, AMOUNT_DESIRED);

        MintParams memory params = MintParams({
            token0: address(token0),
            token1: address(token1),
            fee: FEE,
            tickLower: TICK_LOWER,
            tickUpper: TICK_UPPER,
            amount0Desired: AMOUNT_DESIRED,
            amount1Desired: AMOUNT_DESIRED,
            amount0Min: 0,
            amount1Min: 0,
            recipient: user,
            deadline: block.timestamp + 3600
        });

        vm.prank(user);
        (uint256 amount0, uint256 amount1) = proxy.mintUnchecked(params);

        assertApproxEqAbs(amount0, expectedAmt0, 1);
        assertApproxEqAbs(amount1, expectedAmt1, 1);

        bytes32 posKey = keccak256(abi.encodePacked(address(user), TICK_LOWER, TICK_UPPER));
        (uint128 posLiq,,,,) = pool.positions(posKey);
        assertEq(posLiq, expectedLiq);
    }

    /// @notice Two positions on the same pool are independent and each gets its exact liquidity
    function testMintMultiplePositionsSamePool() public {
        // First mint -- narrow ticks
        (uint128 expectedLiq1,,) = _computeExpectedMintAmounts(TICK_LOWER, TICK_UPPER, AMOUNT_DESIRED, AMOUNT_DESIRED);

        MintParams memory params1 = MintParams({
            token0: address(token0),
            token1: address(token1),
            fee: FEE,
            tickLower: TICK_LOWER,
            tickUpper: TICK_UPPER,
            amount0Desired: AMOUNT_DESIRED,
            amount1Desired: AMOUNT_DESIRED,
            amount0Min: 0,
            amount1Min: 0,
            recipient: user,
            deadline: block.timestamp + 3600
        });

        vm.prank(user);
        proxy.mintUnchecked(params1);

        uint256 poolBal0After1 = token0.balanceOf(address(pool));
        uint256 poolBal1After1 = token1.balanceOf(address(pool));

        // Second mint -- wide ticks
        (uint128 expectedLiq2, uint256 expectedAmt0_2, uint256 expectedAmt1_2) =
            _computeExpectedMintAmounts(TICK_LOWER_WIDE, TICK_UPPER_WIDE, AMOUNT_DESIRED, AMOUNT_DESIRED);

        MintParams memory params2 = MintParams({
            token0: address(token0),
            token1: address(token1),
            fee: FEE,
            tickLower: TICK_LOWER_WIDE,
            tickUpper: TICK_UPPER_WIDE,
            amount0Desired: AMOUNT_DESIRED,
            amount1Desired: AMOUNT_DESIRED,
            amount0Min: 0,
            amount1Min: 0,
            recipient: user,
            deadline: block.timestamp + 3600
        });

        vm.prank(user);
        (uint256 amount0Second, uint256 amount1Second) = proxy.mintUnchecked(params2);

        // Second mint amounts match expected
        assertApproxEqAbs(amount0Second, expectedAmt0_2, 1);
        assertApproxEqAbs(amount1Second, expectedAmt1_2, 1);

        // Pool balance increased by exactly the second mint amounts
        assertEq(token0.balanceOf(address(pool)), poolBal0After1 + amount0Second);
        assertEq(token1.balanceOf(address(pool)), poolBal1After1 + amount1Second);

        // Both positions exist with correct liquidity
        bytes32 posKey1 = keccak256(abi.encodePacked(address(user), TICK_LOWER, TICK_UPPER));
        (uint128 liq1,,,,) = pool.positions(posKey1);
        assertEq(liq1, expectedLiq1);

        bytes32 posKey2 = keccak256(abi.encodePacked(address(user), TICK_LOWER_WIDE, TICK_UPPER_WIDE));
        (uint128 liq2,,,,) = pool.positions(posKey2);
        assertEq(liq2, expectedLiq2);
    }

    // ===========================================================================
    // MINT -- revert cases
    // ===========================================================================

    /// @notice A mint past its deadline reverts
    function testMintRevertsOnExpiredDeadline() public {
        MintParams memory params = MintParams({
            token0: address(token0),
            token1: address(token1),
            fee: FEE,
            tickLower: TICK_LOWER,
            tickUpper: TICK_UPPER,
            amount0Desired: AMOUNT_DESIRED,
            amount1Desired: AMOUNT_DESIRED,
            amount0Min: AMOUNT_MIN,
            amount1Min: AMOUNT_MIN,
            recipient: recipient,
            deadline: block.timestamp - 1
        });

        vm.prank(user);
        vm.expectRevert(IProxyErrors.TransactionTooOld.selector);
        proxy.mintUnchecked(params);
    }

    /// @notice A mint depositing less than amount0Min / amount1Min reverts
    function testMintRevertsOnSlippageExceeded() public {
        MintParams memory params = MintParams({
            token0: address(token0),
            token1: address(token1),
            fee: FEE,
            tickLower: TICK_LOWER,
            tickUpper: TICK_UPPER,
            amount0Desired: AMOUNT_DESIRED,
            amount1Desired: AMOUNT_DESIRED,
            amount0Min: type(uint256).max,
            amount1Min: type(uint256).max,
            recipient: recipient,
            deadline: block.timestamp + 3600
        });

        vm.prank(user);
        vm.expectRevert(IProxyErrors.PriceSlippageCheck.selector);
        proxy.mintUnchecked(params);
    }

    /// @notice A position minted to address(0) could never be withdrawn: the harness refuses it
    function testMintRevertsOnZeroRecipient() public {
        MintParams memory params = MintParams({
            token0: address(token0),
            token1: address(token1),
            fee: FEE,
            tickLower: TICK_LOWER,
            tickUpper: TICK_UPPER,
            amount0Desired: AMOUNT_DESIRED,
            amount1Desired: AMOUNT_DESIRED,
            amount0Min: 0,
            amount1Min: 0,
            recipient: address(0),
            deadline: block.timestamp + 3600
        });

        vm.prank(user);
        vm.expectRevert(UniswapV3ProxyHarness.InvalidRecipient.selector);
        proxy.mintUnchecked(params);
    }

    /// @notice The caller, whom the mint callback charges, has not approved the harness: the callback
    /// cannot pull the tokens
    function testMintRevertsWithoutApproval() public {
        address noApproval = makeAddr("noApproval");
        token0.mint(noApproval, AMOUNT_DESIRED);
        token1.mint(noApproval, AMOUNT_DESIRED);

        MintParams memory params = MintParams({
            token0: address(token0),
            token1: address(token1),
            fee: FEE,
            tickLower: TICK_LOWER,
            tickUpper: TICK_UPPER,
            amount0Desired: AMOUNT_DESIRED,
            amount1Desired: AMOUNT_DESIRED,
            amount0Min: 0,
            amount1Min: 0,
            recipient: recipient,
            deadline: block.timestamp + 3600
        });

        vm.prank(noApproval);
        vm.expectRevert(_stringError("STF"));
        proxy.mintUnchecked(params);
    }

    /// @notice The caller approved the harness but cannot cover the deposit
    function testMintRevertsWithInsufficientBalance() public {
        address poor = makeAddr("poor");
        token0.mint(poor, 1);
        token1.mint(poor, 1);

        vm.startPrank(poor);
        token0.approve(address(proxy), type(uint256).max);
        token1.approve(address(proxy), type(uint256).max);
        vm.stopPrank();

        MintParams memory params = MintParams({
            token0: address(token0),
            token1: address(token1),
            fee: FEE,
            tickLower: TICK_LOWER,
            tickUpper: TICK_UPPER,
            amount0Desired: AMOUNT_DESIRED,
            amount1Desired: AMOUNT_DESIRED,
            amount0Min: 0,
            amount1Min: 0,
            recipient: recipient,
            deadline: block.timestamp + 3600
        });

        vm.prank(poor);
        vm.expectRevert(_stringError("STF"));
        proxy.mintUnchecked(params);
    }

    /// @notice A mint on a pair no pool exists for reverts
    function testMintRevertsOnNonExistentPool() public {
        MockERC20 rogue = new MockERC20();

        MintParams memory params = MintParams({
            token0: address(token0),
            token1: address(rogue),
            fee: FEE,
            tickLower: TICK_LOWER,
            tickUpper: TICK_UPPER,
            amount0Desired: AMOUNT_DESIRED,
            amount1Desired: AMOUNT_DESIRED,
            amount0Min: 0,
            amount1Min: 0,
            recipient: recipient,
            deadline: block.timestamp + 3600
        });

        vm.prank(user);
        vm.expectRevert();
        proxy.mintUnchecked(params);
    }

    // ===========================================================================
    // EXACT INPUT SINGLE -- happy paths (a one-leg `swap`)
    // ===========================================================================

    /// @notice Exact input token0 -> token1: the caller pays exactly amountIn and receives exactly
    /// what the call reports, nobody else is involved
    function testExactInputSingleZeroForOne() public {
        _mintDefaultLiquidity();

        // Probe expected output via snapshot
        uint256 expectedOut = _probeExactInput(address(token0), address(token1), SWAP_AMOUNT);

        uint256 userT0Before = token0.balanceOf(user);
        uint256 userT1Before = token1.balanceOf(user);
        uint256 recipientT1Before = token1.balanceOf(recipient);
        uint256 poolT0Before = token0.balanceOf(address(pool));
        uint256 poolT1Before = token1.balanceOf(address(pool));

        uint256 amountOut = _swap(user, _exactIn(address(token0), address(token1), SWAP_AMOUNT, 0));

        // Output matches the probed expectation exactly
        assertEq(amountOut, expectedOut, "amountOut should match probed value");

        // The fee + price impact cost is exactly SWAP_AMOUNT - amountOut
        uint256 totalCost = SWAP_AMOUNT - amountOut;
        assertEq(totalCost, SWAP_AMOUNT - expectedOut, "total cost should match probed expectation");

        // Exact balance accounting: the output goes to the caller, never to the outsider
        assertEq(token0.balanceOf(user), userT0Before - SWAP_AMOUNT);
        assertEq(token1.balanceOf(user), userT1Before + amountOut);
        assertEq(token1.balanceOf(recipient), recipientT1Before, "an outsider received the output");
        assertEq(token0.balanceOf(address(pool)), poolT0Before + SWAP_AMOUNT);
        assertEq(token1.balanceOf(address(pool)), poolT1Before - amountOut);
    }

    /// @notice Exact input token1 -> token0: same exact accounting in the other direction
    function testExactInputSingleOneForZero() public {
        _mintDefaultLiquidity();

        uint256 expectedOut = _probeExactInput(address(token1), address(token0), SWAP_AMOUNT);

        uint256 userT1Before = token1.balanceOf(user);
        uint256 userT0Before = token0.balanceOf(user);
        uint256 recipientT0Before = token0.balanceOf(recipient);
        uint256 poolT0Before = token0.balanceOf(address(pool));
        uint256 poolT1Before = token1.balanceOf(address(pool));

        uint256 amountOut = _swap(user, _exactIn(address(token1), address(token0), SWAP_AMOUNT, 0));

        assertEq(amountOut, expectedOut);
        assertEq(token1.balanceOf(user), userT1Before - SWAP_AMOUNT);
        assertEq(token0.balanceOf(user), userT0Before + amountOut);
        assertEq(token0.balanceOf(recipient), recipientT0Before, "an outsider received the output");
        assertEq(token1.balanceOf(address(pool)), poolT1Before + SWAP_AMOUNT);
        assertEq(token0.balanceOf(address(pool)), poolT0Before - amountOut);
    }

    /// @notice The caller is its own recipient (now the only possible one): it pays exactly amountIn
    /// and receives exactly amountOut
    function testExactInputSingleRecipientIsSelf() public {
        _mintDefaultLiquidity();

        uint256 expectedOut = _probeExactInput(address(token0), address(token1), SWAP_AMOUNT);
        uint256 userT0Before = token0.balanceOf(user);
        uint256 userT1Before = token1.balanceOf(user);

        uint256 amountOut = _swap(user, _exactIn(address(token0), address(token1), SWAP_AMOUNT, 0));

        assertEq(amountOut, expectedOut);
        assertEq(token0.balanceOf(user), userT0Before - SWAP_AMOUNT);
        assertEq(token1.balanceOf(user), userT1Before + amountOut);
    }

    /// @notice amountOutMinimum set to exactly the expected output passes
    function testExactInputSingleWithSlippageProtection() public {
        _mintDefaultLiquidity();

        uint256 expectedOut = _probeExactInput(address(token0), address(token1), SWAP_AMOUNT);

        // set to exact expected -- should pass
        uint256 amountOut = _swap(user, _exactIn(address(token0), address(token1), SWAP_AMOUNT, expectedOut));

        assertEq(amountOut, expectedOut);
    }

    /// @notice A price limit 1 unit below the current price: the swap stops exactly there, spends only
    /// what the pool took to get there and delivers less than the same swap without a limit
    function testExactInputSingleWithSqrtPriceLimit() public {
        _mintDefaultLiquidity();

        (uint160 currentSqrtPrice,,,,,,) = pool.slot0();
        uint160 priceLimit = currentSqrtPrice - 1;
        SwapCalldata.Leg memory leg = _limited(_exactIn(address(token0), address(token1), SWAP_AMOUNT, 0), priceLimit);

        // Probe with the same limit
        uint256 snap = vm.snapshotState();
        uint256 expectedOut = _swap(user, leg);
        vm.revertToState(snap);

        // Also probe the unlimited case for comparison
        uint256 unlimitedOut = _probeExactInput(address(token0), address(token1), SWAP_AMOUNT);

        uint256 userT0Before = token0.balanceOf(user);
        uint256 poolT0Before = token0.balanceOf(address(pool));

        // Execute with limit
        uint256 amountOut = _swap(user, leg);

        assertEq(amountOut, expectedOut);

        // With a very tight price limit (1 unit below current), the limited output is less than unlimited
        assertLt(amountOut, unlimitedOut, "the limit did not bind");
        // Verify the exact difference
        uint256 limitationCost = unlimitedOut - expectedOut;
        assertEq(unlimitedOut - amountOut, limitationCost, "limitation cost should be exact");

        // The pool stopped at the limit and the caller paid only what it took to get there
        (uint160 priceAfter,,,,,,) = pool.slot0();
        assertEq(priceAfter, priceLimit, "the swap did not stop at its limit");
        uint256 paid = token0.balanceOf(address(pool)) - poolT0Before;
        assertEq(token0.balanceOf(user), userT0Before - paid, "the caller paid more than the pool took");
        assertLt(paid, SWAP_AMOUNT, "a limited swap spent all of amountIn");
    }

    /// @notice A tiny exact input still settles exactly
    function testExactInputSingleSmallAmount() public {
        _mintDefaultLiquidity();

        uint256 smallAmount = 1000;
        uint256 expectedOut = _probeExactInput(address(token0), address(token1), smallAmount);

        uint256 userT1Before = token1.balanceOf(user);

        uint256 amountOut = _swap(user, _exactIn(address(token0), address(token1), smallAmount, 0));

        assertEq(amountOut, expectedOut);
        assertEq(token1.balanceOf(user), userT1Before + amountOut);
    }

    /// @notice Two identical swaps in a row: the second runs on the moved price and gets less
    function testExactInputSingleConsecutiveSwapsPriceImpact() public {
        _mintDefaultLiquidity();

        // Probe first swap output
        uint256 expectedOut1 = _probeExactInput(address(token0), address(token1), SWAP_AMOUNT);

        SwapCalldata.Leg memory leg = _exactIn(address(token0), address(token1), SWAP_AMOUNT, 0);

        uint256 amountOut1 = _swap(user, leg);
        assertEq(amountOut1, expectedOut1);

        // After first swap, probe second swap on shifted state
        uint256 expectedOut2 = _probeExactInput(address(token0), address(token1), SWAP_AMOUNT);

        uint256 amountOut2 = _swap(user, leg);
        assertEq(amountOut2, expectedOut2);

        // Verify the exact price impact: second output is less by a precise delta
        assertLt(amountOut2, amountOut1, "the second swap was not worse");
        uint256 priceImpactDelta = amountOut1 - amountOut2;
        assertEq(amountOut1 - amountOut2, priceImpactDelta, "price impact delta should be exact");
    }

    // ===========================================================================
    // EXACT INPUT SINGLE -- revert cases
    // ===========================================================================

    /// @notice A call past its deadline reverts before anything runs: the pool is never called
    function testExactInputSingleRevertsOnExpiredDeadline() public {
        _mintDefaultLiquidity();

        bytes memory data = SwapCalldata.encode(
            vm.getBlockTimestamp() - 1, _one(_exactIn(address(token0), address(token1), SWAP_AMOUNT, 0))
        );

        vm.expectCall(address(pool), abi.encodeWithSelector(IUniswapV3PoolMinimal.swap.selector), 0);
        _expectSwapRevert(user, data, _proxyError(IProxyErrors.TransactionTooOld.selector));
    }

    /// @notice An unreachable amountOutMinimum (the largest the 128-bit field holds) reverts
    function testExactInputSingleRevertsOnSlippageExceeded() public {
        _mintDefaultLiquidity();

        _expectSwapRevert(
            user,
            _data(_exactIn(address(token0), address(token1), SWAP_AMOUNT, type(uint128).max)),
            _proxyError(IProxyErrors.TooLittleReceived.selector)
        );
    }

    /// @notice amountOutMinimum one wei above the actual output reverts
    function testExactInputSingleRevertsSlippageByOneWei() public {
        _mintDefaultLiquidity();

        uint256 expectedOut = _probeExactInput(address(token0), address(token1), SWAP_AMOUNT);

        // one wei above actual -- must revert
        _expectSwapRevert(
            user,
            _data(_exactIn(address(token0), address(token1), SWAP_AMOUNT, expectedOut + 1)),
            _proxyError(IProxyErrors.TooLittleReceived.selector)
        );
    }

    /// @notice Replaces "zero recipient reverts". A leg has no recipient field, so its output can be
    /// neither burnt nor sent elsewhere: appending one, as the old parameters had, leaves bytes after
    /// the last leg and the data is malformed; the well-formed leg makes the pool pay the caller, in
    /// full (what the pool lost is what the caller gained, the supply is unchanged)
    function testExactInputSingleOutputCanOnlyGoToTheCaller() public {
        _mintDefaultLiquidity();
        SwapCalldata.Leg memory leg = _exactIn(address(token0), address(token1), SWAP_AMOUNT, 0);

        _expectSwapRevert(
            user, bytes.concat(_data(leg), bytes20(address(0))), _proxyError(IProxyErrors.MalformedSwap.selector)
        );

        uint256 supply = token1.totalSupply();
        uint256 userT1Before = token1.balanceOf(user);
        uint256 poolT1Before = token1.balanceOf(address(pool));
        uint256 recipientT1Before = token1.balanceOf(recipient);

        vm.expectCall(address(pool), abi.encodeWithSelector(IUniswapV3PoolMinimal.swap.selector, user));
        uint256 amountOut = _swap(user, leg);

        assertGt(amountOut, 0, "nothing was swapped");
        assertEq(token1.balanceOf(user), userT1Before + amountOut, "the caller did not get the output");
        assertEq(poolT1Before - token1.balanceOf(address(pool)), amountOut, "the pool paid out something else");
        assertEq(token1.totalSupply(), supply, "output was burnt");
        assertEq(token1.balanceOf(recipient), recipientT1Before, "an outsider received the output");
        _assertProxyHoldsNothing();
    }

    /// @notice The caller (registered for the pool) has not approved the proxy: the pool's callback
    /// cannot pull the input
    function testExactInputSingleRevertsWithoutApproval() public {
        _mintDefaultLiquidity();

        address noApproval = makeAddr("noApproval");
        token0.mint(noApproval, SWAP_AMOUNT);
        _allow(noApproval, address(pool));

        _expectSwapRevert(
            noApproval, _data(_exactIn(address(token0), address(token1), SWAP_AMOUNT, 0)), _stringError("STF")
        );
        assertEq(token0.balanceOf(noApproval), SWAP_AMOUNT);
    }

    /// @notice The caller (registered, approved) cannot cover amountIn
    function testExactInputSingleRevertsWithInsufficientBalance() public {
        _mintDefaultLiquidity();

        address poor = makeAddr("poor");
        token0.mint(poor, 1);
        _allow(poor, address(pool));

        vm.prank(poor);
        token0.approve(address(lobster), type(uint256).max);

        _expectSwapRevert(poor, _data(_exactIn(address(token0), address(token1), SWAP_AMOUNT, 0)), _stringError("STF"));
    }

    /// @notice A pair no pool was ever created for. Unregistered, the registry refuses it before
    /// anything runs (PoolNotAllowed). Registered by its CREATE2 key, the proxy finds no pool behind
    /// the address and refuses it (NotAPool) rather than "swap" on an empty account. Nothing moves.
    function testExactInputSingleRevertsOnNonExistentPool() public {
        MockERC20 rogue = new MockERC20();
        address nowhere = _v3PoolAddress(address(token0), address(rogue), FEE);
        assertEq(nowhere.code.length, 0, "a pool exists there: the test proves nothing");

        bytes memory data = _data(_exactIn(address(token0), address(rogue), SWAP_AMOUNT, 0));
        uint256 userT0Before = token0.balanceOf(user);
        vm.expectCall(nowhere, abi.encodeWithSelector(IUniswapV3PoolMinimal.swap.selector), 0);

        _expectSwapRevert(user, data, _proxyError(IProxyErrors.PoolNotAllowed.selector));

        _allow(user, nowhere);
        _expectSwapRevert(user, data, _proxyError(IProxyErrors.NotAPool.selector));

        assertEq(token0.balanceOf(user), userT0Before, "caller paid");
        assertEq(rogue.balanceOf(user), 0, "caller received");
        assertEq(rogue.balanceOf(address(lobster)), 0, "proxy holds rogue");
        _assertProxyHoldsNothing();
    }

    // ===========================================================================
    // ROUNDTRIP -- swap and swap back, verify fee accounting
    // ===========================================================================

    /// @notice token0 -> token1 -> token0 in two calls: token1 ends where it started and the caller
    /// lost exactly the fees and price impact in token0
    function testRoundtripSwapPaysFees() public {
        _mintDefaultLiquidity();

        uint256 userT0Start = token0.balanceOf(user);
        uint256 userT1Start = token1.balanceOf(user);

        // Probe both legs
        uint256 expectedOut1 = _probeExactInput(address(token0), address(token1), SWAP_AMOUNT);

        // Leg 1: token0 -> token1
        uint256 received = _swap(user, _exactIn(address(token0), address(token1), SWAP_AMOUNT, 0));
        assertEq(received, expectedOut1);

        // Probe leg 2 on shifted state
        uint256 expectedGotBack = _probeExactInput(address(token1), address(token0), received);

        // Leg 2: token1 -> token0
        uint256 gotBack = _swap(user, _exactIn(address(token1), address(token0), received, 0));
        assertEq(gotBack, expectedGotBack);

        // token1 balance unchanged
        assertEq(token1.balanceOf(user), userT1Start, "token1 balance should return to start");

        // token0: lost exactly SWAP_AMOUNT - gotBack
        uint256 totalLoss = SWAP_AMOUNT - gotBack;
        assertEq(token0.balanceOf(user), userT0Start - totalLoss);
    }

    // ===========================================================================
    // CALLBACK SECURITY -- only the pool being called, and only once
    // ===========================================================================

    /// @notice Outside a swap no one may call the swap callback; here this contract, which is no pool
    function testSwapCallbackRevertsFromNonPool() public {
        vm.expectRevert(IProxyErrors.UnexpectedCallback.selector);
        lobster.uniswapV3SwapCallback(1, -1, _callbackData(address(token0)));
    }

    /// @notice The mint callback verifies its caller is the factory's pool for the key in the data
    /// (CREATE2): this contract, which is no pool, is refused by that check, a bare require, even with
    /// data in the old layout naming as payer the user, who approved the harness. The user pays nothing.
    function testMintCallbackRevertsFromNonPool() public {
        uint256 userT0Before = token0.balanceOf(user);
        uint256 userT1Before = token1.balanceOf(user);
        bytes memory data = abi.encode(
            MintCallbackData({
                poolKey: PoolAddress.PoolKey({token0: address(token0), token1: address(token1), fee: FEE}), payer: user
            })
        );

        (bool ok, bytes memory ret) =
            address(proxy).call(abi.encodeCall(IUniswapV3MintCallback.uniswapV3MintCallback, (1, 1, data)));

        assertFalse(ok, "a mint callback from a non-pool was honoured");
        assertEq(ret.length, 0, "refused for another reason than the CREATE2 check");
        assertEq(token0.balanceOf(user), userT0Before, "a forged mint callback moved token0");
        assertEq(token1.balanceOf(user), userT1Before, "a forged mint callback moved token1");
    }

    /// @notice The mint callback charges the account holding the lock, the caller of `mint`, never
    /// anyone named in its data, so even the genuine pool cannot make it pay outside a mint: called by
    /// the pool outside any entry point, it passes the CREATE2 check and is refused
    /// (`UnexpectedCallback`), with data in the old layout (`MintCallbackData`) naming as payer the
    /// user, who holds the tokens and approved the harness, and with the data `mint` passes now (the
    /// pool key alone); on the mint harness and on LobsterProxy alike. No token moves, not even in a
    /// reverted frame.
    function testMintCallbackRevertsFromTheGenuinePoolOutsideAMint() public {
        _mintDefaultLiquidity();
        PoolAddress.PoolKey memory key =
            PoolAddress.PoolKey({token0: address(token0), token1: address(token1), fee: FEE});
        bytes[2] memory datas = [abi.encode(MintCallbackData({poolKey: key, payer: user})), abi.encode(key)];
        uint256[4] memory before = [
            token0.balanceOf(user),
            token1.balanceOf(user),
            token0.balanceOf(address(pool)),
            token1.balanceOf(address(pool))
        ];

        vm.expectCall(address(token0), abi.encodeWithSelector(IERC20.transferFrom.selector), 0);
        vm.expectCall(address(token1), abi.encodeWithSelector(IERC20.transferFrom.selector), 0);
        for (uint256 i = 0; i < datas.length; i++) {
            vm.prank(address(pool));
            vm.expectRevert(IProxyErrors.UnexpectedCallback.selector);
            proxy.uniswapV3MintCallback(AMOUNT_DESIRED, AMOUNT_DESIRED, datas[i]);

            vm.prank(address(pool));
            vm.expectRevert(IProxyErrors.UnexpectedCallback.selector);
            lobster.uniswapV3MintCallback(AMOUNT_DESIRED, AMOUNT_DESIRED, datas[i]);
        }

        assertEq(token0.balanceOf(user), before[0], "the named payer paid token0");
        assertEq(token1.balanceOf(user), before[1], "the named payer paid token1");
        assertEq(token0.balanceOf(address(pool)), before[2], "the pool was paid token0");
        assertEq(token1.balanceOf(address(pool)), before[3], "the pool was paid token1");
    }

    /// @notice An attacker calling the swap callback directly, claiming a pool is owed: refused, and
    /// the vault, which has standing approvals, pays nothing
    function testSwapCallbackRevertsFromRandomAddress() public {
        address attacker = makeAddr("attacker");
        uint256 userT0Before = token0.balanceOf(user);

        vm.prank(attacker);
        vm.expectRevert(IProxyErrors.UnexpectedCallback.selector);
        lobster.uniswapV3SwapCallback(FORGED_AMOUNT, -1, _callbackData(address(token0)));

        assertEq(token0.balanceOf(user), userT0Before, "a forged callback moved funds");
    }

    /// @notice Even the genuine, registered pool cannot call the swap callback outside a swap the
    /// proxy is making on it: being a pool is not enough
    function testSwapCallbackRevertsFromTheGenuinePoolOutsideASwap() public {
        _mintDefaultLiquidity();
        uint256 userT0Before = token0.balanceOf(user);
        uint256 poolT0Before = token0.balanceOf(address(pool));

        vm.prank(address(pool));
        vm.expectRevert(IProxyErrors.UnexpectedCallback.selector);
        lobster.uniswapV3SwapCallback(FORGED_AMOUNT, 0, _callbackData(address(token0)));

        assertEq(token0.balanceOf(user), userT0Before, "the vault paid");
        assertEq(token0.balanceOf(address(pool)), poolT0Before, "the pool was paid");
    }

    /// @notice Outside a swap the callback is refused for every caller, deltas and data
    function testFuzz_SwapCallbackRevertsOutsideASwap(
        address caller,
        int256 amount0Delta,
        int256 amount1Delta,
        bytes calldata data
    )
        public
    {
        assumeNotForgeAddress(caller);
        uint256 userT0Before = token0.balanceOf(user);
        uint256 userT1Before = token1.balanceOf(user);

        vm.prank(caller);
        vm.expectRevert(IProxyErrors.UnexpectedCallback.selector);
        lobster.uniswapV3SwapCallback(amount0Delta, amount1Delta, data);

        assertEq(token0.balanceOf(user), userT0Before, "a forged callback moved token0");
        assertEq(token1.balanceOf(user), userT1Before, "a forged callback moved token1");
    }

    /// @dev A V3 pool of token0 and a {CallbackForgingToken}, with liquidity, registered for the user
    function _forgingTokenPool() internal returns (CallbackForgingToken evil) {
        evil = new CallbackForgingToken();
        IUniswapV3PoolMinimal evilPool = IUniswapV3PoolMinimal(factory.createPool(address(token0), address(evil), FEE));
        evilPool.initialize(2 ** 96);

        (address a, address b) =
            address(token0) < address(evil) ? (address(token0), address(evil)) : (address(evil), address(token0));
        token0.approve(address(proxy), type(uint256).max);
        evil.approve(address(proxy), type(uint256).max);
        proxy.mintUnchecked(
            MintParams({
                token0: a,
                token1: b,
                fee: FEE,
                tickLower: TICK_LOWER_WIDE,
                tickUpper: TICK_UPPER_WIDE,
                amount0Desired: AMOUNT_DESIRED,
                amount1Desired: AMOUNT_DESIRED,
                amount0Min: 0,
                amount1Min: 0,
                recipient: address(this),
                deadline: vm.getBlockTimestamp() + 3600
            })
        );
        _allow(user, address(evilPool));
    }

    /// @notice Mid-swap, while the proxy waits for the pool's callback, the token being paid out calls
    /// the callback itself: "the pool is owed, pay me from the vault". Only the pool the proxy is
    /// calling is honoured: the forgery is refused, the swap completes, the vault pays its swap only.
    function testSwapCallbackForgedMidSwapIsRefused() public {
        CallbackForgingToken evil = _forgingTokenPool();
        evil.arm(
            address(lobster),
            abi.encodeCall(
                IUniswapV3SwapCallback.uniswapV3SwapCallback, (FORGED_AMOUNT, 0, _callbackData(address(token0)))
            ),
            address(0)
        );
        uint256 userT0Before = token0.balanceOf(user);

        uint256 amountOut = _swap(user, _exactIn(address(token0), address(evil), SWAP_AMOUNT, 0));

        assertTrue(evil.attempted(), "the forgery never ran: the test proves nothing");
        assertFalse(evil.forgerySucceeded(), "a forged callback was honoured");
        assertEq(evil.forgeryRevertData(), abi.encodeWithSelector(IProxyErrors.UnexpectedCallback.selector));
        assertEq(token0.balanceOf(user), userT0Before - SWAP_AMOUNT, "the vault paid more than its swap");
        assertEq(token0.balanceOf(address(evil)), 0, "the forger was paid");
        assertEq(evil.balanceOf(user), amountOut, "the swap did not deliver");
    }

    /// @notice The same mid-swap forgery, made as another genuine pool the vault registered: a pool's
    /// CREATE2 identity is not enough, only the pool being called right now is honoured
    function testSwapCallbackFromAnotherRegisteredPoolMidSwapIsRefused() public {
        CallbackForgingToken evil = _forgingTokenPool();
        evil.arm(
            address(lobster),
            abi.encodeCall(
                IUniswapV3SwapCallback.uniswapV3SwapCallback, (FORGED_AMOUNT, 0, _callbackData(address(token0)))
            ),
            address(pool)
        );
        uint256 userT0Before = token0.balanceOf(user);
        uint256 poolT0Before = token0.balanceOf(address(pool));

        _swap(user, _exactIn(address(token0), address(evil), SWAP_AMOUNT, 0));

        assertTrue(evil.attempted(), "the forgery never ran: the test proves nothing");
        assertFalse(evil.forgerySucceeded(), "a callback from a pool not being called was honoured");
        assertEq(evil.forgeryRevertData(), abi.encodeWithSelector(IProxyErrors.UnexpectedCallback.selector));
        assertEq(token0.balanceOf(user), userT0Before - SWAP_AMOUNT, "the vault paid more than its swap");
        assertEq(token0.balanceOf(address(pool)), poolT0Before, "the impersonated pool was paid");
    }

    /// @notice The callback is honoured once per pool call: a registered "pool" (an etched contract
    /// standing for one that misbehaves) calling back a second time is refused, so the vault pays once
    function testSwapCallbackIsHonouredOnlyOnce() public {
        address fake = _v3PoolAddress(address(token0), address(token1), UNCREATED_FEE);
        vm.etch(fake, address(new DoubleCallbackPool()).code);
        _allow(user, fake);
        SwapCalldata.Leg memory leg = _exactIn(address(token0), address(token1), SWAP_AMOUNT, 0);
        leg.fee = UNCREATED_FEE;
        uint256 userT0Before = token0.balanceOf(user);

        _swap(user, leg);

        assertFalse(DoubleCallbackPool(fake).secondCallbackSucceeded(), "a second callback was honoured");
        assertEq(
            DoubleCallbackPool(fake).secondCallbackRevertData(),
            abi.encodeWithSelector(IProxyErrors.UnexpectedCallback.selector)
        );
        assertEq(token0.balanceOf(user), userT0Before - SWAP_AMOUNT, "the vault paid twice");
        assertEq(token0.balanceOf(fake), SWAP_AMOUNT);
    }

    // ===========================================================================
    // POOL STATE VERIFICATION
    // ===========================================================================

    /// @notice Selling token0 (zeroForOne) lowers sqrtPriceX96, exactly as probed
    function testSwapZeroForOneDecreasesSqrtPrice() public {
        _mintDefaultLiquidity();

        (uint160 priceBefore,,,,,,) = pool.slot0();
        SwapCalldata.Leg memory leg = _exactIn(address(token0), address(token1), SWAP_AMOUNT, 0);

        // Probe the exact post-swap price
        uint256 snap = vm.snapshotState();
        _swap(user, leg);
        (uint160 expectedPriceAfter,,,,,,) = pool.slot0();
        vm.revertToState(snap);

        // Execute the real swap
        _swap(user, leg);
        (uint160 priceAfter,,,,,,) = pool.slot0();

        assertEq(priceAfter, expectedPriceAfter, "post-swap price should match probed value");
        // Selling token0 for token1 (zeroForOne) must decrease sqrtPriceX96
        assertLt(priceAfter, priceBefore, "the price did not go down");
        assertEq(priceBefore - priceAfter, priceBefore - expectedPriceAfter, "price decrease should be exact");
    }

    /// @notice Selling token1 (oneForZero) raises sqrtPriceX96, exactly as probed
    function testSwapOneForZeroIncreasesSqrtPrice() public {
        _mintDefaultLiquidity();

        (uint160 priceBefore,,,,,,) = pool.slot0();
        SwapCalldata.Leg memory leg = _exactIn(address(token1), address(token0), SWAP_AMOUNT, 0);

        uint256 snap = vm.snapshotState();
        _swap(user, leg);
        (uint160 expectedPriceAfter,,,,,,) = pool.slot0();
        vm.revertToState(snap);

        _swap(user, leg);
        (uint160 priceAfter,,,,,,) = pool.slot0();

        assertEq(priceAfter, expectedPriceAfter);
        assertGt(priceAfter, priceBefore, "the price did not go up");
        assertEq(priceAfter - priceBefore, expectedPriceAfter - priceBefore, "price increase should be exact");
    }

    /// @notice A mint creates exactly the computed liquidity
    function testMintIncreasesPoolLiquidity() public {
        bytes32 posKey = keccak256(abi.encodePacked(address(user), TICK_LOWER_WIDE, TICK_UPPER_WIDE));
        (uint128 liqBefore,,,,) = pool.positions(posKey);
        assertEq(liqBefore, 0);

        (uint128 expectedLiq,,) =
            _computeExpectedMintAmounts(TICK_LOWER_WIDE, TICK_UPPER_WIDE, AMOUNT_DESIRED, AMOUNT_DESIRED);

        _mintDefaultLiquidity();

        (uint128 liqAfter,,,,) = pool.positions(posKey);
        assertEq(liqAfter, expectedLiq, "liquidity should equal computed expected value");
    }

    // ===========================================================================
    // EDGE CASES
    // ===========================================================================

    /// @notice A large exact input settles exactly and pays for its price impact
    function testExactInputSingleLargeSwapHighSlippage() public {
        _mintDefaultLiquidity();

        uint256 hugeAmount = 500e18;
        uint256 expectedOut = _probeExactInput(address(token0), address(token1), hugeAmount);

        uint256 poolT1Before = token1.balanceOf(address(pool));

        uint256 amountOut = _swap(user, _exactIn(address(token0), address(token1), hugeAmount, 0));

        assertEq(amountOut, expectedOut);
        assertEq(token1.balanceOf(address(pool)), poolT1Before - amountOut);

        // Verify price impact: output is less than linear expectation
        uint256 linearOut = hugeAmount * (1_000_000 - FEE) / 1_000_000;
        assertLt(amountOut, linearOut, "no price impact");
        uint256 slippageLoss = linearOut - amountOut;
        assertEq(linearOut - amountOut, slippageLoss);
    }

    /// @notice The deadline is inclusive: a call whose deadline is this block's timestamp runs
    function testDeadlineExactlyAtBlockTimestamp() public {
        _mintDefaultLiquidity();

        uint256 expectedOut = _probeExactInput(address(token0), address(token1), SWAP_AMOUNT);

        // boundary -- should pass (<=)
        bytes memory data = SwapCalldata.encode(
            vm.getBlockTimestamp(), _one(_exactIn(address(token0), address(token1), SWAP_AMOUNT, 0))
        );
        uint256 amountOut = _swapData(user, data);
        assertEq(amountOut, expectedOut);
    }

    /// @notice The deadline is a uint32 in the call's header: the largest one is honoured up to and
    /// including its own second, and once block.timestamp passes 2**32 - 1 (in 2106) no deadline a
    /// swap accepts can be encoded any more (documented in {SwapFlags})
    function testDeadlineIsAUint32Timestamp() public {
        _mintDefaultLiquidity();
        bytes memory data =
            SwapCalldata.encode(type(uint32).max, _one(_exactIn(address(token0), address(token1), SWAP_AMOUNT, 0)));

        vm.warp(type(uint32).max);
        assertGt(_swapData(user, data), 0, "the largest deadline was refused at its own second");

        vm.warp(2 ** 32);
        _expectSwapRevert(user, data, _proxyError(IProxyErrors.TransactionTooOld.selector));
    }

    /// @notice The deadline is inclusive for mints too
    function testMintDeadlineExactlyAtBlockTimestamp() public {
        (, uint256 expectedAmt0, uint256 expectedAmt1) =
            _computeExpectedMintAmounts(TICK_LOWER, TICK_UPPER, AMOUNT_DESIRED, AMOUNT_DESIRED);

        MintParams memory params = MintParams({
            token0: address(token0),
            token1: address(token1),
            fee: FEE,
            tickLower: TICK_LOWER,
            tickUpper: TICK_UPPER,
            amount0Desired: AMOUNT_DESIRED,
            amount1Desired: AMOUNT_DESIRED,
            amount0Min: 0,
            amount1Min: 0,
            recipient: recipient,
            deadline: block.timestamp
        });

        vm.prank(user);
        (uint256 amount0, uint256 amount1) = proxy.mintUnchecked(params);

        assertApproxEqAbs(amount0, expectedAmt0, 1);
        assertApproxEqAbs(amount1, expectedAmt1, 1);
    }

    /// @notice A swap leaves every other account alone, even one with standing approvals to the proxy
    function testSwapDoesNotAffectUnrelatedBalances() public {
        _mintDefaultLiquidity();

        address bystander = makeAddr("bystander");
        token0.mint(bystander, 100e18);
        token1.mint(bystander, 100e18);
        vm.startPrank(bystander);
        token0.approve(address(lobster), type(uint256).max);
        token1.approve(address(lobster), type(uint256).max);
        vm.stopPrank();

        uint256 bystanderT0 = token0.balanceOf(bystander);
        uint256 bystanderT1 = token1.balanceOf(bystander);
        uint256 recipientT0 = token0.balanceOf(recipient);
        uint256 recipientT1 = token1.balanceOf(recipient);

        _swap(user, _exactIn(address(token0), address(token1), SWAP_AMOUNT, 0));

        assertEq(token0.balanceOf(bystander), bystanderT0);
        assertEq(token1.balanceOf(bystander), bystanderT1);
        assertEq(token0.balanceOf(recipient), recipientT0);
        assertEq(token1.balanceOf(recipient), recipientT1);
    }

    /// @notice The mint harness keeps nothing
    function testProxyHoldsNoTokensAfterMint() public {
        _mintDefaultLiquidity();

        assertEq(token0.balanceOf(address(proxy)), 0, "proxy should hold zero token0");
        assertEq(token1.balanceOf(address(proxy)), 0, "proxy should hold zero token1");
    }

    /// @notice The swapping proxy keeps nothing, tokens or ETH
    function testProxyHoldsNoTokensAfterSwap() public {
        _mintDefaultLiquidity();

        _swap(user, _exactIn(address(token0), address(token1), SWAP_AMOUNT, 0));
        _swap(user, _exactOut(address(token1), address(token0), 5e18, type(uint128).max));

        _assertProxyHoldsNothing();
    }

    // ===========================================================================
    // V3 LEGS NEED NO NATIVE ETH AND NO POOL MANAGER
    // ===========================================================================

    /// @notice V3 has no native ETH: a V3 leg naming address(0) as either token is malformed, even if
    /// the caller registered the CREATE2 key such a pool would have and attached ETH
    function testV3LegCannotTradeNativeEth() public {
        _mintDefaultLiquidity();
        _allow(user, _v3PoolAddress(address(0), address(token1), FEE));
        bytes memory ethIn = _data(_exactIn(address(0), address(token1), 1 ether, 0));
        bytes memory ethOut = _data(_exactIn(address(token1), address(0), SWAP_AMOUNT, 0));
        uint256 ethBefore = user.balance;
        uint256 userT1Before = token1.balanceOf(user);

        vm.prank(user);
        vm.expectRevert(IProxyErrors.MalformedSwap.selector);
        lobster.swap{value: 1 ether}(ethIn);
        _expectSwapRevert(user, ethOut, _proxyError(IProxyErrors.MalformedSwap.selector));

        assertEq(user.balance, ethBefore, "ETH moved");
        assertEq(token1.balanceOf(user), userT1Before, "token1 moved");
        _assertProxyHoldsNothing();
    }

    /// @notice A call with only V3 legs never unlocks the PoolManager: a single leg either way, nor a
    /// V3 -> V3 chain, whose parked output waits in the proxy itself
    function testV3OnlySwapNeverUnlocksThePoolManager() public {
        _mintDefaultLiquidity();
        SwapCalldata.Leg memory parked = _exactIn(address(token0), address(token1), SWAP_AMOUNT, 0);
        parked.park = true;
        SwapCalldata.Leg memory held = _exactIn(address(token1), address(token0), 0, 0);
        held.held = true;
        bytes memory chain = SwapCalldata.encode(vm.getBlockTimestamp() + 3600, _two(parked, held));

        vm.expectCall(manager, abi.encodeWithSelector(IPoolManagerMinimal.unlock.selector), 0);
        _swap(user, _exactIn(address(token0), address(token1), SWAP_AMOUNT, 0));
        _swap(user, _exactOut(address(token1), address(token0), 5e18, type(uint128).max));
        vm.prank(user);
        lobster.swap(chain);

        _assertProxyHoldsNothing();
    }

    /// @notice Replaces "force-fed ETH is swept to the caller". `swap` is payable (V4 legs may spend
    /// native ETH) but a V3 leg spends none, and a call refunds exactly what is left of its own
    /// msg.value: ETH sent with a V3-only call comes back in full, no more. ETH force-fed to the proxy
    /// (a selfdestruct, a coinbase payment; `vm.deal` here) belongs to no one: a call attaching more
    /// ETH than that, less, or none neither spends nor refunds it, so it stays in the proxy, call after
    /// call, while every swap runs.
    function testV3SwapRefundsAnyEthSent() public {
        _mintDefaultLiquidity();
        bytes memory data = _data(_exactIn(address(token0), address(token1), SWAP_AMOUNT, 0));
        uint256 ethBefore = user.balance;
        uint256 userT1Before = token1.balanceOf(user);

        // nothing held: the whole msg.value comes back
        vm.prank(user);
        uint256 received = lobster.swap{value: 1 ether}(data)[0];
        assertEq(user.balance, ethBefore, "the swap kept ETH");
        assertEq(address(lobster).balance, 0, "the proxy kept ETH");

        vm.deal(address(lobster), 0.5 ether);
        uint256[3] memory values = [uint256(1 ether), 1, 0];
        for (uint256 i = 0; i < values.length; i++) {
            vm.prank(user);
            received += lobster.swap{value: values[i]}(data)[0];
            string memory which = string.concat("call ", vm.toString(i));
            assertEq(user.balance, ethBefore, string.concat(which, ": not refunded exactly its msg.value"));
            assertEq(address(lobster).balance, 0.5 ether, string.concat(which, ": the force-fed ETH moved"));
        }
        assertEq(token1.balanceOf(user), userT1Before + received, "a swap did not deliver");
        assertEq(token0.balanceOf(address(lobster)), 0, "proxy holds token0");
        assertEq(token1.balanceOf(address(lobster)), 0, "proxy holds token1");
    }

    /// @notice A call that sends no ETH gets none back, so ETH force-fed to the proxy cannot block a
    /// caller that cannot receive ETH (with the old sweep, one force-fed wei made every swap of such a
    /// caller revert "STE"): a contract with no receive and no fallback swaps with no msg.value while
    /// the proxy holds force-fed ETH, pays and receives exactly its swap, is sent no ETH, and the
    /// force-fed ETH stays in the proxy. The refund path is live: the same caller attaching ETH that no
    /// leg spends is refunded it, cannot receive it, and that call reverts ("STE") with nothing moved.
    function testForceFedEthCannotBlockACallerThatCannotReceiveEth() public {
        _mintDefaultLiquidity();
        NoEthReceiver caller = new NoEthReceiver();
        (bool accepted,) = address(caller).call{value: 1}("");
        assertFalse(accepted, "the caller accepts ETH: the test proves nothing");
        token0.mint(address(caller), SWAP_AMOUNT);
        vm.prank(address(caller));
        token0.approve(address(lobster), type(uint256).max);
        _allow(address(caller), address(pool));
        vm.deal(address(lobster), 0.5 ether);
        bytes memory data = _data(_exactIn(address(token0), address(token1), SWAP_AMOUNT, 0));

        vm.expectRevert(_stringError("STE"));
        caller.swap{value: 1}(lobster, data);
        assertEq(token0.balanceOf(address(caller)), SWAP_AMOUNT, "a reverted swap moved the caller's tokens");
        assertEq(address(lobster).balance, 0.5 ether, "a reverted swap moved the proxy's ETH");

        uint256[] memory amounts = caller.swap(lobster, data);

        assertGt(amounts[0], 0, "the swap did not deliver");
        assertEq(token0.balanceOf(address(caller)), 0, "the caller did not pay exactly its input");
        assertEq(token1.balanceOf(address(caller)), amounts[0], "the caller did not receive its output");
        assertEq(address(caller).balance, 0, "the caller was sent ETH");
        assertEq(address(lobster).balance, 0.5 ether, "the force-fed ETH left the proxy");
    }

    // ===========================================================================
    // OUTPUTS ONLY EVER REACH THE CALLER -- the proxy cannot be a recipient
    // ===========================================================================

    /// @notice Replaces "the proxy is rejected as recipient". A leg names no recipient, so the proxy
    /// only ever gets an output through PARK, for a later leg of the same call. Appending the proxy's
    /// address as a recipient makes the data malformed; parking with no later leg to spend it reverts
    /// (FundsLeftInProxy) and costs nothing; parked and spent, the round trip ends at the caller.
    function testSwapOutputCanNeverStayInTheProxy() public {
        _mintDefaultLiquidity();
        uint256 userT0Before = token0.balanceOf(user);
        uint256 userT1Before = token1.balanceOf(user);
        uint256 poolT1Before = token1.balanceOf(address(pool));
        SwapCalldata.Leg memory parked = _exactIn(address(token0), address(token1), SWAP_AMOUNT, 0);
        parked.park = true;

        _expectSwapRevert(
            user,
            bytes.concat(_data(_exactIn(address(token0), address(token1), SWAP_AMOUNT, 0)), bytes20(address(lobster))),
            _proxyError(IProxyErrors.MalformedSwap.selector)
        );
        _expectSwapRevert(user, _data(parked), _proxyError(IProxyErrors.FundsLeftInProxy.selector));
        assertEq(token0.balanceOf(user), userT0Before, "caller paid");
        _assertProxyHoldsNothing();

        SwapCalldata.Leg memory back = _exactIn(address(token1), address(token0), 0, 0);
        back.held = true;
        bytes memory roundTrip = SwapCalldata.encode(vm.getBlockTimestamp() + 3600, _two(parked, back));
        vm.prank(user);
        uint256[] memory amounts = lobster.swap(roundTrip);

        assertEq(amounts.length, 2);
        assertEq(
            token1.balanceOf(address(pool)), poolT1Before, "the second leg did not spend exactly the parked output"
        );
        assertEq(token1.balanceOf(user), userT1Before, "the parked output reached the caller");
        assertLt(amounts[1], SWAP_AMOUNT, "a round trip cannot gain");
        assertEq(
            token0.balanceOf(user), userT0Before - SWAP_AMOUNT + amounts[1], "the round trip did not end at the caller"
        );
        _assertProxyHoldsNothing();
    }

    /// @notice Whoever calls, in either direction and for either kind of leg, the pool is told to pay
    /// the caller and does: the caller gains exactly what the pool loses and pays exactly what it
    /// gains; the user, the outsider and the proxy are untouched
    function testFuzz_OutputAlwaysLandsAtTheCaller(
        address caller,
        uint256 amount,
        bool zeroForOne,
        bool exactOut
    )
        public
    {
        vm.assume(caller != address(0) && caller.code.length == 0 && caller != user && caller != recipient);
        assumeNotPrecompile(caller);
        assumeNotForgeAddress(caller);
        _mintDefaultLiquidity();
        amount = bound(amount, 1e6, 100e18);
        (MockERC20 tokenIn, MockERC20 tokenOut) = zeroForOne ? (token0, token1) : (token1, token0);
        tokenIn.mint(caller, 1000e18);
        vm.prank(caller);
        tokenIn.approve(address(lobster), type(uint256).max);
        _allow(caller, address(pool));

        uint256[2] memory callerBefore = [tokenIn.balanceOf(caller), tokenOut.balanceOf(caller)];
        uint256[2] memory poolBefore = [tokenIn.balanceOf(address(pool)), tokenOut.balanceOf(address(pool))];
        uint256[4] memory othersBefore = [
            tokenIn.balanceOf(user),
            tokenOut.balanceOf(user),
            tokenIn.balanceOf(recipient),
            tokenOut.balanceOf(recipient)
        ];

        vm.expectCall(address(pool), abi.encodeWithSelector(IUniswapV3PoolMinimal.swap.selector, caller));
        uint256 reported = _swap(
            caller,
            exactOut
                ? _exactOut(address(tokenIn), address(tokenOut), amount, type(uint128).max)
                : _exactIn(address(tokenIn), address(tokenOut), amount, 0)
        );

        uint256 paid = tokenIn.balanceOf(address(pool)) - poolBefore[0];
        uint256 received = poolBefore[1] - tokenOut.balanceOf(address(pool));
        assertEq(tokenIn.balanceOf(caller), callerBefore[0] - paid, "the caller did not pay exactly");
        assertEq(tokenOut.balanceOf(caller), callerBefore[1] + received, "the caller did not get the output");
        assertEq(reported, exactOut ? paid : received, "the reported amount is wrong");
        assertEq(exactOut ? received : paid, amount, "the exact side is not exact");
        assertEq(tokenIn.balanceOf(user), othersBefore[0]);
        assertEq(tokenOut.balanceOf(user), othersBefore[1]);
        assertEq(tokenIn.balanceOf(recipient), othersBefore[2]);
        assertEq(tokenOut.balanceOf(recipient), othersBefore[3]);
        _assertProxyHoldsNothing();
    }

    /// @notice The mint harness refuses itself as the recipient
    /// @dev A position minted to the proxy would be owned by it in the pool, and the proxy has no
    /// burn/collect, so the liquidity could never be withdrawn.
    function testMintRejectsTheProxyAsRecipient() public {
        uint256 userBefore = token0.balanceOf(user);

        vm.prank(user);
        vm.expectRevert(UniswapV3ProxyHarness.InvalidRecipient.selector);
        proxy.mintUnchecked(
            MintParams({
                token0: address(token0),
                token1: address(token1),
                fee: FEE,
                tickLower: TICK_LOWER,
                tickUpper: TICK_UPPER,
                amount0Desired: AMOUNT_DESIRED,
                amount1Desired: AMOUNT_DESIRED,
                amount0Min: 0,
                amount1Min: 0,
                recipient: address(proxy),
                deadline: block.timestamp + 3600
            })
        );

        assertEq(token0.balanceOf(user), userBefore, "caller paid");
        (uint128 liquidity,,,,) = pool.positions(keccak256(abi.encodePacked(address(proxy), TICK_LOWER, TICK_UPPER)));
        assertEq(liquidity, 0, "a position was minted to the proxy");
    }

    /// @notice The exit path the `mint` docs describe: only the recipient can withdraw a position,
    /// with two direct calls on the pool. Not even the account that paid for it can.
    function testOnlyTheRecipientCanExitAPositionDirectlyOnThePool() public {
        vm.prank(user);
        (uint256 paid0, uint256 paid1) = proxy.mintUnchecked(
            MintParams({
                token0: address(token0),
                token1: address(token1),
                fee: FEE,
                tickLower: TICK_LOWER,
                tickUpper: TICK_UPPER,
                amount0Desired: AMOUNT_DESIRED,
                amount1Desired: AMOUNT_DESIRED,
                amount0Min: 0,
                amount1Min: 0,
                recipient: recipient,
                deadline: block.timestamp + 3600
            })
        );
        bytes32 posKey = keccak256(abi.encodePacked(recipient, TICK_LOWER, TICK_UPPER));
        (uint128 liquidity,,,,) = pool.positions(posKey);
        assertGt(liquidity, 0, "no position minted");

        // The payer is not the owner: the pool has no position of theirs to burn
        vm.prank(user);
        vm.expectRevert();
        pool.burn(TICK_LOWER, TICK_UPPER, liquidity);

        // The recipient exits with the two documented calls
        uint256 r0 = token0.balanceOf(recipient);
        uint256 r1 = token1.balanceOf(recipient);
        vm.startPrank(recipient);
        pool.burn(TICK_LOWER, TICK_UPPER, liquidity);
        pool.collect(recipient, TICK_LOWER, TICK_UPPER, type(uint128).max, type(uint128).max);
        vm.stopPrank();

        // Burning rounds down by at most a wei per token
        assertApproxEqAbs(token0.balanceOf(recipient) - r0, paid0, 1, "token0 principal not returned");
        assertApproxEqAbs(token1.balanceOf(recipient) - r1, paid1, 1, "token1 principal not returned");
        (liquidity,,,,) = pool.positions(posKey);
        assertEq(liquidity, 0, "position not fully withdrawn");
    }

    // ===========================================================================
    // THE PAYER IS ALWAYS THE CALLER
    // ===========================================================================

    /// @notice The input is pulled from the account that called `swap` (the lock holder), not from
    /// tx.origin, even when tx.origin has standing approvals to the proxy
    function testSwapIsPaidByItsCallerNotByTxOrigin() public {
        _mintDefaultLiquidity();
        address vault = makeAddr("vault");
        token0.mint(vault, SWAP_AMOUNT);
        vm.prank(vault);
        token0.approve(address(lobster), type(uint256).max);
        _allow(vault, address(pool));
        bytes memory data = _data(_exactIn(address(token0), address(token1), SWAP_AMOUNT, 0));
        uint256 userT0Before = token0.balanceOf(user);
        uint256 userT1Before = token1.balanceOf(user);

        vm.prank(vault, user);
        uint256[] memory amounts = lobster.swap(data);

        assertEq(token0.balanceOf(vault), 0, "the caller did not pay");
        assertEq(token1.balanceOf(vault), amounts[0], "the caller did not receive");
        assertEq(token0.balanceOf(user), userT0Before, "tx.origin paid");
        assertEq(token1.balanceOf(user), userT1Before, "tx.origin received");
    }

    /// @notice An account registered for the pool but with nothing to pay can never make the proxy
    /// charge another account that approved it: its own swap fails to pull from itself ("STF"); funded,
    /// it pays for itself. The approved account is untouched either way.
    function testFuzz_SwapNeverChargesAnotherApprovedAccount(uint256 amount, bool exactOut) public {
        _mintDefaultLiquidity();
        address attacker = makeAddr("attacker");
        _allow(attacker, address(pool));
        amount = bound(amount, 1, 100e18);
        bytes memory data = _data(
            exactOut
                ? _exactOut(address(token0), address(token1), amount, type(uint128).max)
                : _exactIn(address(token0), address(token1), amount, 0)
        );
        uint256 userT0Before = token0.balanceOf(user);
        uint256 userT1Before = token1.balanceOf(user);

        _expectSwapRevert(attacker, data, _stringError("STF"));

        token0.mint(attacker, 1000e18);
        vm.prank(attacker);
        token0.approve(address(lobster), type(uint256).max);
        uint256 reported = _swapData(attacker, data);

        if (exactOut) {
            assertEq(token1.balanceOf(attacker), amount, "the attacker did not get its exact output");
            assertEq(token0.balanceOf(attacker), 1000e18 - reported, "the attacker did not pay its input");
        } else {
            assertEq(token0.balanceOf(attacker), 1000e18 - amount, "the attacker did not pay its input");
            assertEq(token1.balanceOf(attacker), reported, "the attacker did not get its output");
        }
        assertEq(token0.balanceOf(user), userT0Before, "another account paid");
        assertEq(token1.balanceOf(user), userT1Before, "another account was touched");
    }

    /// @notice A harness mint is paid by its caller, the account holding the lock, and by no one else:
    /// not by tx.origin, nor by the position's recipient, here one account that holds both tokens and
    /// approved the harness. A caller that has not approved the harness is refused ("STF") although that
    /// account could pay; once it approves, it pays exactly the amounts the call reports, the pool
    /// receives exactly them, and the position is the recipient's.
    function testMintIsPaidByItsCallerOnly() public {
        address vault = makeAddr("vault");
        token0.mint(vault, AMOUNT_DESIRED);
        token1.mint(vault, AMOUNT_DESIRED);
        MintParams memory params = MintParams({
            token0: address(token0),
            token1: address(token1),
            fee: FEE,
            tickLower: TICK_LOWER,
            tickUpper: TICK_UPPER,
            amount0Desired: AMOUNT_DESIRED,
            amount1Desired: AMOUNT_DESIRED,
            amount0Min: 0,
            amount1Min: 0,
            recipient: user,
            deadline: vm.getBlockTimestamp() + 3600
        });
        uint256 userT0Before = token0.balanceOf(user);
        uint256 userT1Before = token1.balanceOf(user);

        vm.prank(vault, user);
        vm.expectRevert(_stringError("STF"));
        proxy.mintUnchecked(params);

        vm.startPrank(vault);
        token0.approve(address(proxy), type(uint256).max);
        token1.approve(address(proxy), type(uint256).max);
        vm.stopPrank();
        uint256 poolT0Before = token0.balanceOf(address(pool));
        uint256 poolT1Before = token1.balanceOf(address(pool));

        vm.prank(vault, user);
        (uint256 amount0, uint256 amount1) = proxy.mintUnchecked(params);

        assertGt(amount0, 0, "nothing was deposited: the test proves nothing");
        assertGt(amount1, 0, "nothing was deposited: the test proves nothing");
        assertEq(token0.balanceOf(vault), AMOUNT_DESIRED - amount0, "the caller did not pay exactly amount0");
        assertEq(token1.balanceOf(vault), AMOUNT_DESIRED - amount1, "the caller did not pay exactly amount1");
        assertEq(token0.balanceOf(address(pool)), poolT0Before + amount0, "the pool was not paid exactly amount0");
        assertEq(token1.balanceOf(address(pool)), poolT1Before + amount1, "the pool was not paid exactly amount1");
        assertEq(token0.balanceOf(user), userT0Before, "tx.origin, the recipient, paid token0");
        assertEq(token1.balanceOf(user), userT1Before, "tx.origin, the recipient, paid token1");
        (uint128 liquidity,,,,) = pool.positions(keccak256(abi.encodePacked(user, TICK_LOWER, TICK_UPPER)));
        assertGt(liquidity, 0, "the recipient does not own the position");
    }

    // ===========================================================================
    // AMOUNTS CANNOT WRAP -- 128-bit fields
    // ===========================================================================

    /// @notice Replaces the uint256 -> int256 wrap test. Amounts are 128-bit fields now, so 2**255 and
    /// above cannot even be written, and the largest that can, including those with the field's top
    /// bit set, reach the pool as a positive amountSpecified (exact input), with the caller as
    /// recipient and the default price limit. The pool runs to that limit and the caller pays exactly
    /// what it took, far less than the amount.
    function testExactInputSingleLargestAmountsStayExactInput() public {
        _mintDefaultLiquidity();
        uint256[3] memory amounts = [uint256(2 ** 127 - 1), 2 ** 127, type(uint128).max];

        for (uint256 i = 0; i < amounts.length; i++) {
            for (uint256 direction = 0; direction < 2; direction++) {
                bool zeroForOne = direction == 0;
                (MockERC20 tokenIn, MockERC20 tokenOut) = zeroForOne ? (token0, token1) : (token1, token0);
                uint160 defaultLimit = zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1;
                uint256 snap = vm.snapshotState();
                uint256 userInBefore = tokenIn.balanceOf(user);
                uint256 userOutBefore = tokenOut.balanceOf(user);
                uint256 poolInBefore = tokenIn.balanceOf(address(pool));

                vm.expectCall(
                    address(pool), _poolSwapCall(user, zeroForOne, SafeCast.toInt256(amounts[i]), defaultLimit)
                );
                uint256 received = _swap(user, _exactIn(address(tokenIn), address(tokenOut), amounts[i], 1e18));

                uint256 paid = tokenIn.balanceOf(address(pool)) - poolInBefore;
                assertEq(tokenIn.balanceOf(user), userInBefore - paid, "the caller paid more than the pool took");
                assertLt(paid, amounts[i], "the amount was spent, not bounded by the pool");
                assertGe(received, 1e18, "amountOutMinimum not honoured");
                assertEq(tokenOut.balanceOf(user), userOutBefore + received);
                (uint160 priceAfter,,,,,,) = pool.slot0();
                assertEq(priceAfter, defaultLimit, "the swap did not run to the default limit");
                vm.revertToState(snap);
            }
        }
    }

    /// @notice The exact-output side of the same boundary: the largest amounts reach the pool as a
    /// negative amountSpecified (exact output). No pool holds that much, so without a price limit the
    /// leg reverts (exact output fills completely) and the caller pays nothing; with a limit, the
    /// partial fill costs exactly what the pool took.
    function testExactOutputSingleLargestAmountsStayExactOutput() public {
        _mintDefaultLiquidity();
        uint256[3] memory amounts = [uint256(2 ** 127 - 1), 2 ** 127, type(uint128).max];
        uint160 limit = TickMath.getSqrtRatioAtTick(-30);
        uint256 userT0Before = token0.balanceOf(user);

        for (uint256 i = 0; i < amounts.length; i++) {
            _expectSwapRevert(
                user,
                _data(_exactOut(address(token0), address(token1), amounts[i], type(uint128).max)),
                _proxyError(IProxyErrors.TooLittleReceived.selector)
            );
            assertEq(token0.balanceOf(user), userT0Before, "caller paid");

            uint256 snap = vm.snapshotState();
            uint256 poolT0Before = token0.balanceOf(address(pool));
            vm.expectCall(address(pool), _poolSwapCall(user, true, -SafeCast.toInt256(amounts[i]), limit));
            uint256 paid = _swap(
                user, _limited(_exactOut(address(token0), address(token1), amounts[i], type(uint128).max), limit)
            );

            assertEq(paid, token0.balanceOf(address(pool)) - poolT0Before, "reported input is not what the pool took");
            assertEq(token0.balanceOf(user), userT0Before - paid, "the caller paid more than the pool took");
            (uint160 priceAfter,,,,,,) = pool.slot0();
            assertEq(priceAfter, limit, "the partial fill did not stop at the limit");
            vm.revertToState(snap);
        }
    }

    /// @notice 2**128 needs 17 bytes: a leg written with one, as amount or as bound, no longer ends
    /// where the format says it does, so the data is malformed and nothing runs
    function testAmountsWiderThan128BitsCannotBeEncoded() public {
        _mintDefaultLiquidity();
        // V3, exact input, token0 -> token1, FEE
        bytes memory head = bytes.concat(bytes1(0x00), bytes1(0x00), bytes1(0x01), bytes3(FEE));
        bytes memory twoPow128 = bytes.concat(bytes1(0x01), bytes16(0));
        uint256 userT0Before = token0.balanceOf(user);

        vm.expectCall(address(pool), abi.encodeWithSelector(IUniswapV3PoolMinimal.swap.selector), 0);
        _expectSwapRevert(
            user, _rawData(bytes.concat(head, twoPow128, bytes16(0))), _proxyError(IProxyErrors.MalformedSwap.selector)
        );
        _expectSwapRevert(
            user,
            _rawData(bytes.concat(head, bytes16(SafeCast.toUint128(SWAP_AMOUNT)), twoPow128)),
            _proxyError(IProxyErrors.MalformedSwap.selector)
        );

        assertEq(token0.balanceOf(user), userT0Before, "caller paid");
    }

    /// @notice The low end: an amount of 0 reaches the pool, which refuses it ("AS"), for exact input
    /// and exact output alike; nothing moves
    function testZeroAmountIsRefused() public {
        _mintDefaultLiquidity();
        uint256 userT0Before = token0.balanceOf(user);
        uint256 userT1Before = token1.balanceOf(user);

        _expectSwapRevert(user, _data(_exactIn(address(token0), address(token1), 0, 0)), _stringError("AS"));
        _expectSwapRevert(
            user, _data(_exactOut(address(token0), address(token1), 0, type(uint128).max)), _stringError("AS")
        );

        assertEq(token0.balanceOf(user), userT0Before);
        assertEq(token1.balanceOf(user), userT1Before);
    }

    // ===========================================================================
    // PRICE LIMITS
    // ===========================================================================

    /// @notice A limit reached before amountIn is spent: the leg passes it to the pool as given, the
    /// pool stops exactly there, the caller pays only what the pool took, and the leg reports what
    /// the caller received
    function testExactInputSingleStopsAtItsPriceLimit() public {
        _mintDefaultLiquidity();
        uint160 limit = TickMath.getSqrtRatioAtTick(-30);
        uint256 userT0Before = token0.balanceOf(user);
        uint256 userT1Before = token1.balanceOf(user);
        uint256 poolT0Before = token0.balanceOf(address(pool));
        uint256 poolT1Before = token1.balanceOf(address(pool));

        vm.expectCall(address(pool), _poolSwapCall(user, true, SafeCast.toInt256(SWAP_AMOUNT), limit));
        uint256 amountOut = _swap(user, _limited(_exactIn(address(token0), address(token1), SWAP_AMOUNT, 0), limit));

        (uint160 priceAfter,,,,,,) = pool.slot0();
        assertEq(priceAfter, limit, "the swap did not stop at its limit");
        uint256 paid = token0.balanceOf(address(pool)) - poolT0Before;
        assertGt(paid, 0, "nothing was swapped");
        assertLt(paid, SWAP_AMOUNT, "the limit did not bind");
        assertEq(token0.balanceOf(user), userT0Before - paid, "the caller paid more than the pool took");
        assertEq(amountOut, poolT1Before - token1.balanceOf(address(pool)), "reported output is not what the pool paid");
        assertEq(token1.balanceOf(user), userT1Before + amountOut);
    }

    /// @notice A limit on the wrong side of the price, or at the pool's own extreme, reaches the pool as
    /// given and the pool refuses it ("SPL"); nothing moves
    function testPriceLimitOnTheWrongSideIsRefused() public {
        _mintDefaultLiquidity();
        (uint160 price,,,,,,) = pool.slot0();
        uint256 userT0Before = token0.balanceOf(user);
        uint256 userT1Before = token1.balanceOf(user);

        // Selling token0 lowers the price: a limit above it, or MIN_SQRT_RATIO itself, is invalid
        _expectSwapRevert(
            user,
            _data(_limited(_exactIn(address(token0), address(token1), SWAP_AMOUNT, 0), price + 1)),
            _stringError("SPL")
        );
        _expectSwapRevert(
            user,
            _data(_limited(_exactIn(address(token0), address(token1), SWAP_AMOUNT, 0), TickMath.MIN_SQRT_RATIO)),
            _stringError("SPL")
        );
        // Selling token1 raises it: a limit below it is invalid
        _expectSwapRevert(
            user,
            _data(_limited(_exactIn(address(token1), address(token0), SWAP_AMOUNT, 0), price - 1)),
            _stringError("SPL")
        );

        assertEq(token0.balanceOf(user), userT0Before);
        assertEq(token1.balanceOf(user), userT1Before);
    }

    /// @notice With the PRICE_LIMIT flag the limit field cannot be 0 (no limit is written by leaving the
    /// flag out): such data is malformed and runs nothing, while the same leg with a real limit runs
    function testZeroPriceLimitIsMalformed() public {
        _mintDefaultLiquidity();
        // V3, exact input with a price limit, token0 -> token1, FEE, amountIn, amountOutMinimum 0
        bytes memory head = bytes.concat(
            bytes1(SwapFlags.PRICE_LIMIT),
            bytes1(0x00),
            bytes1(0x01),
            bytes3(FEE),
            bytes16(SafeCast.toUint128(SWAP_AMOUNT)),
            bytes16(0)
        );
        uint160 limit = TickMath.getSqrtRatioAtTick(-30);

        // The pool is called once: by the well-formed control below
        vm.expectCall(address(pool), abi.encodeWithSelector(IUniswapV3PoolMinimal.swap.selector), 1);
        _expectSwapRevert(
            user, _rawData(bytes.concat(head, bytes20(0))), _proxyError(IProxyErrors.MalformedSwap.selector)
        );
        _swapData(user, _rawData(bytes.concat(head, bytes20(limit))));

        (uint160 priceAfter,,,,,,) = pool.slot0();
        assertEq(priceAfter, limit, "the control leg did not run with its limit");
    }

    // ===========================================================================
    // EXACT OUTPUT SINGLE -- happy paths
    // ===========================================================================

    /// @notice Exact output token0 -> token1: the caller receives exactly amountOut and pays exactly
    /// what the call reports
    function testExactOutputSingleZeroForOne() public {
        _mintDefaultLiquidity();

        uint256 desiredOut = 5e18;
        uint256 expectedIn = _probeExactOutput(address(token0), address(token1), desiredOut);

        uint256 userT0Before = token0.balanceOf(user);
        uint256 userT1Before = token1.balanceOf(user);
        uint256 recipientT1Before = token1.balanceOf(recipient);
        uint256 poolT0Before = token0.balanceOf(address(pool));
        uint256 poolT1Before = token1.balanceOf(address(pool));

        uint256 amountIn = _swap(user, _exactOut(address(token0), address(token1), desiredOut, SWAP_AMOUNT));

        // Input matches probed expectation
        assertEq(amountIn, expectedIn, "amountIn should match probed value");

        // The fee + price impact cost is exactly amountIn - desiredOut
        uint256 totalCost = amountIn - desiredOut;
        assertEq(totalCost, expectedIn - desiredOut, "total cost should match probed expectation");

        // The caller received exactly the desired output, the outsider nothing
        assertEq(token1.balanceOf(user), userT1Before + desiredOut);
        assertEq(token1.balanceOf(recipient), recipientT1Before, "an outsider received the output");

        // Exact balance accounting
        assertEq(token0.balanceOf(user), userT0Before - amountIn);
        assertEq(token0.balanceOf(address(pool)), poolT0Before + amountIn);
        assertEq(token1.balanceOf(address(pool)), poolT1Before - desiredOut);
    }

    /// @notice Exact output token1 -> token0: same exact accounting in the other direction
    function testExactOutputSingleOneForZero() public {
        _mintDefaultLiquidity();

        uint256 desiredOut = 5e18;
        uint256 expectedIn = _probeExactOutput(address(token1), address(token0), desiredOut);

        uint256 userT1Before = token1.balanceOf(user);
        uint256 userT0Before = token0.balanceOf(user);
        uint256 recipientT0Before = token0.balanceOf(recipient);
        uint256 poolT0Before = token0.balanceOf(address(pool));
        uint256 poolT1Before = token1.balanceOf(address(pool));

        uint256 amountIn = _swap(user, _exactOut(address(token1), address(token0), desiredOut, SWAP_AMOUNT));

        assertEq(amountIn, expectedIn);
        assertEq(token0.balanceOf(user), userT0Before + desiredOut);
        assertEq(token0.balanceOf(recipient), recipientT0Before, "an outsider received the output");
        assertEq(token1.balanceOf(user), userT1Before - amountIn);
        assertEq(token1.balanceOf(address(pool)), poolT1Before + amountIn);
        assertEq(token0.balanceOf(address(pool)), poolT0Before - desiredOut);
    }

    /// @notice The caller is its own recipient (now the only possible one) for exact output too
    function testExactOutputSingleRecipientIsSelf() public {
        _mintDefaultLiquidity();

        uint256 desiredOut = 5e18;
        uint256 expectedIn = _probeExactOutput(address(token0), address(token1), desiredOut);
        uint256 userT0Before = token0.balanceOf(user);
        uint256 userT1Before = token1.balanceOf(user);

        uint256 amountIn = _swap(user, _exactOut(address(token0), address(token1), desiredOut, SWAP_AMOUNT));

        assertEq(amountIn, expectedIn);
        assertEq(token0.balanceOf(user), userT0Before - amountIn);
        assertEq(token1.balanceOf(user), userT1Before + desiredOut);
    }

    /// @notice amountInMaximum set to exactly the required input passes
    function testExactOutputSingleMaximumInputExactlyMet() public {
        _mintDefaultLiquidity();

        uint256 desiredOut = 5e18;
        uint256 exactRequired = _probeExactOutput(address(token0), address(token1), desiredOut);
        uint256 userT1Before = token1.balanceOf(user);

        // exactly enough
        uint256 amountIn = _swap(user, _exactOut(address(token0), address(token1), desiredOut, exactRequired));

        assertEq(amountIn, exactRequired, "amountIn should equal the exact required amount");
        assertEq(token1.balanceOf(user), userT1Before + desiredOut);
    }

    // ===========================================================================
    // EXACT OUTPUT SINGLE -- revert cases
    // ===========================================================================

    /// @notice An exact-output call past its deadline reverts before anything runs
    function testExactOutputSingleRevertsOnExpiredDeadline() public {
        _mintDefaultLiquidity();

        bytes memory data = SwapCalldata.encode(
            vm.getBlockTimestamp() - 1, _one(_exactOut(address(token0), address(token1), 5e18, SWAP_AMOUNT))
        );

        vm.expectCall(address(pool), abi.encodeWithSelector(IUniswapV3PoolMinimal.swap.selector), 0);
        _expectSwapRevert(user, data, _proxyError(IProxyErrors.TransactionTooOld.selector));
    }

    /// @notice An impossibly small amountInMaximum reverts
    function testExactOutputSingleRevertsOnSlippageExceeded() public {
        _mintDefaultLiquidity();

        // impossibly small
        _expectSwapRevert(
            user,
            _data(_exactOut(address(token0), address(token1), 5e18, 1)),
            _proxyError(IProxyErrors.TooMuchRequested.selector)
        );
    }

    /// @notice amountInMaximum one wei below the required input reverts
    function testExactOutputSingleRevertsSlippageByOneWei() public {
        _mintDefaultLiquidity();

        uint256 desiredOut = 5e18;
        uint256 exactRequired = _probeExactOutput(address(token0), address(token1), desiredOut);

        // one wei below required -- must revert
        _expectSwapRevert(
            user,
            _data(_exactOut(address(token0), address(token1), desiredOut, exactRequired - 1)),
            _proxyError(IProxyErrors.TooMuchRequested.selector)
        );
    }

    /// @notice Replaces "zero recipient reverts" for exact output: appending a recipient makes the data
    /// malformed, and the well-formed leg delivers exactly amountOut to the caller, nothing burnt
    function testExactOutputSingleOutputCanOnlyGoToTheCaller() public {
        _mintDefaultLiquidity();
        uint256 desiredOut = 5e18;
        SwapCalldata.Leg memory leg = _exactOut(address(token0), address(token1), desiredOut, SWAP_AMOUNT);

        _expectSwapRevert(
            user, bytes.concat(_data(leg), bytes20(address(0))), _proxyError(IProxyErrors.MalformedSwap.selector)
        );

        uint256 supply = token1.totalSupply();
        uint256 userT1Before = token1.balanceOf(user);
        uint256 poolT1Before = token1.balanceOf(address(pool));
        uint256 recipientT1Before = token1.balanceOf(recipient);

        vm.expectCall(address(pool), abi.encodeWithSelector(IUniswapV3PoolMinimal.swap.selector, user));
        _swap(user, leg);

        assertEq(token1.balanceOf(user), userT1Before + desiredOut, "the caller did not get exactly amountOut");
        assertEq(poolT1Before - token1.balanceOf(address(pool)), desiredOut, "the pool paid out something else");
        assertEq(token1.totalSupply(), supply, "output was burnt");
        assertEq(token1.balanceOf(recipient), recipientT1Before, "an outsider received the output");
        _assertProxyHoldsNothing();
    }

    /// @notice The caller (registered for the pool) has not approved the proxy
    function testExactOutputSingleRevertsWithoutApproval() public {
        _mintDefaultLiquidity();

        address noApproval = makeAddr("noApproval");
        token0.mint(noApproval, SWAP_AMOUNT);
        _allow(noApproval, address(pool));

        _expectSwapRevert(
            noApproval, _data(_exactOut(address(token0), address(token1), 5e18, SWAP_AMOUNT)), _stringError("STF")
        );
        assertEq(token0.balanceOf(noApproval), SWAP_AMOUNT);
    }

    /// @notice Exact output on a pair no pool exists for: PoolNotAllowed unregistered, NotAPool once
    /// its CREATE2 key is registered; the pool address is never called and nothing moves
    function testExactOutputSingleRevertsOnNonExistentPool() public {
        MockERC20 rogue = new MockERC20();
        address nowhere = _v3PoolAddress(address(token0), address(rogue), FEE);
        assertEq(nowhere.code.length, 0, "a pool exists there: the test proves nothing");

        bytes memory data = _data(_exactOut(address(token0), address(rogue), 5e18, SWAP_AMOUNT));
        uint256 userT0Before = token0.balanceOf(user);
        vm.expectCall(nowhere, abi.encodeWithSelector(IUniswapV3PoolMinimal.swap.selector), 0);

        _expectSwapRevert(user, data, _proxyError(IProxyErrors.PoolNotAllowed.selector));

        _allow(user, nowhere);
        _expectSwapRevert(user, data, _proxyError(IProxyErrors.NotAPool.selector));

        assertEq(token0.balanceOf(user), userT0Before, "caller paid");
        assertEq(rogue.balanceOf(user), 0, "caller received");
        _assertProxyHoldsNothing();
    }

    // ===========================================================================
    // SWAP CONSISTENCY -- exactInput and exactOutput produce matching results
    // ===========================================================================

    /// @notice Exact output of what an exact input yields costs that exact input, within a wei
    function testExactInputAndOutputConsistency() public {
        _mintDefaultLiquidity();

        // Probe: exactInput of SWAP_AMOUNT -> how much output?
        uint256 outputForInput = _probeExactInput(address(token0), address(token1), SWAP_AMOUNT);

        // Probe: how much input to get exactly that output?
        uint256 inputForOutput = _probeExactOutput(address(token0), address(token1), outputForInput);

        // They should agree within 1 wei rounding
        assertApproxEqAbs(
            inputForOutput, SWAP_AMOUNT, 1, "exactOutput input should match the original exactInput amount"
        );
    }

    // ===========================================================================
    // EXACT OUTPUT MEANS EXACT -- no silent partial fills without a price limit
    // ===========================================================================

    uint24 constant THIN_FEE = 500;

    /// @dev A second, deliberately thin pool: 20 of each token around price 1, so it can run dry.
    /// Registered for the user like the main pool.
    function _createThinPool() internal returns (IUniswapV3PoolMinimal thin) {
        thin = IUniswapV3PoolMinimal(factory.createPool(address(token0), address(token1), THIN_FEE));
        thin.initialize(2 ** 96);

        address lp = makeAddr("lp");
        token0.mint(lp, 20e18);
        token1.mint(lp, 20e18);
        vm.startPrank(lp);
        token0.approve(address(proxy), type(uint256).max);
        token1.approve(address(proxy), type(uint256).max);
        proxy.mintUnchecked(_thinMintParams(-6000, 6000, 20e18, 20e18, lp));
        vm.stopPrank();

        _allow(user, address(thin));
    }

    function _thinMintParams(
        int24 lower,
        int24 upper,
        uint256 amount0,
        uint256 amount1,
        address to
    )
        internal
        view
        returns (MintParams memory)
    {
        return MintParams({
            token0: address(token0),
            token1: address(token1),
            fee: THIN_FEE,
            tickLower: lower,
            tickUpper: upper,
            amount0Desired: amount0,
            amount1Desired: amount1,
            amount0Min: 0,
            amount1Min: 0,
            recipient: to,
            deadline: vm.getBlockTimestamp() + 3600
        });
    }

    /// @dev token0 in, token1 out, on the thin pool
    function _thinExactOut(
        uint256 amountOut,
        uint256 maxIn,
        uint160 limit
    )
        internal
        view
        returns (SwapCalldata.Leg memory leg)
    {
        leg = _limited(_exactOut(address(token0), address(token1), amountOut, maxIn), limit);
        leg.fee = THIN_FEE;
    }

    /// @notice Without a price limit, an exact output the pool cannot fill reverts instead of
    /// spending amountInMaximum on a partial fill
    function testExactOutputSingleRevertsOnShortFill() public {
        _createThinPool();
        uint256 userT0Before = token0.balanceOf(user);
        uint256 userT1Before = token1.balanceOf(user);

        // pool holds ~20
        _expectSwapRevert(
            user,
            _data(_thinExactOut(100e18, type(uint128).max, 0)),
            _proxyError(IProxyErrors.TooLittleReceived.selector)
        );

        assertEq(token0.balanceOf(user), userT0Before, "caller paid for a partial fill");
        assertEq(token1.balanceOf(user), userT1Before, "a partial fill was delivered");
    }

    /// @notice An exact output with a price limit may fill partially, up to the limit, and is charged
    /// exactly what it reports
    /// @dev With an explicit price limit the caller has bounded the price, so a partial fill is a
    /// legitimate outcome and still succeeds.
    function testExactOutputSingleWithPriceLimitMayFillPartially() public {
        IUniswapV3PoolMinimal thin = _createThinPool();
        uint256 userT0Before = token0.balanceOf(user);
        uint256 userT1Before = token1.balanceOf(user);
        uint160 limit = TickMath.getSqrtRatioAtTick(-600);

        uint256 amountIn = _swap(user, _thinExactOut(100e18, type(uint128).max, limit));

        uint256 delivered = token1.balanceOf(user) - userT1Before;
        assertGt(amountIn, 0, "nothing was paid");
        assertEq(token0.balanceOf(user), userT0Before - amountIn, "the reported input is not what was paid");
        assertGt(delivered, 0, "nothing was delivered");
        assertLt(delivered, 100e18, "expected a partial fill up to the price limit");
        (uint160 priceAfter,,,,,,) = thin.slot0();
        assertEq(priceAfter, limit, "the partial fill did not stop at the limit");
    }

    /// @notice The audit's sandwich, end to end. The attacker buys out the honest liquidity and parks
    /// a tiny position at a price ~20x worse than fair. Before the fix the victim's "exactly 2, for at
    /// most 2.2" order filled 0.1 of the 2 against it for ~1.95 and reported success. Now it reverts.
    function testExactOutputSingleSandwichAgainstShortFillReverts() public {
        IUniswapV3PoolMinimal thin = _createThinPool();

        // The attacker is just another account that registered the pool for itself
        address attacker = makeAddr("attacker");
        token0.mint(attacker, 1000e18);
        token1.mint(attacker, 10e18);
        _allow(attacker, address(thin));
        vm.startPrank(attacker);
        token0.approve(address(lobster), type(uint256).max);
        token1.approve(address(proxy), type(uint256).max);
        vm.stopPrank();

        // Front-run 1: buy out all honest token1, stopping just past the honest range
        SwapCalldata.Leg memory buyOut =
            _limited(_exactIn(address(token0), address(token1), 1000e18, 0), TickMath.getSqrtRatioAtTick(-6010));
        buyOut.fee = THIN_FEE;
        _swap(attacker, buyOut);
        // Front-run 2: a tiny token1-only position far below fair price
        vm.prank(attacker);
        proxy.mintUnchecked(_thinMintParams(-30000, -29400, 0, 0.1e18, attacker));

        uint256 victimBefore = token0.balanceOf(user);
        uint256 victimT1Before = token1.balanceOf(user);

        _expectSwapRevert(
            user, _data(_thinExactOut(2e18, 2.2e18, 0)), _proxyError(IProxyErrors.TooLittleReceived.selector)
        );

        assertEq(token0.balanceOf(user), victimBefore, "victim paid");
        assertEq(token1.balanceOf(user), victimT1Before, "victim received a partial fill");
    }
}
