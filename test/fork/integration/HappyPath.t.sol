// SPDX-License-Identifier: GPL-3.0
pragma solidity =0.8.28;

import "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ForkBase} from "../helpers/ForkBase.sol";
import {SwapCalldata} from "../../helpers/SwapCalldata.sol";
import {MintParams} from "../../../src/interfaces/uniswapV3/IUniswapV3MintCallback.sol";
import {IUniswapV3PoolMinimal} from "../../../src/interfaces/uniswapV3/IUniswapV3PoolMinimal.sol";
import {IProxyErrors} from "../../../src/interfaces/IProxyErrors.sol";

/// @notice Baseline: the proxy actually works against real mainnet pools.
/// @dev The positive control for the negative tests in security/. A revert there only means the
/// guard fired if the same fixture can complete a normal call, which is what this asserts.
contract HappyPathTest is ForkBase {
    /// @notice A one-leg V3 exact-input swap spends exactly `amountIn`, delivers its output to the
    /// caller, opens no PoolManager unlock and leaves the proxy holding nothing
    function test_swap_v3ExactInput_usdcForWeth() public {
        uint128 amountIn = tradeUsdc;

        uint256 usdcBefore = IERC20(USDC).balanceOf(approver);
        uint256 wethBefore = IERC20(WETH).balanceOf(approver);

        // A call without a V4 leg never involves the PoolManager
        _expectUnlocks(0);
        uint256 amountOut = _swapOne(approver, _v3In(USDC, WETH, 500, amountIn, 0), 0);

        assertGt(amountOut, 0, "no output");
        assertEq(IERC20(USDC).balanceOf(approver), usdcBefore - amountIn, "exact input not debited exactly");
        assertEq(IERC20(WETH).balanceOf(approver), wethBefore + amountOut, "output not delivered to the caller");
        // The proxy must never end a call holding funds; that is what makes the standing allowance safe.
        assertEq(IERC20(USDC).balanceOf(address(proxy)), 0, "proxy retained USDC");
        assertEq(IERC20(WETH).balanceOf(address(proxy)), 0, "proxy retained WETH");
    }

    /// @notice A mint on the live pool spends at most the desired amounts, from the caller, and the
    /// position belongs to the caller
    function test_mint_usdcWethPosition() public {
        (int24 lower, int24 upper) = _rangeAroundSpot(USDC_WETH_500, 10);

        uint256 usdcBefore = IERC20(USDC).balanceOf(approver);
        uint256 wethBefore = IERC20(WETH).balanceOf(approver);

        vm.prank(approver);
        (uint256 amount0, uint256 amount1) = proxy.mint(
            MintParams({
                token0: USDC,
                token1: WETH,
                fee: 500,
                tickLower: lower,
                tickUpper: upper,
                amount0Desired: lpUsdc,
                amount1Desired: lpWeth,
                amount0Min: 0,
                amount1Min: 0,
                recipient: approver,
                deadline: block.timestamp
            })
        );

        assertTrue(amount0 > 0 || amount1 > 0, "minted nothing");
        // The desired amounts are the real spend cap here: getLiquidityForAmounts never returns
        // liquidity that costs more than what was offered.
        assertLe(amount0, lpUsdc, "spent more token0 than desired");
        assertLe(amount1, lpWeth, "spent more token1 than desired");
        assertEq(IERC20(USDC).balanceOf(approver), usdcBefore - amount0, "token0 debit mismatch");
        assertEq(IERC20(WETH).balanceOf(approver), wethBefore - amount1, "token1 debit mismatch");

        // Position must belong to the caller, not to the proxy.
        bytes32 key = keccak256(abi.encodePacked(approver, lower, upper));
        (uint128 liquidity,,,,) = IUniswapV3PoolMinimal(USDC_WETH_500).positions(key);
        assertGt(liquidity, 0, "the caller holds no liquidity");
    }

    /// @notice On the real pool, a mint is refused when the live price is outside the caller's band,
    /// and nothing is spent
    function test_mint_refusedWhenSpotOutsideBand() public {
        (int24 lower, int24 upper) = _rangeAroundSpot(USDC_WETH_500, 10);
        (, int24 tick,,,,,) = IUniswapV3PoolMinimal(USDC_WETH_500).slot0();

        // a band entirely above today's price, as if it had been set before the price dropped
        bytes32 key = proxy.v3Key(USDC_WETH_500);
        vm.prank(approver);
        proxy.setPriceBand(key, tick + 100, tick + 2000);

        uint256 usdcBefore = IERC20(USDC).balanceOf(approver);
        uint256 wethBefore = IERC20(WETH).balanceOf(approver);

        vm.prank(approver);
        vm.expectRevert(IProxyErrors.PriceOutOfBand.selector);
        proxy.mint(
            MintParams({
                token0: USDC,
                token1: WETH,
                fee: 500,
                tickLower: lower,
                tickUpper: upper,
                amount0Desired: lpUsdc,
                amount1Desired: lpWeth,
                amount0Min: 0,
                amount1Min: 0,
                recipient: approver,
                deadline: block.timestamp
            })
        );

        assertEq(IERC20(USDC).balanceOf(approver), usdcBefore, "USDC spent on a refused mint");
        assertEq(IERC20(WETH).balanceOf(approver), wethBefore, "WETH spent on a refused mint");
    }

    /// @notice A `swap` call past its deadline (one uint32 per call) is refused
    function test_deadlineIsEnforced() public {
        vm.warp(vm.getBlockTimestamp() + 1000);
        bytes memory data = SwapCalldata.encode(vm.getBlockTimestamp() - 1, _one(_v3In(USDC, WETH, 500, tradeUsdc, 0)));

        vm.prank(approver);
        vm.expectRevert(IProxyErrors.TransactionTooOld.selector);
        proxy.swap(data);
    }

    /// @notice On the real pool, a swap is refused when the live price is outside the caller's band,
    /// and nothing is spent
    function test_swap_refusedWhenSpotOutsideBand() public {
        (, int24 tick,,,,,) = IUniswapV3PoolMinimal(USDC_WETH_500).slot0();
        bytes32 key = proxy.v3Key(USDC_WETH_500);
        vm.prank(approver);
        proxy.setPriceBand(key, tick + 100, tick + 2000);

        uint256 usdcBefore = IERC20(USDC).balanceOf(approver);
        uint256 wethBefore = IERC20(WETH).balanceOf(approver);
        bytes memory data = _swapData(_one(_v3In(USDC, WETH, 500, tradeUsdc, 0)));

        vm.prank(approver);
        vm.expectRevert(IProxyErrors.PriceOutOfBand.selector);
        proxy.swap(data);

        assertEq(IERC20(USDC).balanceOf(approver), usdcBefore, "USDC spent on a refused swap");
        assertEq(IERC20(WETH).balanceOf(approver), wethBefore, "WETH moved on a refused swap");
    }
}
