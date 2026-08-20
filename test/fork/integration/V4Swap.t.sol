// SPDX-License-Identifier: GPL-3.0
pragma solidity =0.8.26;

import "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ForkBase} from "../helpers/ForkBase.sol";
import {Currency, PoolKey, IHooks, SwapParams} from "../../../src/interfaces/uniswapV4/IPoolManagerMinimal.sol";
import {
    V4ExactInputSingleParams,
    V4ExactOutputSingleParams,
    V4SwapCallbackData
} from "../../../src/interfaces/uniswapV4/IUnlockCallback.sol";

/// @notice The V4 surface, against the real mainnet PoolManager singleton.
/// @dev V4 concentrates the risk differently from V3: one singleton instead of derived pool
/// addresses, ETH as a first-class currency, and hooks that can run arbitrary code inside a swap.
contract V4SwapTest is ForkBase {
    /// @dev The live mainnet ETH/USDC pool: native currency0, 0.05% fee, tick spacing 10, no hooks.
    function _ethUsdcKey() internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(USDC),
            fee: V4_FEE,
            tickSpacing: V4_TICK_SPACING,
            hooks: IHooks(address(0))
        });
    }

    // ---------------------------------------------------------------------------
    // Happy paths
    // ---------------------------------------------------------------------------

    function test_exactInputSingleV4_nativeForUsdc() public {
        uint128 amountIn = tradeWeth;
        uint256 usdcBefore = IERC20(USDC).balanceOf(recipient);
        uint256 ethBefore = approver.balance;

        vm.prank(approver);
        uint256 amountOut = proxy.exactInputSingleV4{value: amountIn}(
            V4ExactInputSingleParams({
                poolKey: _ethUsdcKey(),
                zeroForOne: true,
                recipient: recipient,
                deadline: block.timestamp,
                amountIn: amountIn,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );

        assertGt(amountOut, 0, "no output");
        assertEq(IERC20(USDC).balanceOf(recipient), usdcBefore + amountOut, "output not delivered");
        assertEq(approver.balance, ethBefore - amountIn, "ETH debit does not match amountIn");
        assertEq(address(proxy).balance, 0, "proxy retained ETH");
    }

    function test_exactInputSingleV4_usdcForNative() public {
        uint128 amountIn = tradeUsdc;
        uint256 ethBefore = recipient.balance;

        vm.prank(approver);
        uint256 amountOut = proxy.exactInputSingleV4(
            V4ExactInputSingleParams({
                poolKey: _ethUsdcKey(),
                zeroForOne: false,
                recipient: recipient,
                deadline: block.timestamp,
                amountIn: amountIn,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );

        assertGt(amountOut, 0, "no output");
        assertEq(recipient.balance, ethBefore + amountOut, "native output not delivered to recipient");
        assertEq(address(proxy).balance, 0, "proxy retained ETH");
    }

    function test_exactOutputSingleV4_deliversExactly() public {
        uint128 amountOut = tradeUsdc;
        uint256 usdcBefore = IERC20(USDC).balanceOf(recipient);

        vm.prank(approver);
        uint256 amountIn = proxy.exactOutputSingleV4{value: uint256(tradeWeth) * 20}(
            V4ExactOutputSingleParams({
                poolKey: _ethUsdcKey(),
                zeroForOne: true,
                recipient: recipient,
                deadline: block.timestamp,
                amountOut: amountOut,
                amountInMaximum: type(uint128).max,
                sqrtPriceLimitX96: 0
            })
        );

        assertEq(IERC20(USDC).balanceOf(recipient), usdcBefore + amountOut, "exact output not exact");
        assertGt(amountIn, 0, "no input consumed");
        assertEq(address(proxy).balance, 0, "proxy retained ETH after refund");
    }

    /// @dev The overpayment path: send far more ETH than the swap needs and confirm the remainder
    /// comes back rather than sitting in the proxy for the next caller to sweep.
    function test_excessNativeIsRefundedToCaller() public {
        uint128 amountOut = tradeUsdc;
        uint256 ethBefore = approver.balance;

        vm.prank(approver);
        uint256 amountIn = proxy.exactOutputSingleV4{value: uint256(tradeWeth) * 50}(
            V4ExactOutputSingleParams({
                poolKey: _ethUsdcKey(),
                zeroForOne: true,
                recipient: approver,
                deadline: block.timestamp,
                amountOut: amountOut,
                amountInMaximum: type(uint128).max,
                sqrtPriceLimitX96: 0
            })
        );

        assertEq(approver.balance, ethBefore - amountIn, "caller lost more than the swap consumed");
        assertEq(address(proxy).balance, 0, "proxy retained the excess");
    }

    // ---------------------------------------------------------------------------
    // Hooks
    // ---------------------------------------------------------------------------

    /// @dev The load-bearing V4 restriction. A hook runs outsider code inside the swap and can
    /// rewrite the caller's balance delta, which would make it reachable code behind every standing
    /// allowance this contract holds. Rejection must happen before the unlock, on both entry points.
    function test_hookedPoolIsRejected() public {
        PoolKey memory hooked = _ethUsdcKey();
        hooked.hooks = IHooks(makeAddr("someHook"));

        uint256[4] memory before = _approverHoldings();

        vm.prank(approver);
        vm.expectRevert("Hooks not supported");
        proxy.exactInputSingleV4{value: uint256(tradeWeth)}(
            V4ExactInputSingleParams({
                poolKey: hooked,
                zeroForOne: true,
                recipient: approver,
                deadline: block.timestamp,
                amountIn: tradeWeth,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );

        vm.prank(approver);
        vm.expectRevert("Hooks not supported");
        proxy.exactOutputSingleV4{value: uint256(tradeWeth)}(
            V4ExactOutputSingleParams({
                poolKey: hooked,
                zeroForOne: true,
                recipient: approver,
                deadline: block.timestamp,
                amountOut: tradeUsdc,
                amountInMaximum: type(uint128).max,
                sqrtPriceLimitX96: 0
            })
        );

        _assertApproverUntouched(before, "hooked pool");
    }

    function testFuzz_anyNonZeroHookIsRejected(address hook) public {
        vm.assume(hook != address(0));
        PoolKey memory hooked = _ethUsdcKey();
        hooked.hooks = IHooks(hook);

        vm.prank(approver);
        vm.expectRevert("Hooks not supported");
        proxy.exactInputSingleV4(
            V4ExactInputSingleParams({
                poolKey: hooked,
                zeroForOne: false,
                recipient: approver,
                deadline: block.timestamp,
                amountIn: tradeUsdc,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );
    }

    // ---------------------------------------------------------------------------
    // Payer authority
    // ---------------------------------------------------------------------------

    /// @dev The V4 counterpart to the V3 callback tests. `unlockCallback` trusts its `data`
    /// completely — payer included — and is guarded only by `msg.sender == POOL_MANAGER`. Reaching
    /// it therefore requires the PoolManager to deliver the payload, and v4's `unlock` calls back
    /// its own caller, so the callback is only reachable from a payload the proxy itself built.
    function test_unlockCallbackCannotBeReachedWithAttackerData() public {
        uint256[4] memory before = _approverHoldings();

        V4SwapCallbackData memory payload = V4SwapCallbackData({
            poolKey: _ethUsdcKey(),
            swapParams: SwapParams({zeroForOne: false, amountSpecified: -int256(500_000e6), sqrtPriceLimitX96: 0}),
            payer: approver,
            recipient: outsider
        });

        vm.prank(outsider);
        vm.expectRevert("Not pool manager");
        proxy.unlockCallback(abi.encode(payload));

        // Even impersonating the manager only works with a cheat code, i.e. not on a real chain.
        // Included to show what the guard is actually load-bearing for.
        vm.prank(POOL_MANAGER);
        vm.expectRevert(); // manager is locked; the inner swap cannot proceed
        proxy.unlockCallback(abi.encode(payload));

        _assertApproverUntouched(before, "v4 unlock callback");
    }

    function test_outsiderV4Swap_debitsOutsiderNotApprover() public {
        uint256[4] memory before = _approverHoldings();

        vm.startPrank(outsider);
        IERC20(USDC).approve(address(proxy), type(uint256).max);
        proxy.exactInputSingleV4(
            V4ExactInputSingleParams({
                poolKey: _ethUsdcKey(),
                zeroForOne: false,
                recipient: outsider,
                deadline: block.timestamp,
                amountIn: tradeUsdc,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );
        vm.stopPrank();

        _assertApproverUntouched(before, "outsider v4 swap");
    }

    // ---------------------------------------------------------------------------
    // The native refund sweep
    // ---------------------------------------------------------------------------

    /// @dev `_refundExcessNative` pays out the contract's whole balance, so any ETH sitting in the
    /// proxy goes to the next V4 caller. Pins down the invariant documented on that function: the
    /// contract must never carry a balance between calls.
    function test_forceFedEthIsSweptByTheNextV4Caller() public {
        // Deltas, not absolutes: on a fork the feeder's deterministic CREATE address may already be
        // a funded mainnet account, and its dust rides along with the selfdestruct.
        // A contract with no `receive()` can still end up holding ETH — via `selfdestruct` or as a
        // block's coinbase — and can prevent neither. `vm.deal` puts us in that state directly.
        vm.deal(address(proxy), 10 ether);

        uint256 outsiderBefore = outsider.balance;
        uint256 sweepable = address(proxy).balance;

        vm.startPrank(outsider);
        IERC20(USDC).approve(address(proxy), type(uint256).max);
        proxy.exactInputSingleV4(
            V4ExactInputSingleParams({
                poolKey: _ethUsdcKey(),
                zeroForOne: false,
                recipient: recipient, // output goes elsewhere; only the sweep credits the caller
                deadline: block.timestamp,
                amountIn: tradeUsdc,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );
        vm.stopPrank();

        // The caller receives ETH it did not deposit. This is why the `_refundExcessNative`
        // invariant (no receive, no multicall, one payable path per transaction) is load-bearing.
        assertEq(outsider.balance, outsiderBefore + sweepable, "stray ETH was not swept by the caller");
        assertEq(address(proxy).balance, 0, "proxy still holds ETH");
    }

    /// @dev The same invariant from the settle side: `CurrencySettler.settle` pays the manager out
    /// of `address(this).balance`, so a native-input swap with `msg.value == 0` settles from any
    /// balance the contract is carrying.
    function test_strandedEthCanPayForSomeoneElsesSwap() public {
        vm.deal(address(proxy), 20 ether);

        uint256 usdcBefore = IERC20(USDC).balanceOf(outsider);
        uint256 outsiderEthBefore = outsider.balance;

        // Note the absence of a `{value: ...}`: the outsider contributes no ETH of their own.
        vm.prank(outsider);
        uint256 amountOut = proxy.exactInputSingleV4(
            V4ExactInputSingleParams({
                poolKey: _ethUsdcKey(),
                zeroForOne: true, // native in
                recipient: outsider,
                deadline: block.timestamp,
                amountIn: tradeWeth * 5,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );

        assertGt(amountOut, 0, "swap did not execute");
        assertEq(IERC20(USDC).balanceOf(outsider), usdcBefore + amountOut, "outsider did not receive output");
        // No ETH was contributed by the caller, and the remainder is returned on the way out.
        assertGt(outsider.balance, outsiderEthBefore, "outsider did not profit");
        assertEq(address(proxy).balance, 0, "proxy still holds ETH");
    }
}
