// SPDX-License-Identifier: GPL-3.0
pragma solidity =0.8.28;

import "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ForkBase} from "../helpers/ForkBase.sol";
import {MockSafe} from "../../Mocks/zodiac/MockSafe.sol";
import {MockRoles} from "../../Mocks/zodiac/MockRoles.sol";
import {PositionRecorder, Range} from "../../../src/base/PositionRecorder.sol";
import {UniswapV4LiquidityProxy, V4LiquidityOp} from "../../../src/UniswapV4LiquidityProxy.sol";
import {MintParams} from "../../../src/interfaces/uniswapV3/IUniswapV3MintCallback.sol";
import {IUniswapV3PoolMinimal} from "../../../src/interfaces/uniswapV3/IUniswapV3PoolMinimal.sol";
import {IPoolManagerMinimal, PoolKey} from "../../../src/interfaces/uniswapV4/IPoolManagerMinimal.sol";
import {Operation} from "../../../src/interfaces/zodiac/IRoles.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";

/// @notice The recording entry points against the live pools: the proxy reads a V3 position through
/// the real pool's `positions()` and a V4 position straight out of the deployed PoolManager's storage,
/// so this checks both reads, and the cleanup they drive, against what is actually deployed.
contract RecordingTest is ForkBase {
    bytes32 constant ROLE_PROXY = keccak256("LOBSTER_V4_LIQUIDITY");
    bytes32 constant ROLE_EXEC = keccak256("LOBSTER_EXECUTOR");

    // --- V3: USDC/WETH 0.05% ---------------------------------------------------

    function _mintParams(int24 lower, int24 upper) internal view returns (MintParams memory) {
        return MintParams({
            token0: USDC,
            token1: WETH,
            fee: 500,
            tickLower: lower,
            tickUpper: upper,
            amount0Desired: lpUsdc,
            amount1Desired: lpWeth,
            amount0Min: 0,
            amount1Min: 0,
            recipient: approver,
            deadline: block.timestamp
        });
    }

    function _v3Position(
        int24 lower,
        int24 upper
    )
        internal
        view
        returns (uint128 liquidity, uint128 owed0, uint128 owed1)
    {
        (liquidity,,, owed0, owed1) =
            IUniswapV3PoolMinimal(USDC_WETH_500).positions(keccak256(abi.encodePacked(approver, lower, upper)));
    }

    /// @notice On the live pool: recorded under the pool's key, burnt but uncollected stays, collected
    /// is deleted by the next recording mint
    function test_v3_recordsAndDeletesEmptyRanges() public {
        bytes32 key = proxy.v3Key(USDC_WETH_500);
        (int24 a0, int24 a1) = _rangeAroundSpot(USDC_WETH_500, 10);
        (int24 b0, int24 b1) = _rangeAroundSpot(USDC_WETH_500, 20);
        (int24 c0, int24 c1) = _rangeAroundSpot(USDC_WETH_500, 30);

        vm.startPrank(approver);
        proxy.mintWithRecording(_mintParams(a0, a1));
        proxy.mintWithRecording(_mintParams(b0, b1));
        proxy.mintWithRecording(_mintParams(a0, a1)); // listed already
        vm.stopPrank();
        assertEq(proxy.rangesOf(approver, key).length, 2, "two ranges");

        // The vault exits range A directly on the pool: burnt, then (later) collected
        (uint128 liquidity,,) = _v3Position(a0, a1);
        vm.prank(approver);
        IUniswapV3PoolMinimal(USDC_WETH_500).burn(a0, a1, liquidity);
        (, uint128 owed0, uint128 owed1) = _v3Position(a0, a1);
        assertTrue(owed0 > 0 || owed1 > 0, "test bug: nothing owed after the burn");

        vm.prank(approver);
        proxy.mintWithRecording(_mintParams(c0, c1));
        assertEq(proxy.rangesOf(approver, key).length, 3, "a burnt range still owing tokens was deleted");

        vm.prank(approver);
        IUniswapV3PoolMinimal(USDC_WETH_500).collect(approver, a0, a1, type(uint128).max, type(uint128).max);
        vm.expectEmit(true, true, false, true, address(proxy));
        emit PositionRecorder.RangeDeleted(approver, key, a0, a1, bytes32(0));
        vm.prank(approver);
        proxy.mintWithRecording(_mintParams(b0, b1));

        Range[] memory ranges = proxy.rangesOf(approver, key);
        assertEq(ranges.length, 2, "the collected range was not deleted");
        for (uint256 i = 0; i < ranges.length; i++) {
            assertTrue(ranges[i].tickLower != a0 || ranges[i].tickUpper != a1, "range A still listed");
            assertEq(ranges[i].salt, bytes32(0), "a V3 range has no salt");
        }
        assertEq(IERC20(USDC).balanceOf(address(proxy)), 0, "proxy retained USDC");
        assertEq(IERC20(WETH).balanceOf(address(proxy)), 0, "proxy retained WETH");
    }

    // --- V4: the live ETH/USDC pool ---------------------------------------------

    /// @dev A funded vault (MockSafe) whose Roles modifier (MockRoles) is set up as in production
    function _v4Vault() internal returns (MockSafe safe, MockRoles roles, address executor) {
        safe = new MockSafe();
        roles = new MockRoles(address(safe), address(safe));
        safe.enableModule(address(roles));
        roles.enableModule(address(proxy));
        roles.assignRole(address(proxy), ROLE_PROXY, true);
        roles.scopeCustomCondition(
            ROLE_PROXY, POOL_MANAGER, IPoolManagerMinimal.modifyLiquidity.selector, address(proxy)
        );
        roles.scopeParamEqualToAvatar(ROLE_PROXY, POOL_MANAGER, IPoolManagerMinimal.take.selector, 1);
        executor = _actor("v4 executor");
        roles.enableModule(executor);
        roles.assignRole(executor, ROLE_EXEC, true);
        roles.allowFunction(ROLE_EXEC, address(proxy), UniswapV4LiquidityProxy.modifyLiquidityV4.selector, true);
        roles.allowFunction(
            ROLE_EXEC, address(proxy), UniswapV4LiquidityProxy.modifyLiquidityV4WithRecording.selector, true
        );

        deal(USDC, address(safe), fundUsdc);
        vm.deal(address(safe), fundWeth);
        vm.startPrank(address(safe));
        IERC20(USDC).approve(address(proxy), type(uint256).max);
        proxy.setV4Roles(address(roles), ROLE_PROXY);
        vm.stopPrank();
        _allow(address(safe), proxy.v4Key(_v4EthUsdc()), MINT);
    }

    function _op(int24 lower, int24 upper, int256 delta) internal view returns (V4LiquidityOp memory) {
        return V4LiquidityOp({
            key: _v4EthUsdc(),
            tickLower: lower,
            tickUpper: upper,
            liquidityDelta: delta,
            salt: bytes32(0),
            amount0Limit: delta > 0 ? type(uint128).max : 0,
            amount1Limit: delta > 0 ? type(uint128).max : 0
        });
    }

    function _exec(
        MockRoles roles,
        address executor,
        bytes4 selector,
        V4LiquidityOp memory op,
        uint256 value
    )
        internal
    {
        V4LiquidityOp[] memory ops = new V4LiquidityOp[](1);
        ops[0] = op;
        vm.prank(executor);
        roles.execTransactionWithRoleReturnData(
            address(proxy),
            value,
            abi.encodeWithSelector(selector, ops, block.timestamp),
            Operation.Call,
            ROLE_EXEC,
            true
        );
    }

    function _v4Liquidity(address owner, int24 lower, int24 upper) internal view returns (uint128 liquidity) {
        (liquidity,,) = StateLibrary.getPositionInfo(
            IPoolManager(POOL_MANAGER), PoolId.wrap(proxy.v4Key(_v4EthUsdc())), owner, lower, upper, bytes32(0)
        );
    }

    /// @notice On the deployed PoolManager: the proxy's read of a position's liquidity agrees with
    /// v4-core's StateLibrary, so a range emptied with plain modifyLiquidityV4 is deleted by the next
    /// recording add, and a range holding liquidity is kept
    function test_v4_recordsAndDeletesEmptyRanges() public {
        (MockSafe safe, MockRoles roles, address executor) = _v4Vault();
        bytes32 key = proxy.v4Key(_v4EthUsdc());
        // The live tick, aligned to the pool's spacing of 10
        int24 tick = int24(int256(_v4Slot0(key) >> 160));
        tick = (tick / 10) * 10;
        bytes4 rec = UniswapV4LiquidityProxy.modifyLiquidityV4WithRecording.selector;
        bytes4 plain = UniswapV4LiquidityProxy.modifyLiquidityV4.selector;

        _exec(roles, executor, rec, _op(tick - 100, tick + 100, 1e14), 10 ether);
        _exec(roles, executor, rec, _op(tick - 200, tick + 200, 1e14), 10 ether);
        assertEq(_v4Liquidity(address(safe), tick - 100, tick + 100), 1e14, "the vault does not own the position");
        assertEq(proxy.rangesOf(address(safe), key).length, 2, "two ranges");

        _exec(roles, executor, plain, _op(tick - 100, tick + 100, -1e14), 0);
        assertEq(_v4Liquidity(address(safe), tick - 100, tick + 100), 0, "test bug: not emptied");
        assertEq(proxy.rangesOf(address(safe), key).length, 2, "deleted before the next recording add");

        vm.expectEmit(true, true, false, true, address(proxy));
        emit PositionRecorder.RangeDeleted(address(safe), key, tick - 100, tick + 100, bytes32(0));
        _exec(roles, executor, rec, _op(tick - 300, tick + 300, 1e14), 10 ether);

        Range[] memory ranges = proxy.rangesOf(address(safe), key);
        assertEq(ranges.length, 2, "the emptied range was not deleted, or a live one was");
        for (uint256 i = 0; i < ranges.length; i++) {
            assertGt(_v4Liquidity(address(safe), ranges[i].tickLower, ranges[i].tickUpper), 0, "an empty range listed");
        }
        assertEq(address(proxy).balance, 0, "proxy retained ETH");
        assertEq(IERC20(USDC).balanceOf(address(proxy)), 0, "proxy retained USDC");
    }
}
