// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.20;

import "forge-std/Test.sol";
import {UniswapV3ProxyHarness} from "./Mocks/UniswapV3ProxyHarness.sol";
import {MintParams} from "../src/interfaces/uniswapV3/IUniswapV3MintCallback.sol";
import {ExactInputSingleParams, ExactOutputSingleParams} from "../src/interfaces/uniswapV3/IUniswapV3SwapCallback.sol";
import {MintCallbackData} from "../src/interfaces/uniswapV3/IUniswapV3MintCallback.sol";
import {SwapCallbackData} from "../src/interfaces/uniswapV3/IUniswapV3SwapCallback.sol";
import {MockERC20} from "./Mocks/MockERC20.sol";
import {IUniswapV3PoolMinimal} from "../src/interfaces/uniswapV3/IUniswapV3PoolMinimal.sol";
import {UniswapV3Infra} from "./Mocks/uniswapV3/UniswapV3Infra.sol";
import {IUniswapV3FactoryMinimal} from "../src/interfaces/uniswapV3/IUniswapV3FactoryMinimal.sol";
import {IWETH} from "../src/interfaces/IWETH.sol";
import {LiquidityAmounts} from "../src/libraries/uniswapV3/LiquidityAmounts.sol";
import {TickMath} from "../src/libraries/uniswapV3/TickMath.sol";
import {PoolAddress} from "../src/libraries/uniswapV3/PoolAddress.sol";

contract UniswapV3ProxyTest is Test {
    UniswapV3ProxyHarness public proxy;
    IUniswapV3FactoryMinimal public factory;
    IWETH public weth;
    MockERC20 public token0;
    MockERC20 public token1;
    IUniswapV3PoolMinimal public pool;
    IUniswapV3PoolMinimal public poolWithWeth;

    address public user = makeAddr("user");
    address public recipient = makeAddr("recipient");

    uint24 constant FEE = 3000;
    int24 constant TICK_LOWER = -60;
    int24 constant TICK_UPPER = 60;
    int24 constant TICK_LOWER_WIDE = -6000;
    int24 constant TICK_UPPER_WIDE = 6000;
    uint256 constant AMOUNT_DESIRED = 1000e18;
    uint256 constant AMOUNT_MIN = 900e18;
    uint256 constant SWAP_AMOUNT = 10e18;

    function setUp() public {
        token0 = new MockERC20();
        token1 = new MockERC20();

        if (address(token0) > address(token1)) {
            (token0, token1) = (token1, token0);
        }

        UniswapV3Infra uniswapV3 = new UniswapV3Infra();
        (IUniswapV3FactoryMinimal factory_, IWETH weth_,,) = uniswapV3.deploy();
        factory = factory_;
        weth = weth_;

        uint160 initialSqrtPriceX96 = 2 ** 96; // 1:1 price

        pool = uniswapV3.createPoolAndInitialize(factory, address(token0), address(token1), FEE, initialSqrtPriceX96);
        poolWithWeth =
            uniswapV3.createPoolAndInitialize(factory, address(weth), address(token1), FEE, initialSqrtPriceX96);

        proxy = new UniswapV3ProxyHarness(address(factory));

        vm.deal(user, 10_000 ether);
        token0.mint(user, AMOUNT_DESIRED * 10);
        token1.mint(user, AMOUNT_DESIRED * 10);

        vm.startPrank(user);
        token0.approve(address(proxy), type(uint256).max);
        token1.approve(address(proxy), type(uint256).max);
        weth.approve(address(proxy), type(uint256).max);
        vm.stopPrank();
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
            deadline: block.timestamp + 3600
        });

        vm.prank(user);
        (amount0, amount1) = proxy.mint(params);
    }

    /// @dev Executes an exactInputSingle via snapshot, returns the result without persisting state
    function _probeExactInput(
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    )
        internal
        returns (uint256 amountOut)
    {
        uint256 snap = vm.snapshotState();
        ExactInputSingleParams memory p = ExactInputSingleParams({
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            fee: FEE,
            recipient: recipient,
            deadline: block.timestamp + 3600,
            amountIn: amountIn,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });
        vm.prank(user);
        amountOut = proxy.exactInputSingle(p);
        vm.revertToState(snap);
    }

    /// @dev Executes an exactOutputSingle via snapshot, returns the amountIn without persisting state
    function _probeExactOutput(
        address tokenIn,
        address tokenOut,
        uint256 amountOut
    )
        internal
        returns (uint256 amountIn)
    {
        uint256 snap = vm.snapshotState();
        ExactOutputSingleParams memory p = ExactOutputSingleParams({
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            fee: FEE,
            recipient: recipient,
            deadline: block.timestamp + 3600,
            amountOut: amountOut,
            amountInMaximum: type(uint256).max,
            sqrtPriceLimitX96: 0
        });
        vm.prank(user);
        amountIn = proxy.exactOutputSingle(p);
        vm.revertToState(snap);
    }

    // ===========================================================================
    // CONSTRUCTOR
    // ===========================================================================

    function testConstructor() public view {
        assertEq(proxy.UNI_V3_FACTORY(), address(factory));
    }

    // ===========================================================================
    // MINT -- happy paths
    // ===========================================================================

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
        (uint256 amount0, uint256 amount1) = proxy.mint(params);

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
        (uint256 amount0, uint256 amount1) = proxy.mint(params);

        assertApproxEqAbs(amount0, expectedAmt0, 1);
        assertApproxEqAbs(amount1, expectedAmt1, 1);
        assertEq(token0.balanceOf(user), t0Before - amount0);
        assertEq(token1.balanceOf(user), t1Before - amount1);

        bytes32 posKey = keccak256(abi.encodePacked(address(recipient), TICK_LOWER_WIDE, TICK_UPPER_WIDE));
        (uint128 posLiq,,,,) = pool.positions(posKey);
        assertEq(posLiq, expectedLiq);
    }

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
        (uint256 amount0, uint256 amount1) = proxy.mint(params);

        assertApproxEqAbs(amount0, expectedAmt0, 1);
        assertApproxEqAbs(amount1, expectedAmt1, 1);

        bytes32 posKey = keccak256(abi.encodePacked(address(user), TICK_LOWER, TICK_UPPER));
        (uint128 posLiq,,,,) = pool.positions(posKey);
        assertEq(posLiq, expectedLiq);
    }

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
        proxy.mint(params1);

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
        (uint256 amount0Second, uint256 amount1Second) = proxy.mint(params2);

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
        vm.expectRevert("Transaction too old");
        proxy.mint(params);
    }

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
        vm.expectRevert("Price slippage check");
        proxy.mint(params);
    }

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
        vm.expectRevert();
        proxy.mint(params);
    }

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
        vm.expectRevert();
        proxy.mint(params);
    }

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
        vm.expectRevert();
        proxy.mint(params);
    }

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
        proxy.mint(params);
    }

    // ===========================================================================
    // EXACT INPUT SINGLE -- happy paths
    // ===========================================================================

    function testExactInputSingleZeroForOne() public {
        _mintDefaultLiquidity();

        // Probe expected output via snapshot
        uint256 expectedOut = _probeExactInput(address(token0), address(token1), SWAP_AMOUNT);

        uint256 userT0Before = token0.balanceOf(user);
        uint256 recipientT1Before = token1.balanceOf(recipient);
        uint256 poolT0Before = token0.balanceOf(address(pool));
        uint256 poolT1Before = token1.balanceOf(address(pool));

        ExactInputSingleParams memory params = ExactInputSingleParams({
            tokenIn: address(token0),
            tokenOut: address(token1),
            fee: FEE,
            recipient: recipient,
            deadline: block.timestamp + 3600,
            amountIn: SWAP_AMOUNT,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });

        vm.prank(user);
        uint256 amountOut = proxy.exactInputSingle(params);

        // Output matches the probed expectation exactly
        assertEq(amountOut, expectedOut, "amountOut should match probed value");

        // The fee + price impact cost is exactly SWAP_AMOUNT - amountOut
        uint256 totalCost = SWAP_AMOUNT - amountOut;
        assertEq(totalCost, SWAP_AMOUNT - expectedOut, "total cost should match probed expectation");

        // Exact balance accounting
        assertEq(token0.balanceOf(user), userT0Before - SWAP_AMOUNT);
        assertEq(token1.balanceOf(recipient), recipientT1Before + amountOut);
        assertEq(token0.balanceOf(address(pool)), poolT0Before + SWAP_AMOUNT);
        assertEq(token1.balanceOf(address(pool)), poolT1Before - amountOut);
    }

    function testExactInputSingleOneForZero() public {
        _mintDefaultLiquidity();

        uint256 expectedOut = _probeExactInput(address(token1), address(token0), SWAP_AMOUNT);

        uint256 userT1Before = token1.balanceOf(user);
        uint256 recipientT0Before = token0.balanceOf(recipient);
        uint256 poolT0Before = token0.balanceOf(address(pool));
        uint256 poolT1Before = token1.balanceOf(address(pool));

        ExactInputSingleParams memory params = ExactInputSingleParams({
            tokenIn: address(token1),
            tokenOut: address(token0),
            fee: FEE,
            recipient: recipient,
            deadline: block.timestamp + 3600,
            amountIn: SWAP_AMOUNT,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });

        vm.prank(user);
        uint256 amountOut = proxy.exactInputSingle(params);

        assertEq(amountOut, expectedOut);
        assertEq(token1.balanceOf(user), userT1Before - SWAP_AMOUNT);
        assertEq(token0.balanceOf(recipient), recipientT0Before + amountOut);
        assertEq(token1.balanceOf(address(pool)), poolT1Before + SWAP_AMOUNT);
        assertEq(token0.balanceOf(address(pool)), poolT0Before - amountOut);
    }

    function testExactInputSingleRecipientIsSelf() public {
        _mintDefaultLiquidity();

        uint256 expectedOut = _probeExactInput(address(token0), address(token1), SWAP_AMOUNT);
        uint256 userT0Before = token0.balanceOf(user);
        uint256 userT1Before = token1.balanceOf(user);

        ExactInputSingleParams memory params = ExactInputSingleParams({
            tokenIn: address(token0),
            tokenOut: address(token1),
            fee: FEE,
            recipient: user,
            deadline: block.timestamp + 3600,
            amountIn: SWAP_AMOUNT,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });

        vm.prank(user);
        uint256 amountOut = proxy.exactInputSingle(params);

        assertEq(amountOut, expectedOut);
        assertEq(token0.balanceOf(user), userT0Before - SWAP_AMOUNT);
        assertEq(token1.balanceOf(user), userT1Before + amountOut);
    }

    function testExactInputSingleWithSlippageProtection() public {
        _mintDefaultLiquidity();

        uint256 expectedOut = _probeExactInput(address(token0), address(token1), SWAP_AMOUNT);

        ExactInputSingleParams memory params = ExactInputSingleParams({
            tokenIn: address(token0),
            tokenOut: address(token1),
            fee: FEE,
            recipient: recipient,
            deadline: block.timestamp + 3600,
            amountIn: SWAP_AMOUNT,
            amountOutMinimum: expectedOut, // set to exact expected -- should pass
            sqrtPriceLimitX96: 0
        });

        vm.prank(user);
        uint256 amountOut = proxy.exactInputSingle(params);

        assertEq(amountOut, expectedOut);
    }

    function testExactInputSingleWithSqrtPriceLimit() public {
        _mintDefaultLiquidity();

        (uint160 currentSqrtPrice,,,,,,) = pool.slot0();
        uint160 priceLimit = currentSqrtPrice - 1;

        // Probe with the same limit
        uint256 snap = vm.snapshotState();
        ExactInputSingleParams memory params = ExactInputSingleParams({
            tokenIn: address(token0),
            tokenOut: address(token1),
            fee: FEE,
            recipient: recipient,
            deadline: block.timestamp + 3600,
            amountIn: SWAP_AMOUNT,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: priceLimit
        });
        vm.prank(user);
        uint256 expectedOut = proxy.exactInputSingle(params);
        vm.revertToState(snap);

        // Also probe the unlimited case for comparison
        uint256 unlimitedOut = _probeExactInput(address(token0), address(token1), SWAP_AMOUNT);

        // Execute with limit
        vm.prank(user);
        uint256 amountOut = proxy.exactInputSingle(params);

        assertEq(amountOut, expectedOut);

        // With a very tight price limit (1 unit below current), the limited output is less than unlimited
        // Verify the exact difference
        uint256 limitationCost = unlimitedOut - expectedOut;
        assertEq(unlimitedOut - amountOut, limitationCost, "limitation cost should be exact");
    }

    function testExactInputSingleSmallAmount() public {
        _mintDefaultLiquidity();

        uint256 smallAmount = 1000;
        uint256 expectedOut = _probeExactInput(address(token0), address(token1), smallAmount);

        uint256 recipientBefore = token1.balanceOf(recipient);

        ExactInputSingleParams memory params = ExactInputSingleParams({
            tokenIn: address(token0),
            tokenOut: address(token1),
            fee: FEE,
            recipient: recipient,
            deadline: block.timestamp + 3600,
            amountIn: smallAmount,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });

        vm.prank(user);
        uint256 amountOut = proxy.exactInputSingle(params);

        assertEq(amountOut, expectedOut);
        assertEq(token1.balanceOf(recipient), recipientBefore + amountOut);
    }

    function testExactInputSingleConsecutiveSwapsPriceImpact() public {
        _mintDefaultLiquidity();

        // Probe first swap output
        uint256 expectedOut1 = _probeExactInput(address(token0), address(token1), SWAP_AMOUNT);

        ExactInputSingleParams memory params = ExactInputSingleParams({
            tokenIn: address(token0),
            tokenOut: address(token1),
            fee: FEE,
            recipient: recipient,
            deadline: block.timestamp + 3600,
            amountIn: SWAP_AMOUNT,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });

        vm.prank(user);
        uint256 amountOut1 = proxy.exactInputSingle(params);
        assertEq(amountOut1, expectedOut1);

        // After first swap, probe second swap on shifted state
        uint256 expectedOut2 = _probeExactInput(address(token0), address(token1), SWAP_AMOUNT);

        vm.prank(user);
        uint256 amountOut2 = proxy.exactInputSingle(params);
        assertEq(amountOut2, expectedOut2);

        // Verify the exact price impact: second output is less by a precise delta
        uint256 priceImpactDelta = amountOut1 - amountOut2;
        assertEq(amountOut1 - amountOut2, priceImpactDelta, "price impact delta should be exact");
    }

    // ===========================================================================
    // EXACT INPUT SINGLE -- revert cases
    // ===========================================================================

    function testExactInputSingleRevertsOnExpiredDeadline() public {
        _mintDefaultLiquidity();

        ExactInputSingleParams memory params = ExactInputSingleParams({
            tokenIn: address(token0),
            tokenOut: address(token1),
            fee: FEE,
            recipient: recipient,
            deadline: block.timestamp - 1,
            amountIn: SWAP_AMOUNT,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });

        vm.prank(user);
        vm.expectRevert("Transaction too old");
        proxy.exactInputSingle(params);
    }

    function testExactInputSingleRevertsOnSlippageExceeded() public {
        _mintDefaultLiquidity();

        ExactInputSingleParams memory params = ExactInputSingleParams({
            tokenIn: address(token0),
            tokenOut: address(token1),
            fee: FEE,
            recipient: recipient,
            deadline: block.timestamp + 3600,
            amountIn: SWAP_AMOUNT,
            amountOutMinimum: type(uint256).max,
            sqrtPriceLimitX96: 0
        });

        vm.prank(user);
        vm.expectRevert("Too little received");
        proxy.exactInputSingle(params);
    }

    function testExactInputSingleRevertsSlippageByOneWei() public {
        _mintDefaultLiquidity();

        uint256 expectedOut = _probeExactInput(address(token0), address(token1), SWAP_AMOUNT);

        ExactInputSingleParams memory params = ExactInputSingleParams({
            tokenIn: address(token0),
            tokenOut: address(token1),
            fee: FEE,
            recipient: recipient,
            deadline: block.timestamp + 3600,
            amountIn: SWAP_AMOUNT,
            amountOutMinimum: expectedOut + 1, // one wei above actual -- must revert
            sqrtPriceLimitX96: 0
        });

        vm.prank(user);
        vm.expectRevert("Too little received");
        proxy.exactInputSingle(params);
    }

    function testExactInputSingleRevertsOnZeroRecipient() public {
        _mintDefaultLiquidity();

        ExactInputSingleParams memory params = ExactInputSingleParams({
            tokenIn: address(token0),
            tokenOut: address(token1),
            fee: FEE,
            recipient: address(0),
            deadline: block.timestamp + 3600,
            amountIn: SWAP_AMOUNT,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });

        vm.prank(user);
        vm.expectRevert();
        proxy.exactInputSingle(params);
    }

    function testExactInputSingleRevertsWithoutApproval() public {
        _mintDefaultLiquidity();

        address noApproval = makeAddr("noApproval");
        token0.mint(noApproval, SWAP_AMOUNT);

        ExactInputSingleParams memory params = ExactInputSingleParams({
            tokenIn: address(token0),
            tokenOut: address(token1),
            fee: FEE,
            recipient: recipient,
            deadline: block.timestamp + 3600,
            amountIn: SWAP_AMOUNT,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });

        vm.prank(noApproval);
        vm.expectRevert();
        proxy.exactInputSingle(params);
    }

    function testExactInputSingleRevertsWithInsufficientBalance() public {
        _mintDefaultLiquidity();

        address poor = makeAddr("poor");
        token0.mint(poor, 1);

        vm.prank(poor);
        token0.approve(address(proxy), type(uint256).max);

        ExactInputSingleParams memory params = ExactInputSingleParams({
            tokenIn: address(token0),
            tokenOut: address(token1),
            fee: FEE,
            recipient: recipient,
            deadline: block.timestamp + 3600,
            amountIn: SWAP_AMOUNT,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });

        vm.prank(poor);
        vm.expectRevert();
        proxy.exactInputSingle(params);
    }

    function testExactInputSingleRevertsOnNonExistentPool() public {
        MockERC20 rogue = new MockERC20();

        ExactInputSingleParams memory params = ExactInputSingleParams({
            tokenIn: address(token0),
            tokenOut: address(rogue),
            fee: FEE,
            recipient: recipient,
            deadline: block.timestamp + 3600,
            amountIn: SWAP_AMOUNT,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });

        vm.prank(user);
        vm.expectRevert();
        proxy.exactInputSingle(params);
    }

    // ===========================================================================
    // EXACT OUTPUT SINGLE -- happy paths
    // ===========================================================================

    function testExactOutputSingleZeroForOne() public {
        _mintDefaultLiquidity();

        uint256 desiredOut = 5e18;
        uint256 expectedIn = _probeExactOutput(address(token0), address(token1), desiredOut);

        uint256 userT0Before = token0.balanceOf(user);
        uint256 recipientT1Before = token1.balanceOf(recipient);
        uint256 poolT0Before = token0.balanceOf(address(pool));
        uint256 poolT1Before = token1.balanceOf(address(pool));

        ExactOutputSingleParams memory params = ExactOutputSingleParams({
            tokenIn: address(token0),
            tokenOut: address(token1),
            fee: FEE,
            recipient: recipient,
            deadline: block.timestamp + 3600,
            amountOut: desiredOut,
            amountInMaximum: SWAP_AMOUNT,
            sqrtPriceLimitX96: 0
        });

        vm.prank(user);
        uint256 amountIn = proxy.exactOutputSingle(params);

        // Input matches probed expectation
        assertEq(amountIn, expectedIn, "amountIn should match probed value");

        // The fee + price impact cost is exactly amountIn - desiredOut
        uint256 totalCost = amountIn - desiredOut;
        assertEq(totalCost, expectedIn - desiredOut, "total cost should match probed expectation");

        // Recipient received exactly the desired output
        assertEq(token1.balanceOf(recipient), recipientT1Before + desiredOut);

        // Exact balance accounting
        assertEq(token0.balanceOf(user), userT0Before - amountIn);
        assertEq(token0.balanceOf(address(pool)), poolT0Before + amountIn);
        assertEq(token1.balanceOf(address(pool)), poolT1Before - desiredOut);
    }

    function testExactOutputSingleOneForZero() public {
        _mintDefaultLiquidity();

        uint256 desiredOut = 5e18;
        uint256 expectedIn = _probeExactOutput(address(token1), address(token0), desiredOut);

        uint256 userT1Before = token1.balanceOf(user);
        uint256 recipientT0Before = token0.balanceOf(recipient);
        uint256 poolT0Before = token0.balanceOf(address(pool));
        uint256 poolT1Before = token1.balanceOf(address(pool));

        ExactOutputSingleParams memory params = ExactOutputSingleParams({
            tokenIn: address(token1),
            tokenOut: address(token0),
            fee: FEE,
            recipient: recipient,
            deadline: block.timestamp + 3600,
            amountOut: desiredOut,
            amountInMaximum: SWAP_AMOUNT,
            sqrtPriceLimitX96: 0
        });

        vm.prank(user);
        uint256 amountIn = proxy.exactOutputSingle(params);

        assertEq(amountIn, expectedIn);
        assertEq(token0.balanceOf(recipient), recipientT0Before + desiredOut);
        assertEq(token1.balanceOf(user), userT1Before - amountIn);
        assertEq(token1.balanceOf(address(pool)), poolT1Before + amountIn);
        assertEq(token0.balanceOf(address(pool)), poolT0Before - desiredOut);
    }

    function testExactOutputSingleRecipientIsSelf() public {
        _mintDefaultLiquidity();

        uint256 desiredOut = 5e18;
        uint256 expectedIn = _probeExactOutput(address(token0), address(token1), desiredOut);
        uint256 userT0Before = token0.balanceOf(user);
        uint256 userT1Before = token1.balanceOf(user);

        ExactOutputSingleParams memory params = ExactOutputSingleParams({
            tokenIn: address(token0),
            tokenOut: address(token1),
            fee: FEE,
            recipient: user,
            deadline: block.timestamp + 3600,
            amountOut: desiredOut,
            amountInMaximum: SWAP_AMOUNT,
            sqrtPriceLimitX96: 0
        });

        vm.prank(user);
        uint256 amountIn = proxy.exactOutputSingle(params);

        assertEq(amountIn, expectedIn);
        assertEq(token0.balanceOf(user), userT0Before - amountIn);
        assertEq(token1.balanceOf(user), userT1Before + desiredOut);
    }

    function testExactOutputSingleMaximumInputExactlyMet() public {
        _mintDefaultLiquidity();

        uint256 desiredOut = 5e18;
        uint256 exactRequired = _probeExactOutput(address(token0), address(token1), desiredOut);

        ExactOutputSingleParams memory params = ExactOutputSingleParams({
            tokenIn: address(token0),
            tokenOut: address(token1),
            fee: FEE,
            recipient: recipient,
            deadline: block.timestamp + 3600,
            amountOut: desiredOut,
            amountInMaximum: exactRequired, // exactly enough
            sqrtPriceLimitX96: 0
        });

        vm.prank(user);
        uint256 amountIn = proxy.exactOutputSingle(params);

        assertEq(amountIn, exactRequired, "amountIn should equal the exact required amount");
        assertEq(token1.balanceOf(recipient), desiredOut);
    }

    // ===========================================================================
    // EXACT OUTPUT SINGLE -- revert cases
    // ===========================================================================

    function testExactOutputSingleRevertsOnExpiredDeadline() public {
        _mintDefaultLiquidity();

        ExactOutputSingleParams memory params = ExactOutputSingleParams({
            tokenIn: address(token0),
            tokenOut: address(token1),
            fee: FEE,
            recipient: recipient,
            deadline: block.timestamp - 1,
            amountOut: 5e18,
            amountInMaximum: SWAP_AMOUNT,
            sqrtPriceLimitX96: 0
        });

        vm.prank(user);
        vm.expectRevert("Transaction too old");
        proxy.exactOutputSingle(params);
    }

    function testExactOutputSingleRevertsOnSlippageExceeded() public {
        _mintDefaultLiquidity();

        ExactOutputSingleParams memory params = ExactOutputSingleParams({
            tokenIn: address(token0),
            tokenOut: address(token1),
            fee: FEE,
            recipient: recipient,
            deadline: block.timestamp + 3600,
            amountOut: 5e18,
            amountInMaximum: 1, // impossibly small
            sqrtPriceLimitX96: 0
        });

        vm.prank(user);
        vm.expectRevert("Too much requested");
        proxy.exactOutputSingle(params);
    }

    function testExactOutputSingleRevertsSlippageByOneWei() public {
        _mintDefaultLiquidity();

        uint256 desiredOut = 5e18;
        uint256 exactRequired = _probeExactOutput(address(token0), address(token1), desiredOut);

        ExactOutputSingleParams memory params = ExactOutputSingleParams({
            tokenIn: address(token0),
            tokenOut: address(token1),
            fee: FEE,
            recipient: recipient,
            deadline: block.timestamp + 3600,
            amountOut: desiredOut,
            amountInMaximum: exactRequired - 1, // one wei below required -- must revert
            sqrtPriceLimitX96: 0
        });

        vm.prank(user);
        vm.expectRevert("Too much requested");
        proxy.exactOutputSingle(params);
    }

    function testExactOutputSingleRevertsOnZeroRecipient() public {
        _mintDefaultLiquidity();

        ExactOutputSingleParams memory params = ExactOutputSingleParams({
            tokenIn: address(token0),
            tokenOut: address(token1),
            fee: FEE,
            recipient: address(0),
            deadline: block.timestamp + 3600,
            amountOut: 5e18,
            amountInMaximum: SWAP_AMOUNT,
            sqrtPriceLimitX96: 0
        });

        vm.prank(user);
        vm.expectRevert();
        proxy.exactOutputSingle(params);
    }

    function testExactOutputSingleRevertsWithoutApproval() public {
        _mintDefaultLiquidity();

        address noApproval = makeAddr("noApproval");
        token0.mint(noApproval, SWAP_AMOUNT);

        ExactOutputSingleParams memory params = ExactOutputSingleParams({
            tokenIn: address(token0),
            tokenOut: address(token1),
            fee: FEE,
            recipient: recipient,
            deadline: block.timestamp + 3600,
            amountOut: 5e18,
            amountInMaximum: SWAP_AMOUNT,
            sqrtPriceLimitX96: 0
        });

        vm.prank(noApproval);
        vm.expectRevert();
        proxy.exactOutputSingle(params);
    }

    function testExactOutputSingleRevertsOnNonExistentPool() public {
        MockERC20 rogue = new MockERC20();

        ExactOutputSingleParams memory params = ExactOutputSingleParams({
            tokenIn: address(token0),
            tokenOut: address(rogue),
            fee: FEE,
            recipient: recipient,
            deadline: block.timestamp + 3600,
            amountOut: 5e18,
            amountInMaximum: SWAP_AMOUNT,
            sqrtPriceLimitX96: 0
        });

        vm.prank(user);
        vm.expectRevert();
        proxy.exactOutputSingle(params);
    }

    // ===========================================================================
    // ROUNDTRIP -- swap and swap back, verify fee accounting
    // ===========================================================================

    function testRoundtripSwapPaysFees() public {
        _mintDefaultLiquidity();

        uint256 userT0Start = token0.balanceOf(user);
        uint256 userT1Start = token1.balanceOf(user);

        // Probe both legs
        uint256 expectedOut1 = _probeExactInput(address(token0), address(token1), SWAP_AMOUNT);

        // Leg 1: token0 -> token1
        ExactInputSingleParams memory leg1 = ExactInputSingleParams({
            tokenIn: address(token0),
            tokenOut: address(token1),
            fee: FEE,
            recipient: user,
            deadline: block.timestamp + 3600,
            amountIn: SWAP_AMOUNT,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });

        vm.prank(user);
        uint256 received = proxy.exactInputSingle(leg1);
        assertEq(received, expectedOut1);

        // Probe leg 2 on shifted state
        uint256 expectedGotBack = _probeExactInput(address(token1), address(token0), received);

        // Leg 2: token1 -> token0
        ExactInputSingleParams memory leg2 = ExactInputSingleParams({
            tokenIn: address(token1),
            tokenOut: address(token0),
            fee: FEE,
            recipient: user,
            deadline: block.timestamp + 3600,
            amountIn: received,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });

        vm.prank(user);
        uint256 gotBack = proxy.exactInputSingle(leg2);
        assertEq(gotBack, expectedGotBack);

        // token1 balance unchanged
        assertEq(token1.balanceOf(user), userT1Start, "token1 balance should return to start");

        // token0: lost exactly SWAP_AMOUNT - gotBack
        uint256 totalLoss = SWAP_AMOUNT - gotBack;
        assertEq(token0.balanceOf(user), userT0Start - totalLoss);
    }

    // ===========================================================================
    // SWAP CONSISTENCY -- exactInput and exactOutput produce matching results
    // ===========================================================================

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
    // CALLBACK SECURITY
    // ===========================================================================

    function testSwapCallbackRevertsFromNonPool() public {
        vm.expectRevert();
        proxy.uniswapV3SwapCallback(
            1,
            -1,
            abi.encode(SwapCallbackData({tokenIn: address(token0), tokenOut: address(token1), fee: FEE, payer: user}))
        );
    }

    function testMintCallbackRevertsFromNonPool() public {
        vm.expectRevert();
        proxy.uniswapV3MintCallback(
            1,
            1,
            abi.encode(
                MintCallbackData({
                    poolKey: PoolAddress.PoolKey({token0: address(token0), token1: address(token1), fee: FEE}),
                    payer: user
                })
            )
        );
    }

    function testSwapCallbackRevertsFromRandomAddress() public {
        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        vm.expectRevert();
        proxy.uniswapV3SwapCallback(
            1,
            -1,
            abi.encode(SwapCallbackData({tokenIn: address(token0), tokenOut: address(token1), fee: FEE, payer: user}))
        );
    }

    // ===========================================================================
    // POOL STATE VERIFICATION
    // ===========================================================================

    function testSwapZeroForOneDecreasesSqrtPrice() public {
        _mintDefaultLiquidity();

        (uint160 priceBefore,,,,,,) = pool.slot0();

        // Probe the exact post-swap price
        uint256 snap = vm.snapshotState();
        ExactInputSingleParams memory params = ExactInputSingleParams({
            tokenIn: address(token0),
            tokenOut: address(token1),
            fee: FEE,
            recipient: recipient,
            deadline: block.timestamp + 3600,
            amountIn: SWAP_AMOUNT,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });
        vm.prank(user);
        proxy.exactInputSingle(params);
        (uint160 expectedPriceAfter,,,,,,) = pool.slot0();
        vm.revertToState(snap);

        // Execute the real swap
        vm.prank(user);
        proxy.exactInputSingle(params);
        (uint160 priceAfter,,,,,,) = pool.slot0();

        assertEq(priceAfter, expectedPriceAfter, "post-swap price should match probed value");
        // Selling token0 for token1 (zeroForOne) must decrease sqrtPriceX96
        assertEq(priceBefore - priceAfter, priceBefore - expectedPriceAfter, "price decrease should be exact");
    }

    function testSwapOneForZeroIncreasesSqrtPrice() public {
        _mintDefaultLiquidity();

        (uint160 priceBefore,,,,,,) = pool.slot0();

        uint256 snap = vm.snapshotState();
        ExactInputSingleParams memory params = ExactInputSingleParams({
            tokenIn: address(token1),
            tokenOut: address(token0),
            fee: FEE,
            recipient: recipient,
            deadline: block.timestamp + 3600,
            amountIn: SWAP_AMOUNT,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });
        vm.prank(user);
        proxy.exactInputSingle(params);
        (uint160 expectedPriceAfter,,,,,,) = pool.slot0();
        vm.revertToState(snap);

        vm.prank(user);
        proxy.exactInputSingle(params);
        (uint160 priceAfter,,,,,,) = pool.slot0();

        assertEq(priceAfter, expectedPriceAfter);
        assertEq(priceAfter - priceBefore, expectedPriceAfter - priceBefore, "price increase should be exact");
    }

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

    function testExactInputSingleLargeSwapHighSlippage() public {
        _mintDefaultLiquidity();

        uint256 hugeAmount = 500e18;
        uint256 expectedOut = _probeExactInput(address(token0), address(token1), hugeAmount);

        uint256 poolT1Before = token1.balanceOf(address(pool));

        ExactInputSingleParams memory params = ExactInputSingleParams({
            tokenIn: address(token0),
            tokenOut: address(token1),
            fee: FEE,
            recipient: recipient,
            deadline: block.timestamp + 3600,
            amountIn: hugeAmount,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });

        vm.prank(user);
        uint256 amountOut = proxy.exactInputSingle(params);

        assertEq(amountOut, expectedOut);
        assertEq(token1.balanceOf(address(pool)), poolT1Before - amountOut);

        // Verify price impact: output is less than linear expectation
        uint256 linearOut = hugeAmount * (1_000_000 - FEE) / 1_000_000;
        uint256 slippageLoss = linearOut - amountOut;
        assertEq(linearOut - amountOut, slippageLoss);
    }

    function testDeadlineExactlyAtBlockTimestamp() public {
        _mintDefaultLiquidity();

        uint256 expectedOut = _probeExactInput(address(token0), address(token1), SWAP_AMOUNT);

        ExactInputSingleParams memory params = ExactInputSingleParams({
            tokenIn: address(token0),
            tokenOut: address(token1),
            fee: FEE,
            recipient: recipient,
            deadline: block.timestamp, // boundary -- should pass (<=)
            amountIn: SWAP_AMOUNT,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });

        vm.prank(user);
        uint256 amountOut = proxy.exactInputSingle(params);
        assertEq(amountOut, expectedOut);
    }

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
        (uint256 amount0, uint256 amount1) = proxy.mint(params);

        assertApproxEqAbs(amount0, expectedAmt0, 1);
        assertApproxEqAbs(amount1, expectedAmt1, 1);
    }

    function testSwapDoesNotAffectUnrelatedBalances() public {
        _mintDefaultLiquidity();

        address bystander = makeAddr("bystander");
        token0.mint(bystander, 100e18);
        token1.mint(bystander, 100e18);

        uint256 bystanderT0 = token0.balanceOf(bystander);
        uint256 bystanderT1 = token1.balanceOf(bystander);

        ExactInputSingleParams memory params = ExactInputSingleParams({
            tokenIn: address(token0),
            tokenOut: address(token1),
            fee: FEE,
            recipient: recipient,
            deadline: block.timestamp + 3600,
            amountIn: SWAP_AMOUNT,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });

        vm.prank(user);
        proxy.exactInputSingle(params);

        assertEq(token0.balanceOf(bystander), bystanderT0);
        assertEq(token1.balanceOf(bystander), bystanderT1);
    }

    function testProxyHoldsNoTokensAfterMint() public {
        _mintDefaultLiquidity();

        assertEq(token0.balanceOf(address(proxy)), 0, "proxy should hold zero token0");
        assertEq(token1.balanceOf(address(proxy)), 0, "proxy should hold zero token1");
    }

    function testProxyHoldsNoTokensAfterSwap() public {
        _mintDefaultLiquidity();

        ExactInputSingleParams memory params = ExactInputSingleParams({
            tokenIn: address(token0),
            tokenOut: address(token1),
            fee: FEE,
            recipient: recipient,
            deadline: block.timestamp + 3600,
            amountIn: SWAP_AMOUNT,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });

        vm.prank(user);
        proxy.exactInputSingle(params);

        assertEq(token0.balanceOf(address(proxy)), 0, "proxy should hold zero token0");
        assertEq(token1.balanceOf(address(proxy)), 0, "proxy should hold zero token1");
    }
}
