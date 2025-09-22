// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import {UniV3LpVault} from "../../../src/vaults/UniV3LpVault.sol";
import {SingleVault} from "../../../src/vaults/SingleVault.sol";
import {TestHelper} from "../helpers/TestHelper.sol";
import {TestConstants} from "../helpers/Constants.sol";
import {MockERC20} from "../../Mocks/MockERC20.sol";
import {UniswapV3Infra} from "../../Mocks/uniswapV3/UniswapV3Infra.sol";
import {IUniswapV3FactoryMinimal} from "../../../src/interfaces/uniswapV3/IUniswapV3FactoryMinimal.sol";
import {IUniswapV3PoolMinimal} from "../../../src/interfaces/uniswapV3/IUniswapV3PoolMinimal.sol";

contract UniV3LpVaultConstructorTest is Test {
    TestHelper helper;

    function setUp() public {
        helper = new TestHelper();
    }

    function test_constructor_ValidParameters_Success() public {
        TestHelper.VaultSetup memory setup = helper.deployVaultWithPool();

        // Verify all state variables are set correctly
        assertEq(setup.vault.owner(), setup.owner);
        assertEq(setup.vault.executor(), setup.executor);
        assertEq(setup.vault.executorManager(), setup.executorManager);
        assertEq(address(setup.vault.token0()), address(setup.token0));
        assertEq(address(setup.vault.token1()), address(setup.token1));
        assertEq(address(setup.vault.pool()), address(setup.pool));
        assertEq(setup.vault.pool().fee(), TestConstants.POOL_FEE);
    }

    function test_constructor_WithDifferentTvlFee_Success() public {
        TestHelper.VaultSetup memory setup = helper.deployVaultWithPool(TestConstants.HIGH_TVL_FEE);

        // Vault should be deployed successfully
        assertTrue(address(setup.vault) != address(0));
    }

    function test_constructor_WrongTokenOrder_Reverts() public {
        address owner = makeAddr("owner");
        address executor = makeAddr("executor");
        address executorManager = makeAddr("executorManager");
        address feeCollector = makeAddr("feeCollector");

        MockERC20 token0 = new MockERC20();
        MockERC20 token1 = new MockERC20();

        // Create pool with correct order
        UniswapV3Infra uniswapV3 = new UniswapV3Infra();
        (IUniswapV3FactoryMinimal factory,,,) = uniswapV3.deploy();

        // Ensure token0 < token1 for pool creation
        if (address(token0) > address(token1)) {
            (token0, token1) = (token1, token0);
        }

        IUniswapV3PoolMinimal pool = uniswapV3.createPoolAndInitialize(
            factory, address(token0), address(token1), TestConstants.POOL_FEE, TestConstants.INITIAL_SQRT_PRICE_X96
        );

        // Try to create vault with wrong token order
        vm.expectRevert("Wrong token 0 & 1 order");
        new UniV3LpVault(
            owner,
            executor,
            executorManager,
            address(token1), // Wrong order
            address(token0), // Wrong order
            address(pool),
            feeCollector,
            TestConstants.LOW_TVL_FEE
        );
    }

    function test_constructor_ZeroFeeCollector_Reverts() public {
        address owner = makeAddr("owner");
        address executor = makeAddr("executor");
        address executorManager = makeAddr("executorManager");

        MockERC20 token0 = new MockERC20();
        MockERC20 token1 = new MockERC20();

        if (address(token0) > address(token1)) {
            (token0, token1) = (token1, token0);
        }

        UniswapV3Infra uniswapV3 = new UniswapV3Infra();
        (IUniswapV3FactoryMinimal factory,,,) = uniswapV3.deploy();

        IUniswapV3PoolMinimal pool = uniswapV3.createPoolAndInitialize(
            factory, address(token0), address(token1), TestConstants.POOL_FEE, TestConstants.INITIAL_SQRT_PRICE_X96
        );

        vm.expectRevert(SingleVault.ZeroAddress.selector);
        new UniV3LpVault(
            owner,
            executor,
            executorManager,
            address(token0),
            address(token1),
            address(pool),
            address(0), // Zero address
            TestConstants.LOW_TVL_FEE
        );
    }

    function test_constructor_TokenMismatch_Reverts() public {
        address owner = makeAddr("owner");
        address executor = makeAddr("executor");
        address executorManager = makeAddr("executorManager");
        address feeCollector = makeAddr("feeCollector");

        MockERC20 token0 = new MockERC20();
        MockERC20 token1 = new MockERC20();
        MockERC20 wrongToken = new MockERC20();

        if (address(token0) > address(token1)) {
            (token0, token1) = (token1, token0);
        }

        UniswapV3Infra uniswapV3 = new UniswapV3Infra();
        (IUniswapV3FactoryMinimal factory,,,) = uniswapV3.deploy();

        IUniswapV3PoolMinimal pool = uniswapV3.createPoolAndInitialize(
            factory, address(token0), address(token1), TestConstants.POOL_FEE, TestConstants.INITIAL_SQRT_PRICE_X96
        );

        vm.expectRevert("Token mismatch");
        new UniV3LpVault(
            owner,
            executor,
            executorManager,
            address(wrongToken), // Wrong token
            address(token1),
            address(pool),
            feeCollector,
            TestConstants.LOW_TVL_FEE
        );
    }

    function test_constructor_InitialState_Correct() public {
        TestHelper.VaultSetup memory setup = helper.deployVaultWithPool(TestConstants.MEDIUM_TVL_FEE);

        // Check that TVL fee collection timestamp is set to current block timestamp
        // Note: This would require making tvlFeeCollectedAt public or adding a getter

        // Check that no positions exist initially
        vm.expectRevert();
        setup.vault.getPosition(0);

        // Check that total LP value is zero
        (uint256 totalAssets0, uint256 totalAssets1) = setup.vault.totalLpValue();
        assertEq(totalAssets0, 0);
        assertEq(totalAssets1, 0);

        // Check net assets value is zero (no deposits yet)
        (uint256 netAssets0, uint256 netAssets1) = setup.vault.netAssetsValue();
        assertEq(netAssets0, 0);
        assertEq(netAssets1, 0);
    }

    function test_constructor_MaxTvlFee_Success() public {
        TestHelper.VaultSetup memory setup = helper.deployVaultWithPool(TestConstants.MAX_SCALED_PERCENTAGE);

        // Should not revert - 100% TVL fee is technically allowed (though impractical)
        assertTrue(address(setup.vault) != address(0));
    }

    function test_constructor_ZeroTvlFee_Success() public {
        TestHelper.VaultSetup memory setup = helper.deployVaultWithPool(0);

        // Zero TVL fee should be allowed
        assertTrue(address(setup.vault) != address(0));
    }
}
