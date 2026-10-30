// SPDX-License-Identifier: GPL-3.0
pragma solidity =0.8.28;

import "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ForkBase} from "../helpers/ForkBase.sol";
import {BatchSwapCalls} from "../../helpers/BatchSwapCalls.sol";
import {SwapType} from "../../../src/UniswapBatchSwapProxy.sol";
import {Chaining} from "../../../src/libraries/Chaining.sol";
import {IUniswapV3PoolMinimal} from "../../../src/interfaces/uniswapV3/IUniswapV3PoolMinimal.sol";
import {ExactInputSingleParams} from "../../../src/interfaces/uniswapV3/IUniswapV3SwapCallback.sol";
import {Currency, PoolKey, IHooks} from "../../../src/interfaces/uniswapV4/IPoolManagerMinimal.sol";
import {V4ExactInputSingleParams} from "../../../src/interfaces/uniswapV4/IUnlockCallback.sol";
import {IProxyErrors} from "../../../src/interfaces/IProxyErrors.sol";

/// @notice `batchSwap` against live pools: V3 and V4 swaps in one transaction.
/// @dev The mock suite (test/LobsterBatchSwap.t.sol) covers the batching rules in depth. This one
/// confirms they hold against the canonical deployments, where a V3 callback and a V4 unlock really do
/// happen inside the same transaction.
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

    /// @dev USDC -> WETH on V3 (0.05%), USDC -> ETH on V4, then WETH -> USDC on V3 (0.3%). Two V3
    /// pools, one V4 pool, both swap directions.
    /// Every output goes to `to`, which must be the caller.
    function _mixedBatch(uint128 v4MinOut, address to) internal view returns (bytes[] memory swaps) {
        swaps = new bytes[](3);
        swaps[0] = abi.encodePacked(
            SwapType.V3_EXACT_INPUT,
            abi.encode(
                ExactInputSingleParams({
                    tokenIn: USDC,
                    tokenOut: WETH,
                    fee: 500,
                    recipient: to,
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
                    recipient: to,
                    deadline: block.timestamp,
                    amountIn: tradeUsdc,
                    amountOutMinimum: v4MinOut,
                    sqrtPriceLimitX96: 0
                })
            )
        );
        swaps[2] = abi.encodePacked(
            SwapType.V3_EXACT_INPUT,
            abi.encode(
                ExactInputSingleParams({
                    tokenIn: WETH,
                    tokenOut: USDC,
                    fee: 3000,
                    recipient: to,
                    deadline: block.timestamp,
                    amountIn: tradeWeth,
                    amountOutMinimum: 0,
                    sqrtPriceLimitX96: 0
                })
            )
        );
    }

    function _price(address pool) internal view returns (uint160 sqrtPriceX96) {
        (sqrtPriceX96,,,,,,) = IUniswapV3PoolMinimal(pool).slot0();
    }

    function test_mixedV3AndV4Batch_matchesSameSwapsMadeOneByOne() public {
        bytes[] memory swaps = _mixedBatch(0, approver);

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

        uint256 wethBefore = IERC20(WETH).balanceOf(approver);
        uint256 usdcBefore = IERC20(USDC).balanceOf(approver);
        uint256 ethBefore = approver.balance;

        vm.prank(approver);
        uint256[] memory amounts = proxy.batchSwap(swaps);

        for (uint256 i = 0; i < swaps.length; i++) {
            assertEq(amounts[i], expected[i], "batched amount differs from the direct call");
        }
        uint256[4] memory holdings = _approverHoldings();
        for (uint256 i = 0; i < 4; i++) {
            assertEq(holdings[i], expectedHoldings[i], "approver balances differ from one-by-one");
        }

        // The caller is also the recipient, so each net change is received minus paid:
        // WETH: +first leg's output - third leg's input; ETH: +V4 output; USDC: -2 inputs + third leg's output
        assertEq(IERC20(WETH).balanceOf(approver) + tradeWeth, wethBefore + amounts[0], "WETH: received minus paid");
        assertEq(approver.balance - ethBefore, amounts[1], "V4 native output");
        assertEq(IERC20(USDC).balanceOf(approver) + 2 * tradeUsdc, usdcBefore + amounts[2], "USDC: received minus paid");
        assertEq(IERC20(USDC).balanceOf(address(proxy)), 0, "proxy retained USDC");
        assertEq(IERC20(WETH).balanceOf(address(proxy)), 0, "proxy retained WETH");
        assertEq(address(proxy).balance, 0, "proxy retained ETH");
    }

    function _v4UsdcEth(
        bool zeroForOne,
        uint128 amountIn,
        address to
    )
        internal
        view
        returns (V4ExactInputSingleParams memory)
    {
        return V4ExactInputSingleParams({
            poolKey: _ethUsdcKey(),
            zeroForOne: zeroForOne,
            recipient: to,
            deadline: block.timestamp,
            amountIn: amountIn,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });
    }

    function _v3UsdcWeth(uint256 amountIn, address to) internal view returns (ExactInputSingleParams memory) {
        return ExactInputSingleParams({
            tokenIn: USDC,
            tokenOut: WETH,
            fee: 500,
            recipient: to,
            deadline: block.timestamp,
            amountIn: amountIn,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });
    }

    /// @dev Chaining on live pools, crossing both versions with native ETH in the middle:
    ///   USDC -V4-> ETH (parked) -V4-> USDC (parked) -V3-> WETH
    /// Only the first amount is fixed. It must match the same legs made one by one with each output
    /// fed by hand into the next, and leave the proxy holding nothing.
    function test_chainedRoute_matchesManualSequence() public {
        bytes[] memory swaps = new bytes[](3);
        swaps[0] =
            abi.encodePacked(SwapType.V4_EXACT_INPUT, abi.encode(_v4UsdcEth(false, tradeUsdc, Chaining.ADDRESS_THIS)));
        swaps[1] = abi.encodePacked(
            SwapType.V4_EXACT_INPUT, abi.encode(_v4UsdcEth(true, uint128(Chaining.HELD_BALANCE), Chaining.ADDRESS_THIS))
        );
        swaps[2] = abi.encodePacked(SwapType.V3_EXACT_INPUT, abi.encode(_v3UsdcWeth(Chaining.HELD_BALANCE, approver)));

        // Reference: three direct calls, each intermediate output delivered to the approver and
        // passed by hand (as msg.value for the ETH leg)
        uint256 snap = vm.snapshotState();
        vm.startPrank(approver);
        uint256 a = proxy.exactInputSingleV4(_v4UsdcEth(false, tradeUsdc, approver));
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 b = proxy.exactInputSingleV4{value: a}(_v4UsdcEth(true, uint128(a), approver));
        uint256 c = proxy.exactInputSingle(_v3UsdcWeth(b, approver));
        vm.stopPrank();
        uint256[4] memory expectedHoldings = _approverHoldings();
        uint256 expectedApproverEth = approver.balance;
        vm.revertToState(snap);

        uint256 wethBefore = IERC20(WETH).balanceOf(approver);
        vm.prank(approver);
        uint256[] memory amounts = proxy.batchSwap(swaps);

        assertEq(amounts[0], a, "USDC -> ETH leg");
        assertEq(amounts[1], b, "ETH -> USDC leg did not spend exactly the parked ETH");
        assertEq(amounts[2], c, "USDC -> WETH leg did not spend exactly the parked USDC");
        assertEq(IERC20(WETH).balanceOf(approver) - wethBefore, c, "the caller did not get the WETH");

        uint256[4] memory holdings = _approverHoldings();
        for (uint256 i = 0; i < 4; i++) {
            assertEq(holdings[i], expectedHoldings[i], "approver balances differ from the manual sequence");
        }
        assertEq(approver.balance, expectedApproverEth, "approver ETH differs from the manual sequence");
        assertEq(IERC20(USDC).balanceOf(address(proxy)), 0, "proxy retained USDC");
        assertEq(IERC20(WETH).balanceOf(address(proxy)), 0, "proxy retained WETH");
        assertEq(address(proxy).balance, 0, "proxy retained ETH");
    }

    function test_failingV4Swap_undoesTheV3SwapsAroundIt() public {
        uint256[4] memory before = _approverHoldings();
        uint160 price500 = _price(USDC_WETH_500);

        vm.prank(approver);
        vm.expectRevert(IProxyErrors.TooLittleReceived.selector);
        proxy.batchSwap(_mixedBatch(type(uint128).max, approver));

        _assertApproverUntouched(before, "reverted batch");
        assertEq(_price(USDC_WETH_500), price500, "V3 swap survived the revert");
    }

    /// @dev The Authorisation suite's invariant, restated for batches: `payer` is `msg.sender` for
    /// every batched swap, so a batch can never reach someone else's standing approval. The outsider
    /// has registered the same pools, so without an approval of its own only payment can stop it.
    function test_outsiderBatch_cannotSpendApproverAllowance() public {
        uint256[4] memory before = _approverHoldings();

        vm.prank(outsider);
        vm.expectRevert();
        proxy.batchSwap(_mixedBatch(0, outsider));

        vm.startPrank(outsider);
        IERC20(USDC).approve(address(proxy), type(uint256).max);
        IERC20(WETH).approve(address(proxy), type(uint256).max);
        proxy.batchSwap(_mixedBatch(0, outsider));
        vm.stopPrank();

        _assertApproverUntouched(before, "outsider batch");
    }
}
