// SPDX-License-Identifier: GPL-3.0
pragma solidity =0.8.28;

import "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

import {ForkBase} from "../helpers/ForkBase.sol";
import {SwapCalldata} from "../../helpers/SwapCalldata.sol";
import {PoolKey, IHooks} from "../../../src/interfaces/uniswapV4/IPoolManagerMinimal.sol";
import {IProxyErrors} from "../../../src/interfaces/IProxyErrors.sol";

/// @notice V4 legs of `swap`, against the real mainnet PoolManager singleton.
/// @dev V4 concentrates the risk differently from V3: one singleton instead of derived pool
/// addresses, ETH as a first-class currency, and hooks that can run arbitrary code inside a swap.
contract V4SwapTest is ForkBase {
    // ---------------------------------------------------------------------------
    // Happy paths
    // ---------------------------------------------------------------------------

    /// @notice A one-leg V4 swap of native ETH for USDC, paid from msg.value, delivers to the caller and
    /// consumes exactly `amountIn`
    function test_swap_v4ExactInput_nativeForUsdc() public {
        uint128 amountIn = tradeWeth;
        uint256 usdcBefore = IERC20(USDC).balanceOf(approver);
        uint256 ethBefore = approver.balance;

        _expectUnlocks(1);
        uint256 amountOut = _swapOne(approver, _v4In(true, amountIn, 0), amountIn);

        assertGt(amountOut, 0, "no output");
        assertEq(IERC20(USDC).balanceOf(approver), usdcBefore + amountOut, "output not delivered");
        assertEq(approver.balance, ethBefore - amountIn, "ETH debit does not match amountIn");
        assertEq(address(proxy).balance, 0, "proxy retained ETH");
    }

    /// @notice A one-leg V4 swap of USDC for native ETH delivers the ETH to the caller
    function test_swap_v4ExactInput_usdcForNative() public {
        uint128 amountIn = tradeUsdc;
        uint256 ethBefore = approver.balance;

        uint256 amountOut = _swapOne(approver, _v4In(false, amountIn, 0), 0);

        assertGt(amountOut, 0, "no output");
        assertEq(approver.balance, ethBefore + amountOut, "native output not delivered to the caller");
        assertEq(address(proxy).balance, 0, "proxy retained ETH");
    }

    /// @notice ETH sent beyond what the leg consumes comes back to the caller
    /// @dev The overpayment path: send far more ETH than the swap needs and confirm the remainder
    /// comes back rather than sitting in the proxy for the next caller to sweep.
    function test_excessNativeIsRefundedToCaller() public {
        uint128 amountIn = tradeWeth;
        uint256 ethBefore = approver.balance;

        _swapOne(approver, _v4In(true, amountIn, 0), uint256(tradeWeth) * 50);

        assertEq(approver.balance, ethBefore - amountIn, "caller lost more than the swap consumed");
        assertEq(address(proxy).balance, 0, "proxy retained the excess");
    }

    // ---------------------------------------------------------------------------
    // Hooks
    // ---------------------------------------------------------------------------

    /// @notice A hook cannot be encoded: a vault that registered only a hooked pool cannot swap on it,
    /// and nothing runs
    /// @dev The load-bearing V4 restriction. A hook runs outsider code inside the swap and can
    /// rewrite the caller's balance delta, which would make it reachable code behind every standing
    /// allowance this contract holds. A leg has no hooks field: (currencies, fee, tickSpacing) always
    /// name the hookless pool's PoolId, so registering the hooked PoolId authorises nothing, and the
    /// refusal happens before the unlock.
    function test_hookedPoolCannotBeTargeted() public {
        PoolKey memory hooked = _v4EthUsdc();
        hooked.hooks = IHooks(makeAddr("someHook"));
        _allow(approver, proxy.v4Key(hooked), SWAP); // registered: only the format can refuse it
        _deny(approver, proxy.v4Key(_v4EthUsdc())); // and the hookless twin is not

        uint256[4] memory before = _approverHoldings();
        uint256 ethBefore = approver.balance;
        bytes memory data = _swapData(_one(_v4In(true, tradeWeth, 0)));

        _expectUnlocks(0);
        vm.prank(approver);
        vm.expectRevert(IProxyErrors.PoolNotAllowed.selector);
        proxy.swap{value: tradeWeth}(data);

        _assertApproverUntouched(before, "hooked pool");
        assertEq(approver.balance, ethBefore, "ETH left the caller on a refused swap");
    }

    /// @notice Whatever the hook, registering a hooked pool never authorises a swap
    function testFuzz_noHookedRegistrationAuthorisesASwap(address hook) public {
        vm.assume(hook != address(0));
        PoolKey memory hooked = _v4EthUsdc();
        hooked.hooks = IHooks(hook);
        _allow(approver, proxy.v4Key(hooked), SWAP);
        _deny(approver, proxy.v4Key(_v4EthUsdc()));
        bytes memory data = _swapData(_one(_v4In(false, tradeUsdc, 0)));

        _expectUnlocks(0);
        vm.prank(approver);
        vm.expectRevert(IProxyErrors.PoolNotAllowed.selector);
        proxy.swap(data);
    }

    /// @notice With the hookless pool registered as well, the same leg trades on the hookless pool;
    /// the hooked pool is never touched
    function test_hookedRegistration_legStillRunsOnTheHooklessPool() public {
        PoolKey memory hooked = _v4EthUsdc();
        hooked.hooks = IHooks(makeAddr("someHook"));
        bytes32 hookedId = proxy.v4Key(hooked);
        bytes32 hooklessId = proxy.v4Key(_v4EthUsdc());
        _allow(approver, hookedId, SWAP);

        uint256 hooklessBefore = _v4Slot0(hooklessId);
        uint256 hookedBefore = _v4Slot0(hookedId);

        uint256 amountOut = _swapOne(approver, _v4In(true, tradeWeth, 0), tradeWeth);

        assertGt(amountOut, 0, "no output");
        assertTrue(_v4Slot0(hooklessId) != hooklessBefore, "the hookless pool did not trade");
        assertEq(_v4Slot0(hookedId), hookedBefore, "the hooked pool changed");
    }

    // ---------------------------------------------------------------------------
    // Payer authority
    // ---------------------------------------------------------------------------

    /// @notice `unlockCallback` cannot be reached with attacker data: anyone but the PoolManager is
    /// refused, and even the PoolManager's address cannot run a payload outside an unlock
    /// @dev The V4 counterpart to the V3 callback tests. `unlockCallback` trusts its payload, plan
    /// included (the registry and band checks `swap` made before opening the unlock), and is guarded
    /// only by `msg.sender == POOL_MANAGER`. Reaching it therefore requires the PoolManager to deliver
    /// the payload, and v4's `unlock` calls back its own caller, so the callback is only reachable
    /// from a payload the proxy itself built. The payload names no payer either: payments are for the
    /// account holding the proxy's lock, and outside a call nobody holds it.
    function test_unlockCallbackCannotBeReachedWithAttackerData() public {
        uint256[4] memory before = _approverHoldings();

        // A well-formed swap unlock payload (SWAP_TAG | legs | usesLedger | plan words | data) selling
        // 500k of USDC on the live pool, with a plan claiming any band is fine
        bytes memory data = _swapData(_one(_v4In(false, 500_000e6, 0)));
        bytes memory payload =
            bytes.concat(hex"01", abi.encode(uint256(1), uint256(0), proxy.v4Key(_v4EthUsdc()), _anyBand()), data);

        vm.prank(outsider);
        vm.expectRevert(IProxyErrors.NotPoolManager.selector);
        proxy.unlockCallback(payload);

        // Even impersonating the manager only works with a cheat code, i.e. not on a real chain.
        // Included to show what the guard is actually load-bearing for: the manager is locked, so
        // the inner swap cannot proceed.
        vm.prank(POOL_MANAGER);
        vm.expectRevert(IPoolManager.ManagerLocked.selector);
        proxy.unlockCallback(payload);

        // A liquidity unlock outside `modifyLiquidityV4`, and an unknown kind of unlock, are refused
        vm.prank(POOL_MANAGER);
        vm.expectRevert(IProxyErrors.NoLiquidityOperation.selector);
        proxy.unlockCallback(hex"02");

        vm.prank(POOL_MANAGER);
        vm.expectRevert(IProxyErrors.UnexpectedCallback.selector);
        proxy.unlockCallback(hex"03");

        _assertApproverUntouched(before, "v4 unlock callback");
    }

    /// @notice An outsider's V4 swap is paid by the outsider; the approver's balances never move
    function test_outsiderV4Swap_debitsOutsiderNotApprover() public {
        uint256[4] memory before = _approverHoldings();
        uint256 outsiderUsdcBefore = IERC20(USDC).balanceOf(outsider);
        uint256 outsiderEthBefore = outsider.balance;

        vm.prank(outsider);
        IERC20(USDC).approve(address(proxy), type(uint256).max);
        uint256 amountOut = _swapOne(outsider, _v4In(false, tradeUsdc, 0), 0);

        assertEq(IERC20(USDC).balanceOf(outsider), outsiderUsdcBefore - tradeUsdc, "outsider not debited");
        assertEq(outsider.balance, outsiderEthBefore + amountOut, "output not delivered to the caller");
        _assertApproverUntouched(before, "outsider v4 swap");
    }

    // ---------------------------------------------------------------------------
    // The native refund sweep
    // ---------------------------------------------------------------------------

    /// @notice ETH force-fed to the proxy goes to the next caller of `swap` (documented behaviour)
    /// @dev `_refundExcessNative` pays out the contract's whole balance at the end of every `swap`
    /// call, so any ETH sitting in the proxy goes to the next caller. Pins down the invariant
    /// documented on that function: the contract must never carry a balance between calls.
    function test_forceFedEthIsSweptByTheNextSwapCaller() public {
        // Deltas, not absolutes: on a fork the feeder's deterministic CREATE address may already be
        // a funded mainnet account, and its dust rides along with the selfdestruct.
        // A contract with no `receive()` can still end up holding ETH — via `selfdestruct` or as a
        // block's coinbase — and can prevent neither. `vm.deal` puts us in that state directly.
        vm.deal(address(proxy), 10 ether);

        uint256 outsiderBefore = outsider.balance;
        uint256 sweepable = address(proxy).balance;

        vm.prank(outsider);
        IERC20(USDC).approve(address(proxy), type(uint256).max);
        // USDC in, ETH out, to the caller
        uint256 amountOut = _swapOne(outsider, _v4In(false, tradeUsdc, 0), 0);

        // The caller receives ETH it did not deposit, on top of the swap's own ETH output. This is
        // why the `_refundExcessNative` invariant (no receive, no entry point inside another) is
        // load-bearing.
        assertEq(outsider.balance, outsiderBefore + amountOut + sweepable, "stray ETH was not swept by the caller");
        assertEq(address(proxy).balance, 0, "proxy still holds ETH");
    }

    /// @notice The sweep is part of every `swap` call, so even a V3-only call collects force-fed ETH
    /// @dev `swap` is the one swap entry point and it is payable, so the refund runs whatever the legs
    /// are. A swap with no native leg at all still hands the stray balance to its caller.
    function test_forceFedEthIsSweptByAV3OnlySwapToo() public {
        vm.deal(address(proxy), 3 ether);

        uint256 outsiderEthBefore = outsider.balance;
        uint256 sweepable = address(proxy).balance;

        vm.prank(outsider);
        IERC20(USDC).approve(address(proxy), type(uint256).max);
        _expectUnlocks(0);
        _swapOne(outsider, _v3In(USDC, WETH, 500, tradeUsdc, 0), 0);

        assertEq(outsider.balance, outsiderEthBefore + sweepable, "stray ETH was not swept by the caller");
        assertEq(address(proxy).balance, 0, "proxy still holds ETH");
    }

    /// @notice ETH stranded in the proxy can pay for the next caller's native-input leg
    /// @dev The same invariant from the settle side: a native-input leg is paid from
    /// `address(this).balance` (msg.value plus anything force-fed), so a native-input swap with
    /// `msg.value == 0` settles from any balance the contract is carrying.
    function test_strandedEthCanPayForSomeoneElsesSwap() public {
        vm.deal(address(proxy), 20 ether);

        uint256 usdcBefore = IERC20(USDC).balanceOf(outsider);
        uint256 outsiderEthBefore = outsider.balance;

        // Note the zero value: the outsider contributes no ETH of their own.
        uint256 amountOut = _swapOne(outsider, _v4In(true, tradeWeth * 5, 0), 0);

        assertGt(amountOut, 0, "swap did not execute");
        assertEq(IERC20(USDC).balanceOf(outsider), usdcBefore + amountOut, "outsider did not receive output");
        // No ETH was contributed by the caller, and the remainder is returned on the way out.
        assertGt(outsider.balance, outsiderEthBefore, "outsider did not profit");
        assertEq(address(proxy).balance, 0, "proxy still holds ETH");
    }

    /// @notice A one-leg V4 exact-output swap delivers exactly `amountOut` and refunds the unspent ETH
    function test_swap_v4ExactOutput_deliversExactly() public {
        uint128 amountOut = tradeUsdc;
        uint256 usdcBefore = IERC20(USDC).balanceOf(approver);
        uint256 ethBefore = approver.balance;

        uint256 amountIn = _swapOne(approver, _v4Out(true, amountOut, type(uint128).max), uint256(tradeWeth) * 20);

        assertEq(IERC20(USDC).balanceOf(approver), usdcBefore + amountOut, "exact output not exact");
        assertGt(amountIn, 0, "no input consumed");
        assertEq(approver.balance, ethBefore - amountIn, "caller paid other than the reported input");
        assertEq(address(proxy).balance, 0, "proxy retained ETH after refund");
    }

    /// @dev A plan word's band covering every tick: minTick | maxTick << 24, each as 24 bits
    function _anyBand() internal pure returns (uint256 band) {
        int24 minTick = -887272;
        int24 maxTick = 887272;
        assembly ("memory-safe") {
            band := or(and(minTick, 0xffffff), shl(24, and(maxTick, 0xffffff)))
        }
    }
}
