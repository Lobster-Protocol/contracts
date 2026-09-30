// SPDX-License-Identifier: GPL-3.0
pragma solidity =0.8.26;

import "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ForkBase} from "../helpers/ForkBase.sol";
import {BatchSwapCalls} from "../../helpers/BatchSwapCalls.sol";
import {SwapType} from "../../../src/UniswapBatchSwapProxy.sol";
import {IUniswapV3PoolMinimal} from "../../../src/interfaces/uniswapV3/IUniswapV3PoolMinimal.sol";
import {
    ExactInputSingleParams,
    ExactOutputSingleParams
} from "../../../src/interfaces/uniswapV3/IUniswapV3SwapCallback.sol";
import {Currency, PoolKey, IHooks} from "../../../src/interfaces/uniswapV4/IPoolManagerMinimal.sol";
import {V4ExactInputSingleParams} from "../../../src/interfaces/uniswapV4/IUnlockCallback.sol";

/// @notice `batchSwap` against live pools: V3 and V4 swaps in one transaction.
/// @dev The mock suite (test/UniswapProxyBatchSwap.t.sol) covers the batching rules in depth. This
/// one confirms they hold against the canonical deployments, where a V3 callback and a V4 unlock
/// really do happen inside the same transaction.
contract BatchSwapTest is ForkBase {
    /// @dev The live ETH/USDC V4 pool: native currency0, no hooks.
    function _ethUsdcKey() internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(USDC),
            fee: V4_FEE,
            tickSpacing: V4_TICK_SPACING,
            hooks: IHooks(address(0))
        });
    }

    /// @dev USDC -> WETH on V3 (0.05%), USDC -> ETH on V4, then an exact amount of USDC back out of
    /// WETH on V3 (0.3%). Two V3 pools, one V4 pool, both swap directions, both exact-in and exact-out.
    function _mixedBatch(uint128 v4MinOut) internal view returns (bytes[] memory swaps) {
        swaps = new bytes[](3);
        swaps[0] = abi.encodePacked(
            SwapType.V3_EXACT_INPUT,
            abi.encode(
                ExactInputSingleParams({
                    tokenIn: USDC,
                    tokenOut: WETH,
                    fee: 500,
                    recipient: recipient,
                    deadline: block.timestamp,
                    amountIn: tradeUsdc,
                    amountOutMinimum: 0,
                    sqrtPriceLimitX96: 0
                })
            )
        );
        swaps[1] = abi.encodePacked(
            SwapType.V4_EXACT_INPUT,
            abi.encode(
                V4ExactInputSingleParams({
                    poolKey: _ethUsdcKey(),
                    zeroForOne: false, // USDC in, native ETH out
                    recipient: recipient,
                    deadline: block.timestamp,
                    amountIn: tradeUsdc,
                    amountOutMinimum: v4MinOut,
                    sqrtPriceLimitX96: 0
                })
            )
        );
        swaps[2] = abi.encodePacked(
            SwapType.V3_EXACT_OUTPUT,
            abi.encode(
                ExactOutputSingleParams({
                    tokenIn: WETH,
                    tokenOut: USDC,
                    fee: 3000,
                    recipient: recipient,
                    deadline: block.timestamp,
                    amountOut: tradeUsdc,
                    amountInMaximum: type(uint256).max,
                    sqrtPriceLimitX96: 0
                })
            )
        );
    }

    function _price(address pool) internal view returns (uint160 sqrtPriceX96) {
        (sqrtPriceX96,,,,,,) = IUniswapV3PoolMinimal(pool).slot0();
    }

    function test_mixedV3AndV4Batch_matchesSameSwapsMadeOneByOne() public {
        bytes[] memory swaps = _mixedBatch(0);

        // Reference run: each swap as a direct call to its single-swap entry point, then rewind
        uint256 snap = vm.snapshotState();
        uint256[] memory expected = new uint256[](swaps.length);
        for (uint256 i = 0; i < swaps.length; i++) {
            vm.prank(approver);
            (bool ok, bytes memory ret) = address(proxy).call(BatchSwapCalls.toDirectCall(swaps[i]));
            assertTrue(ok, "reference call failed");
            expected[i] = abi.decode(ret, (uint256));
        }
        uint256[4] memory expectedHoldings = _approverHoldings();
        vm.revertToState(snap);

        uint256 wethBefore = IERC20(WETH).balanceOf(recipient);
        uint256 usdcBefore = IERC20(USDC).balanceOf(recipient);
        uint256 ethBefore = recipient.balance;

        vm.prank(approver);
        uint256[] memory amounts = proxy.batchSwap(swaps);

        for (uint256 i = 0; i < swaps.length; i++) {
            assertEq(amounts[i], expected[i], "batched amount differs from the direct call");
        }
        uint256[4] memory holdings = _approverHoldings();
        for (uint256 i = 0; i < 4; i++) {
            assertEq(holdings[i], expectedHoldings[i], "approver balances differ from one-by-one");
        }

        assertEq(IERC20(WETH).balanceOf(recipient) - wethBefore, amounts[0], "V3 output");
        assertEq(recipient.balance - ethBefore, amounts[1], "V4 native output");
        assertEq(IERC20(USDC).balanceOf(recipient) - usdcBefore, tradeUsdc, "V3 exact output");
        assertEq(IERC20(USDC).balanceOf(address(proxy)), 0, "proxy retained USDC");
        assertEq(IERC20(WETH).balanceOf(address(proxy)), 0, "proxy retained WETH");
        assertEq(address(proxy).balance, 0, "proxy retained ETH");
    }

    function test_failingV4Swap_undoesTheV3SwapsAroundIt() public {
        uint256[4] memory before = _approverHoldings();
        uint160 price500 = _price(USDC_WETH_500);

        vm.prank(approver);
        vm.expectRevert(bytes("Too little received"));
        proxy.batchSwap(_mixedBatch(type(uint128).max));

        _assertApproverUntouched(before, "reverted batch");
        assertEq(_price(USDC_WETH_500), price500, "V3 swap survived the revert");
    }

    /// @dev The Authorisation suite's invariant, restated for batches: `payer` is `msg.sender` for
    /// every batched swap, so a batch can never reach someone else's standing approval.
    function test_outsiderBatch_cannotSpendApproverAllowance() public {
        uint256[4] memory before = _approverHoldings();

        vm.prank(outsider);
        vm.expectRevert();
        proxy.batchSwap(_mixedBatch(0));

        vm.startPrank(outsider);
        IERC20(USDC).approve(address(proxy), type(uint256).max);
        IERC20(WETH).approve(address(proxy), type(uint256).max);
        proxy.batchSwap(_mixedBatch(0));
        vm.stopPrank();

        _assertApproverUntouched(before, "outsider batch");
    }
}
