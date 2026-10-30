// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.20;

import "forge-std/Test.sol";

import {UniswapBatchSwapProxy, SwapType} from "../src/UniswapBatchSwapProxy.sol";
import {ExactInputSingleParams} from "../src/interfaces/uniswapV3/IUniswapV3SwapCallback.sol";
import {MintParams} from "../src/interfaces/uniswapV3/IUniswapV3MintCallback.sol";
import {V4ExactInputSingleParams} from "../src/interfaces/uniswapV4/IUnlockCallback.sol";
import {IUniswapV3FactoryMinimal} from "../src/interfaces/uniswapV3/IUniswapV3FactoryMinimal.sol";
import {IUniswapV3PoolMinimal} from "../src/interfaces/uniswapV3/IUniswapV3PoolMinimal.sol";
// The proxy deliberately uses its own vendored types, so they are distinct from v4-core's even
// though they are ABI-identical. Alias them to keep the two worlds visibly separate.
import {
    PoolKey as ProxyPoolKey,
    Currency as ProxyCurrency,
    IHooks as ProxyIHooks
} from "../src/interfaces/uniswapV4/IPoolManagerMinimal.sol";
import {BatchSwapCalls} from "./helpers/BatchSwapCalls.sol";
import {BatchSwapFixture} from "./helpers/BatchSwapFixture.sol";
import {Chaining} from "../src/libraries/Chaining.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
// `^0.8.0`, unlike UniswapV3Infra (`^0.8.28`), so a real V3 factory can share this 0.8.26 unit
// with the real V4 PoolManager.
import {FACTORY_BYTECODE} from "./Mocks/uniswapV3/bytecodes/factory.sol";

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";

// NOTE: solmate's mock, not test/Mocks/MockERC20.sol. v4-core's PoolManager pins `pragma =0.8.26`
// and the repo mock requires ^0.8.28, which makes the two impossible to compile together.
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IProxyErrors} from "../src/interfaces/IProxyErrors.sol";

/// @notice LobsterProxy's `batchSwap`: V3 and V4 swaps in one atomic transaction.
/// @dev Runs against a real V3 factory and a real V4 PoolManager side by side, so a single batch can
/// cross both versions. Every pool is registered for the user (the vault), so the registry is never
/// what stops a swap here; its checks have their own suites. The central property: a batch is exactly
/// equivalent to making the same swaps one by one from the same account, except that it is
/// all-or-nothing. Chaining has its own suite.
contract LobsterBatchSwapTest is BatchSwapFixture {
    // ---------------------------------------------------------------------------
    // Batch == the same swaps one by one
    // ---------------------------------------------------------------------------

    /// @notice The defining property: a batch of V3 and V4 swaps, in both directions, has exactly the
    /// effect of the same four swaps made one by one — same amounts, same balances.
    function test_mixedV3AndV4Batch_matchesSameSwapsMadeOneByOne() public {
        bytes[] memory swaps = new bytes[](4);
        swaps[0] = _v3In(address(token0), address(token1), 1e18, 0);
        swaps[1] = _v4In(cleanKey, false, 1e18, 0); // token1 -> token0
        swaps[2] = _v3In(address(token1), address(token0), 0.5e18, 0);
        swaps[3] = _v4In(cleanKey, true, 0.5e18, 0); // token0 -> token1

        uint256[6] memory before = _holdings();

        (bool succeeded, uint256[] memory amounts) = _assertBatchMatchesOneByOne(swaps);
        assertTrue(succeeded, "fixture: every swap should succeed");

        // amounts[i] is what swap i's single-swap entry point returns. The caller is also the
        // recipient, so each token's net change is what it received minus what it paid.
        assertEq(
            token1.balanceOf(user) + 1e18 + 0.5e18, before[1] + amounts[0] + amounts[3], "token1: received minus paid"
        );
        assertEq(
            token0.balanceOf(user) + 1e18 + 0.5e18, before[0] + amounts[1] + amounts[2], "token0: received minus paid"
        );
        _assertProxyHoldsNothing();
    }

    /// @notice The same property over random batches: any length up to six, any mix of the two swap
    /// types, pools, directions and sizes, including the native pool paying out ETH.
    function testFuzz_randomBatch_matchesSameSwapsMadeOneByOne(uint256 seed, uint256 length) public {
        uint256 n = bound(length, 1, 6);
        bytes[] memory swaps = new bytes[](n);
        for (uint256 i = 0; i < n; i++) {
            swaps[i] = _randomSwap(uint256(keccak256(abi.encode(seed, i))));
        }

        _assertBatchMatchesOneByOne(swaps);
    }

    /// @notice Both swap types, on all three pools, in one batch
    function test_bothSwapTypesAreBatchable() public {
        bytes[] memory swaps = new bytes[](4);
        swaps[0] = _v3In(address(token0), address(token1), 1e18, 0);
        swaps[1] = _v3In(address(token1), address(token0), 1e18, 0);
        swaps[2] = _v4In(cleanKey, true, 1e18, 0);
        swaps[3] = _v4In(nativeKey, false, 1e18, 0); // token1 -> ETH

        vm.prank(user);
        uint256[] memory amounts = proxy.batchSwap(swaps);

        for (uint256 i = 0; i < amounts.length; i++) {
            assertGt(amounts[i], 0, "swap did not execute");
        }
        _assertProxyHoldsNothing();
    }

    function test_emptyBatch_isANoOp() public {
        uint256[6] memory before = _holdings();

        vm.prank(user);
        uint256[] memory amounts = proxy.batchSwap(new bytes[](0));

        assertEq(amounts.length, 0, "amounts for an empty batch");
        _assertHoldingsEq(_holdings(), before, "empty batch");
    }

    // ---------------------------------------------------------------------------
    // Atomicity and error reporting
    // ---------------------------------------------------------------------------

    /// @notice A failing swap undoes the swaps before it, including their effect on pool prices, and
    /// the caller sees the failing swap's own revert reason.
    function test_failingSwap_revertsWholeBatchWithItsReason() public {
        bytes[] memory swaps = _batch(
            _v3In(address(token0), address(token1), 1e18, 0),
            _v4In(cleanKey, true, 1e18, 2e18) // unreachable minimum
        );

        uint256[6] memory before = _holdings();
        uint160 priceBefore = _v3Price();

        vm.prank(user);
        vm.expectRevert(IProxyErrors.TooLittleReceived.selector);
        proxy.batchSwap(swaps);

        _assertHoldingsEq(_holdings(), before, "reverted batch");
        assertEq(_v3Price(), priceBefore, "first swap's price impact survived the revert");
    }

    /// @notice Batching does not bypass any per-swap check. Each still runs, with its own message.
    function test_perSwapChecksStillApplyInsideBatch() public {
        bytes memory validSwap = _v3In(address(token0), address(token1), 1e18, 0);
        uint256[6] memory before = _holdings();

        // Hooked V4 pools are still refused, even registered
        ProxyPoolKey memory hooked = cleanKey;
        hooked.hooks = ProxyIHooks(makeAddr("someHook"));
        _allow(user, proxy.v4Key(hooked), SWAP);
        vm.prank(user);
        vm.expectRevert(IProxyErrors.HooksNotSupported.selector);
        proxy.batchSwap(_batch(validSwap, _v4In(hooked, true, 1e18, 0)));

        // Each swap's own deadline is still enforced
        bytes memory expired = abi.encodePacked(
            SwapType.V3_EXACT_INPUT,
            abi.encode(
                ExactInputSingleParams({
                    tokenIn: address(token1),
                    tokenOut: address(token0),
                    fee: FEE,
                    recipient: recipient,
                    deadline: block.timestamp - 1,
                    amountIn: 1e18,
                    amountOutMinimum: 0,
                    sqrtPriceLimitX96: 0
                })
            )
        );
        vm.prank(user);
        vm.expectRevert(IProxyErrors.TransactionTooOld.selector);
        proxy.batchSwap(_batch(validSwap, expired));

        // So is each swap's own amountOutMinimum
        vm.prank(user);
        vm.expectRevert(IProxyErrors.TooLittleReceived.selector);
        proxy.batchSwap(_batch(validSwap, _v3In(address(token1), address(token0), 1e18, 2e18)));

        _assertHoldingsEq(_holdings(), before, "rejected batches");
    }

    /// @notice The V3 guard lives in the shared internal body, so batched swaps get it too: no amount
    /// that wraps at 2**255.
    function test_v3SafetyGuardsApplyInsideBatch() public {
        bytes memory validSwap = _v4In(cleanKey, true, 1e18, 0);
        uint256[6] memory before = _holdings();

        // An amount that would wrap negative and flip exact-input into exact-output
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(SafeCast.SafeCastOverflowedUintToInt.selector, uint256(2 ** 255)));
        proxy.batchSwap(_batch(validSwap, _v3In(address(token0), address(token1), 2 ** 255, 1e18)));

        _assertHoldingsEq(_holdings(), before, "rejected batches");
    }

    /// @notice A batched swap cannot name the proxy as recipient either, on V3 or V4: only the caller
    /// or ADDRESS_THIS. Refused before anything runs, valid swap before it included.
    function test_proxyIsRejectedAsRecipientInsideBatch() public {
        bytes memory validSwap = _v4In(cleanKey, true, 1e18, 0);
        bytes[] memory toProxy = new bytes[](2);
        toProxy[0] = abi.encodePacked(
            SwapType.V3_EXACT_INPUT,
            abi.encode(
                ExactInputSingleParams({
                    tokenIn: address(token0),
                    tokenOut: address(token1),
                    fee: FEE,
                    recipient: address(proxy),
                    deadline: block.timestamp,
                    amountIn: 1e18,
                    amountOutMinimum: 0,
                    sqrtPriceLimitX96: 0
                })
            )
        );
        toProxy[1] = abi.encodePacked(
            SwapType.V4_EXACT_INPUT,
            abi.encode(
                V4ExactInputSingleParams({
                    poolKey: cleanKey,
                    zeroForOne: true,
                    recipient: address(proxy),
                    deadline: block.timestamp,
                    amountIn: 1e18,
                    amountOutMinimum: 0,
                    sqrtPriceLimitX96: 0
                })
            )
        );
        uint256[6] memory before = _holdings();

        for (uint256 i = 0; i < toProxy.length; i++) {
            vm.prank(user);
            vm.expectRevert(IProxyErrors.RecipientMustBeCaller.selector);
            proxy.batchSwap(_batch(validSwap, toProxy[i]));
        }

        _assertHoldingsEq(_holdings(), before, "rejected batches");
        _assertProxyHoldsNothing();
    }

    // ---------------------------------------------------------------------------
    // Malformed batches
    // ---------------------------------------------------------------------------

    /// @notice An item whose first byte is not a known swap type (0x01-0x04) is refused, and refusing
    /// it undoes the valid swap placed before it. Includes 0x00, so a zeroed item is never read as a
    /// swap.
    function test_invalidSwapTypeIsRejected() public {
        bytes memory validSwap = _v3In(address(token0), address(token1), 1e18, 0);
        bytes memory validParams = new bytes(validSwap.length - 1);
        for (uint256 i = 0; i < validParams.length; i++) {
            validParams[i] = validSwap[i + 1];
        }

        bytes[] memory invalid = new bytes[](4);
        invalid[0] = ""; // no type byte at all
        invalid[1] = abi.encodePacked(uint8(0x00), validParams);
        invalid[2] = abi.encodePacked(uint8(0x05), validParams);
        invalid[3] = abi.encodePacked(uint8(0xff), validParams);

        uint256[6] memory before = _holdings();
        uint160 priceBefore = _v3Price();

        for (uint256 i = 0; i < invalid.length; i++) {
            vm.prank(user);
            vm.expectRevert(IProxyErrors.InvalidSwapType.selector);
            proxy.batchSwap(_batch(validSwap, invalid[i]));
        }

        _assertHoldingsEq(_holdings(), before, "rejected batches");
        assertEq(_v3Price(), priceBefore, "a rejected batch moved the pool");
    }

    /// @notice Every byte value other than the four swap types is refused, whatever follows it.
    function testFuzz_anyUnknownSwapTypeIsRejected(uint8 swapType, bytes calldata params) public {
        vm.assume(swapType == 0 || swapType > SwapType.V4_EXACT_OUTPUT);
        uint256[6] memory before = _holdings();

        vm.prank(user);
        vm.expectRevert(IProxyErrors.InvalidSwapType.selector);
        proxy.batchSwap(_batch(_v3In(address(token0), address(token1), 1e18, 0), abi.encodePacked(swapType, params)));

        _assertHoldingsEq(_holdings(), before, "rejected batch");
    }

    /// @notice A known swap type followed by params too short for it fails to decode, and the batch
    /// reverts. Here V3 params (8 words) under the V4 type (11 words).
    function test_truncatedParamsRevert() public {
        bytes memory v3Swap = _v3In(address(token0), address(token1), 1e18, 0);
        bytes memory v3Params = new bytes(v3Swap.length - 1);
        for (uint256 i = 0; i < v3Params.length; i++) {
            v3Params[i] = v3Swap[i + 1];
        }
        uint256[6] memory before = _holdings();

        vm.prank(user);
        vm.expectRevert();
        proxy.batchSwap(_batch(v3Swap, abi.encodePacked(SwapType.V4_EXACT_INPUT, v3Params)));

        _assertHoldingsEq(_holdings(), before, "malformed batch");
    }

    // ---------------------------------------------------------------------------
    // Native ETH
    // ---------------------------------------------------------------------------

    /// @notice `batchSwap` is not payable, so a batch never carries ETH of its own.
    function test_batchSwapRejectsEth() public {
        bytes memory payload =
            abi.encodeCall(UniswapBatchSwapProxy.batchSwap, (_batch(_v4In(nativeKey, true, 1e18, 0))));
        uint256 ethBefore = user.balance;

        vm.prank(user);
        (bool ok,) = address(proxy).call{value: 1e18}(payload);

        assertFalse(ok, "batchSwap accepted ETH");
        assertEq(user.balance, ethBefore, "caller lost ETH");
        _assertProxyHoldsNothing();
    }

    /// @notice Paying native ETH inside a batch fails: the proxy has nothing to settle with. Holds
    /// while the proxy carries no balance, which is its normal state (see the stranded-ETH test).
    function test_nativeInputV4SwapCannotBePaidInBatch() public {
        uint256[6] memory before = _holdings();

        vm.prank(user);
        vm.expectRevert();
        proxy.batchSwap(_batch(_v3In(address(token0), address(token1), 1e18, 0), _v4In(nativeKey, true, 1e18, 0)));

        _assertHoldingsEq(_holdings(), before, "failed native batch");
    }

    /// @notice Receiving native ETH works, because the PoolManager pays the recipient directly and the
    /// proxy never touches the ETH.
    function test_nativeOutputV4SwapWorksInBatch() public {
        uint256 ethBefore = recipient.balance;

        vm.prank(user);
        uint256[] memory amounts = proxy.batchSwap(
            _batch(
                _v3In(address(token0), address(token1), 1e18, 0),
                _v4In(nativeKey, false, 1e18, 0) // token1 in, ETH out
            )
        );

        assertGt(amounts[1], 0, "no ETH output");
        assertEq(recipient.balance - ethBefore, amounts[1], "recipient did not receive ETH");
        _assertProxyHoldsNothing();
    }

    /// @notice ETH stranded in the proxy (via selfdestruct or coinbase; `receive` admits only the
    /// PoolManager) belongs to no one. A batch never refunds, so it never hands stranded ETH to its
    /// caller as change, and a native-input swap paid "by the caller" is refused outright. The only
    /// way a batch touches it is the explicit `HELD_BALANCE` amount, which spends all of it.
    function test_strandedEth_isOnlySpentThroughHeldBalance() public {
        vm.deal(address(proxy), 5e18);
        uint256 userEthBefore = user.balance;

        // Swaps that do not involve ETH leave the stranded balance alone
        vm.prank(user);
        proxy.batchSwap(_batch(_v3In(address(token0), address(token1), 1e18, 0), _v4In(cleanKey, true, 1e18, 0)));
        assertEq(address(proxy).balance, 5e18, "a batch swept the stranded ETH");
        assertEq(user.balance, userEthBefore, "the caller received stranded ETH");

        // A native-input swap with a fixed amount would quietly draw on it, so it is refused
        vm.prank(user);
        vm.expectRevert(IProxyErrors.NativeInputMustComeFromAPreviousSwap.selector);
        proxy.batchSwap(_batch(_v4In(nativeKey, true, 1e18, 0)));

        // HELD_BALANCE spends all of it
        uint256 recipientToken1Before = token1.balanceOf(recipient);
        vm.prank(user);
        uint256[] memory amounts = proxy.batchSwap(_batch(_v4In(nativeKey, true, uint128(Chaining.HELD_BALANCE), 0)));
        assertEq(address(proxy).balance, 0, "HELD_BALANCE did not spend the whole stranded balance");
        assertEq(token1.balanceOf(recipient) - recipientToken1Before, amounts[0], "native swap output");
        assertEq(user.balance, userEthBefore, "the caller received stranded ETH");
    }

    // ---------------------------------------------------------------------------
    // Payer authority
    // ---------------------------------------------------------------------------

    /// @notice A batch pays from whoever submits it, never from another account's standing approval.
    /// The outsider is a vault in its own right here (its own registrations, its own output), so the
    /// only thing between it and the user's allowance is who pays.
    function test_batchAlwaysPaysFromItsCaller() public {
        address outsider = makeAddr("outsider");
        token0.mint(outsider, 10e18);
        _allow(outsider, proxy.v3Key(address(v3Pool)), SWAP);
        _allow(outsider, proxy.v4Key(cleanKey), SWAP);
        uint256[6] memory userBefore = _holdings();
        recipient = outsider; // the items below pay out to the outsider

        // Without an approval of their own, the outsider's batch cannot reach the user's allowance
        vm.prank(outsider);
        vm.expectRevert();
        proxy.batchSwap(_batch(_v3In(address(token0), address(token1), 1e18, 0), _v4In(cleanKey, true, 1e18, 0)));

        // With one, the outsider's batch debits the outsider
        vm.startPrank(outsider);
        token0.approve(address(proxy), type(uint256).max);
        proxy.batchSwap(_batch(_v3In(address(token0), address(token1), 1e18, 0), _v4In(cleanKey, true, 1e18, 0)));
        vm.stopPrank();

        assertEq(token0.balanceOf(outsider), 8e18, "outsider was not the payer");
        assertEq(token0.balanceOf(user), userBefore[0], "user's token0 moved");
        assertEq(token1.balanceOf(user), userBefore[1], "user's token1 moved");
    }
}
