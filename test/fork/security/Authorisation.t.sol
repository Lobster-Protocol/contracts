// SPDX-License-Identifier: GPL-3.0
pragma solidity =0.8.26;

import "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ForkBase} from "../helpers/ForkBase.sol";
import {PoolImpersonator, ReentrantToken} from "../helpers/Callers.sol";
import {MintParams, MintCallbackData} from "../../../src/interfaces/uniswapV3/IUniswapV3MintCallback.sol";
import {SwapCallbackData, ExactInputSingleParams} from "../../../src/interfaces/uniswapV3/IUniswapV3SwapCallback.sol";
import {IUniswapV3PoolMinimal} from "../../../src/interfaces/uniswapV3/IUniswapV3PoolMinimal.sol";
import {PoolAddress} from "../../../src/libraries/uniswapV3/PoolAddress.sol";

/// @notice Authorisation tests for standing approvals.
/// @dev Fixture: an account has granted this proxy `type(uint256).max` on four tokens and holds the
/// funds in its own wallet. These tests assert the invariant the design rests on — that the approval
/// is only ever spendable by the account that granted it, and only within a call it initiated.
contract AuthorisationTest is ForkBase {
    PoolImpersonator internal impersonator;

    function setUp() public override {
        super.setUp();
        impersonator = new PoolImpersonator(proxy);

        // Precondition for everything below: the allowance really is unlimited and really is live.
        assertEq(IERC20(USDC).allowance(approver, address(proxy)), type(uint256).max, "fixture: no allowance");
        assertGt(IERC20(USDC).balanceOf(approver), 0, "fixture: approver holds no balance");
    }

    // ---------------------------------------------------------------------------
    // 1. Forged callbacks — calling the payment hooks directly
    // ---------------------------------------------------------------------------

    /// @dev The mint callback takes `payer` from decoded calldata and transfers to `msg.sender`,
    /// so `CallbackValidation` is what establishes that the caller is a real pool.
    function test_mintCallback_directFromEOA_reverts() public {
        uint256[4] memory before = _approverHoldings();

        vm.prank(outsider);
        vm.expectRevert();
        proxy.uniswapV3MintCallback(
            500_000e6,
            100 ether,
            abi.encode(
                MintCallbackData({
                    poolKey: PoolAddress.PoolKey({token0: USDC, token1: WETH, fee: 500}), payer: approver
                })
            )
        );

        _assertApproverUntouched(before, "direct mint callback from EOA");
    }

    function test_mintCallback_fromContract_reverts() public {
        uint256[4] memory before = _approverHoldings();

        vm.prank(outsider);
        vm.expectRevert();
        impersonator.callViaMintCallback(USDC, WETH, 500, approver, 500_000e6, 100 ether);

        _assertApproverUntouched(before, "mint callback from contract");
    }

    function test_swapCallback_directFromEOA_reverts() public {
        uint256[4] memory before = _approverHoldings();

        vm.prank(outsider);
        vm.expectRevert();
        proxy.uniswapV3SwapCallback(
            int256(500_000e6),
            -1,
            abi.encode(SwapCallbackData({tokenIn: USDC, tokenOut: WETH, fee: 500, payer: approver}))
        );

        _assertApproverUntouched(before, "direct swap callback from EOA");
    }

    function test_swapCallback_fromContract_reverts() public {
        uint256[4] memory before = _approverHoldings();

        vm.prank(outsider);
        vm.expectRevert();
        impersonator.callViaSwapCallback(USDC, WETH, 500, approver, int256(500_000e6), -1);

        _assertApproverUntouched(before, "swap callback from contract");
    }

    /// @dev Sweeps every approved token across a spread of real fee tiers, so the guard is shown to
    /// hold uniformly rather than for one lucky pair.
    function test_swapCallback_everyApprovedTokenAndFeeTier_reverts() public {
        uint256[4] memory before = _approverHoldings();
        address[4] memory tokens = [USDC, WETH, USDT, DAI];
        uint24[4] memory fees = [uint24(100), 500, 3000, 10000];

        for (uint256 i = 0; i < tokens.length; i++) {
            for (uint256 j = 0; j < fees.length; j++) {
                address other = tokens[i] == WETH ? USDC : WETH;

                vm.prank(outsider);
                vm.expectRevert();
                impersonator.callViaSwapCallback(tokens[i], other, fees[j], approver, int256(1e18), -1);

                vm.prank(outsider);
                vm.expectRevert();
                impersonator.callViaMintCallback(
                    tokens[i] < other ? tokens[i] : other,
                    tokens[i] < other ? other : tokens[i],
                    fees[j],
                    approver,
                    1e18,
                    1e18
                );
            }
        }

        _assertApproverUntouched(before, "callback sweep over tokens x fees");
    }

    function test_unlockCallback_fromNonManager_reverts() public {
        vm.prank(outsider);
        vm.expectRevert("Not pool manager");
        proxy.unlockCallback("");

        vm.prank(outsider);
        vm.expectRevert("Not pool manager");
        impersonator.callViaUnlockCallback("");
    }

    /// @dev Establishes *why* the callback guard holds, not just that it does. A caller-supplied
    /// poolKey only passes if its CREATE2-derived address matches `msg.sender`, and the derivation
    /// is over a 160-bit address space. This is the same address-derivation assumption Uniswap's own
    /// periphery relies on.
    function test_forgedPoolKey_neverLandsOnAttackerAddress() public view {
        // Vary the two free components of a poolKey — the paired token and the fee tier — while
        // holding token0 fixed.
        for (uint160 salt = 1; salt <= 200; salt++) {
            address pairedToken = address(uint160(uint256(keccak256(abi.encode(salt)))));
            if (pairedToken <= USDC) continue;
            for (uint24 fee = 0; fee < 50; fee++) {
                address derived = PoolAddress.computeAddress(
                    V3_FACTORY, PoolAddress.PoolKey({token0: USDC, token1: pairedToken, fee: fee})
                );
                assertTrue(derived != address(impersonator), "collision found");
                assertTrue(derived != outsider, "collision found");
            }
        }
    }

    // ---------------------------------------------------------------------------
    // 2. payer is always msg.sender — using the entry points as intended
    // ---------------------------------------------------------------------------

    function test_outsiderSwap_debitsOutsiderNotApprover() public {
        uint256[4] memory before = _approverHoldings();
        uint256 outsiderUsdcBefore = IERC20(USDC).balanceOf(outsider);

        vm.startPrank(outsider);
        IERC20(USDC).approve(address(proxy), type(uint256).max);
        proxy.exactInputSingle(
            ExactInputSingleParams({
                tokenIn: USDC,
                tokenOut: WETH,
                fee: 500,
                recipient: outsider,
                deadline: block.timestamp,
                amountIn: tradeUsdc,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );
        vm.stopPrank();

        // The caller settled from its own balance.
        assertEq(IERC20(USDC).balanceOf(outsider), outsiderUsdcBefore - tradeUsdc, "outsider not debited");
        _assertApproverUntouched(before, "outsider swap");
    }

    function test_outsiderMint_debitsOutsiderNotApprover() public {
        uint256[4] memory before = _approverHoldings();
        (int24 lower, int24 upper) = _rangeAroundSpot(USDC_WETH_500, 10);

        // Directing the resulting position elsewhere changes nothing about who pays: `mint` stamps
        // payer = msg.sender into the callback data.
        vm.startPrank(outsider);
        IERC20(USDC).approve(address(proxy), type(uint256).max);
        IERC20(WETH).approve(address(proxy), type(uint256).max);
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
                recipient: outsider,
                deadline: block.timestamp
            })
        );
        vm.stopPrank();

        _assertApproverUntouched(before, "outsider mint");
    }

    /// @dev A caller with no balance of its own must simply fail, rather than settling from any
    /// other account's approval.
    function test_callerWithNoBalance_cannotSwapAtAll() public {
        address brokeCaller = _actor("brokeCaller");
        uint256[4] memory before = _approverHoldings();

        vm.startPrank(brokeCaller);
        IERC20(USDC).approve(address(proxy), type(uint256).max);
        vm.expectRevert();
        proxy.exactInputSingle(
            ExactInputSingleParams({
                tokenIn: USDC,
                tokenOut: WETH,
                fee: 500,
                recipient: brokeCaller,
                deadline: block.timestamp,
                amountIn: tradeUsdc,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );
        vm.stopPrank();

        _assertApproverUntouched(before, "penniless outsider");
    }

    /// @dev Fuzzed across callers, recipients, tokens, fees and amounts. No calldata combination
    /// should ever settle from an account other than the caller.
    function testFuzz_approverUntouchedByArbitraryCalls(
        address caller,
        address dest,
        uint256 amountIn,
        uint8 tokenSel,
        uint8 feeSel
    )
        public
    {
        vm.assume(caller != approver && caller != address(0) && caller != address(proxy));
        vm.assume(dest != address(0));
        vm.assume(caller.code.length == 0);

        address[4] memory tokens = [USDC, WETH, USDT, DAI];
        uint24[4] memory fees = [uint24(100), 500, 3000, 10000];
        address tokenIn = tokens[tokenSel % 4];
        address tokenOut = tokens[(tokenSel / 4) % 4];
        vm.assume(tokenIn != tokenOut);
        // Bounded deliberately: the property under test is who pays, not how deep the swap goes.
        // A redirected payer shows up at 1 wei as clearly as at 1e30, and large orders only
        // rate-limit the fork RPC.
        amountIn = bound(amountIn, 1, 1e9);

        uint256[4] memory before = _approverHoldings();

        // Gas-capped: thin fee tiers can make a large order walk tens of thousands of ticks, which
        // on a fork is one RPC storage read each. Out-of-gas is just another revert here — the
        // approver's balance is the only thing being asserted.
        vm.prank(caller);
        try proxy.exactInputSingle{gas: 3_000_000}(
            ExactInputSingleParams({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                fee: fees[feeSel % 4],
                recipient: dest,
                deadline: block.timestamp,
                amountIn: amountIn,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        ) {}
            catch {}

        _assertApproverUntouched(before, "fuzzed arbitrary call");
    }

    /// @dev Same property, for the raw callbacks with fully caller-chosen poolKeys.
    function testFuzz_forgedCallbackNeverPays(address caller, address otherToken, uint24 fee, uint256 amount) public {
        vm.assume(caller != address(0) && caller.code.length == 0);
        vm.assume(otherToken > USDC);
        amount = bound(amount, 1, 1e24);

        uint256[4] memory before = _approverHoldings();

        vm.prank(caller);
        try proxy.uniswapV3MintCallback(
            amount,
            amount,
            abi.encode(
                MintCallbackData({
                    poolKey: PoolAddress.PoolKey({token0: USDC, token1: otherToken, fee: fee}), payer: approver
                })
            )
        ) {}
            catch {}

        vm.prank(caller);
        try proxy.uniswapV3SwapCallback(
            // casting to 'int256' is safe because `amount` is bounded to 1e24, far below int256 max
            // forge-lint: disable-next-line(unsafe-typecast)
            int256(amount),
            -1,
            abi.encode(SwapCallbackData({tokenIn: USDC, tokenOut: otherToken, fee: fee, payer: approver}))
        ) {}
            catch {}

        _assertApproverUntouched(before, "fuzzed forged callback");
    }

    // ---------------------------------------------------------------------------
    // 3. Re-entrancy from a token inside a genuine, factory-derived pool
    // ---------------------------------------------------------------------------

    /// @dev The case worth proving. A V3 pool pairing a real token with an arbitrary contract is
    /// still factory-derived, so its callbacks pass verification, and that token's `transferFrom`
    /// runs inside the proxy's own payment callback. This asserts that re-entering from there
    /// cannot change which account settles.
    function test_reentrantTokenInGenuinePool_cannotRedirectPayer() public {
        ReentrantToken reentrant = new ReentrantToken();
        reentrant.mint(outsider, 1_000_000e18);
        // This pool is built by the test, so fund to its scale rather than the chain's.
        deal(USDC, outsider, 1_000_000e6);

        // A real pool, created through the real factory.
        address pool = factory.createPool(address(reentrant), USDC, 3000);
        IUniswapV3PoolMinimal(pool).initialize(79228162514264337593543950336); // tick 0
        assertEq(pool, _poolFor(address(reentrant), USDC, 3000), "created pool is not the derived address");

        // Re-entry aims at a *different*, unlocked pool so we are testing the proxy, not the V3
        // reentrancy lock on the pool we happen to be inside.
        reentrant.arm(proxy, approver, outsider, USDC, WETH, 500);

        (int24 lower, int24 upper) = _rangeAroundSpot(pool, 10);
        (address token0, address token1) =
            address(reentrant) < USDC ? (address(reentrant), USDC) : (USDC, address(reentrant));

        uint256[4] memory before = _approverHoldings();

        vm.startPrank(outsider);
        IERC20(USDC).approve(address(proxy), type(uint256).max);
        reentrant.approve(address(proxy), type(uint256).max);
        proxy.mint(
            MintParams({
                token0: token0,
                token1: token1,
                fee: 3000,
                tickLower: lower,
                tickUpper: upper,
                amount0Desired: token0 == USDC ? 10_000e6 : 10_000e18,
                amount1Desired: token1 == USDC ? 10_000e6 : 10_000e18,
                amount0Min: 0,
                amount1Min: 0,
                recipient: outsider,
                deadline: block.timestamp
            })
        );
        vm.stopPrank();

        // The token really did receive control inside the proxy's callback...
        assertGt(reentrant.reentryAttempts(), 0, "re-entry never fired; test proves nothing");
        // ...and neither route worked.
        assertFalse(reentrant.entryPointReentrySucceeded(), "re-entered entry point succeeded");
        assertFalse(reentrant.directCallbackReentrySucceeded(), "re-entered raw callback succeeded");
        _assertApproverUntouched(before, "re-entrant token");
    }

    // ---------------------------------------------------------------------------
    // 4. ETH held by the proxy
    // ---------------------------------------------------------------------------

    /// @dev `_refundExcessNative` pays out `address(this).balance` — the whole balance, not the
    /// caller's unspent share. That is only safe while the proxy cannot accumulate ETH between
    /// calls. It has no `receive()`, so ordinary sends bounce; selfdestruct is the remaining route.
    function test_proxyRejectsPlainEthTransfers() public {
        vm.deal(outsider, 1 ether);
        // Delta, not absolute: a freshly deployed proxy can land on an address that already holds a
        // balance on the forked chain (it does on Sepolia), which says nothing about this call.
        uint256 before = address(proxy).balance;

        vm.prank(outsider);
        (bool ok,) = address(proxy).call{value: 1 ether}("");

        assertFalse(ok, "proxy accepted a plain ETH transfer; the refund sweep is now unsafe");
        assertEq(address(proxy).balance, before, "proxy balance changed despite the bounced send");
    }
}
