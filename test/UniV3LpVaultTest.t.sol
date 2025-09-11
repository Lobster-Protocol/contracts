// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.20;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import {UniV3LpVault} from "../src/vaults/UniV3LpVault.sol";
import {IWETH} from "../src/interfaces/IWETH.sol";
import {MockERC20} from "./Mocks/MockERC20.sol";
import {UniswapV3Infra} from "./Mocks/uniswapV3/UniswapV3Infra.sol";
import {IUniswapV3FactoryMinimal} from "../src/interfaces/uniswapV3/IUniswapV3FactoryMinimal.sol";
import {IUniswapV3PoolMinimal} from "../src/interfaces/uniswapV3/IUniswapV3PoolMinimal.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";

uint24 constant FEE = 3000; // 0.3%

contract UniV3LpVaultTest is Test {
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
}
