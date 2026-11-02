// SPDX-License-Identifier: GPL-3.0
pragma solidity =0.8.28;

import "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ForkBase} from "../helpers/ForkBase.sol";
import {SwapCalldata} from "../../helpers/SwapCalldata.sol";
import {PoolKey, IHooks} from "../../../src/interfaces/uniswapV4/IPoolManagerMinimal.sol";
import {IProxyErrors} from "../../../src/interfaces/IProxyErrors.sol";

/// @notice A vault contract with no `receive()` and no fallback: any ETH sent to it bounces
contract NoEthVault {}

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
    /// comes back rather than staying in the proxy.
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
    /// refused, and even the PoolManager's address cannot run a swap payload outside a `swap` call,
    /// not even one claiming a msg.value to spend the ETH the proxy holds
    /// @dev The V4 counterpart to the V3 callback tests. Once the caller is checked to be the
    /// PoolManager, `unlockCallback` trusts its payload: the plan (the registry and band checks `swap`
    /// made before opening the unlock) and the msg.value `swap` received, which native-input legs may
    /// spend. Reaching it therefore requires the PoolManager to deliver the payload, and v4's `unlock`
    /// calls back its own caller, so the callback is only reachable from a payload the proxy itself
    /// built. The payload names no payer either: payments are for the account holding the proxy's
    /// lock, and the swap body runs only while that lock is held, i.e. while a `swap` call is running.
    function test_unlockCallbackCannotBeReachedWithAttackerData() public {
        // ETH force-fed to the proxy: what a payload claiming a msg.value would try to spend
        vm.deal(address(proxy), 10 ether);
        uint256 proxyEth = address(proxy).balance;
        uint256[4] memory before = _approverHoldings();

        // Well-formed swap unlock payloads, each with a plan claiming any band is fine: one selling
        // 500k of USDC on the live pool, one buying with 10 ETH it claims was sent as msg.value
        bytes[2] memory payloads =
            [_swapUnlockPayload(_v4In(false, 500_000e6, 0), 0), _swapUnlockPayload(_v4In(true, 10 ether, 0), 10 ether)];

        // Nothing below reaches the PoolManager, not even to read a pool's tick
        vm.expectCall(POOL_MANAGER, "", 0);
        for (uint256 i = 0; i < payloads.length; i++) {
            vm.prank(outsider);
            vm.expectRevert(IProxyErrors.NotPoolManager.selector);
            proxy.unlockCallback(payloads[i]);

            // Even impersonating the manager only works with a cheat code, i.e. not on a real chain.
            // Included to show what the guard is actually load-bearing for: outside a `swap` call
            // nobody holds the proxy's lock, so the swap body refuses the payload before it reaches
            // the PoolManager.
            vm.prank(POOL_MANAGER);
            vm.expectRevert(IProxyErrors.UnexpectedCallback.selector);
            proxy.unlockCallback(payloads[i]);
        }

        // A liquidity unlock outside `modifyLiquidityV4`, and an unknown kind of unlock, are refused
        vm.prank(POOL_MANAGER);
        vm.expectRevert(IProxyErrors.NoLiquidityOperation.selector);
        proxy.unlockCallback(hex"02");

        vm.prank(POOL_MANAGER);
        vm.expectRevert(IProxyErrors.UnexpectedCallback.selector);
        proxy.unlockCallback(hex"03");

        _assertApproverUntouched(before, "v4 unlock callback");
        assertEq(address(proxy).balance, proxyEth, "the proxy's ETH moved");
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
    // Force-fed ETH: never spent, never refunded
    // ---------------------------------------------------------------------------
    // A contract with no `receive()` can still end up holding ETH, via `selfdestruct` or as a block's
    // coinbase, and can prevent neither; `vm.deal` on the proxy puts it in that state directly. Native
    // input is paid out of the caller's msg.value only, and the call refunds the proxy's balance above
    // what it held before msg.value arrived (`_refundExcessNative`): exactly the unspent msg.value.

    /// @notice ETH force-fed to the proxy is not refunded to the next caller of `swap`: a caller that
    /// sends no ETH gets exactly its swap's output, one that overpays gets back exactly its unspent
    /// msg.value, and the force-fed ETH stays in the proxy
    function test_forceFedEthIsNotRefundedToTheNextSwapCaller() public {
        vm.deal(address(proxy), 10 ether);
        uint256 forceFed = address(proxy).balance;

        // USDC in, ETH out, to the caller, which sends no ETH
        uint256 outsiderBefore = outsider.balance;
        vm.prank(outsider);
        IERC20(USDC).approve(address(proxy), type(uint256).max);
        uint256 amountOut = _swapOne(outsider, _v4In(false, tradeUsdc, 0), 0);

        assertGt(amountOut, 0, "no output");
        assertEq(outsider.balance, outsiderBefore + amountOut, "the caller got ETH beyond its swap's output");
        assertEq(address(proxy).balance, forceFed, "force-fed ETH left the proxy");

        // The same, now sending ETH that no leg spends: exactly that ETH comes back, with the output
        vm.deal(outsider, outsider.balance + 1 ether);
        outsiderBefore = outsider.balance;
        amountOut = _swapOne(outsider, _v4In(false, tradeUsdc, 0), 1 ether);
        assertGt(amountOut, 0, "no output");
        assertEq(outsider.balance, outsiderBefore + amountOut, "the unspent msg.value was not refunded exactly");
        assertEq(address(proxy).balance, forceFed, "force-fed ETH left the proxy");

        // ETH in, sending fifty times what the leg spends
        uint256 approverBefore = approver.balance;
        _swapOne(approver, _v4In(true, tradeWeth, 0), uint256(tradeWeth) * 50);

        assertEq(approver.balance, approverBefore - tradeWeth, "the refund was not exactly the unspent msg.value");
        assertEq(address(proxy).balance, forceFed, "force-fed ETH left the proxy");
    }

    /// @notice A V3-only call does not refund force-fed ETH either: sending none it gets none, and
    /// sending some it gets back exactly what it sent, which no V3 leg spends
    /// @dev `swap` is the one swap entry point and it is payable, so the refund runs whatever the legs
    /// are, and it is the same exact refund: the balance above what the proxy held before the call.
    function test_forceFedEthIsNotRefundedByAV3OnlySwap() public {
        vm.deal(address(proxy), 3 ether);
        uint256 forceFed = address(proxy).balance;
        uint256 outsiderEthBefore = outsider.balance;

        vm.prank(outsider);
        IERC20(USDC).approve(address(proxy), type(uint256).max);
        _expectUnlocks(0);
        _swapOne(outsider, _v3In(USDC, WETH, 500, tradeUsdc, 0), 0);

        assertEq(outsider.balance, outsiderEthBefore, "a V3-only call sent ETH to its caller");
        assertEq(address(proxy).balance, forceFed, "force-fed ETH left the proxy");

        _swapOne(outsider, _v3In(USDC, WETH, 500, tradeUsdc, 0), 1 ether);

        assertEq(outsider.balance, outsiderEthBefore, "the caller did not get back exactly its msg.value");
        assertEq(address(proxy).balance, forceFed, "force-fed ETH left the proxy");
    }

    /// @notice ETH stranded in the proxy cannot pay for anyone's native-input leg: short of msg.value
    /// the leg reverts `NotEnoughEthSent`, although the proxy's balance would cover it, and nothing moves
    /// @dev A native-input leg is paid out of what is left of the caller's msg.value, never out of the
    /// proxy's balance. With msg.value covering the leg's input, the same leg runs, paid by the caller
    /// alone.
    function test_strandedEthCannotPayForSomeoneElsesSwap() public {
        vm.deal(address(proxy), 20 ether);
        uint256 stranded = address(proxy).balance;
        uint128 amountIn = tradeWeth * 5;
        bytes32 poolId = proxy.v4Key(_v4EthUsdc());
        uint256 slot0Before = _v4Slot0(poolId);
        uint256 usdcBefore = IERC20(USDC).balanceOf(outsider);
        uint256 ethBefore = outsider.balance;
        bytes memory data = _swapData(_one(_v4In(true, amountIn, 0)));

        // No ETH at all, then one wei short: the stranded ETH would cover either
        uint256[2] memory values = [uint256(0), amountIn - 1];
        for (uint256 i = 0; i < values.length; i++) {
            vm.prank(outsider);
            vm.expectRevert(IProxyErrors.NotEnoughEthSent.selector);
            proxy.swap{value: values[i]}(data);
        }

        assertEq(outsider.balance, ethBefore, "the caller's ETH moved on a refused swap");
        assertEq(IERC20(USDC).balanceOf(outsider), usdcBefore, "the caller got output from a refused swap");
        assertEq(_v4Slot0(poolId), slot0Before, "the pool traded on a refused swap");
        assertEq(address(proxy).balance, stranded, "stranded ETH was spent");

        // Control: the same leg, with msg.value covering it, runs and is paid by the caller alone
        uint256 amountOut = _swapOne(outsider, _v4In(true, amountIn, 0), amountIn);

        assertGt(amountOut, 0, "swap did not execute");
        assertEq(IERC20(USDC).balanceOf(outsider), usdcBefore + amountOut, "outsider did not receive output");
        assertEq(outsider.balance, ethBefore - amountIn, "the caller did not pay the whole input itself");
        assertEq(address(proxy).balance, stranded, "stranded ETH was spent");
    }

    /// @notice ETH force-fed to the proxy cannot block a caller that cannot receive ETH: a call that
    /// sends none, or exactly what its native-input legs spend, gets none back
    /// @dev Only what is left of msg.value is refunded, and nothing is sent when that is zero, so a
    /// stranger's force-fed ETH cannot make the refund to a vault contract without `receive` revert
    /// ("STE"), V3-only call or native-input V4 call alike.
    function test_forceFedEthDoesNotBlockACallerThatCannotReceiveEth() public {
        address vault = address(new NoEthVault());
        vm.prank(outsider);
        (bool accepted,) = vault.call{value: 1}("");
        assertFalse(accepted, "fixture: the vault accepts ETH");

        _allow(vault, proxy.v3Key(_poolFor(USDC, WETH, 500)), SWAP);
        _allow(vault, proxy.v4Key(_v4EthUsdc()), SWAP);
        deal(USDC, vault, tradeUsdc);
        vm.deal(vault, tradeWeth);
        vm.prank(vault);
        IERC20(USDC).approve(address(proxy), type(uint256).max);
        vm.deal(address(proxy), 5 ether);
        uint256 forceFed = address(proxy).balance;
        uint256 usdcBefore = IERC20(USDC).balanceOf(vault);
        uint256 wethBefore = IERC20(WETH).balanceOf(vault);
        uint256 ethBefore = vault.balance;

        // V3 only, sending no ETH
        uint256 wethOut = _swapOne(vault, _v3In(USDC, WETH, 500, tradeUsdc, 0), 0);
        // V4, ETH in, sending exactly what the leg spends
        uint256 usdcOut = _swapOne(vault, _v4In(true, tradeWeth, 0), tradeWeth);

        assertEq(IERC20(WETH).balanceOf(vault), wethBefore + wethOut, "V3 output not delivered");
        assertEq(IERC20(USDC).balanceOf(vault), usdcBefore - tradeUsdc + usdcOut, "V4 output not delivered");
        assertEq(vault.balance, ethBefore - tradeWeth, "the vault did not pay exactly the leg's input");
        assertEq(address(proxy).balance, forceFed, "force-fed ETH left the proxy");
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

    /// @dev A well-formed swap unlock payload running `leg` on the live ETH/USDC pool, as {swap} writes
    /// it (SWAP_TAG | legs | msg.value << 1 | usesLedger | plan words | data), claiming `claimedValue`
    /// was sent as msg.value, with a plan claiming any band is fine
    function _swapUnlockPayload(SwapCalldata.Leg memory leg, uint256 claimedValue)
        internal
        view
        returns (bytes memory)
    {
        return bytes.concat(
            hex"01",
            abi.encode(uint256(1), claimedValue << 1, proxy.v4Key(_v4EthUsdc()), _anyBand()),
            _swapData(_one(leg))
        );
    }
}
