// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import {UniV3LpVault, Position} from "../../../src/vaults/uniV3LpVault/UniV3LpVault.sol";
import {SingleVault} from "../../../src/vaults/SingleVault.sol";
import {IUniswapV3PoolMinimal} from "../../../src/interfaces/uniswapV3/IUniswapV3PoolMinimal.sol";
import {MintParams} from "../../../src/interfaces/uniswapV3/IUniswapV3MintCallback.sol";
import {UniswapV3ProxyHarness} from "../../Mocks/UniswapV3ProxyHarness.sol";
import {TestHelper} from "../helpers/TestHelper.sol";
import {TestConstants} from "../helpers/Constants.sol";

/// @dev Slots of the pool's storage where a PoolCallObserver records what it saw (no pool variable lives there)
bytes32 constant OBSERVED_MAX_POSITIONS_SLOT = keccak256("PoolCallObserver.maxPositionsSeen");
bytes32 constant OBSERVED_CALLS_SLOT = keccak256("PoolCallObserver.callsSeen");

contract UniV3LpVaultBurnTest is Test {
    TestHelper helper;
    TestHelper.VaultSetup setup;

    function setUp() public {
        helper = new TestHelper();
        setup = helper.deployVaultWithPool();

        // Setup with funds and initial position
        helper.depositToVault(setup, TestConstants.LARGE_AMOUNT, TestConstants.LARGE_AMOUNT);
    }

    /// @dev Tick range of TICK_RANGE_NARROW around the current tick, aligned like the tests below
    function _narrowRange() internal view returns (int24 tickLower, int24 tickUpper) {
        (, int24 currentTick,,,,,) = setup.pool.slot0();
        int24 tickSpacing = setup.pool.tickSpacing();
        tickLower = ((currentTick - TestConstants.TICK_RANGE_NARROW) / tickSpacing) * tickSpacing;
        tickUpper = ((currentTick + TestConstants.TICK_RANGE_NARROW) / tickSpacing) * tickSpacing;
    }

    /// @dev Replaces the pool's code with a PoolCallObserver running the pool's own code
    function _observePoolCalls() internal {
        address poolCode = makeAddr("poolCode");
        vm.etch(poolCode, address(setup.pool).code);
        vm.etch(address(setup.pool), address(new PoolCallObserver(poolCode)).code);
    }

    /// @dev Number of burn and collect calls the vault made to the observed pool
    function _poolCallsSeen() internal view returns (uint256) {
        return uint256(vm.load(address(setup.pool), OBSERVED_CALLS_SLOT));
    }

    /// @dev Highest number of positions the vault recorded while calling burn or collect on the observed pool
    function _maxPositionsSeen() internal view returns (uint256) {
        return uint256(vm.load(address(setup.pool), OBSERVED_MAX_POSITIONS_SLOT));
    }

    function test_burn_PartialPosition_Success() public {
        // Create position first
        (, int24 currentTick,,,,,) = setup.pool.slot0();
        int24 tickSpacing = setup.pool.tickSpacing();
        int24 tickRange = TestConstants.TICK_RANGE_NARROW;

        // Calculate desired ticks
        int24 desiredTickLower = currentTick - tickRange;
        int24 desiredTickUpper = currentTick + tickRange;

        // Align ticks to tick spacing (round down for lower, round up for upper)
        int24 tickLower = (desiredTickLower / tickSpacing) * tickSpacing;
        int24 tickUpper = (desiredTickUpper / tickSpacing) * tickSpacing;

        helper.createPosition(
            setup.vault, setup.allocator, tickLower, tickUpper, TestConstants.MEDIUM_AMOUNT, TestConstants.MEDIUM_AMOUNT
        );

        Position memory initialPosition = setup.vault.getPosition(0);
        uint128 initialLiquidity = initialPosition.liquidity;
        uint128 burnAmount = initialLiquidity / 2; // Burn half

        uint256 initialVaultBalance0 = setup.token0.balanceOf(address(setup.vault));
        uint256 initialVaultBalance1 = setup.token1.balanceOf(address(setup.vault));

        vm.prank(setup.allocator);
        (uint256 amount0, uint256 amount1) = setup.vault.burn(tickLower, tickUpper, burnAmount);

        // Should receive tokens back to vault
        assertTrue(setup.token0.balanceOf(address(setup.vault)) > initialVaultBalance0);
        assertTrue(setup.token1.balanceOf(address(setup.vault)) > initialVaultBalance1);
        assertTrue(amount0 > 0);
        assertTrue(amount1 > 0);

        // Position should still exist but with reduced liquidity
        Position memory finalPosition = setup.vault.getPosition(0);
        assertEq(finalPosition.lowerTick, tickLower);
        assertEq(finalPosition.upperTick, tickUpper);
        assertEq(finalPosition.liquidity, initialLiquidity - burnAmount);
    }

    function test_burn_FullPosition_RemovesFromArray() public {
        (, int24 currentTick,,,,,) = setup.pool.slot0();
        int24 tickSpacing = setup.pool.tickSpacing();
        int24 tickRange = TestConstants.TICK_RANGE_NARROW;

        // Calculate desired ticks
        int24 desiredTickLower = currentTick - tickRange;
        int24 desiredTickUpper = currentTick + tickRange;

        // Align ticks to tick spacing (round down for lower, round up for upper)
        int24 tickLower = (desiredTickLower / tickSpacing) * tickSpacing;
        int24 tickUpper = (desiredTickUpper / tickSpacing) * tickSpacing;

        helper.createPosition(
            setup.vault, setup.allocator, tickLower, tickUpper, TestConstants.MEDIUM_AMOUNT, TestConstants.MEDIUM_AMOUNT
        );

        Position memory position = setup.vault.getPosition(0);
        uint128 fullLiquidity = position.liquidity;

        vm.prank(setup.allocator);
        setup.vault.burn(tickLower, tickUpper, fullLiquidity);

        // Position should be removed from array
        vm.expectRevert();
        setup.vault.getPosition(0);
    }

    function test_burn_MultiplePositions_RemovesCorrectOne() public {
        (, int24 currentTick,,,,,) = setup.pool.slot0();

        // Create two different positions
        int24 tickSpacing = setup.pool.tickSpacing();
        int24 tickRange1 = TestConstants.TICK_RANGE_NARROW;
        int24 tickRange2 = TestConstants.TICK_RANGE_WIDE;

        // Calculate desired ticks
        int24 desiredTickLower1 = currentTick - tickRange1;
        int24 desiredTickUpper1 = currentTick + tickRange1;
        int24 desiredTickLower2 = currentTick - tickRange2;
        int24 desiredTickUpper2 = currentTick + tickRange2;

        // Align ticks to tick spacing (round down for lower, round up for upper)
        int24 tickLower1 = (desiredTickLower1 / tickSpacing) * tickSpacing;
        int24 tickUpper1 = (desiredTickUpper1 / tickSpacing) * tickSpacing;
        int24 tickLower2 = (desiredTickLower2 / tickSpacing) * tickSpacing;
        int24 tickUpper2 = (desiredTickUpper2 / tickSpacing) * tickSpacing;

        helper.createPosition(
            setup.vault, setup.allocator, tickLower1, tickUpper1, TestConstants.SMALL_AMOUNT, TestConstants.SMALL_AMOUNT
        );
        helper.createPosition(
            setup.vault,
            setup.allocator,
            tickLower2,
            tickUpper2,
            TestConstants.MEDIUM_AMOUNT,
            TestConstants.MEDIUM_AMOUNT
        );

        // Get second position liquidity
        Position memory position2 = setup.vault.getPosition(1);
        uint128 liquidity2 = position2.liquidity;

        // Burn second position completely
        vm.prank(setup.allocator);
        setup.vault.burn(tickLower2, tickUpper2, liquidity2);

        // First position should still exist
        Position memory remainingPosition = setup.vault.getPosition(0);
        assertTrue(remainingPosition.liquidity > 0);

        // Should only have one position now
        vm.expectRevert();
        setup.vault.getPosition(1);
    }

    function test_burn_NotAuthorized_Reverts() public {
        (, int24 currentTick,,,,,) = setup.pool.slot0();

        int24 tickSpacing = setup.pool.tickSpacing();
        int24 tickRange = TestConstants.TICK_RANGE_NARROW;

        // Calculate desired ticks
        int24 desiredTickLower = currentTick - tickRange;
        int24 desiredTickUpper = currentTick + tickRange;

        // Align ticks to tick spacing (round down for lower, round up for upper)
        int24 tickLower = (desiredTickLower / tickSpacing) * tickSpacing;
        int24 tickUpper = (desiredTickUpper / tickSpacing) * tickSpacing;

        helper.createPosition(
            setup.vault, setup.allocator, tickLower, tickUpper, TestConstants.MEDIUM_AMOUNT, TestConstants.MEDIUM_AMOUNT
        );

        address unauthorized = makeAddr("unauthorized");

        vm.prank(unauthorized);
        vm.expectRevert(SingleVault.Unauthorized.selector);
        setup.vault.burn(tickLower, tickUpper, 100);
    }

    function test_burn_NonExistentPosition_HandlesGracefully() public {
        // Try to burn from non-existent position
        (, int24 currentTick,,,,,) = setup.pool.slot0();
        int24 tickSpacing = setup.pool.tickSpacing();
        int24 tickRange = TestConstants.TICK_RANGE_NARROW;

        // Calculate desired ticks
        int24 desiredTickLower = currentTick - tickRange;
        int24 desiredTickUpper = currentTick + tickRange;

        // Align ticks to tick spacing (round down for lower, round up for upper)
        int24 tickLower = (desiredTickLower / tickSpacing) * tickSpacing;
        int24 tickUpper = (desiredTickUpper / tickSpacing) * tickSpacing;

        vm.prank(setup.allocator);
        vm.expectRevert(bytes("LS"));
        setup.vault.burn(tickLower, tickUpper, 1000);
    }

    function test_burn_ExcessiveLiquidity_HandlesGracefully() public {
        (, int24 currentTick,,,,,) = setup.pool.slot0();
        int24 tickSpacing = setup.pool.tickSpacing();
        int24 tickRange = TestConstants.TICK_RANGE_NARROW;

        // Calculate desired ticks
        int24 desiredTickLower = currentTick - tickRange;
        int24 desiredTickUpper = currentTick + tickRange;

        // Align ticks to tick spacing (round down for lower, round up for upper)
        int24 tickLower = (desiredTickLower / tickSpacing) * tickSpacing;
        int24 tickUpper = (desiredTickUpper / tickSpacing) * tickSpacing;

        helper.createPosition(
            setup.vault, setup.allocator, tickLower, tickUpper, TestConstants.SMALL_AMOUNT, TestConstants.SMALL_AMOUNT
        );

        Position memory position = setup.vault.getPosition(0);
        uint128 excessiveAmount = position.liquidity * 2; // More than available

        vm.prank(setup.allocator);
        // Should revert or handle gracefully
        vm.expectRevert(bytes("LS"));
        setup.vault.burn(tickLower, tickUpper, excessiveAmount);
    }

    function test_burn_AutoCollect_TransfersTokens() public {
        (, int24 currentTick,,,,,) = setup.pool.slot0();
        int24 tickSpacing = setup.pool.tickSpacing();
        int24 tickRange = TestConstants.TICK_RANGE_NARROW;

        // Calculate desired ticks
        int24 desiredTickLower = currentTick - tickRange;
        int24 desiredTickUpper = currentTick + tickRange;

        // Align ticks to tick spacing (round down for lower, round up for upper)
        int24 tickLower = (desiredTickLower / tickSpacing) * tickSpacing;
        int24 tickUpper = (desiredTickUpper / tickSpacing) * tickSpacing;

        helper.createPosition(
            setup.vault, setup.allocator, tickLower, tickUpper, TestConstants.MEDIUM_AMOUNT, TestConstants.MEDIUM_AMOUNT
        );

        // todo:
        // Simulate some trading to generate fees (in real scenario). Then use > and < instead of <= and >=

        Position memory position = setup.vault.getPosition(0);
        uint256 initialBalance0 = setup.token0.balanceOf(address(setup.vault));
        uint256 initialBalance1 = setup.token1.balanceOf(address(setup.vault));

        vm.prank(setup.allocator);
        (uint256 amount0, uint256 amount1) = setup.vault.burn(tickLower, tickUpper, position.liquidity / 4);

        // Vault balance should increase (tokens returned from pool)
        assertTrue(setup.token0.balanceOf(address(setup.vault)) >= initialBalance0 + amount0);
        assertTrue(setup.token1.balanceOf(address(setup.vault)) >= initialBalance1 + amount1);
    }

    function test_burn_UpdatesLpValue() public {
        (, int24 currentTick,,,,,) = setup.pool.slot0();
        int24 tickSpacing = setup.pool.tickSpacing();
        int24 tickRange = TestConstants.TICK_RANGE_NARROW;

        // Calculate desired ticks
        int24 desiredTickLower = currentTick - tickRange;
        int24 desiredTickUpper = currentTick + tickRange;

        // Align ticks to tick spacing (round down for lower, round up for upper)
        int24 tickLower = (desiredTickLower / tickSpacing) * tickSpacing;
        int24 tickUpper = (desiredTickUpper / tickSpacing) * tickSpacing;

        helper.createPosition(
            setup.vault, setup.allocator, tickLower, tickUpper, TestConstants.MEDIUM_AMOUNT, TestConstants.MEDIUM_AMOUNT
        );

        (uint256 initialLp0, uint256 initialLp1) = setup.vault.totalLpValue();

        Position memory position = setup.vault.getPosition(0);

        vm.prank(setup.allocator);
        (uint256 amount0, uint256 amount1) = setup.vault.burn(tickLower, tickUpper, position.liquidity / 2);

        (uint256 finalLp0, uint256 finalLp1) = setup.vault.totalLpValue();

        // LP value should decrease after burning
        assertApproxEqAbs(finalLp0 + amount0, initialLp0, 1);
        assertApproxEqAbs(finalLp1 + amount1, initialLp1, 1);
        assertTrue(amount0 > 0);
        assertTrue(amount1 > 0);
    }

    function test_burn_ZeroAmount_Success() public {
        (, int24 currentTick,,,,,) = setup.pool.slot0();
        int24 tickSpacing = setup.pool.tickSpacing();
        int24 tickRange = TestConstants.TICK_RANGE_NARROW;

        // Calculate desired ticks
        int24 desiredTickLower = currentTick - tickRange;
        int24 desiredTickUpper = currentTick + tickRange;

        // Align ticks to tick spacing (round down for lower, round up for upper)
        int24 tickLower = (desiredTickLower / tickSpacing) * tickSpacing;
        int24 tickUpper = (desiredTickUpper / tickSpacing) * tickSpacing;

        helper.createPosition(
            setup.vault, setup.allocator, tickLower, tickUpper, TestConstants.MEDIUM_AMOUNT, TestConstants.MEDIUM_AMOUNT
        );

        vm.prank(setup.allocator);
        (uint256 amount0, uint256 amount1) = setup.vault.burn(tickLower, tickUpper, 0);

        // Should return zero amounts
        assertEq(amount0, 0);
        assertEq(amount1, 0);

        // Position should remain unchanged
        Position memory position = setup.vault.getPosition(0);
        assertTrue(position.liquidity > 0);
    }

    function test_burn_OwnerCanAlsoBurn_Success() public {
        (, int24 currentTick,,,,,) = setup.pool.slot0();
        int24 tickSpacing = setup.pool.tickSpacing();
        int24 tickRange = TestConstants.TICK_RANGE_NARROW;

        // Calculate desired ticks
        int24 desiredTickLower = currentTick - tickRange;
        int24 desiredTickUpper = currentTick + tickRange;

        // Align ticks to tick spacing (round down for lower, round up for upper)
        int24 tickLower = (desiredTickLower / tickSpacing) * tickSpacing;
        int24 tickUpper = (desiredTickUpper / tickSpacing) * tickSpacing;

        helper.createPosition(
            setup.vault, setup.allocator, tickLower, tickUpper, TestConstants.MEDIUM_AMOUNT, TestConstants.MEDIUM_AMOUNT
        );

        Position memory position = setup.vault.getPosition(0);

        // Owner should be able to burn (onlyOwnerOrAllocator modifier)
        vm.prank(setup.owner);
        (uint256 amount0, uint256 amount1) = setup.vault.burn(tickLower, tickUpper, position.liquidity / 4);

        assertTrue(amount0 > 0 || amount1 > 0);
    }

    /// @notice Burning more than the vault recorded still reverts when the pool accepts the burn because liquidity
    ///         was minted to the vault's position from outside: with the arithmetic panic of the record update
    function test_burn_ExcessiveLiquidity_DonatedToPosition_RevertsWithPanic() public {
        (int24 tickLower, int24 tickUpper) = _narrowRange();
        helper.createPosition(
            setup.vault, setup.allocator, tickLower, tickUpper, TestConstants.MEDIUM_AMOUNT, TestConstants.MEDIUM_AMOUNT
        );
        uint128 recorded = setup.vault.getPosition(0).liquidity;

        // A third party mints liquidity to the vault's position, at its own cost
        address donor = makeAddr("donor");
        setup.token0.mint(donor, TestConstants.MEDIUM_AMOUNT);
        setup.token1.mint(donor, TestConstants.MEDIUM_AMOUNT);
        vm.startPrank(donor);
        UniswapV3ProxyHarness mintProxy = new UniswapV3ProxyHarness(setup.pool.factory());
        setup.token0.approve(address(mintProxy), type(uint256).max);
        setup.token1.approve(address(mintProxy), type(uint256).max);
        mintProxy.mint(
            MintParams({
                token0: address(setup.token0),
                token1: address(setup.token1),
                fee: setup.pool.fee(),
                tickLower: tickLower,
                tickUpper: tickUpper,
                amount0Desired: TestConstants.SMALL_AMOUNT,
                amount1Desired: TestConstants.SMALL_AMOUNT,
                amount0Min: 0,
                amount1Min: 0,
                recipient: address(setup.vault),
                deadline: vm.getBlockTimestamp()
            })
        );
        vm.stopPrank();

        vm.prank(setup.allocator);
        vm.expectRevert(stdError.arithmeticError);
        setup.vault.burn(tickLower, tickUpper, recorded + 1);

        assertEq(setup.vault.getPosition(0).liquidity, recorded, "Record unchanged");
    }

    /// @notice A full burn removes the position from the vault's record before the vault calls the pool
    function test_burn_UpdatesPositionsBeforeCallingPool() public {
        (int24 tickLower, int24 tickUpper) = _narrowRange();
        helper.createPosition(
            setup.vault, setup.allocator, tickLower, tickUpper, TestConstants.MEDIUM_AMOUNT, TestConstants.MEDIUM_AMOUNT
        );
        uint128 liquidity = setup.vault.getPosition(0).liquidity;

        _observePoolCalls();

        vm.prank(setup.allocator);
        setup.vault.burn(tickLower, tickUpper, liquidity);

        assertEq(_poolCallsSeen(), 2, "burn and collect observed");
        assertEq(_maxPositionsSeen(), 0, "Position removed before the pool calls");
        assertEq(setup.vault.positionsLength(), 0, "Position removed");
    }

    /// @notice A full withdrawal books every position before the first pool call: the fee collection, burns and
    ///         collects all see the record already updated
    function test_withdraw_UpdatesPositionsBeforeCallingPool() public {
        (int24 tickLower, int24 tickUpper) = _narrowRange();
        helper.createPosition(
            setup.vault, setup.allocator, tickLower, tickUpper, TestConstants.MEDIUM_AMOUNT, TestConstants.MEDIUM_AMOUNT
        );
        helper.createPosition(
            setup.vault,
            setup.allocator,
            tickLower - TestConstants.TICK_SPACING,
            tickUpper + TestConstants.TICK_SPACING,
            TestConstants.SMALL_AMOUNT,
            TestConstants.SMALL_AMOUNT
        );
        assertEq(setup.vault.positionsLength(), 2, "Two positions");

        _observePoolCalls();

        helper.withdrawFromVault(setup, TestConstants.MAX_SCALED_PERCENTAGE, makeAddr("recipient"));

        // 2 fee collections, then a burn and a collect per position
        assertEq(_poolCallsSeen(), 6, "Pool calls observed");
        assertEq(_maxPositionsSeen(), 0, "Positions removed before the pool calls");
        assertEq(setup.vault.positionsLength(), 0, "Positions removed");
    }

    /// @notice burn reports the principal the pool released, but never more than what the pool's collect paid
    function test_burn_ReturnsAtMostWhatThePoolPaid() public {
        (int24 tickLower, int24 tickUpper) = _narrowRange();
        helper.createPosition(
            setup.vault, setup.allocator, tickLower, tickUpper, TestConstants.MEDIUM_AMOUNT, TestConstants.MEDIUM_AMOUNT
        );
        uint128 liquidity = setup.vault.getPosition(0).liquidity;

        // A Uniswap V3 pool pays at least the principal: the vault reports the principal
        uint256 snapshot = vm.snapshotState();
        vm.prank(setup.allocator);
        (uint256 released0, uint256 released1) = setup.vault.burn(tickLower, tickUpper, liquidity / 2);
        assertGt(released0, 0, "Principal released in token0");
        assertGt(released1, 0, "Principal released in token1");
        vm.revertToState(snapshot);

        // A pool whose collect pays less than it released: the vault reports what it received
        vm.mockCall(
            address(setup.pool),
            abi.encodeWithSelector(IUniswapV3PoolMinimal.collect.selector),
            abi.encode(uint128(1), uint128(2))
        );
        vm.prank(setup.allocator);
        (uint256 amount0, uint256 amount1) = setup.vault.burn(tickLower, tickUpper, liquidity / 2);
        assertEq(amount0, 1, "Capped by the token0 collected");
        assertEq(amount1, 2, "Capped by the token1 collected");
    }
}

/// @dev Stands in for a Uniswap V3 pool (its code is etched at the pool's address): on burn and collect it records
///      how many positions the calling vault holds, in slots of the pool's storage nothing else uses, then runs the
///      pool's own code (copied at POOL_CODE) by delegatecall, returning what the pool returns
contract PoolCallObserver {
    address internal immutable POOL_CODE;

    constructor(address poolCode) {
        POOL_CODE = poolCode;
    }

    function burn(int24, int24, uint128) external {
        _record();
        _delegate();
    }

    function collect(address, int24, int24, uint128, uint128) external {
        _record();
        _delegate();
    }

    fallback() external {
        _delegate();
    }

    function _record() internal {
        uint256 positionsCount = UniV3LpVault(msg.sender).positionsLength();
        bytes32 maxSlot = OBSERVED_MAX_POSITIONS_SLOT;
        bytes32 callsSlot = OBSERVED_CALLS_SLOT;
        assembly ("memory-safe") {
            if gt(positionsCount, sload(maxSlot)) { sstore(maxSlot, positionsCount) }
            sstore(callsSlot, add(sload(callsSlot), 1))
        }
    }

    function _delegate() internal {
        address target = POOL_CODE;
        assembly {
            calldatacopy(0, 0, calldatasize())
            let ok := delegatecall(gas(), target, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            if iszero(ok) { revert(0, returndatasize()) }
            return(0, returndatasize())
        }
    }
}
