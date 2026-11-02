// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import {IUniswapV3PoolMinimal} from "../src/interfaces/uniswapV3/IUniswapV3PoolMinimal.sol";
import {UniswapUtils} from "../src/libraries/uniswapV3/UniswapUtils.sol";
import {TickMath} from "../src/libraries/uniswapV3/TickMath.sol";
import {TWAP_SECONDS_AGO} from "../src/vaults/uniV3LpVault/constants.sol";
import {TestHelper} from "./UniV3LpVault/helpers/TestHelper.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @notice Runs `UniswapUtils.observeTickCumulatives` and the high-level `observe` call it replaced in
/// `UniswapUtils.getTwap`, each in a call of its own, so that a test can compare what they return and how they revert
contract ObserveCaller {
    /// @notice `UniswapUtils.observeTickCumulatives(pool, secondsAgos)`
    function observeTickCumulatives(
        IUniswapV3PoolMinimal pool,
        uint32[] memory secondsAgos
    )
        external
        view
        returns (int56[] memory tickCumulatives)
    {
        return UniswapUtils.observeTickCumulatives(pool, secondsAgos);
    }

    /// @notice `pool.observe(secondsAgos)` as a high-level call, whose decoder checks both arrays
    function observe(
        IUniswapV3PoolMinimal pool,
        uint32[] memory secondsAgos
    )
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s)
    {
        return pool.observe(secondsAgos);
    }

    /// @notice Decodes the seconds-per-liquidity array of `observe`'s return data as the high-level call's decoder
    /// does: it reverts when that decoder would revert on that array (or on data too short for both offsets)
    function decodeSecondsPerLiquidity(bytes memory returnData)
        external
        pure
        returns (uint160[] memory secondsPerLiquidityCumulativeX128s)
    {
        (, secondsPerLiquidityCumulativeX128s) = abi.decode(returnData, (uint256, uint160[]));
    }
}

/// @notice Stands in for a pool whose `observe` a test mocks: a call that is not mocked reverts, so a reader that
/// sent other calldata than `observe(secondsAgos)` could not pass for one that reads the mocked data
contract UnmockedPool {
    fallback() external {
        revert("not mocked");
    }
}

/// @notice `UniswapUtils.observeTickCumulatives` reads `observe` like the high-level call `getTwap` used to make, and
/// `getTwap`, which now reads the pool through it, still quotes at the mean tick of the window and bubbles the
/// pool's reverts
contract UniswapUtilsTest is Test {
    /// @dev How far back the pool of `TestHelper.deployVaultWithPool` has observations: it is initialized, then
    /// 14 days pass
    uint32 private constant POOL_HISTORY = 14 days;

    ObserveCaller private caller;
    IUniswapV3PoolMinimal private pool;
    address private mockedPool;

    function setUp() public {
        caller = new ObserveCaller();
        pool = new TestHelper().deployVaultWithPool().pool;
        mockedPool = address(new UnmockedPool());
    }

    // ---------------------------------------------------------------------------
    // observeTickCumulatives on a Uniswap V3 pool
    // ---------------------------------------------------------------------------

    /// @notice On a Uniswap V3 pool, the reader returns the tick cumulatives `observe` returns, for any window
    /// within the pool's history
    function testFuzz_observeTickCumulatives_onAPool_returnsWhatObserveReturns(uint256 secondsAgo) public view {
        uint32[] memory secondsAgos = _window(SafeCast.toUint32(bound(secondsAgo, 0, POOL_HISTORY)));

        (bool readOk, bytes memory readOut, bool observeOk, bytes memory observeOut) =
            _outcomes(address(pool), secondsAgos);

        assertTrue(readOk, "reader reverted");
        assertTrue(observeOk, "observe reverted");
        assertEq(readOut, observeOut);
    }

    /// @notice The pool's own revert reaches the caller unchanged: "OLD" for a window that starts before the pool's
    /// oldest observation, exactly as the high-level call bubbles it
    function test_observeTickCumulatives_onAPool_bubblesOld() public {
        uint32[] memory secondsAgos = _window(POOL_HISTORY + 1);

        vm.expectRevert(bytes("OLD"));
        caller.observeTickCumulatives(pool, secondsAgos);

        _assertSameOutcome(address(pool), secondsAgos);
    }

    // ---------------------------------------------------------------------------
    // observeTickCumulatives against the high-level call, on mocked return data
    // ---------------------------------------------------------------------------

    /// @notice For any window and any valid return data, the reader sends the calldata of `observe(secondsAgos)`
    /// (the mock answers no other) and returns exactly the tick cumulatives, whatever the seconds-per-liquidity
    /// array holds, as the high-level call does
    function testFuzz_observeTickCumulatives_returnsTheTickCumulatives(
        uint32[] memory secondsAgos,
        int56[] memory tickCumulatives,
        uint160[] memory secondsPerLiquidityCumulativeX128s
    )
        public
    {
        vm.mockCall(
            mockedPool, _observeCall(secondsAgos), abi.encode(tickCumulatives, secondsPerLiquidityCumulativeX128s)
        );

        int56[] memory read = caller.observeTickCumulatives(IUniswapV3PoolMinimal(mockedPool), secondsAgos);

        assertEq(abi.encode(read), abi.encode(tickCumulatives));
        _assertSameOutcome(mockedPool, secondsAgos);
    }

    /// @notice Whatever the pool reverts with, empty data included, the reader reverts with exactly that, as the
    /// high-level call does
    function testFuzz_observeTickCumulatives_bubblesThePoolsRevertData(bytes memory revertData) public {
        uint32[] memory secondsAgos = _window(TWAP_SECONDS_AGO);
        vm.mockCallRevert(mockedPool, _observeCall(secondsAgos), revertData);

        vm.expectRevert(revertData);
        caller.observeTickCumulatives(IUniswapV3PoolMinimal(mockedPool), secondsAgos);

        _assertSameOutcome(mockedPool, secondsAgos);
    }

    /// @notice An address without code returns no data, which the high-level call's decoder rejects without data:
    /// the reader reverts without data too
    function test_observeTickCumulatives_revertsWithoutDataOnAnAddressWithoutCode() public {
        address noCode = makeAddr("no code");
        uint32[] memory secondsAgos = _window(TWAP_SECONDS_AGO);

        vm.expectRevert(bytes(""));
        caller.observeTickCumulatives(IUniswapV3PoolMinimal(noCode), secondsAgos);

        _assertSameOutcome(noCode, secondsAgos);
    }

    /// @notice Return data too short to hold the offsets of the two arrays, whatever its bytes, is rejected without
    /// data, as the high-level call's decoder rejects it
    function testFuzz_observeTickCumulatives_revertsWithoutDataOnShortReturnData(
        bytes memory returnData,
        uint256 length
    )
        public
    {
        returnData = _prefix(returnData, bound(length, 0, returnData.length < 63 ? returnData.length : 63));
        uint32[] memory secondsAgos = _window(TWAP_SECONDS_AGO);
        vm.mockCall(mockedPool, _observeCall(secondsAgos), returnData);

        vm.expectRevert(bytes(""));
        caller.observeTickCumulatives(IUniswapV3PoolMinimal(mockedPool), secondsAgos);

        _assertSameOutcome(mockedPool, secondsAgos);
    }

    /// @notice A zero word followed by less than a word: decoded as one array it would be an empty array (a zero
    /// offset pointing at a zero length), but the high-level call's decoder requires the offsets of both arrays and
    /// rejects it without data, and so does the reader
    function test_observeTickCumulatives_revertsWithoutDataOnAZeroWordAlone() public {
        uint32[] memory secondsAgos = _window(TWAP_SECONDS_AGO);
        for (uint256 length = 32; length < 64; ++length) {
            vm.mockCall(mockedPool, _observeCall(secondsAgos), new bytes(length));

            vm.expectRevert(bytes(""));
            caller.observeTickCumulatives(IUniswapV3PoolMinimal(mockedPool), secondsAgos);

            _assertSameOutcome(mockedPool, secondsAgos);
        }
    }

    /// @notice On invalid return data (a valid encoding with one word overwritten, by any value or a small one that
    /// moves an offset or a length, then cut at any length), the reader fails exactly when the high-level call
    /// fails, with the same revert data, except where the only invalid part is the seconds-per-liquidity array,
    /// which the reader does not read: there the high-level call reverts with its decoder's error for that array and
    /// the reader returns the tick cumulatives
    function testFuzz_observeTickCumulatives_failsLikeObserveOnInvalidReturnData(
        int56[] memory tickCumulatives,
        uint160[] memory secondsPerLiquidityCumulativeX128s,
        uint256 wordIndex,
        uint256 value,
        bool smallValue,
        uint256 length
    )
        public
    {
        bytes memory returnData = abi.encode(tickCumulatives, secondsPerLiquidityCumulativeX128s);
        uint256 at = bound(wordIndex, 0, returnData.length / 32 - 1) * 32;
        bytes32 word = bytes32(smallValue ? value % 512 : value);
        for (uint256 i; i < 32; ++i) {
            returnData[at + i] = word[i];
        }
        returnData = _prefix(returnData, bound(length, 0, returnData.length));
        uint32[] memory secondsAgos = _window(TWAP_SECONDS_AGO);
        vm.mockCall(mockedPool, _observeCall(secondsAgos), returnData);

        (bool readOk, bytes memory readOut, bool observeOk, bytes memory observeOut) =
            _outcomes(mockedPool, secondsAgos);

        if (readOk && !observeOk) {
            try caller.decodeSecondsPerLiquidity(returnData) returns (uint160[] memory) {
                fail("observe reverted on valid seconds-per-liquidity");
            } catch (bytes memory decoderError) {
                assertEq(observeOut, decoderError);
            }
        } else {
            assertEq(readOk, observeOk);
            assertEq(readOut, observeOut);
        }
    }

    // ---------------------------------------------------------------------------
    // getTwap
    // ---------------------------------------------------------------------------

    /// @notice `getTwap` quotes `baseAmount` at the window's mean tick, rounded towards negative infinity, taken from
    /// the tick cumulatives that the high-level `observe` returns
    function testFuzz_getTwap_quotesAtTheMeanTickOfObserve(
        uint256 secondsAgo,
        uint128 baseAmount,
        bool inverse
    )
        public
        view
    {
        uint32 window = SafeCast.toUint32(bound(secondsAgo, 1, POOL_HISTORY));
        (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s) =
            caller.observe(pool, _window(window));
        assertEq(secondsPerLiquidityCumulativeX128s.length, tickCumulatives.length, "one value per point in time");

        int256 delta = int256(tickCumulatives[1]) - tickCumulatives[0];
        int256 meanTick = delta / SafeCast.toInt256(window);
        if (delta < 0 && delta % SafeCast.toInt256(window) != 0) meanTick--;
        uint256 expected = UniswapUtils.getQuoteFromSqrtRatioX96(
            TickMath.getSqrtRatioAtTick(SafeCast.toInt24(meanTick)), baseAmount, inverse
        );

        assertEq(UniswapUtils.getTwap(pool, window, baseAmount, inverse), expected);
    }

    /// @notice `getTwap` bubbles the pool's revert: "OLD" for a window that starts before the pool's history
    function test_getTwap_bubblesOld() public {
        vm.expectRevert(bytes("OLD"));
        UniswapUtils.getTwap(pool, POOL_HISTORY + 1, 1e18, true);
    }

    /// @notice `getTwap` on an address without code reverts without data, as it did with the high-level call
    function test_getTwap_revertsWithoutDataOnAnAddressWithoutCode() public {
        vm.expectRevert(bytes(""));
        UniswapUtils.getTwap(IUniswapV3PoolMinimal(makeAddr("no code")), TWAP_SECONDS_AGO, 1e18, true);
    }

    // ---------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------

    /// @dev Asserts that the reader and the high-level call both return the same tick cumulatives or both revert
    /// with the same data
    function _assertSameOutcome(address target, uint32[] memory secondsAgos) private view {
        (bool readOk, bytes memory readOut, bool observeOk, bytes memory observeOut) = _outcomes(target, secondsAgos);
        assertEq(readOk, observeOk);
        assertEq(readOut, observeOut);
    }

    /// @dev Runs the reader and the high-level call on `target`: whether each returned, and the tick cumulatives it
    /// returned (ABI-encoded) or the data it reverted with
    function _outcomes(
        address target,
        uint32[] memory secondsAgos
    )
        private
        view
        returns (bool readOk, bytes memory readOut, bool observeOk, bytes memory observeOut)
    {
        try caller.observeTickCumulatives(IUniswapV3PoolMinimal(target), secondsAgos) returns (
            int56[] memory tickCumulatives
        ) {
            (readOk, readOut) = (true, abi.encode(tickCumulatives));
        } catch (bytes memory revertData) {
            readOut = revertData;
        }
        try caller.observe(IUniswapV3PoolMinimal(target), secondsAgos) returns (
            int56[] memory tickCumulatives, uint160[] memory
        ) {
            (observeOk, observeOut) = (true, abi.encode(tickCumulatives));
        } catch (bytes memory revertData) {
            observeOut = revertData;
        }
    }

    /// @dev `[secondsAgo, 0]`: the window `getTwap` observes
    function _window(uint32 secondsAgo) private pure returns (uint32[] memory secondsAgos) {
        secondsAgos = new uint32[](2);
        secondsAgos[0] = secondsAgo;
    }

    /// @dev The calldata of `observe(secondsAgos)`
    function _observeCall(uint32[] memory secondsAgos) private pure returns (bytes memory) {
        return abi.encodeCall(IUniswapV3PoolMinimal.observe, (secondsAgos));
    }

    /// @dev The first `length` bytes of `data`
    function _prefix(bytes memory data, uint256 length) private pure returns (bytes memory prefix) {
        prefix = new bytes(length);
        for (uint256 i; i < length; ++i) {
            prefix[i] = data[i];
        }
    }
}
