// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.20;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import {UniswapV3Proxy, MintParams, MintCallbackData} from "../src/UniswapV3Proxy.sol";
import {MockERC20} from "./Mocks/MockERC20.sol";
import {IUniswapV3PoolMinimal} from "../src/interfaces/uniswapV3/IUniswapV3PoolMinimal.sol";
import {PoolAddress} from "../src/libraries/uniswapV3/PoolAddress.sol";
import {UniswapV3Infra} from "./Mocks/uniswapV3/UniswapV3Infra.sol";
import {IUniswapV3FactoryMinimal} from "../src/interfaces/uniswapV3/IUniswapV3FactoryMinimal.sol";
import {IWETH} from "../src/interfaces/IWETH.sol";
import {INonFungiblePositionManager} from "../src/interfaces/uniswapV3/INonFungiblePositionManager.sol";
import {TickMath} from "../src/libraries/uniswapV3/TickMath.sol";

contract UniswapV3ProxyTest is Test {
    UniswapV3Proxy public proxy;
    IWETH public weth;
    MockERC20 public token0;
    MockERC20 public token1;
    IUniswapV3PoolMinimal public pool;
    IUniswapV3PoolMinimal public poolWithWeth;

    address public user = makeAddr("user");
    address public recipient = makeAddr("recipient");

    uint24 constant FEE = 3000; // 0.3%
    int24 constant TICK_LOWER = -60;
    int24 constant TICK_UPPER = 60;
    uint256 constant AMOUNT_DESIRED = 1000e18;
    uint256 constant AMOUNT_MIN = 900e18;

    function setUp() public {
        // Deploy mock contracts
        token0 = new MockERC20();
        token1 = new MockERC20();

        // Ensure proper token ordering for Uniswap V3
        if (address(token0) > address(token1)) {
            (token0, token1) = (token1, token0);
        }

        // Deploy uniV3 infra
        UniswapV3Infra uniswapV3 = new UniswapV3Infra();
        (IUniswapV3FactoryMinimal factory, IWETH weth_,,) = uniswapV3.deploy();
        weth = weth_;

        uint160 initialSqrtPriceX96 = 2 ** 96; // = quote = 1:1 if both tokens have the same decimals value

        // Deploy pool
        pool = uniswapV3.createPoolAndInitialize(factory, address(token0), address(token1), FEE, initialSqrtPriceX96);

        poolWithWeth =
            uniswapV3.createPoolAndInitialize(factory, address(weth), address(token1), FEE, initialSqrtPriceX96);

        // Deploy proxy
        proxy = new UniswapV3Proxy(address(factory));

        // Setup user balances
        vm.deal(user, 10_000 ether);
        token0.mint(user, AMOUNT_DESIRED * 2);
        token1.mint(user, AMOUNT_DESIRED * 2);

        // Approve proxy to spend tokens
        vm.startPrank(user);
        token0.approve(address(proxy), type(uint256).max);
        token1.approve(address(proxy), type(uint256).max);
        weth.approve(address(proxy), type(uint256).max);
        vm.stopPrank();
    }

    function testConstructor() public view {
        assertEq(proxy.UNI_V3_FACTORY(), address(pool.factory()));
    }

    function testMintSuccess() public {
        MintParams memory params = MintParams({
            token0: address(token0),
            token1: address(token1),
            fee: FEE,
            tickLower: TICK_LOWER,
            tickUpper: TICK_UPPER,
            amount0Desired: AMOUNT_DESIRED,
            amount1Desired: AMOUNT_DESIRED,
            amount0Min: AMOUNT_MIN,
            amount1Min: AMOUNT_MIN,
            recipient: recipient,
            deadline: block.timestamp + 3600
        });

        uint256 token0BalanceBefore = token0.balanceOf(user);
        uint256 token1BalanceBefore = token1.balanceOf(user);

        vm.prank(user);
        (uint256 amount0, uint256 amount1) = proxy.mint(params);

        // Check that amounts were returned
        assertTrue(amount0 > 0);
        assertTrue(amount1 > 0);

        // Check that tokens were transferred from user
        assertTrue(token0.balanceOf(user) < token0BalanceBefore);
        assertTrue(token1.balanceOf(user) < token1BalanceBefore);

        // Check slippage protection
        assertTrue(amount0 >= params.amount0Min);
        assertTrue(amount1 >= params.amount1Min);
    }

    function testMintWithDeadlineExpired() public {
        MintParams memory params = MintParams({
            token0: address(token0),
            token1: address(token1),
            fee: FEE,
            tickLower: TICK_LOWER,
            tickUpper: TICK_UPPER,
            amount0Desired: AMOUNT_DESIRED,
            amount1Desired: AMOUNT_DESIRED,
            amount0Min: AMOUNT_MIN,
            amount1Min: AMOUNT_MIN,
            recipient: recipient,
            deadline: block.timestamp - 1 // Expired deadline
        });

        vm.prank(user);
        vm.expectRevert("Transaction too old");
        proxy.mint(params);
    }

    function testMintWithSlippageProtection() public {
        MintParams memory params = MintParams({
            token0: address(token0),
            token1: address(token1),
            fee: FEE,
            tickLower: TICK_LOWER,
            tickUpper: TICK_UPPER,
            amount0Desired: AMOUNT_DESIRED,
            amount1Desired: AMOUNT_DESIRED,
            amount0Min: type(uint256).max, // Impossible minimum
            amount1Min: type(uint256).max, // Impossible minimum
            recipient: recipient,
            deadline: block.timestamp + 3600
        });

        vm.prank(user);
        vm.expectRevert("Price slippage check");
        proxy.mint(params);
    }
}
