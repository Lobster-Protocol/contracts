// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.20;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import {
    UniV3LpVault,
    MinimalMintParams,
    SCALING_FACTOR,
    MAX_SCALED_PERCENTAGE,
    SingleVault,
    Position
} from "../src/vaults/UniV3LpVault.sol";
import {IWETH} from "../src/interfaces/IWETH.sol";
import {MockERC20} from "./Mocks/MockERC20.sol";
import {UniswapV3Infra} from "./Mocks/uniswapV3/UniswapV3Infra.sol";
import {IUniswapV3FactoryMinimal} from "../src/interfaces/uniswapV3/IUniswapV3FactoryMinimal.sol";
import {IUniswapV3PoolMinimal} from "../src/interfaces/uniswapV3/IUniswapV3PoolMinimal.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MintCallbackData} from "../src/interfaces/uniswapV3/IUniswapV3MintCallback.sol";
import {PoolAddress} from "../src/libraries/uniswapV3/PoolAddress.sol";

uint24 constant FEE = 3000; // 0.3%

contract UniV3LpVaultTest is Test {
    using Math for uint256;

    address vaultOwner = makeAddr("vaultOwner");
    address executor = makeAddr("executor");
    address executorManager = makeAddr("executorManager");
    IWETH weth;
    MockERC20 token0;
    MockERC20 token1;
    IUniswapV3PoolMinimal pool;
    UniV3LpVault vault;

    function setUp() public {
        // Deploy mock tokens
        token0 = new MockERC20();
        token1 = new MockERC20();

        // Ensure proper token ordering for Uniswap V3
        if (address(token0) > address(token1)) {
            (token0, token1) = (token1, token0);
        }

        token0.mint(vaultOwner, 1_000_000 ether);
        token1.mint(vaultOwner, 1_000_000 ether);

        // Deploy uniV3 infra
        UniswapV3Infra uniswapV3 = new UniswapV3Infra();
        (IUniswapV3FactoryMinimal factory, IWETH weth_,,) = uniswapV3.deploy();
        weth = weth_;

        uint160 initialSqrtPriceX96 = 2 ** 96; // = quote = 1:1 (in the smallest units)

        // Deploy pool
        pool = uniswapV3.createPoolAndInitialize(factory, address(token0), address(token1), FEE, initialSqrtPriceX96);

        vault = new UniV3LpVault(vaultOwner, executor, executorManager, address(token0), address(token1), address(pool));

        vm.startPrank(vaultOwner);
        token0.approve(address(vault), type(uint256).max);
        token1.approve(address(vault), type(uint256).max);
        vm.stopPrank();
    }

    function testConstructor() public view {
        assertEq(vault.owner(), vaultOwner);
        assertEq(vault.executorManager(), executorManager);
        assertEq(vault.executor(), executor);
        assertEq(vault.pool().fee(), FEE);
        assertEq(address(vault.pool()), address(pool));
        assertEq(address(vault.token0()), address(token0));
        assertEq(address(vault.token1()), address(token1));
        assertEq(address(vault.token1()), address(token1));
    }

    function testConstructorInvalidTokens() public {
        vm.expectRevert("Wrong token 0 & 1 order");
        new UniV3LpVault(vaultOwner, executor, executorManager, address(token1), address(token0), address(pool));
    }

    function testDeposit() public {
        uint256 deposit0 = 2 ether;
        uint256 deposit1 = 5 ether;

        uint256 initialVaultBalance0 = token0.balanceOf(address(vault));
        uint256 initialVaultBalance1 = token1.balanceOf(address(vault));
        uint256 initialOwnerBalance0 = token0.balanceOf(vaultOwner);
        uint256 initialOwnerBalance1 = token1.balanceOf(vaultOwner);

        vm.startPrank(vaultOwner);
        vm.expectEmit(true, true, true, true);
        emit UniV3LpVault.Deposit(deposit0, deposit1);
        vault.deposit(deposit0, deposit1);
        vm.stopPrank();

        uint256 finalVaultBalance0 = token0.balanceOf(address(vault));
        uint256 finalVaultBalance1 = token1.balanceOf(address(vault));
        uint256 finalOwnerBalance0 = token0.balanceOf(vaultOwner);
        uint256 finalOwnerBalance1 = token1.balanceOf(vaultOwner);

        assertEq(initialOwnerBalance0 - deposit0, finalOwnerBalance0);
        assertEq(initialOwnerBalance1 - deposit1, finalOwnerBalance1);
        assertEq(initialVaultBalance0 + deposit0, finalVaultBalance0);
        assertEq(initialVaultBalance1 + deposit1, finalVaultBalance1);
    }

    function testDepositNotOwner() public {
        uint256 deposit0 = 1 ether;
        uint256 deposit1 = 7 ether;
        address notOwner = makeAddr("notOwner");
        vm.startPrank(notOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, notOwner));
        vault.deposit(deposit0, deposit1);
        vm.stopPrank();
    }

    function testDepositZeroTokens() public {
        uint256 deposit0 = 0;
        uint256 deposit1 = 0;

        vm.startPrank(vaultOwner);
        vm.expectRevert(SingleVault.ZeroValue.selector);
        vault.deposit(deposit0, deposit1);
        vm.stopPrank();
    }

    function testWithdrawLp() public {
        uint256 deposit0 = 2 ether;
        uint256 deposit1 = 5 ether;

        vm.startPrank(vaultOwner);
        vault.deposit(deposit0, deposit1);
        vm.stopPrank();

        // Let's create some positions with the executor & do some swaps
        vm.startPrank(executor);
        (, int24 currentTick,,,,,) = pool.slot0();
        int24 lowerTick = currentTick - 6000;
        int24 upperTick = currentTick + 6000;

        uint256 amount0Desired = 2 ether;
        uint256 amount1Desired = 2 ether;

        MinimalMintParams memory mintParams = MinimalMintParams({
            tickLower: lowerTick,
            tickUpper: upperTick,
            amount0Desired: amount0Desired,
            amount1Desired: amount1Desired,
            amount0Min: 0,
            amount1Min: 0,
            deadline: block.timestamp
        });
        vault.mint(mintParams);
        vm.stopPrank();

        // Owner withdraw
        uint256 withdrawScaledPercentage = 50 * SCALING_FACTOR;
        address receiver = makeAddr("random receiver");

        uint256 initialReceiverBalance0 = token0.balanceOf(receiver);
        uint256 initialReceiverBalance1 = token1.balanceOf(receiver);

        vm.startPrank(vaultOwner);
        vault.withdraw(withdrawScaledPercentage, receiver);
        vm.stopPrank();

        uint256 expectedWithdraw0 = deposit0.mulDiv(withdrawScaledPercentage, MAX_SCALED_PERCENTAGE);
        uint256 expectedWithdraw1 = deposit1.mulDiv(withdrawScaledPercentage, MAX_SCALED_PERCENTAGE);
        assertApproxEqRel(initialReceiverBalance0 + expectedWithdraw0, token0.balanceOf(receiver), 1);
        assertApproxEqRel(initialReceiverBalance1 + expectedWithdraw1, token1.balanceOf(receiver), 1);

        (uint256 finalVaultTotalToken0, uint256 finalVaultTotalToken1) = vault.netAssetsValue();

        assertApproxEqRel(deposit0.mulDiv(withdrawScaledPercentage, MAX_SCALED_PERCENTAGE), finalVaultTotalToken0, 1);
        assertApproxEqRel(deposit1.mulDiv(withdrawScaledPercentage, MAX_SCALED_PERCENTAGE), finalVaultTotalToken1, 1);
    }

    function testWithdrawLpMultiplePositions() public {
        uint256 deposit0 = 7 ether;
        uint256 deposit1 = 13 ether;

        vm.startPrank(vaultOwner);
        vault.deposit(deposit0, deposit1);
        vm.stopPrank();

        // Let's create some positions with the executor & do some swaps
        vm.startPrank(executor);
        (, int24 currentTick,,,,,) = pool.slot0();

        // Mint first position
        int24 lowerTick = currentTick - 6000;
        int24 upperTick = currentTick + 6000;

        uint256 amount0Desired = 2 ether;
        uint256 amount1Desired = 2 ether;

        MinimalMintParams memory mintParams = MinimalMintParams({
            tickLower: lowerTick,
            tickUpper: upperTick,
            amount0Desired: amount0Desired,
            amount1Desired: amount1Desired,
            amount0Min: 0,
            amount1Min: 0,
            deadline: block.timestamp
        });
        vault.mint(mintParams);

        // Mint second position
        int24 lowerTick2 = currentTick - 12000;
        int24 upperTick2 = currentTick + 6000;

        uint256 amount0Desired2 = 5 ether;
        uint256 amount1Desired2 = 5 ether;

        MinimalMintParams memory mintParams2 = MinimalMintParams({
            tickLower: lowerTick2,
            tickUpper: upperTick2,
            amount0Desired: amount0Desired2,
            amount1Desired: amount1Desired2,
            amount0Min: 0,
            amount1Min: 0,
            deadline: block.timestamp
        });
        vault.mint(mintParams2);
        vm.stopPrank();

        // Owner withdraw
        uint256 withdrawScaledPercentage = 50 * SCALING_FACTOR;
        address receiver = makeAddr("random receiver");

        uint256 initialReceiverBalance0 = token0.balanceOf(receiver);
        uint256 initialReceiverBalance1 = token1.balanceOf(receiver);

        vm.startPrank(vaultOwner);
        vault.withdraw(withdrawScaledPercentage, receiver);
        vm.stopPrank();

        uint256 expectedWithdraw0 = deposit0.mulDiv(withdrawScaledPercentage, MAX_SCALED_PERCENTAGE);
        uint256 expectedWithdraw1 = deposit1.mulDiv(withdrawScaledPercentage, MAX_SCALED_PERCENTAGE);
        assertApproxEqRel(initialReceiverBalance0 + expectedWithdraw0, token0.balanceOf(receiver), 1);
        assertApproxEqRel(initialReceiverBalance1 + expectedWithdraw1, token1.balanceOf(receiver), 1);

        (uint256 finalVaultTotalToken0, uint256 finalVaultTotalToken1) = vault.netAssetsValue();

        assertApproxEqRel(deposit0.mulDiv(withdrawScaledPercentage, MAX_SCALED_PERCENTAGE), finalVaultTotalToken0, 1);
        assertApproxEqRel(deposit1.mulDiv(withdrawScaledPercentage, MAX_SCALED_PERCENTAGE), finalVaultTotalToken1, 1);
    }

    function testWithdrawWrongScaledPercent() public {
        uint256 deposit0 = 2 ether;
        uint256 deposit1 = 5 ether;

        vm.startPrank(vaultOwner);
        vault.deposit(deposit0, deposit1);
        vm.stopPrank();

        // Let's create some positions with the executor & do some swaps
        vm.startPrank(executor);
        (, int24 currentTick,,,,,) = pool.slot0();
        int24 lowerTick = currentTick - 6000;
        int24 upperTick = currentTick + 6000;

        uint256 amount0Desired = 2 ether;
        uint256 amount1Desired = 2 ether;

        MinimalMintParams memory mintParams = MinimalMintParams({
            tickLower: lowerTick,
            tickUpper: upperTick,
            amount0Desired: amount0Desired,
            amount1Desired: amount1Desired,
            amount0Min: 0,
            amount1Min: 0,
            deadline: block.timestamp
        });
        vault.mint(mintParams);
        vm.stopPrank();

        // Owner withdraw
        uint256 withdrawScaledPercentage = MAX_SCALED_PERCENTAGE + 1;
        address receiver = makeAddr("random receiver");

        vm.startPrank(vaultOwner);
        vm.expectRevert(UniV3LpVault.InvalidScalingFactor.selector);
        vault.withdraw(withdrawScaledPercentage, receiver);
        vm.stopPrank();
    }

    function testWithdrawZeroPercent() public {
        uint256 deposit0 = 2 ether;
        uint256 deposit1 = 5 ether;

        vm.startPrank(vaultOwner);
        vault.deposit(deposit0, deposit1);
        vm.stopPrank();

        // Let's create some positions with the executor & do some swaps
        vm.startPrank(executor);
        (, int24 currentTick,,,,,) = pool.slot0();
        int24 lowerTick = currentTick - 6000;
        int24 upperTick = currentTick + 6000;

        uint256 amount0Desired = 2 ether;
        uint256 amount1Desired = 2 ether;

        MinimalMintParams memory mintParams = MinimalMintParams({
            tickLower: lowerTick,
            tickUpper: upperTick,
            amount0Desired: amount0Desired,
            amount1Desired: amount1Desired,
            amount0Min: 0,
            amount1Min: 0,
            deadline: block.timestamp
        });
        vault.mint(mintParams);
        vm.stopPrank();

        // Owner withdraw
        address receiver = makeAddr("random receiver");

        vm.startPrank(vaultOwner);
        vm.expectRevert(SingleVault.ZeroValue.selector);
        vault.withdraw(0, receiver);
        vm.stopPrank();
    }

    function testWithdrawMultipleLpsAndSwaps() public {
        // todo: complete (copy/paste testWithdrawLp), add some Lps and some swaps (but needs to pass throug a proxy because of the swap callback)
    }

    function testMint() public {
        uint256 deposit0 = 1 ether;
        uint256 deposit1 = 3 ether;

        vm.startPrank(vaultOwner);
        vault.deposit(deposit0, deposit1);
        vm.stopPrank();

        vm.startPrank(executor);
        (, int24 currentTick,,,,,) = pool.slot0();
        int24 lowerTick = currentTick - 6000;
        int24 upperTick = currentTick + 6000;

        uint256 amount0Desired = 0.5 ether;
        uint256 amount1Desired = 0.5 ether;

        MinimalMintParams memory mintParams = MinimalMintParams({
            tickLower: lowerTick,
            tickUpper: upperTick,
            amount0Desired: amount0Desired,
            amount1Desired: amount1Desired,
            amount0Min: 0.5 ether,
            amount1Min: 0.5 ether,
            deadline: block.timestamp
        });
        vault.mint(mintParams);
        vm.stopPrank();

        assertEq(token0.balanceOf(address(vault)), deposit0 - amount0Desired);
        assertEq(token1.balanceOf(address(vault)), deposit1 - amount1Desired);

        (uint256 totalLp0, uint256 totalLp1) = vault.totalLpValue();
        assertApproxEqAbs(totalLp0, amount0Desired, 1);
        assertApproxEqAbs(totalLp1, amount1Desired, 1);
    }

    function testMintMultipleRanges() public {
        uint256 deposit0 = 2 ether;
        uint256 deposit1 = 2 ether;

        vm.startPrank(vaultOwner);
        vault.deposit(deposit0, deposit1);
        vm.stopPrank();

        vm.startPrank(executor);
        (, int24 currentTick,,,,,) = pool.slot0();
        int24 lowerTick = currentTick - 6000;
        int24 upperTick = currentTick + 6000;

        uint256 amount0Desired = 0.5 ether;
        uint256 amount1Desired = 0.5 ether;

        MinimalMintParams memory mintParams = MinimalMintParams({
            tickLower: lowerTick,
            tickUpper: upperTick,
            amount0Desired: amount0Desired,
            amount1Desired: amount1Desired,
            amount0Min: 0.5 ether,
            amount1Min: 0.5 ether,
            deadline: block.timestamp
        });
        vault.mint(mintParams);

        // Mint same Range
        uint256 amount0Desired2 = 0.1 ether;
        uint256 amount1Desired2 = 0.1 ether;

        MinimalMintParams memory mintParams2 = MinimalMintParams({
            tickLower: lowerTick,
            tickUpper: upperTick,
            amount0Desired: amount0Desired2,
            amount1Desired: amount1Desired2,
            amount0Min: 0,
            amount1Min: 0,
            deadline: block.timestamp
        });
        vault.mint(mintParams2);

        // Mint new Range
        uint256 amount0Desired3 = 0.4 ether;
        uint256 amount1Desired3 = 0.4 ether;

        int24 lowerTick3 = currentTick - 12000;
        int24 upperTick3 = currentTick + 12000;

        MinimalMintParams memory mintParams3 = MinimalMintParams({
            tickLower: lowerTick3,
            tickUpper: upperTick3,
            amount0Desired: amount0Desired3,
            amount1Desired: amount1Desired3,
            amount0Min: 0,
            amount1Min: 0,
            deadline: block.timestamp
        });
        vault.mint(mintParams3);
        vm.stopPrank();

        Position memory position0 = vault.getPosition(0);

        assert(position0.lowerTick == lowerTick && position0.upperTick == upperTick);

        assertEq(token0.balanceOf(address(vault)), deposit0 - amount0Desired - amount0Desired2 - amount0Desired3);
        assertEq(token1.balanceOf(address(vault)), deposit1 - amount1Desired - amount1Desired2 - amount1Desired3);

        (uint256 totalLp0, uint256 totalLp1) = vault.totalLpValue();

        console.log(totalLp0, totalLp1);
        console.log(
            amount0Desired + amount0Desired2 - amount0Desired3, amount1Desired + amount1Desired2 - amount1Desired3
        );
        console.log(token0.balanceOf(address(vault)), token1.balanceOf(address(vault)));
        (uint256 t0, uint256 t1) = vault.netAssetsValue();
        console.log(t0, t1);
        assertApproxEqAbs(
            totalLp0,
            amount0Desired + amount0Desired2 + amount0Desired3,
            2 // due to multiple rounding errors
        );
        assertApproxEqAbs(
            totalLp1,
            amount1Desired + amount1Desired2 + amount1Desired3,
            2 // due to multiple rounding errors
        );
    }

    function testMintWrongCaller() public {
        uint256 deposit0 = 1 ether;
        uint256 deposit1 = 3 ether;

        vm.startPrank(vaultOwner);
        vault.deposit(deposit0, deposit1);
        vm.stopPrank();

        vm.startPrank(executor);
        (, int24 currentTick,,,,,) = pool.slot0();
        int24 lowerTick = currentTick - 6000;
        int24 upperTick = currentTick + 6000;

        uint256 amount0Desired = 0.5 ether;
        uint256 amount1Desired = 0.5 ether;

        MinimalMintParams memory mintParams = MinimalMintParams({
            tickLower: lowerTick,
            tickUpper: upperTick,
            amount0Desired: amount0Desired,
            amount1Desired: amount1Desired,
            amount0Min: 0.5 ether,
            amount1Min: 0.5 ether,
            deadline: block.timestamp
        });
        vm.stopPrank();

        vm.startPrank(makeAddr("SomeRandomDude"));
        vm.expectRevert(SingleVault.Unauthorized.selector);
        vault.mint(mintParams);
        vm.stopPrank();
    }

    function testMintDeadlinePassed() public {
        uint256 deposit0 = 1 ether;
        uint256 deposit1 = 3 ether;

        vm.startPrank(vaultOwner);
        vault.deposit(deposit0, deposit1);
        vm.stopPrank();

        vm.startPrank(executor);
        (, int24 currentTick,,,,,) = pool.slot0();
        int24 lowerTick = currentTick - 6000;
        int24 upperTick = currentTick + 6000;

        uint256 amount0Desired = 0.5 ether;
        uint256 amount1Desired = 0.5 ether;

        uint256 deadline = block.timestamp + 5;

        MinimalMintParams memory mintParams = MinimalMintParams({
            tickLower: lowerTick,
            tickUpper: upperTick,
            amount0Desired: amount0Desired,
            amount1Desired: amount1Desired,
            amount0Min: 0.5 ether,
            amount1Min: 0.5 ether,
            deadline: deadline
        });
        vm.stopPrank();

        vm.warp(deadline + 1);

        vm.startPrank(executor);
        vm.expectRevert("Transaction too old");
        vault.mint(mintParams);
        vm.stopPrank();
    }

    function testUniswapV3MintCallbackAsNotPool() public {
        MintCallbackData memory mintCallbackData = MintCallbackData({
            poolKey: PoolAddress.PoolKey({token0: address(token0), token1: address(token1), fee: pool.fee()}),
            payer: address(vault)
        });

        // call as not pool
        vm.startPrank(makeAddr("random user"));
        vm.expectRevert(UniV3LpVault.NotPool.selector);
        vault.uniswapV3MintCallback(0, 0, abi.encode(mintCallbackData));
        vm.stopPrank();
    }

    function testUniswapV3MintCallbackAsWrongPayer() public {
        MintCallbackData memory mintCallbackData = MintCallbackData({
            poolKey: PoolAddress.PoolKey({token0: address(token0), token1: address(token1), fee: pool.fee()}),
            payer: address(makeAddr("wrong payer"))
        });

        // call as not pool
        vm.startPrank(address(pool));
        vm.expectRevert(UniV3LpVault.WrongPayer.selector);
        vault.uniswapV3MintCallback(0, 0, abi.encode(mintCallbackData));
        vm.stopPrank();
    }
}
