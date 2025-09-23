// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {UniV3LpVault, MinimalMintParams, Position} from "../../../src/vaults/UniV3LpVault.sol";
import {MockERC20} from "../../Mocks/MockERC20.sol";
import {UniswapV3Infra} from "../../Mocks/uniswapV3/UniswapV3Infra.sol";
import {IUniswapV3FactoryMinimal} from "../../../src/interfaces/uniswapV3/IUniswapV3FactoryMinimal.sol";
import {IUniswapV3PoolMinimal} from "../../../src/interfaces/uniswapV3/IUniswapV3PoolMinimal.sol";
import {IWETH} from "../../../src/interfaces/IWETH.sol";
import {TestConstants} from "./Constants.sol";

contract TestHelper is Test {
    using Math for uint256;

    struct VaultSetup {
        UniV3LpVault vault;
        MockERC20 token0;
        MockERC20 token1;
        IUniswapV3PoolMinimal pool;
        address owner;
        address executor;
        address executorManager;
        address feeCollector;
    }

    function deployVaultWithPool() public returns (VaultSetup memory setup) {
        return deployVaultWithPool(TestConstants.LOW_TVL_FEE);
    }

    function deployVaultWithPool(uint256 tvlFee) public returns (VaultSetup memory setup) {
        // Create addresses
        setup.owner = makeAddr("vaultOwner");
        setup.executor = makeAddr("executor");
        setup.executorManager = makeAddr("executorManager");
        setup.feeCollector = makeAddr("feeCollector");

        // Deploy mock tokens
        setup.token0 = new MockERC20();
        setup.token1 = new MockERC20();

        // Ensure proper token ordering for Uniswap V3
        if (address(setup.token0) > address(setup.token1)) {
            (setup.token0, setup.token1) = (setup.token1, setup.token0);
        }

        // Mint tokens to owner
        setup.token0.mint(setup.owner, TestConstants.INITIAL_BALANCE);
        setup.token1.mint(setup.owner, TestConstants.INITIAL_BALANCE);

        // Deploy Uniswap V3 infrastructure
        UniswapV3Infra uniswapV3 = new UniswapV3Infra();
        (IUniswapV3FactoryMinimal factory,,,) = uniswapV3.deploy();

        // Create and initialize pool
        setup.pool = uniswapV3.createPoolAndInitialize(
            factory,
            address(setup.token0),
            address(setup.token1),
            TestConstants.POOL_FEE,
            TestConstants.INITIAL_SQRT_PRICE_X96
        );

        // Deploy vault
        setup.vault = new UniV3LpVault(
            setup.owner,
            setup.executor,
            setup.executorManager,
            address(setup.token0),
            address(setup.token1),
            address(setup.pool),
            setup.feeCollector,
            tvlFee
        );

        // Setup approvals
        vm.startPrank(setup.owner);
        setup.token0.approve(address(setup.vault), type(uint256).max);
        setup.token1.approve(address(setup.vault), type(uint256).max);
        vm.stopPrank();
    }

    function createPosition(
        UniV3LpVault vault,
        address caller,
        int24 tickLower,
        int24 tickUpper,
        uint256 amount0Desired,
        uint256 amount1Desired
    )
        public
        returns (uint256 amount0, uint256 amount1)
    {
        MinimalMintParams memory mintParams = MinimalMintParams({
            tickLower: tickLower,
            tickUpper: tickUpper,
            amount0Desired: amount0Desired,
            amount1Desired: amount1Desired,
            amount0Min: 0,
            amount1Min: 0,
            deadline: block.timestamp + 1 hours
        });

        vm.prank(caller);
        return vault.mint(mintParams);
    }

    function createPositionAroundCurrentTick(
        UniV3LpVault vault,
        address caller,
        int24 tickRange,
        uint256 amount0Desired,
        uint256 amount1Desired
    )
        public
        returns (uint256 amount0, uint256 amount1)
    {
        (, int24 currentTick,,,,,) = vault.pool().slot0();
        int24 tickLower = currentTick - tickRange;
        int24 tickUpper = currentTick + tickRange;

        return createPosition(vault, caller, tickLower, tickUpper, amount0Desired, amount1Desired);
    }

    function simulateTimePass(uint256 timeInSeconds) public {
        vm.warp(block.timestamp + timeInSeconds);
    }

    function movePoolPriceUp(IUniswapV3PoolMinimal pool, uint256 percentage) public {
        // This would require implementing swaps through a mock router
        // For now, we'll use vm.mockCall for testing purposes
        (, int24 currentTick,,,,,) = pool.slot0();
        int24 newTick = currentTick + int24(int256(percentage * 100)); // Simplified calculation

        vm.mockCall(
            address(pool),
            abi.encodeWithSignature("slot0()"),
            abi.encode(
                (TestConstants.INITIAL_SQRT_PRICE_X96 * 110) / 100, // +10% price increase
                newTick,
                0,
                0,
                0,
                0,
                0
            )
        );
    }

    function assertApproxEqual(
        uint256 actual,
        uint256 expected,
        uint256 tolerance,
        string memory message
    )
        public
        pure
    {
        if (expected == 0) {
            assertEq(actual, expected, message);
            return;
        }

        uint256 diff = actual > expected ? actual - expected : expected - actual;
        uint256 maxDiff = expected.mulDiv(tolerance, 1e18);

        assertLe(
            diff,
            maxDiff,
            string(
                abi.encodePacked(
                    message,
                    " - actual: ",
                    vm.toString(actual),
                    ", expected: ",
                    vm.toString(expected),
                    ", tolerance: ",
                    vm.toString(tolerance)
                )
            )
        );
    }

    function assertPositionExists(
        UniV3LpVault vault,
        int24 tickLower,
        int24 tickUpper,
        uint128 expectedLiquidity
    )
        public
        view
    {
        // Search through positions to find matching range
        bool found = false;
        uint128 actualLiquidity = 0;

        // We need to iterate through positions - this assumes we have a way to get position count
        // For now, we'll try positions 0-9 (reasonable for tests)
        for (uint256 i = 0; i < 10; i++) {
            try vault.getPosition(i) returns (Position memory pos) {
                if (pos.lowerTick == tickLower && pos.upperTick == tickUpper) {
                    found = true;
                    actualLiquidity = pos.liquidity;
                    break;
                }
            } catch {
                break; // End of positions array
            }
        }

        assertTrue(found, "Position not found");
        assertEq(actualLiquidity, expectedLiquidity, "Position liquidity mismatch");
    }

    function assertPositionDoesNotExist(UniV3LpVault vault, int24 tickLower, int24 tickUpper) public view {
        bool found = false;

        for (uint256 i = 0; i < 10; i++) {
            try vault.getPosition(i) returns (Position memory pos) {
                if (pos.lowerTick == tickLower && pos.upperTick == tickUpper && pos.liquidity > 0) {
                    found = true;
                    break;
                }
            } catch {
                break;
            }
        }

        assertFalse(found, "Position should not exist");
    }

    function depositToVault(VaultSetup memory setup, uint256 amount0, uint256 amount1) public {
        vm.prank(setup.owner);
        setup.vault.deposit(amount0, amount1);
    }

    function withdrawFromVault(
        VaultSetup memory setup,
        uint256 scaledPercentage,
        address recipient
    )
        public
        returns (uint256 amount0, uint256 amount1)
    {
        vm.prank(setup.owner);
        return setup.vault.withdraw(scaledPercentage, recipient);
    }
}
