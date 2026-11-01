// SPDX-License-Identifier: GPL-3.0
pragma solidity =0.8.28;

import "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ForkBase} from "../helpers/ForkBase.sol";
import {PlainToken, FeeOnTransferToken} from "../helpers/Tokens.sol";
import {SwapCalldata} from "../../helpers/SwapCalldata.sol";
import {MintParams} from "../../../src/interfaces/uniswapV3/IUniswapV3MintCallback.sol";
import {TickMath} from "../../../src/libraries/uniswapV3/TickMath.sol";
import {IUniswapV3PoolMinimal} from "../../../src/interfaces/uniswapV3/IUniswapV3PoolMinimal.sol";
import {IProxyErrors} from "../../../src/interfaces/IProxyErrors.sol";

/// @notice Does each kind of leg deliver what its flags promise, at the edges?
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
        _allow(lp, proxy.v3Key(pool), MINT);
        _allow(approver, proxy.v3Key(pool), MINT | SWAP);
        _bandAroundSpot(lp, pool, 1000);
        _bandAroundSpot(approver, pool, 1000);

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

    /// @dev `vault`'s band on the shallow pool widened to any price
    function _anyPriceFor(address vault) internal {
        bytes32 key = proxy.v3Key(pool);
        vm.prank(vault);
        proxy.setPriceBand(key, -887272, 887272); // TickMath.MIN_TICK / MAX_TICK
    }

    function _sorted(address a, address b) internal pure returns (address, address) {
        return a < b ? (a, b) : (b, a);
    }

    // ---------------------------------------------------------------------------
    // Non-standard tokens
    // ---------------------------------------------------------------------------

    /// @notice A V3 leg paying with USDT, whose transferFrom returns nothing, works and debits exactly
    /// @dev USDT returns no data from `transferFrom`. The proxy's own transfer code accepts empty
    /// returndata exactly as TransferHelper does; a bare IERC20 call would revert decoding a bool from
    /// empty returndata. Worth proving against the real deployed USDT rather than a mock.
    function test_usdtSwapWorksDespiteMissingReturnValue() public {
        _requireCanonicalTokens();
        uint256 usdtBefore = IERC20(USDT).balanceOf(approver);
        uint256 wethBefore = IERC20(WETH).balanceOf(approver);

        uint256 amountOut = _swapOne(approver, _v3In(USDT, WETH, 500, tradeUsdc, 0), 0);

        assertGt(amountOut, 0, "USDT swap produced nothing");
        assertEq(IERC20(USDT).balanceOf(approver), usdtBefore - tradeUsdc, "USDT not debited exactly");
        assertEq(IERC20(WETH).balanceOf(approver), wethBefore + amountOut, "WETH not delivered");
    }

    /// @notice A fee-on-transfer token fails closed: the mint reverts rather than underpaying
    /// @dev Fee-on-transfer tokens are not supported and fail closed. The proxy sends `amountOwed`
    /// and does not re-measure; the pool measures its own balance and rejects the short payment, so
    /// the call reverts rather than half-settling.
    function test_feeOnTransferTokenRevertsRatherThanUnderpaying() public {
        FeeOnTransferToken fot = new FeeOnTransferToken(500); // 5%
        address fotPool = factory.createPool(address(fot), USDC, 3000);
        IUniswapV3PoolMinimal(fotPool).initialize(SQRT_PRICE_1_1);
        _allow(approver, proxy.v3Key(fotPool), MINT);
        _bandAroundSpot(approver, fotPool, 1000);

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

    /// @notice `mint` reverts `PriceSlippageCheck` when it would deposit less than the minimums
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
        vm.expectRevert(IProxyErrors.PriceSlippageCheck.selector);
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

    /// @notice `mint` never spends more than the desired amounts, despite the unlimited allowance
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

    // ---------------------------------------------------------------------------
    // Exact output
    // ---------------------------------------------------------------------------

    /// @notice A V3 exact-output leg without a price limit that the pool cannot fill reverts
    /// `TooLittleReceived` rather than settling a partial fill
    /// @dev A V3 pool stops early once its liquidity is exhausted, filling only part of the order.
    /// Without a price limit an exact-output leg must not report that as success: its `bound`
    /// (amountInMaximum) would then cap only the total spent, not the price, and a sandwich that
    /// drains the honest liquidity could fill the order against a tiny position at an absurd price.
    /// So it reverts, like SwapRouter and V4 legs. Callers who accept partial fills set PRICE_LIMIT.
    function test_v3ExactOutput_shortFillIsRejected() public {
        _anyPriceFor(approver); // the band would stop this first; here the short-fill rule is under test
        uint128 requested = 100_000e18; // far more SHAL than the pool holds
        uint256 balBefore = tok.balanceOf(approver);
        uint256 usdcBefore = IERC20(USDC).balanceOf(approver);
        bytes memory data = _swapData(_one(_v3Out(USDC, address(tok), 3000, requested, type(uint128).max)));

        vm.startPrank(approver);
        IERC20(USDC).approve(address(proxy), type(uint256).max);
        vm.expectRevert(IProxyErrors.TooLittleReceived.selector);
        proxy.swap(data);
        vm.stopPrank();

        assertEq(tok.balanceOf(approver), balBefore, "a partial fill was delivered");
        assertEq(IERC20(USDC).balanceOf(approver), usdcBefore, "the caller paid for a partial fill");
    }

    /// @notice With PRICE_LIMIT the same exact-output leg may fill partially, and succeeds
    /// @dev The caller has bounded the price themselves, so a partial fill is a legitimate outcome.
    function test_v3ExactOutput_withPriceLimit_mayFillPartially() public {
        uint128 requested = 100_000e18;
        uint256 balBefore = tok.balanceOf(approver);
        bool zeroForOne = USDC < address(tok);
        (, int24 tick,,,,,) = IUniswapV3PoolMinimal(pool).slot0();
        // 600 ticks (~6%) in the direction of the trade
        SwapCalldata.Leg memory leg = _v3Out(USDC, address(tok), 3000, requested, type(uint128).max);
        leg.sqrtPriceLimitX96 = TickMath.getSqrtRatioAtTick(zeroForOne ? tick - 600 : tick + 600);

        vm.prank(approver);
        IERC20(USDC).approve(address(proxy), type(uint256).max);
        uint256 amountIn = _swapOne(approver, leg, 0);

        uint256 delivered = tok.balanceOf(approver) - balBefore;
        assertGt(amountIn, 0, "nothing was paid");
        assertGt(delivered, 0, "nothing was delivered");
        assertLt(delivered, requested, "expected a partial fill up to the price limit");
    }

    /// @notice An exact-output leg's `bound` (amountInMaximum) still binds the spend: `TooMuchRequested`
    function test_v3ExactOutput_amountInMaximumStillBinds() public {
        _anyPriceFor(approver); // the band would stop this first; here amountInMaximum is under test
        bytes memory data = _swapData(_one(_v3Out(USDC, address(tok), 3000, 100_000e18, 1)));

        vm.startPrank(approver);
        IERC20(USDC).approve(address(proxy), type(uint256).max);
        vm.expectRevert(IProxyErrors.TooMuchRequested.selector);
        proxy.swap(data);
        vm.stopPrank();
    }

    /// @notice A V4 exact-output leg that the pool cannot fill does not return successfully
    /// @dev V4 legs apply the same rule: `received == amount` when no price limit was given. The
    /// revert may come from v4-core's own arithmetic before that check is reached, so this asserts
    /// only that an unfillable order does not return successfully.
    function test_v4ExactOutput_shortFillIsRejected() public {
        // Skipped on mainnet, and the reason is worth stating: proving an order is UNFILLABLE means
        // exhausting the pool's book, which is one RPC storage read per tick crossed. Against
        // mainnet's ETH/USDC depth that is tens of thousands of cold reads and it rate-limits or
        // times out the endpoint — a red test that says nothing about the contract. Sepolia's book
        // is thin enough to exhaust in a few reads, so that is where this assertion actually runs.
        vm.skip(hasCanonicalTokens);
        bytes memory data = _swapData(_one(_v4Out(true, type(uint128).max, type(uint128).max)));

        vm.prank(approver);
        vm.expectRevert();
        proxy.swap{value: uint256(tradeWeth) * 50, gas: 5_000_000}(data);
    }
}
