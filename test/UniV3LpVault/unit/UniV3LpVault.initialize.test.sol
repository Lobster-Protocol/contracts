// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import {UniV3LpVault} from "../../../src/vaults/uniV3LpVault/UniV3LpVault.sol";
import {MAX_FEE_SCALED} from "../../../src/vaults/uniV3LpVault/constants.sol";
import {SingleVault} from "../../../src/vaults/SingleVault.sol";
import {TestHelper} from "../helpers/TestHelper.sol";
import {TestConstants} from "../helpers/Constants.sol";
import {MockERC20} from "../../Mocks/MockERC20.sol";
import {UniswapV3Infra} from "../../Mocks/uniswapV3/UniswapV3Infra.sol";
import {IUniswapV3FactoryMinimal} from "../../../src/interfaces/uniswapV3/IUniswapV3FactoryMinimal.sol";
import {IUniswapV3PoolMinimal} from "../../../src/interfaces/uniswapV3/IUniswapV3PoolMinimal.sol";
import {UniV3LpVaultFactory} from "../../../src/vaults/uniV3LpVault/UniV3LpVaultFactory.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";

contract UniV3LpVaultInitializeTest is Test {
    TestHelper helper;

    function setUp() public {
        helper = new TestHelper();
    }

    function test_initialize_ValidParameters_Success() public {
        TestHelper.VaultSetup memory setup =
            helper.deployVaultWithPool(TestConstants.HIGH_TVL_FEE, TestConstants.HIGH_PERF_FEE);

        // Verify all state variables are set correctly
        assertEq(setup.vault.owner(), setup.owner);
        assertEq(setup.vault.allocator(), setup.allocator);
        assertEq(address(setup.vault.TOKEN0()), address(setup.token0));
        assertEq(address(setup.vault.TOKEN1()), address(setup.token1));
        assertEq(address(setup.vault.POOL()), address(setup.pool));
        assertEq(setup.vault.tvlFeeCollectedAt(), 1209601);
        assertEq(setup.vault.tvlFeeScaled(), TestConstants.HIGH_TVL_FEE);
        assertEq(setup.vault.performanceFeeScaled(), TestConstants.HIGH_PERF_FEE);
        assertEq(setup.vault.feeCollector(), setup.feeCollector);
    }

    function test_initialize_WrongTokenOrder_Reverts() public {
        address owner = makeAddr("owner");
        address allocator = makeAddr("allocator");
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

        address vaultImplementation = address(new UniV3LpVault());
        UniV3LpVaultFactory vaultFactory = new UniV3LpVaultFactory(vaultImplementation, address(1), 0);

        // Try to create vault with wrong token order
        vm.expectRevert("Wrong token 0 & 1 order");
        UniV3LpVault(
            vaultFactory.deployVault(
                bytes32(0),
                owner,
                allocator,
                address(token1), // Wrong order
                address(token0), // Wrong order
                address(pool),
                feeCollector,
                TestConstants.LOW_TVL_FEE,
                TestConstants.LOW_PERF_FEE,
                TestConstants.DELTA5050
            )
        );
    }

    function test_initialize_ZeroFeeCollector_Reverts() public {
        address owner = makeAddr("owner");
        address allocator = makeAddr("allocator");

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

        // Deploy vault
        address vaultImplementation = address(new UniV3LpVault());
        UniV3LpVaultFactory vaultFactory = new UniV3LpVaultFactory(vaultImplementation, address(1), 0);

        vm.expectRevert(SingleVault.ZeroAddress.selector);
        UniV3LpVault(
            vaultFactory.deployVault(
                bytes32(0),
                owner,
                allocator,
                address(token0),
                address(token1),
                address(pool),
                address(0), // Zero address
                TestConstants.LOW_TVL_FEE,
                TestConstants.LOW_PERF_FEE,
                TestConstants.DELTA5050
            )
        );
    }

    function test_initialize_TokenMismatch_Reverts() public {
        address owner = makeAddr("owner");
        address allocator = makeAddr("allocator");
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

        // Deploy vault
        address vaultImplementation = address(new UniV3LpVault());
        UniV3LpVaultFactory vaultFactory = new UniV3LpVaultFactory(vaultImplementation, address(1), 0);

        vm.expectRevert("Token mismatch");
        UniV3LpVault(
            vaultFactory.deployVault(
                bytes32(0),
                owner,
                allocator,
                address(wrongToken), // Wrong token
                address(token1),
                address(pool),
                feeCollector,
                0,
                0,
                TestConstants.DELTA5050
            )
        );
    }

    function test_initialize_InitialState_Correct() public {
        TestHelper.VaultSetup memory setup =
            helper.deployVaultWithPool(TestConstants.MEDIUM_TVL_FEE, TestConstants.MEDIUM_PERF_FEE);

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

    function test_initialize_ZeroFee_Success() public {
        TestHelper.VaultSetup memory setup = helper.deployVaultWithPool(0, 0);

        // Zero TVL fee should be allowed
        assertTrue(address(setup.vault) != address(0));
    }

    function test_initialize_twice() public {
        TestHelper.VaultSetup memory setup = helper.deployVaultWithPool(0, 0);

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        setup.vault
            .initialize(
                setup.owner,
                setup.allocator,
                address(setup.token0),
                address(setup.token1),
                address(setup.pool),
                setup.feeCollector,
                address(0),
                0,
                0,
                0,
                TestConstants.DELTA5050
            );
    }

    function test_initializeImplementation() public {
        TestHelper.VaultSetup memory setup = helper.deployVaultWithPool(0, 0);
        UniV3LpVault vault = new UniV3LpVault();

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        vault.initialize(
            address(1),
            address(1),
            address(setup.token0),
            address(setup.token1),
            address(setup.pool),
            address(1),
            address(1),
            0,
            0,
            0,
            5e17
        );
    }

    function test_initializeWithFeesTooHigh() public {
        vm.expectRevert(abi.encodePacked("Fees > max"));
        helper.deployVaultWithPool(MAX_FEE_SCALED + 1, 0);

        vm.expectRevert(abi.encodePacked("Fees > max"));
        helper.deployVaultWithPool(0, MAX_FEE_SCALED + 1);
    }
}
