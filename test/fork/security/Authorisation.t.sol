// SPDX-License-Identifier: GPL-3.0
pragma solidity =0.8.28;

import "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolKey as CorePoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency as CoreCurrency} from "v4-core/src/types/Currency.sol";
import {IHooks as CoreHooks} from "v4-core/src/interfaces/IHooks.sol";

import {ForkBase} from "../helpers/ForkBase.sol";
import {PoolImpersonator, ReentrantToken, SettlementThiefToken, V3CallbackData} from "../helpers/Callers.sol";
import {PlainToken} from "../helpers/Tokens.sol";
import {SwapCalldata} from "../../helpers/SwapCalldata.sol";
import {MintParams, MintCallbackData} from "../../../src/interfaces/uniswapV3/IUniswapV3MintCallback.sol";
import {IUniswapV3PoolMinimal} from "../../../src/interfaces/uniswapV3/IUniswapV3PoolMinimal.sol";
import {
    PoolKey,
    Currency,
    IHooks,
    IPoolManagerMinimal
} from "../../../src/interfaces/uniswapV4/IPoolManagerMinimal.sol";
import {PoolAddress} from "../../../src/libraries/uniswapV3/PoolAddress.sol";
import {IProxyErrors} from "../../../src/interfaces/IProxyErrors.sol";

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

    /// @notice The mint callback, called by an EOA, fails `CallbackValidation` and moves nothing, whether
    /// its data is the old layout naming the approver as payer or the pool key `mint` writes
    /// @dev The mint callback transfers to `msg.sender`, so `CallbackValidation` (the caller must be the
    /// CREATE2 pool of the key in `data`) is what establishes that the caller is a real pool. It pays
    /// for the account holding the reentrancy lock, never for anyone named in `data`: the old
    /// `MintCallbackData{poolKey, payer}` still decodes, and its payer word is ignored. The check is a
    /// bare `require`, so the revert carries no data, unlike the lock's `UnexpectedCallback`.
    function test_mintCallback_directFromEOA_reverts() public {
        uint256[4] memory before = _approverHoldings();
        PoolAddress.PoolKey memory key = PoolAddress.PoolKey({token0: USDC, token1: WETH, fee: 500});
        bytes[2] memory forged = [abi.encode(MintCallbackData({poolKey: key, payer: approver})), abi.encode(key)];

        for (uint256 i = 0; i < forged.length; i++) {
            vm.prank(outsider);
            vm.expectRevert(bytes("")); // CallbackValidation: not the pool
            proxy.uniswapV3MintCallback(500_000e6, 100 ether, forged[i]);
        }

        _assertApproverUntouched(before, "direct mint callback from EOA");
    }

    /// @notice The same forged mint callback, from a contract, fails `CallbackValidation` and moves
    /// nothing
    function test_mintCallback_fromContract_reverts() public {
        uint256[4] memory before = _approverHoldings();

        vm.prank(outsider);
        vm.expectRevert(bytes("")); // CallbackValidation: not the pool
        impersonator.callViaMintCallback(USDC, WETH, 500, approver, 500_000e6, 100 ether);

        _assertApproverUntouched(before, "mint callback from contract");
    }

    /// @notice The V3 swap callback, called by an EOA, reverts `UnexpectedCallback` whatever its data
    /// says, and moves nothing
    /// @dev The callback no longer reads a payer from its data: it pays for the account holding the
    /// reentrancy lock, and only when called by the pool the proxy is calling at that moment. Outside a
    /// `swap` call there is no such pool. Both the proxy's own packed format and the old ABI-encoded
    /// payload that named a payer are refused.
    function test_swapCallback_directFromEOA_reverts() public {
        uint256[4] memory before = _approverHoldings();

        vm.prank(outsider);
        vm.expectRevert(IProxyErrors.UnexpectedCallback.selector);
        proxy.uniswapV3SwapCallback(
            int256(500_000e6), -1, V3CallbackData.encode(USDC, V3CallbackData.PAY_FROM_CALLER, 0)
        );

        // tokenIn, tokenOut, fee, payer: the callback data of the removed single-swap entry points
        vm.prank(outsider);
        vm.expectRevert(IProxyErrors.UnexpectedCallback.selector);
        proxy.uniswapV3SwapCallback(int256(500_000e6), -1, abi.encode(USDC, WETH, uint24(500), approver));

        _assertApproverUntouched(before, "direct swap callback from EOA");
    }

    /// @notice The same forged swap callback, from a contract, reverts `UnexpectedCallback`
    function test_swapCallback_fromContract_reverts() public {
        uint256[4] memory before = _approverHoldings();

        vm.prank(outsider);
        vm.expectRevert(IProxyErrors.UnexpectedCallback.selector);
        impersonator.callViaSwapCallback(
            int256(500_000e6), -1, V3CallbackData.encode(USDC, V3CallbackData.PAY_FROM_CALLER, 0)
        );

        _assertApproverUntouched(before, "swap callback from contract");
    }

    /// @notice Every approved token, every real fee tier, every callback mode: forged callbacks revert
    /// @dev Sweeps every approved token across a spread of real fee tiers, so the guard is shown to
    /// hold uniformly rather than for one lucky pair. The swap callback is also tried in each of its
    /// payment modes (from the caller, from parked funds, settling to the PoolManager first).
    function test_swapCallback_everyApprovedTokenAndFeeTier_reverts() public {
        uint256[4] memory before = _approverHoldings();
        address[4] memory tokens = [USDC, WETH, USDT, DAI];
        uint24[4] memory fees = [uint24(100), 500, 3000, 10000];
        uint8[3] memory modes =
            [V3CallbackData.PAY_FROM_CALLER, V3CallbackData.PAY_FROM_HELD, V3CallbackData.SETTLE_TO_MANAGER];

        for (uint256 i = 0; i < tokens.length; i++) {
            for (uint256 j = 0; j < fees.length; j++) {
                address other = tokens[i] == WETH ? USDC : WETH;

                for (uint256 m = 0; m < modes.length; m++) {
                    vm.prank(outsider);
                    vm.expectRevert(IProxyErrors.UnexpectedCallback.selector);
                    impersonator.callViaSwapCallback(int256(1e18), -1, V3CallbackData.encode(tokens[i], modes[m], 1e18));
                }

                vm.prank(outsider);
                vm.expectRevert(bytes("")); // CallbackValidation: not the pool
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

    /// @notice Even the genuine, factory-derived pool cannot call the swap callback outside a swap the
    /// proxy is making
    /// @dev Stronger than CREATE2 verification: the callback is honoured only from the pool the proxy
    /// is calling at that moment, once. Impersonating a live pool needs a cheat code, so this is defence
    /// in depth, but it shows the payer can only be charged for a swap the payer's own call started.
    function test_swapCallback_fromGenuinePoolOutsideASwap_reverts() public {
        uint256[4] memory before = _approverHoldings();
        address[4] memory tokens = [USDC, WETH, USDT, DAI];
        uint24[4] memory fees = [uint24(100), 500, 3000, 10000];

        for (uint256 i = 0; i < tokens.length; i++) {
            for (uint256 j = 0; j < fees.length; j++) {
                address other = tokens[i] == WETH ? USDC : WETH;
                address pool = _poolFor(tokens[i], other, fees[j]);

                vm.prank(pool);
                vm.expectRevert(IProxyErrors.UnexpectedCallback.selector);
                proxy.uniswapV3SwapCallback(
                    int256(1e18), -1, V3CallbackData.encode(tokens[i], V3CallbackData.PAY_FROM_CALLER, 0)
                );
            }
        }

        _assertApproverUntouched(before, "swap callback from a genuine pool");
    }

    /// @notice Even the genuine, factory-derived pool cannot call the mint callback outside a call to
    /// the proxy: it reverts `UnexpectedCallback`, whatever payer its data names, and moves nothing
    /// @dev The genuine pool passes `CallbackValidation`; what stops it is the payer. The callback pays
    /// for the account holding the reentrancy lock, never for anyone named in `data`, and outside an
    /// entry point nobody holds it. Tried with the old `MintCallbackData` layout naming the approver
    /// as payer, which still decodes (the payer word is ignored), and with the data `mint` writes (the
    /// pool key), for amounts the approver holds and has approved. Impersonating a live pool needs a
    /// cheat code, so this is defence in depth, like the swap callback's case above.
    function test_mintCallback_fromGenuinePoolOutsideACall_reverts() public {
        uint256[4] memory before = _approverHoldings();
        address[4] memory tokens = [USDC, WETH, USDT, DAI];
        uint24[4] memory fees = [uint24(100), 500, 3000, 10000];

        for (uint256 i = 0; i < tokens.length; i++) {
            for (uint256 j = 0; j < fees.length; j++) {
                address other = tokens[i] == WETH ? USDC : WETH;
                PoolAddress.PoolKey memory key = PoolAddress.getPoolKey(tokens[i], other, fees[j]);
                address pool = _poolFor(tokens[i], other, fees[j]);
                bytes[2] memory forged =
                    [abi.encode(MintCallbackData({poolKey: key, payer: approver})), abi.encode(key)];

                for (uint256 k = 0; k < forged.length; k++) {
                    vm.prank(pool);
                    vm.expectRevert(IProxyErrors.UnexpectedCallback.selector);
                    proxy.uniswapV3MintCallback(1e6, 1e6, forged[k]);
                }
            }
        }

        _assertApproverUntouched(before, "mint callback from a genuine pool");
    }

    /// @notice `unlockCallback` from anyone but the PoolManager reverts `NotPoolManager`, whatever the
    /// payload: empty, a swap unlock's or a liquidity unlock's
    function test_unlockCallback_fromNonManager_reverts() public {
        bytes[3] memory payloads = [bytes(""), bytes(hex"01"), bytes(hex"02")];
        for (uint256 i = 0; i < payloads.length; i++) {
            vm.prank(outsider);
            vm.expectRevert(IProxyErrors.NotPoolManager.selector);
            proxy.unlockCallback(payloads[i]);

            vm.prank(outsider);
            vm.expectRevert(IProxyErrors.NotPoolManager.selector);
            impersonator.callViaUnlockCallback(payloads[i]);
        }
    }

    /// @notice A caller-chosen V3 pool key never derives to an attacker-controlled address
    /// @dev Establishes *why* the mint callback guard holds, not just that it does. A caller-supplied
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

    /// @notice An outsider's swap is paid by the outsider, its output reaches the outsider, and the
    /// approver's balances never move
    function test_outsiderSwap_debitsOutsiderNotApprover() public {
        uint256[4] memory before = _approverHoldings();
        uint256 outsiderUsdcBefore = IERC20(USDC).balanceOf(outsider);
        uint256 outsiderWethBefore = IERC20(WETH).balanceOf(outsider);

        vm.prank(outsider);
        IERC20(USDC).approve(address(proxy), type(uint256).max);
        uint256 amountOut = _swapOne(outsider, _v3In(USDC, WETH, 500, tradeUsdc, 0), 0);

        // The caller settled from its own balance, and a leg cannot name anyone else as recipient.
        assertEq(IERC20(USDC).balanceOf(outsider), outsiderUsdcBefore - tradeUsdc, "outsider not debited");
        assertEq(IERC20(WETH).balanceOf(outsider), outsiderWethBefore + amountOut, "output not delivered to caller");
        _assertApproverUntouched(before, "outsider swap");
    }

    /// @notice An outsider's mint is paid by the outsider; the approver's balances never move
    function test_outsiderMint_debitsOutsiderNotApprover() public {
        uint256[4] memory before = _approverHoldings();
        (int24 lower, int24 upper) = _rangeAroundSpot(USDC_WETH_500, 10);

        // The mint callback is paid by the account holding the lock, i.e. `mint`'s own caller (its data
        // is only the pool key), and `mint` requires the recipient to be the caller.
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

    /// @notice A caller with no balance of its own cannot swap at all: its own payment fails ("STF")
    /// @dev It must simply fail, rather than settling from any other account's approval. It has
    /// registered the pool, so it is the payment that fails.
    function test_callerWithNoBalance_cannotSwapAtAll() public {
        address brokeCaller = _actor("brokeCaller");
        _allow(brokeCaller, proxy.v3Key(_poolFor(USDC, WETH, 500)), SWAP);
        uint256[4] memory before = _approverHoldings();
        bytes memory data = _swapData(_one(_v3In(USDC, WETH, 500, tradeUsdc, 0)));

        vm.startPrank(brokeCaller);
        IERC20(USDC).approve(address(proxy), type(uint256).max);
        vm.expectRevert(bytes("STF"));
        proxy.swap(data);
        vm.stopPrank();

        _assertApproverUntouched(before, "penniless outsider");
    }

    /// @notice No calldata combination ever settles from an account other than the caller
    /// @dev Fuzzed across callers, tokens, fees, amounts and both exact-input and exact-output legs.
    /// Each caller registers the pool it names, so the call gets past the registry to where the payer
    /// is decided.
    function testFuzz_approverUntouchedByArbitraryCalls(
        address caller,
        uint256 amount,
        uint8 tokenSel,
        uint8 feeSel,
        bool exactOut
    )
        public
    {
        vm.assume(caller != approver && caller != address(0) && caller != address(proxy));
        vm.assume(caller.code.length == 0);

        address[4] memory tokens = [USDC, WETH, USDT, DAI];
        uint24[4] memory fees = [uint24(100), 500, 3000, 10000];
        address tokenIn = tokens[tokenSel % 4];
        address tokenOut = tokens[(tokenSel / 4) % 4];
        vm.assume(tokenIn != tokenOut);
        // Bounded deliberately: the property under test is who pays, not how deep the swap goes.
        // A redirected payer shows up at 1 wei as clearly as at 1e30, and large orders only
        // rate-limit the fork RPC.
        uint128 bounded = SafeCast.toUint128(bound(amount, 1, 1e9));

        uint24 fee = fees[feeSel % 4];
        _allow(caller, proxy.v3Key(_poolFor(tokenIn, tokenOut, fee)), SWAP);
        uint256[4] memory before = _approverHoldings();
        bytes memory data = _swapData(
            _one(
                exactOut
                    ? _v3Out(tokenIn, tokenOut, fee, bounded, type(uint128).max)
                    : _v3In(tokenIn, tokenOut, fee, bounded, 0)
            )
        );

        // Gas-capped: thin fee tiers can make a large order walk tens of thousands of ticks, which
        // on a fork is one RPC storage read each. Out-of-gas is just another revert here — the
        // approver's balance is the only thing being asserted.
        vm.prank(caller);
        try proxy.swap{gas: 3_000_000}(data) {} catch {}

        _assertApproverUntouched(before, "fuzzed arbitrary call");
    }

    /// @notice Whatever a funded outsider swaps, on any of its registered live pools, its output lands
    /// at the outsider only
    /// @dev A leg has no recipient field, so there is no calldata that sends an output elsewhere: the
    /// outsider's own balance of the output token moves by exactly what the leg reports, and the
    /// approver's and the proxy's balances do not move.
    function testFuzz_outputsOnlyEverReachTheCaller(uint8 legSel, uint256 amount) public {
        vm.startPrank(outsider);
        IERC20(USDC).approve(address(proxy), type(uint256).max);
        IERC20(WETH).approve(address(proxy), type(uint256).max);
        _rawApprove(USDT, address(proxy), type(uint256).max);
        vm.stopPrank();

        // A routine size, from a hundredth of a trade up to one trade
        uint256 scale = bound(amount, 1, 100);
        uint128 usdcIn = SafeCast.toUint128(uint256(tradeUsdc) * scale / 100);
        uint128 wethIn = SafeCast.toUint128(uint256(tradeWeth) * scale / 100);
        SwapCalldata.Leg[6] memory choices = [
            _v3In(USDC, WETH, 500, usdcIn, 0),
            _v3In(WETH, USDC, 3000, wethIn, 0),
            _v3Out(WETH, USDC, 500, usdcIn, type(uint128).max),
            _v3In(USDT, WETH, 500, usdcIn, 0),
            _v4In(false, usdcIn, 0),
            _v4Out(false, wethIn, type(uint128).max)
        ];
        SwapCalldata.Leg memory leg = choices[legSel % choices.length];

        uint256[4] memory before = _approverHoldings();
        uint256 outBefore = _balanceOf(leg.tokenOut, outsider);
        uint256 proxyOutBefore = _balanceOf(leg.tokenOut, address(proxy));

        uint256 reported = _swapOne(outsider, leg, 0);

        uint256 delivered = _balanceOf(leg.tokenOut, outsider) - outBefore;
        assertEq(delivered, leg.exactOut ? leg.amount : reported, "the caller did not get exactly the output");
        assertEq(_balanceOf(leg.tokenOut, address(proxy)), proxyOutBefore, "the proxy kept part of the output");
        _assertApproverUntouched(before, "fuzzed outsider swap");
    }

    /// @notice Forged mint and swap callbacks, with fully caller-chosen data, always revert and never pay
    /// @dev Same property, for the raw callbacks: any caller, a caller-chosen poolKey naming the
    /// approver as payer for the mint callback, and for the swap callback any token, payment mode and
    /// claimed credit. Each is refused by its own guard: a mint callback from anything but its key's
    /// pool by `CallbackValidation` (a bare `require`, no revert data), from that pool (`asPool`: its
    /// CREATE2 address, live or code-less) by the lock nobody holds; a swap callback by the expected
    /// pool nobody set.
    function testFuzz_forgedCallbackNeverPays(
        address caller,
        bool asPool,
        address otherToken,
        uint24 fee,
        uint256 amount,
        uint8 mode,
        uint256 creditIn
    )
        public
    {
        vm.assume(otherToken > USDC);
        amount = bound(amount, 1, 1e24);
        PoolAddress.PoolKey memory key = PoolAddress.PoolKey({token0: USDC, token1: otherToken, fee: fee});
        address keysPool = PoolAddress.computeAddress(V3_FACTORY, key);
        if (asPool) caller = keysPool;
        else vm.assume(caller != address(0) && caller.code.length == 0 && caller != keysPool);

        uint256[4] memory before = _approverHoldings();

        vm.prank(caller);
        if (asPool) vm.expectRevert(IProxyErrors.UnexpectedCallback.selector);
        else vm.expectRevert(bytes("")); // CallbackValidation: not the pool
        proxy.uniswapV3MintCallback(amount, amount, abi.encode(MintCallbackData({poolKey: key, payer: approver})));

        vm.prank(caller);
        vm.expectRevert(IProxyErrors.UnexpectedCallback.selector);
        proxy.uniswapV3SwapCallback(SafeCast.toInt256(amount), -1, V3CallbackData.encode(USDC, mode, creditIn));

        _assertApproverUntouched(before, "fuzzed forged callback");
    }

    // ---------------------------------------------------------------------------
    // 3. Re-entrancy from a token inside a genuine, factory-derived pool
    // ---------------------------------------------------------------------------

    /// @notice A token re-entering from inside the proxy's mint callback cannot redirect the payer
    /// @dev The case worth proving. A V3 pool pairing a real token with an arbitrary contract is
    /// still factory-derived, so its callbacks pass verification, and that token's `transferFrom`
    /// runs inside the proxy's own payment callback. This asserts that re-entering from there
    /// cannot change which account settles.
    function test_reentrantTokenInGenuinePool_cannotRedirectPayer() public {
        ReentrantToken reentrant = _reentrantToken();
        address pool = _poolWithUsdc(address(reentrant));
        (int24 lower, int24 upper) = _rangeAroundSpot(pool, 10);
        (address token0, address token1) =
            address(reentrant) < USDC ? (address(reentrant), USDC) : (USDC, address(reentrant));

        // Re-entry aims at a *different*, unlocked pool so we are testing the proxy, not the V3
        // reentrancy lock on the pool we happen to be inside.
        reentrant.arm(proxy, approver, USDC, WETH, 500);

        uint256[4] memory before = _approverHoldings();

        vm.prank(outsider);
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

        // The token really did receive control inside the proxy's callback...
        assertGt(reentrant.reentryAttempts(), 0, "re-entry never fired; test proves nothing");
        // ...and no route worked.
        _assertEveryReentryRefused(reentrant);
        _assertApproverUntouched(before, "re-entrant token");
    }

    /// @notice A token re-entering from inside a chained `swap`, while the call holds parked funds,
    /// cannot redirect the payer nor reach those funds
    /// @dev The same attack against the swap entry point. The victim call is a chain whose first leg
    /// sells the re-entrant token and parks its USDC output in the proxy for the second leg. The
    /// pool pays that output out before calling back, so when the token's `transferFrom` runs (inside
    /// the proxy's swap callback) the proxy really is holding the vault's parked USDC. Every entry
    /// point is `nonReentrant`, so the re-entered `swap` is refused outright, and the callbacks refuse
    /// a caller that is not the pool being called. The parked USDC is spent by the chain's own second
    /// leg, as encoded, and by nothing else.
    function test_reentrantTokenInsideChainedSwap_cannotRedirectPayer() public {
        ReentrantToken reentrant = _reentrantToken();
        _poolWithUsdc(address(reentrant));
        _mintWithUsdc(address(reentrant));

        reentrant.arm(proxy, approver, USDC, WETH, 500);
        reentrant.watch(USDC);

        uint256[4] memory before = _approverHoldings();
        uint256 outsiderUsdcBefore = IERC20(USDC).balanceOf(outsider);
        uint256 outsiderWethBefore = IERC20(WETH).balanceOf(outsider);
        uint256 proxyUsdcBefore = IERC20(USDC).balanceOf(address(proxy));

        // RENT -V3-> USDC, parked in the proxy; then USDC -V3-> WETH, spending exactly what was parked
        SwapCalldata.Leg[] memory legs = new SwapCalldata.Leg[](2);
        legs[0] = _parked(_v3In(address(reentrant), USDC, 3000, 1e6, 0));
        legs[1] = _held(_v3In(USDC, WETH, 500, 0, 0));
        bytes memory data = _swapData(legs);
        vm.prank(outsider);
        uint256[] memory amounts = proxy.swap(data);

        // The token really did receive control mid-call, while the proxy held the parked USDC...
        assertGt(reentrant.reentryAttempts(), 0, "re-entry never fired; test proves nothing");
        assertEq(
            reentrant.watchedProxyBalance(),
            proxyUsdcBefore + amounts[0],
            "the re-entry did not happen while the first leg's output was parked"
        );
        // ...and no route worked: the re-entered swap was refused by the reentrancy lock...
        _assertEveryReentryRefused(reentrant);
        // ...so the parked USDC went to the second leg only, and nobody else paid for anything.
        assertEq(IERC20(USDC).balanceOf(address(proxy)), proxyUsdcBefore, "parked USDC left in the proxy");
        assertEq(IERC20(USDC).balanceOf(outsider), outsiderUsdcBefore, "the outsider's USDC moved");
        assertEq(IERC20(WETH).balanceOf(outsider), outsiderWethBefore + amounts[1], "the chain's output went elsewhere");
        _assertApproverUntouched(before, "re-entrant token inside swap");
    }

    /// @notice A token re-entering while the proxy waits for a pool's swap callback cannot answer in the
    /// pool's place
    /// @dev The narrowest window. Between arming the expected pool and receiving its callback, the
    /// proxy runs no code, but the pool does: it pays the output out first. When that output is the
    /// re-entrant token, its `transfer` runs exactly while the callback is armed, and the vault's lock
    /// is held. A forged callback from there would make the proxy pay the token with the vault's
    /// approval; it is refused because only the pool itself may answer.
    function test_reentrantOutputToken_cannotAnswerTheAwaitedCallback() public {
        ReentrantToken reentrant = _reentrantToken();
        _poolWithUsdc(address(reentrant));
        _mintWithUsdc(address(reentrant));

        reentrant.arm(proxy, approver, USDC, WETH, 500);
        reentrant.disarm(); // not from transferFrom: buying the token never calls it
        reentrant.setArmedOnTransfer(true);

        uint256[4] memory before = _approverHoldings();
        uint256 outsiderUsdcBefore = IERC20(USDC).balanceOf(outsider);
        uint256 outsiderRentBefore = reentrant.balanceOf(outsider);

        // USDC -V3-> RENT: the pool transfers RENT to the outsider, then calls the proxy back
        uint256 amountOut = _swapOne(outsider, _v3In(USDC, address(reentrant), 3000, 1e6, 0), 0);

        assertGt(reentrant.reentryAttempts(), 0, "re-entry never fired; test proves nothing");
        _assertEveryReentryRefused(reentrant);
        // The outsider paid exactly its own leg's input, and got its output.
        assertEq(IERC20(USDC).balanceOf(outsider), outsiderUsdcBefore - 1e6, "the outsider paid more than its leg");
        assertEq(reentrant.balanceOf(outsider), outsiderRentBefore + amountOut, "output not delivered to caller");
        _assertApproverUntouched(before, "re-entrant output token");
    }

    /// @notice A token paid to the PoolManager in a V3 -> V4 hand-off cannot claim that payment: the
    /// call reverts `UnexpectedSettlement` and nothing moves, while the same route without the
    /// interference settles exactly and pays the vault
    /// @dev The window the one-unlock design opens. A parked V3 output spent by a later V4 leg goes
    /// from the V3 pool straight to the PoolManager: the proxy syncs the token, the pool transfers its
    /// output and only then calls the proxy back. The output token's own `transfer` runs in between,
    /// while the PoolManager is unlocked and `settle` credits whoever calls it with what arrived since
    /// the sync. {SettlementThiefToken} does exactly that and takes the vault's output; the proxy, which
    /// settles first thing in the callback, must find that the PoolManager booked less than the pool
    /// reports and refuse.
    function test_reentrantOutputToken_cannotClaimAHandOffToThePoolManager() public {
        SettlementThiefToken thief = new SettlementThiefToken(IPoolManagerMinimal(POOL_MANAGER));
        thief.mint(outsider, 1_000_000e18);
        _poolWithUsdc(address(thief));
        _mintWithUsdc(address(thief));
        _v4PoolWithUsdc(address(thief));
        address sink = _actor("sink");

        // USDC -V3-> THIEF, parked: paid by the V3 pool to the PoolManager; then THIEF -V4-> USDC, held
        SwapCalldata.Leg memory spend;
        spend.v4 = true;
        spend.tokenIn = address(thief);
        spend.tokenOut = USDC;
        spend.fee = 3000;
        spend.tickSpacing = 60;
        SwapCalldata.Leg[] memory legs = new SwapCalldata.Leg[](2);
        legs[0] = _parked(_v3In(USDC, address(thief), 3000, 1e6, 0));
        legs[1] = _held(spend);
        bytes memory data = _swapData(legs);

        uint256[4] memory before = _approverHoldings();
        uint256 outsiderUsdcBefore = IERC20(USDC).balanceOf(outsider);
        uint256 outsiderThiefBefore = thief.balanceOf(outsider);

        thief.arm(sink);
        vm.prank(outsider);
        vm.expectRevert(IProxyErrors.UnexpectedSettlement.selector);
        proxy.swap(data);

        assertEq(IERC20(USDC).balanceOf(outsider), outsiderUsdcBefore, "the vault paid for a refused route");
        assertEq(thief.balanceOf(sink), 0, "the token kept the vault's output");

        // Control: the same call, the token inert, settles exactly and pays the vault
        thief.disarm();
        vm.prank(outsider);
        uint256[] memory amounts = proxy.swap(data);

        assertGt(amounts[0], 0, "the hand-off moved nothing");
        assertEq(IERC20(USDC).balanceOf(outsider), outsiderUsdcBefore - 1e6 + amounts[1], "vault USDC");
        assertEq(thief.balanceOf(outsider), outsiderThiefBefore, "the intermediate token reached the vault");
        assertEq(thief.balanceOf(address(proxy)), 0, "proxy retained the intermediate token");
        _assertApproverUntouched(before, "settlement thief");
    }

    // ---------------------------------------------------------------------------
    // 4. ETH held by the proxy
    // ---------------------------------------------------------------------------

    /// @notice Every plain ETH transfer to the proxy bounces, the PoolManager's included
    /// @dev `_refundExcessNative` refunds the proxy's balance above what it held before msg.value
    /// arrived. That is exactly the caller's unspent msg.value only while no other ETH reaches the proxy
    /// during a call, the invariant documented on it. It has no `receive()` and no fallback, so
    /// ordinary sends bounce, from anyone: no path makes even the PoolManager send it ETH (native
    /// outputs stay as credit or are taken straight to the vault). Selfdestruct and coinbase payments
    /// are the remaining routes, and ETH arriving that way is neither spent nor refunded
    /// (integration/V4Swap.t.sol).
    function test_proxyRejectsPlainEthTransfers() public {
        vm.deal(outsider, 2 ether);
        vm.deal(POOL_MANAGER, POOL_MANAGER.balance + 2 ether);
        // Delta, not absolute: a freshly deployed proxy can land on an address that already holds a
        // balance on the forked chain (it does on Sepolia), which says nothing about this call.
        uint256 before = address(proxy).balance;

        address[2] memory senders = [outsider, POOL_MANAGER];
        for (uint256 i = 0; i < senders.length; i++) {
            vm.prank(senders[i]);
            (bool ok,) = address(proxy).call{value: 1 ether}("");
            assertFalse(ok, "proxy accepted a plain ETH transfer; a refund may no longer be only unspent msg.value");

            // with calldata no function matches, so no fallback can take it either
            vm.prank(senders[i]);
            (ok,) = address(proxy).call{value: 1 ether}(hex"deadbeef");
            assertFalse(ok, "proxy accepted ETH through a fallback");
        }

        assertEq(address(proxy).balance, before, "proxy balance changed despite the bounced sends");
    }

    // ---------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------

    /// @dev A fresh, unarmed re-entrant token, held by the outsider
    function _reentrantToken() internal returns (ReentrantToken reentrant) {
        reentrant = new ReentrantToken();
        reentrant.mint(outsider, 1_000_000e18);
    }

    /// @dev `token` paired with USDC in a real V3 pool created through the real factory at tick 0 and
    /// registered by the outsider, who holds and has approved both tokens
    function _poolWithUsdc(address token) internal returns (address pool) {
        // This pool is built by the test, so fund to its scale rather than the chain's.
        deal(USDC, outsider, 1_000_000e6);

        pool = factory.createPool(token, USDC, 3000);
        _allow(outsider, proxy.v3Key(pool), MINT | SWAP);
        _bandAroundSpot(outsider, pool, 1000);
        IUniswapV3PoolMinimal(pool).initialize(79228162514264337593543950336); // tick 0
        assertEq(pool, _poolFor(token, USDC, 3000), "created pool is not the derived address");

        vm.startPrank(outsider);
        IERC20(USDC).approve(address(proxy), type(uint256).max);
        IERC20(token).approve(address(proxy), type(uint256).max);
        vm.stopPrank();
    }

    /// @dev Liquidity in `token`'s V3 pool, minted by the outsider while the token is inert
    function _mintWithUsdc(address token) internal {
        address pool = _poolFor(token, USDC, 3000);
        (int24 lower, int24 upper) = _rangeAroundSpot(pool, 10);
        (address token0, address token1) = token < USDC ? (token, USDC) : (USDC, token);
        vm.prank(outsider);
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
    }

    /// @dev `token` paired with USDC in a new hookless V4 pool on the live PoolManager (fee 3000, tick
    /// spacing 60, price 1), with liquidity added by this test while the token is inert, and
    /// registered by the outsider for swaps
    function _v4PoolWithUsdc(address token) internal {
        (address c0, address c1) = token < USDC ? (token, USDC) : (USDC, token);
        CorePoolKey memory key = CorePoolKey({
            currency0: CoreCurrency.wrap(c0),
            currency1: CoreCurrency.wrap(c1),
            fee: 3000,
            tickSpacing: 60,
            hooks: CoreHooks(address(0))
        });
        IPoolManager(POOL_MANAGER).initialize(key, 79228162514264337593543950336);

        PoolModifyLiquidityTest router = new PoolModifyLiquidityTest(IPoolManager(POOL_MANAGER));
        deal(USDC, address(this), 1_000_000e6);
        PlainToken(token).mint(address(this), 1_000_000e18);
        IERC20(USDC).approve(address(router), type(uint256).max);
        IERC20(token).approve(address(router), type(uint256).max);
        router.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -600, tickUpper: 600, liquidityDelta: SafeCast.toInt256(1e12), salt: bytes32(0)
            }),
            ""
        );

        PoolKey memory registered = PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        _allow(outsider, proxy.v4Key(registered), SWAP);
    }

    /// @dev Each of the token's four re-entry probes failed, for the reason that guards it
    function _assertEveryReentryRefused(ReentrantToken reentrant) internal view {
        assertFalse(reentrant.entryPointReentrySucceeded(), "re-entered swap succeeded");
        assertEq(
            reentrant.entryPointRevertData(),
            abi.encodeWithSelector(IProxyErrors.ReentrancyGuardReentrantCall.selector),
            "re-entered swap failed for an unexpected reason"
        );
        // Integrators decode the lock's revert with OpenZeppelin's ABI; the custom lock keeps its selector
        assertEq(
            IProxyErrors.ReentrancyGuardReentrantCall.selector,
            ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector,
            "lock error selector changed"
        );
        assertFalse(reentrant.directCallbackReentrySucceeded(), "re-entered raw mint callback succeeded");
        // Mid-call the lock is held, so `CallbackValidation` (no revert data) is what refuses the token
        assertEq(
            reentrant.directCallbackRevertData(), bytes(""), "re-entered mint callback failed for an unexpected reason"
        );
        assertFalse(reentrant.swapCallbackReentrySucceeded(), "re-entered raw swap callback succeeded");
        assertEq(
            reentrant.swapCallbackRevertData(),
            abi.encodeWithSelector(IProxyErrors.UnexpectedCallback.selector),
            "re-entered swap callback failed for an unexpected reason"
        );
        assertFalse(reentrant.unlockCallbackReentrySucceeded(), "re-entered unlock callback succeeded");
        assertEq(
            reentrant.unlockCallbackRevertData(),
            abi.encodeWithSelector(IProxyErrors.NotPoolManager.selector),
            "re-entered unlock callback failed for an unexpected reason"
        );
    }

    function _balanceOf(address token, address who) internal view returns (uint256) {
        return token == address(0) ? who.balance : IERC20(token).balanceOf(who);
    }
}
