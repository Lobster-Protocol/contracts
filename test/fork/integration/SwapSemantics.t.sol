// SPDX-License-Identifier: GPL-3.0
pragma solidity =0.8.26;

import "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ForkBase} from "../helpers/ForkBase.sol";
import {PlainToken, FeeOnTransferToken} from "../helpers/Tokens.sol";
import {MintParams} from "../../../src/interfaces/uniswapV3/IUniswapV3MintCallback.sol";
import {
    ExactInputSingleParams,
    ExactOutputSingleParams
} from "../../../src/interfaces/uniswapV3/IUniswapV3SwapCallback.sol";
import {V4ExactOutputSingleParams} from "../../../src/interfaces/uniswapV4/IUnlockCallback.sol";
import {Currency, PoolKey, IHooks} from "../../../src/interfaces/uniswapV4/IPoolManagerMinimal.sol";
import {IUniswapV3PoolMinimal} from "../../../src/interfaces/uniswapV3/IUniswapV3PoolMinimal.sol";

/// @notice Does each entry point deliver what its name promises, at the edges?
contract SwapSemanticsTest is ForkBase {
    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    PlainToken internal tok;
    address internal pool;
    address internal lp;

    function setUp() public override {
        super.setUp();

        lp = _actor("lp");
        tok = new PlainToken("Shallow", "SHAL", 18);

        pool = factory.createPool(address(tok), USDC, 3000);
        IUniswapV3PoolMinimal(pool).initialize(SQRT_PRICE_1_1);

        // A deliberately thin book: enough to trade against, nowhere near enough to fill a large
        // exact-output order.
        // This pool is ours: we are the only LP and the only counterparty, so its scale is set
        // here rather than by the chain. Fund the traders to match.
        deal(USDC, lp, 1_000_000e6);
        deal(USDC, approver, 1_000_000e6);
        tok.mint(lp, 1_000e18);
        tok.mint(approver, 1_000e18);

        (address token0, address token1) = _sorted(address(tok), USDC);
        (int24 lower, int24 upper) = _rangeAroundSpot(pool, 10);

        vm.startPrank(lp);
        IERC20(USDC).approve(address(proxy), type(uint256).max);
        tok.approve(address(proxy), type(uint256).max);
        proxy.mint(
            MintParams({
                token0: token0,
                token1: token1,
                fee: 3000,
                tickLower: lower,
                tickUpper: upper,
                amount0Desired: token0 == USDC ? 1_000e6 : 1_000e18,
                amount1Desired: token1 == USDC ? 1_000e6 : 1_000e18,
                amount0Min: 0,
                amount1Min: 0,
                recipient: lp,
                deadline: block.timestamp
            })
        );
        vm.stopPrank();
    }

    function _sorted(address a, address b) internal pure returns (address, address) {
        return a < b ? (a, b) : (b, a);
    }

    // ---------------------------------------------------------------------------
    // Exact output: does "exact" hold when the pool runs dry?
    // ---------------------------------------------------------------------------

    /// @dev V3 exact-output swaps can stop early once liquidity is exhausted, filling only part of
    /// the order. `exactOutputSingle` checks `amountIn <= amountInMaximum` and returns, so a partial
    /// fill is reported as success. Callers that need the full amount should compare the delivered
    /// balance themselves, or pass a non-zero `sqrtPriceLimitX96` and treat a short fill as expected.
    function test_exactOutputSingle_shortFillSucceedsSilently() public {
        uint256 requested = 100_000e18; // far more SHAL than the pool holds
        uint256 balBefore = tok.balanceOf(recipient);

        vm.startPrank(approver);
        IERC20(USDC).approve(address(proxy), type(uint256).max);
        uint256 amountIn = proxy.exactOutputSingle(
            ExactOutputSingleParams({
                tokenIn: USDC,
                tokenOut: address(tok),
                fee: 3000,
                recipient: recipient,
                deadline: block.timestamp,
                amountOut: requested,
                amountInMaximum: type(uint256).max,
                sqrtPriceLimitX96: 0
            })
        );
        vm.stopPrank();

        uint256 delivered = tok.balanceOf(recipient) - balBefore;

        // The call succeeded and money changed hands...
        assertGt(amountIn, 0, "nothing was paid");
        assertGt(delivered, 0, "nothing was delivered");
        // ...but the caller did not get the amount they asked for, and was told nothing.
        assertLt(delivered, requested, "expected a short fill from the shallow pool");
    }

    /// @dev `exactOutputSingleV4` additionally requires `amountOut == params.amountOut` when no
    /// price limit was given. The revert here comes from v4-core's own arithmetic before that check
    /// is reached, so this asserts only that an unfillable order does not return successfully.
    function test_exactOutputSingleV4_shortFillIsRejected() public {
        // Skipped on mainnet, and the reason is worth stating: proving an order is UNFILLABLE means
        // exhausting the pool's book, which is one RPC storage read per tick crossed. Against
        // mainnet's ETH/USDC depth that is tens of thousands of cold reads and it rate-limits or
        // times out the endpoint — a red test that says nothing about the contract. Sepolia's book
        // is thin enough to exhaust in a few reads, so that is where this assertion actually runs.
        vm.skip(hasCanonicalTokens);

        vm.prank(approver);
        vm.expectRevert();
        proxy.exactOutputSingleV4{value: uint256(tradeWeth) * 50, gas: 5_000_000}(
            V4ExactOutputSingleParams({
                poolKey: PoolKey({
                    currency0: Currency.wrap(address(0)),
                    currency1: Currency.wrap(USDC),
                    fee: V4_FEE,
                    tickSpacing: V4_TICK_SPACING,
                    hooks: IHooks(address(0))
                }),
                zeroForOne: true,
                recipient: recipient,
                deadline: block.timestamp,
                amountOut: type(uint128).max,
                amountInMaximum: type(uint128).max,
                sqrtPriceLimitX96: 0
            })
        );
    }

    /// @dev `amountInMaximum` still bounds the spend regardless of how much is delivered.
    function test_exactOutputSingle_amountInMaximumStillBinds() public {
        vm.startPrank(approver);
        IERC20(USDC).approve(address(proxy), type(uint256).max);
        vm.expectRevert("Too much requested");
        proxy.exactOutputSingle(
            ExactOutputSingleParams({
                tokenIn: USDC,
                tokenOut: address(tok),
                fee: 3000,
                recipient: recipient,
                deadline: block.timestamp,
                amountOut: 100_000e18,
                amountInMaximum: 1,
                sqrtPriceLimitX96: 0
            })
        );
        vm.stopPrank();
    }

    // ---------------------------------------------------------------------------
    // Non-standard tokens
    // ---------------------------------------------------------------------------

    /// @dev USDT returns no data from `transferFrom`. TransferHelper is the reason that works; a
    /// bare IERC20 call would revert decoding a bool from empty returndata. Worth proving against
    /// the real deployed USDT rather than a mock.
    function test_usdtSwapWorksDespiteMissingReturnValue() public {
        _requireCanonicalTokens();
        uint256 usdtBefore = IERC20(USDT).balanceOf(approver);
        uint256 wethBefore = IERC20(WETH).balanceOf(recipient);

        vm.prank(approver);
        uint256 amountOut = proxy.exactInputSingle(
            ExactInputSingleParams({
                tokenIn: USDT,
                tokenOut: WETH,
                fee: 500,
                recipient: recipient,
                deadline: block.timestamp,
                amountIn: tradeUsdc,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );

        assertGt(amountOut, 0, "USDT swap produced nothing");
        assertEq(IERC20(USDT).balanceOf(approver), usdtBefore - tradeUsdc, "USDT not debited exactly");
        assertEq(IERC20(WETH).balanceOf(recipient), wethBefore + amountOut, "WETH not delivered");
    }

    /// @dev Fee-on-transfer tokens are not supported and fail closed. The proxy sends `amountOwed`
    /// and does not re-measure; the pool measures its own balance and rejects the short payment, so
    /// the call reverts rather than half-settling.
    function test_feeOnTransferTokenRevertsRatherThanUnderpaying() public {
        FeeOnTransferToken fot = new FeeOnTransferToken(500); // 5%
        address fotPool = factory.createPool(address(fot), USDC, 3000);
        IUniswapV3PoolMinimal(fotPool).initialize(SQRT_PRICE_1_1);

        fot.mint(approver, 1_000e18);
        (address token0, address token1) = _sorted(address(fot), USDC);
        (int24 lower, int24 upper) = _rangeAroundSpot(fotPool, 10);

        uint256 approverUsdcBefore = IERC20(USDC).balanceOf(approver);

        vm.startPrank(approver);
        fot.approve(address(proxy), type(uint256).max);
        vm.expectRevert(); // pool's own balance check (M0) rejects the underpayment
        proxy.mint(
            MintParams({
                token0: token0,
                token1: token1,
                fee: 3000,
                tickLower: lower,
                tickUpper: upper,
                amount0Desired: token0 == USDC ? 100e6 : 100e18,
                amount1Desired: token1 == USDC ? 100e6 : 100e18,
                amount0Min: 0,
                amount1Min: 0,
                recipient: approver,
                deadline: block.timestamp
            })
        );
        vm.stopPrank();

        // Nothing half-settled: the USDC balance is unchanged because the whole call reverted.
        assertEq(IERC20(USDC).balanceOf(approver), approverUsdcBefore, "USDC moved despite the revert");
    }

    // ---------------------------------------------------------------------------
    // Mint slippage
    // ---------------------------------------------------------------------------

    /// @dev `amount0Min`/`amount1Min` are the only slippage control `mint` offers, and they bound
    /// the deposit from below. The spend cap from above is `amount0Desired`/`amount1Desired`, which
    /// `getLiquidityForAmounts` respects by construction. Both directions matter to an integrator.
    function test_mintSlippageBoundsAreEnforced() public {
        (address token0, address token1) = _sorted(address(tok), USDC);
        (int24 lower, int24 upper) = _rangeAroundSpot(pool, 10);

        tok.mint(approver, 1_000e18);

        vm.startPrank(approver);
        IERC20(USDC).approve(address(proxy), type(uint256).max);
        tok.approve(address(proxy), type(uint256).max);
        vm.expectRevert("Price slippage check");
        proxy.mint(
            MintParams({
                token0: token0,
                token1: token1,
                fee: 3000,
                tickLower: lower,
                tickUpper: upper,
                amount0Desired: token0 == USDC ? 100e6 : 100e18,
                amount1Desired: token1 == USDC ? 100e6 : 100e18,
                // Demand more deposited than was even offered: must fail.
                amount0Min: token0 == USDC ? 200e6 : 200e18,
                amount1Min: token1 == USDC ? 200e6 : 200e18,
                recipient: approver,
                deadline: block.timestamp
            })
        );
        vm.stopPrank();
    }

    function test_mintNeverSpendsMoreThanDesired() public {
        (address token0, address token1) = _sorted(address(tok), USDC);
        (int24 lower, int24 upper) = _rangeAroundSpot(pool, 10);

        tok.mint(approver, 10_000e18);
        uint256 usdcBefore = IERC20(USDC).balanceOf(approver);
        uint256 tokBefore = tok.balanceOf(approver);

        uint256 desired0 = token0 == USDC ? 100e6 : 100e18;
        uint256 desired1 = token1 == USDC ? 100e6 : 100e18;

        vm.startPrank(approver);
        IERC20(USDC).approve(address(proxy), type(uint256).max);
        tok.approve(address(proxy), type(uint256).max);
        (uint256 amount0, uint256 amount1) = proxy.mint(
            MintParams({
                token0: token0,
                token1: token1,
                fee: 3000,
                tickLower: lower,
                tickUpper: upper,
                amount0Desired: desired0,
                amount1Desired: desired1,
                amount0Min: 0,
                amount1Min: 0,
                recipient: approver,
                deadline: block.timestamp
            })
        );
        vm.stopPrank();

        assertLe(amount0, desired0, "spent more token0 than desired");
        assertLe(amount1, desired1, "spent more token1 than desired");

        // And the standing unlimited allowance did not let it reach past the desired amounts.
        uint256 usdcSpent = usdcBefore - IERC20(USDC).balanceOf(approver);
        uint256 tokSpent = tokBefore - tok.balanceOf(approver);
        assertLe(usdcSpent, token0 == USDC ? desired0 : desired1, "USDC overspend");
        assertLe(tokSpent, token0 == USDC ? desired1 : desired0, "SHAL overspend");
    }
}
