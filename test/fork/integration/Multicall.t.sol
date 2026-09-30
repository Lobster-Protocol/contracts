// SPDX-License-Identifier: GPL-3.0
pragma solidity =0.8.26;

import "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ForkBase} from "../helpers/ForkBase.sol";
import {UniswapV3SwapProxy} from "../../../src/UniswapV3SwapProxy.sol";
import {UniswapV4SwapProxy} from "../../../src/UniswapV4SwapProxy.sol";
import {IUniswapV3PoolMinimal} from "../../../src/interfaces/uniswapV3/IUniswapV3PoolMinimal.sol";
import {
    ExactInputSingleParams,
    ExactOutputSingleParams
} from "../../../src/interfaces/uniswapV3/IUniswapV3SwapCallback.sol";
import {Currency, PoolKey, IHooks} from "../../../src/interfaces/uniswapV4/IPoolManagerMinimal.sol";
import {V4ExactInputSingleParams} from "../../../src/interfaces/uniswapV4/IUnlockCallback.sol";

/// @notice `multicall` against live pools: V3 and V4 swaps batched into one transaction.
/// @dev The mock suite (test/UniswapProxyMulticall.t.sol) covers the batching rules in depth. This
/// one confirms they hold against the canonical deployments, where a V3 callback and a V4 unlock
/// really do happen inside the same transaction.
contract MulticallTest is ForkBase {
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
    function _mixedBatch(uint128 v4MinOut) internal view returns (bytes[] memory calls) {
        calls = new bytes[](3);
        calls[0] = abi.encodeCall(
            UniswapV3SwapProxy.exactInputSingle,
            (ExactInputSingleParams({
                    tokenIn: USDC,
                    tokenOut: WETH,
                    fee: 500,
                    recipient: recipient,
                    deadline: block.timestamp,
                    amountIn: tradeUsdc,
                    amountOutMinimum: 0,
                    sqrtPriceLimitX96: 0
                }))
        );
        calls[1] = abi.encodeCall(
            UniswapV4SwapProxy.exactInputSingleV4,
            (V4ExactInputSingleParams({
                    poolKey: _ethUsdcKey(),
                    zeroForOne: false, // USDC in, native ETH out
                    recipient: recipient,
                    deadline: block.timestamp,
                    amountIn: tradeUsdc,
                    amountOutMinimum: v4MinOut,
                    sqrtPriceLimitX96: 0
                }))
        );
        calls[2] = abi.encodeCall(
            UniswapV3SwapProxy.exactOutputSingle,
            (ExactOutputSingleParams({
                    tokenIn: WETH,
                    tokenOut: USDC,
                    fee: 3000,
                    recipient: recipient,
                    deadline: block.timestamp,
                    amountOut: tradeUsdc,
                    amountInMaximum: type(uint256).max,
                    sqrtPriceLimitX96: 0
                }))
        );
    }

    function _price(address pool) internal view returns (uint160 sqrtPriceX96) {
        (sqrtPriceX96,,,,,,) = IUniswapV3PoolMinimal(pool).slot0();
    }

    function test_mixedV3AndV4Batch_matchesSameCallsMadeOneByOne() public {
        bytes[] memory calls = _mixedBatch(0);

        // Reference run: the same calls, one transaction each, then rewind
        uint256 snap = vm.snapshotState();
        bytes[] memory expected = new bytes[](calls.length);
        for (uint256 i = 0; i < calls.length; i++) {
            vm.prank(approver);
            (bool ok, bytes memory ret) = address(proxy).call(calls[i]);
            assertTrue(ok, "reference call failed");
            expected[i] = ret;
        }
        uint256[4] memory expectedHoldings = _approverHoldings();
        vm.revertToState(snap);

        uint256 wethBefore = IERC20(WETH).balanceOf(recipient);
        uint256 usdcBefore = IERC20(USDC).balanceOf(recipient);
        uint256 ethBefore = recipient.balance;

        vm.prank(approver);
        bytes[] memory results = proxy.multicall(calls);

        for (uint256 i = 0; i < calls.length; i++) {
            assertEq(results[i], expected[i], "batched result differs from the direct call");
        }
        uint256[4] memory holdings = _approverHoldings();
        for (uint256 i = 0; i < 4; i++) {
            assertEq(holdings[i], expectedHoldings[i], "approver balances differ from one-by-one");
        }

        assertEq(IERC20(WETH).balanceOf(recipient) - wethBefore, abi.decode(results[0], (uint256)), "V3 output");
        assertEq(recipient.balance - ethBefore, abi.decode(results[1], (uint256)), "V4 native output");
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
        proxy.multicall(_mixedBatch(type(uint128).max));

        _assertApproverUntouched(before, "reverted batch");
        assertEq(_price(USDC_WETH_500), price500, "V3 swap survived the revert");
    }

    /// @dev The Authorisation suite's invariant, restated for batches: `payer` is `msg.sender` inside
    /// every batched call, so a batch can never reach someone else's standing approval.
    function test_outsiderBatch_cannotSpendApproverAllowance() public {
        uint256[4] memory before = _approverHoldings();

        vm.prank(outsider);
        vm.expectRevert();
        proxy.multicall(_mixedBatch(0));

        vm.startPrank(outsider);
        IERC20(USDC).approve(address(proxy), type(uint256).max);
        IERC20(WETH).approve(address(proxy), type(uint256).max);
        proxy.multicall(_mixedBatch(0));
        vm.stopPrank();

        _assertApproverUntouched(before, "outsider batch");
    }
}
