// SPDX-License-Identifier: GPL-3.0
pragma solidity =0.8.26;

import "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ForkBase} from "../helpers/ForkBase.sol";
import {MintParams} from "../../../src/interfaces/uniswapV3/IUniswapV3MintCallback.sol";
import {
    ExactInputSingleParams,
    ExactOutputSingleParams
} from "../../../src/interfaces/uniswapV3/IUniswapV3SwapCallback.sol";
import {IUniswapV3PoolMinimal} from "../../../src/interfaces/uniswapV3/IUniswapV3PoolMinimal.sol";

/// @notice Baseline: the proxy actually works against real mainnet pools.
/// @dev The positive control for the negative tests in security/. A revert there only means the
/// guard fired if the same fixture can complete a normal call, which is what this asserts.
contract HappyPathTest is ForkBase {
    function test_exactInputSingle_usdcForWeth() public {
        uint256 amountIn = tradeUsdc;

        uint256 usdcBefore = IERC20(USDC).balanceOf(approver);
        uint256 wethBefore = IERC20(WETH).balanceOf(recipient);

        vm.prank(approver);
        uint256 amountOut = proxy.exactInputSingle(
            ExactInputSingleParams({
                tokenIn: USDC,
                tokenOut: WETH,
                fee: 500,
                recipient: recipient,
                deadline: block.timestamp,
                amountIn: amountIn,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );

        assertGt(amountOut, 0, "no output");
        assertEq(IERC20(USDC).balanceOf(approver), usdcBefore - amountIn, "exact input not debited exactly");
        assertEq(IERC20(WETH).balanceOf(recipient), wethBefore + amountOut, "output not delivered to recipient");
        // The proxy must never end a call holding funds; that is what makes the standing allowance safe.
        assertEq(IERC20(USDC).balanceOf(address(proxy)), 0, "proxy retained USDC");
        assertEq(IERC20(WETH).balanceOf(address(proxy)), 0, "proxy retained WETH");
    }

    function test_exactOutputSingle_usdcForWeth() public {
        uint256 amountOut = tradeWeth;

        uint256 usdcBefore = IERC20(USDC).balanceOf(approver);
        uint256 wethBefore = IERC20(WETH).balanceOf(recipient);

        vm.prank(approver);
        uint256 amountIn = proxy.exactOutputSingle(
            ExactOutputSingleParams({
                tokenIn: USDC,
                tokenOut: WETH,
                fee: 500,
                recipient: recipient,
                deadline: block.timestamp,
                amountOut: amountOut,
                amountInMaximum: type(uint256).max,
                sqrtPriceLimitX96: 0
            })
        );

        assertGt(amountIn, 0, "no input consumed");
        assertEq(IERC20(WETH).balanceOf(recipient), wethBefore + amountOut, "exact output not delivered exactly");
        assertEq(
            IERC20(USDC).balanceOf(approver), usdcBefore - amountIn, "input debit does not match reported amountIn"
        );
        assertEq(IERC20(USDC).balanceOf(address(proxy)), 0, "proxy retained USDC");
    }

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
                recipient: recipient,
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

        // Position must belong to `recipient`, not to the proxy.
        bytes32 key = keccak256(abi.encodePacked(recipient, lower, upper));
        (uint128 liquidity,,,,) = IUniswapV3PoolMinimal(USDC_WETH_500).positions(key);
        assertGt(liquidity, 0, "recipient holds no liquidity");
    }

    function test_deadlineIsEnforced() public {
        vm.warp(block.timestamp + 1000);

        vm.prank(approver);
        vm.expectRevert("Transaction too old");
        proxy.exactInputSingle(
            ExactInputSingleParams({
                tokenIn: USDC,
                tokenOut: WETH,
                fee: 500,
                recipient: recipient,
                deadline: block.timestamp - 1,
                amountIn: tradeUsdc,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );
    }
}
