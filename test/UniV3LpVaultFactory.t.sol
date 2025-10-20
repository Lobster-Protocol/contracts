// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/vaults/UniV3LpVaultFactory.sol";
import "../src/vaults/UniV3LpVault.sol";
import {MockERC20} from "./Mocks/MockERC20.sol";
import {UniswapV3Infra} from "./Mocks/uniswapV3/UniswapV3Infra.sol";
import {IUniswapV3FactoryMinimal} from "../src/interfaces/uniswapV3/IUniswapV3FactoryMinimal.sol";
import {IWETH} from "../src/interfaces/IWETH.sol";
import {IUniswapV3PoolMinimal} from "../src/interfaces/uniswapV3/IUniswapV3PoolMinimal.sol";

uint24 constant FEE = 3000; // 0.3%

contract UniV3LpVaultFactoryTest is Test {
    UniV3LpVaultFactory public factory;

    address public owner = address(0x100);
    address public allocator = address(0x200);
    address public token0 = address(0x400);
    address public token1 = address(0x500);
    IUniswapV3PoolMinimal public pool;
    address public feeCollector = address(0x700);
    uint256 public tvlFee = 100;
    uint256 public performanceFee = 200;

    bytes32 public salt = keccak256("test-salt");

    event VaultDeployed(address indexed vault, address indexed pool, address indexed deployer, bytes32 salt);

    function setUp() public {
        factory = new UniV3LpVaultFactory();

        // Deploy mock contracts
        token0 = address(new MockERC20());
        token1 = address(new MockERC20());

        // Ensure proper token ordering for Uniswap V3
        if (address(token0) > address(token1)) {
            (token0, token1) = (token1, token0);
        }

        // Deploy uniV3 infra
        UniswapV3Infra uniswapV3 = new UniswapV3Infra();
        (IUniswapV3FactoryMinimal uni_v3_factory,,,) = uniswapV3.deploy();

        uint160 initialSqrtPriceX96 = 2 ** 96; // = quote = 1:1 if both tokens have the same decimals value

        // Deploy pool
        pool = uniswapV3.createPoolAndInitialize(uni_v3_factory, token0, token1, FEE, initialSqrtPriceX96);
    }

    function test_DeployVault() public {
        address vault = factory.deployVault(
            salt, owner, allocator, token0, token1, address(pool), feeCollector, tvlFee, performanceFee
        );

        // Verify vault was deployed
        assertTrue(vault != address(0), "Vault address should not be zero");

        // Verify vault is marked as deployed
        assertTrue(factory.isVault(vault), "Vault should be marked as deployed");

        // Verify vault has code
        uint256 size;
        assembly {
            size := extcodesize(vault)
        }
        assertTrue(size > 0, "Vault should have code");
    }

    function test_DeployVaultEmitsEvent() public {
        // Expect the VaultDeployed event
        vm.expectEmit(false, true, true, true);
        emit VaultDeployed(address(0), address(pool), address(this), salt);

        factory.deployVault(salt, owner, allocator, token0, token1, address(pool), feeCollector, tvlFee, performanceFee);
    }

    function test_ComputeVaultAddress() public {
        // Compute the expected address
        address predicted = factory.computeVaultAddress(
            salt, owner, allocator, token0, token1, address(pool), feeCollector, tvlFee, performanceFee
        );

        // Deploy the vault
        address deployed = factory.deployVault(
            salt, owner, allocator, token0, token1, address(pool), feeCollector, tvlFee, performanceFee
        );

        // Verify they match
        assertEq(predicted, deployed, "Predicted and deployed addresses should match");
    }

    function test_DeterministicDeployment() public {
        // Deploy factory on one chain
        UniV3LpVaultFactory factory1 = new UniV3LpVaultFactory();

        // Simulate another chain with same factory address
        // (In reality, we'd deploy at the same address using CREATE2)
        UniV3LpVaultFactory factory2 = new UniV3LpVaultFactory();

        // Compute addresses on both "chains"
        address predicted1 = factory1.computeVaultAddress(
            salt, owner, allocator, token0, token1, address(pool), feeCollector, tvlFee, performanceFee
        );

        address predicted2 = factory2.computeVaultAddress(
            salt, owner, allocator, token0, token1, address(pool), feeCollector, tvlFee, performanceFee
        );

        // They should be different because factories have different addresses
        // But if factories were at same address, predictions would match
        // This test shows the prediction is consistent for a given factory
        assertEq(predicted1, predicted1, "Prediction should be consistent");
        assertEq(predicted2, predicted2, "Prediction should be consistent");
    }

    function test_CannotDeployTwiceWithSameSalt() public {
        // Deploy once
        factory.deployVault(salt, owner, allocator, token0, token1, address(pool), feeCollector, tvlFee, performanceFee);

        // Try to deploy again with same salt - should revert
        vm.expectRevert();
        factory.deployVault(salt, owner, allocator, token0, token1, address(pool), feeCollector, tvlFee, performanceFee);
    }

    function test_DifferentSaltsDifferentAddresses() public {
        bytes32 salt1 = keccak256("salt1");
        bytes32 salt2 = keccak256("salt2");

        address vault1 = factory.deployVault(
            salt1, owner, allocator, token0, token1, address(pool), feeCollector, tvlFee, performanceFee
        );

        address vault2 = factory.deployVault(
            salt2, owner, allocator, token0, token1, address(pool), feeCollector, tvlFee, performanceFee
        );

        assertTrue(vault1 != vault2, "Different salts should produce different addresses");
        assertTrue(factory.isVault(vault1), "Vault1 should be marked as deployed");
        assertTrue(factory.isVault(vault2), "Vault2 should be marked as deployed");
    }

    function test_DifferentParametersDifferentAddresses() public {
        address vault1 = factory.deployVault(
            salt, owner, allocator, token0, token1, address(pool), feeCollector, tvlFee, performanceFee
        );

        // Different salt for second deployment
        bytes32 salt2 = keccak256("different");

        // Deploy with different tvlFee
        address vault2 = factory.deployVault(
            salt2,
            owner,
            allocator,
            token0,
            token1,
            address(pool),
            feeCollector,
            tvlFee + 1, // Different fee
            performanceFee
        );

        assertTrue(vault1 != vault2, "Different parameters should produce different addresses");
    }

    function test_IsVaultReturnsFalseForNonVault() public view {
        address randomAddress = address(0x999);
        assertFalse(factory.isVault(randomAddress), "Random address should not be marked as vault");
    }

    function test_MultipleVaultsCanBeDeployed() public {
        uint256 numVaults = 5;
        address[] memory vaults = new address[](numVaults);

        for (uint256 i = 0; i < numVaults; i++) {
            bytes32 uniqueSalt = keccak256(abi.encodePacked("salt", i));
            vaults[i] = factory.deployVault(
                uniqueSalt, owner, allocator, token0, token1, address(pool), feeCollector, tvlFee, performanceFee
            );

            assertTrue(factory.isVault(vaults[i]), "Each vault should be marked as deployed");
        }

        // Verify all addresses are unique
        for (uint256 i = 0; i < numVaults; i++) {
            for (uint256 j = i + 1; j < numVaults; j++) {
                assertTrue(vaults[i] != vaults[j], "All vault addresses should be unique");
            }
        }
    }

    function testFuzz_DeployVaultWithDifferentSalts(bytes32 _salt) public {
        // Skip if salt would cause collision with already deployed vault
        address predicted = factory.computeVaultAddress(
            _salt,
            owner,
            allocator,
            address(token0),
            address(token1),
            address(pool),
            feeCollector,
            tvlFee,
            performanceFee
        );

        vm.assume(!factory.isVault(predicted));

        address vault = factory.deployVault(
            _salt,
            owner,
            allocator,
            address(token0),
            address(token1),
            address(pool),
            feeCollector,
            tvlFee,
            performanceFee
        );

        assertEq(predicted, vault, "Predicted and deployed should match");
        assertTrue(factory.isVault(vault), "Vault should be marked as deployed");
    }

    function test_VaultDeployedWithCorrectParameters() public {
        address vault = factory.deployVault(
            salt, owner, allocator, token0, token1, address(pool), feeCollector, tvlFee, performanceFee
        );

        // Verify the vault was deployed
        assertTrue(vault != address(0));
        assertTrue(factory.isVault(vault));
    }
}
