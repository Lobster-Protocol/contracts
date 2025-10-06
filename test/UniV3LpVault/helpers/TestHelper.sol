// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {UniV3LpVault, MinimalMintParams, Position} from "../../../src/vaults/UniV3LpVault.sol";
import {MockERC20} from "../../Mocks/MockERC20.sol";
import {UniswapV3Infra} from "../../Mocks/uniswapV3/UniswapV3Infra.sol";
import {IUniswapV3FactoryMinimal} from "../../../src/interfaces/uniswapV3/IUniswapV3FactoryMinimal.sol";
import {IUniswapV3RouterMinimal} from "../../../src/interfaces/uniswapV3/IUniswapV3RouterMinimal.sol";
import {IUniswapV3PoolMinimal} from "../../../src/interfaces/uniswapV3/IUniswapV3PoolMinimal.sol";
import {IWETH} from "../../../src/interfaces/IWETH.sol";
import {TestConstants} from "./Constants.sol";
import {UniswapV3Proxy} from "../../../src/UniswapV3Proxy.sol";
import {MintParams} from "src/interfaces/uniswapV3/IUniswapV3MintCallback.sol";

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
        IUniswapV3RouterMinimal router;
    }

    function deployVaultWithPool() public returns (VaultSetup memory setup) {
        return deployVaultWithPool(0, 0);
    }

    function deployVaultWithPool(uint256 tvlFee, uint256 perfFee) public returns (VaultSetup memory setup) {
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
        (IUniswapV3FactoryMinimal factory,,, IUniswapV3RouterMinimal router) = uniswapV3.deploy();

        setup.router = router;

        // Create and initialize pool
        setup.pool = uniswapV3.createPoolAndInitialize(
            factory,
            address(setup.token0),
            address(setup.token1),
            TestConstants.POOL_FEE,
            TestConstants.INITIAL_SQRT_PRICE_X96
        );

        // Do some swaps so we can have a twap over 14 days
        address swapper = makeAddr("Swapper");
        setup.token0.mint(swapper, 100_000 ether);
        setup.token1.mint(swapper, 100_000 ether);

        vm.startPrank(swapper);
        UniswapV3Proxy mintProxy = new UniswapV3Proxy(setup.pool.factory());

        setup.token0.approve(address(mintProxy), type(uint256).max);
        setup.token1.approve(address(mintProxy), type(uint256).max);
        setup.token0.approve(address(setup.router), type(uint256).max);
        setup.token1.approve(address(setup.router), type(uint256).max);

        // deposit liquidity
        MintParams memory mintParams = MintParams({
            token0: address(setup.token0),
            token1: address(setup.token1),
            fee: setup.pool.fee(),
            tickLower: -6_000,
            tickUpper: 6_000,
            amount0Desired: 80_000 ether,
            amount1Desired: 80_000 ether,
            amount0Min: 50_000 ether,
            amount1Min: 50_000 ether,
            recipient: swapper,
            deadline: block.timestamp
        });
        mintProxy.mint(mintParams);

        IUniswapV3RouterMinimal.ExactInputSingleParams memory swapParams = IUniswapV3RouterMinimal
            .ExactInputSingleParams({
            tokenIn: address(setup.token0),
            tokenOut: address(setup.token1),
            fee: setup.pool.fee(),
            recipient: swapper,
            deadline: block.timestamp,
            amountIn: 0.5 ether,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: TestConstants.INITIAL_SQRT_PRICE_X96 / 2
        });
        setup.router.exactInputSingle(swapParams);
        vm.stopPrank();

        // Jump 14 days into the future
        vm.warp(block.timestamp + 14 days);

        // Deploy vault
        setup.vault = new UniV3LpVault(
            setup.owner,
            setup.executor,
            setup.executorManager,
            address(setup.token0),
            address(setup.token1),
            address(setup.pool),
            setup.feeCollector,
            tvlFee,
            perfFee
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
        IUniswapV3PoolMinimal pool = vault.pool();
        (, int24 currentTick,,,,,) = pool.slot0();
        int24 tickSpacing = pool.tickSpacing();

        // Calculate desired ticks
        int24 desiredTickLower = currentTick - tickRange;
        int24 desiredTickUpper = currentTick + tickRange;

        // Align ticks to tick spacing (round down for lower, round up for upper)
        int24 tickLower = (desiredTickLower / tickSpacing) * tickSpacing;
        int24 tickUpper = (desiredTickUpper / tickSpacing) * tickSpacing;

        // Ensure tickUpper > tickLower by at least one tick spacing
        if (tickUpper <= tickLower) {
            tickUpper = tickLower + tickSpacing;
        }

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
