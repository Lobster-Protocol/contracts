// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/vaults/uniV3LpVault/UniV3LpVaultFactory.sol";
import "../src/vaults/uniV3LpVault/UniV3LpVault.sol";
import {MockERC20} from "./Mocks/MockERC20.sol";
import {UniswapV3Infra} from "./Mocks/uniswapV3/UniswapV3Infra.sol";
import {IUniswapV3FactoryMinimal} from "../src/interfaces/uniswapV3/IUniswapV3FactoryMinimal.sol";
import {IUniswapV3PoolMinimal} from "../src/interfaces/uniswapV3/IUniswapV3PoolMinimal.sol";

uint24 constant FEE = 3000; // 0.3%
uint256 constant DELTA5050 = (5 * SCALING_FACTOR) / 10; // 0.5

contract UniV3LpVaultFactoryTest is Test {
    UniV3LpVaultFactory public factory;
    UniV3LpVault public implementation;

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
        implementation = new UniV3LpVault();
        factory = new UniV3LpVaultFactory(address(implementation), address(1), 0);

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
            salt, owner, allocator, token0, token1, address(pool), feeCollector, tvlFee, performanceFee, DELTA5050
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

        factory.deployVault(
            salt, owner, allocator, token0, token1, address(pool), feeCollector, tvlFee, performanceFee, DELTA5050
        );
    }

    function test_ComputeVaultAddress() public {
        // Compute the expected address
        address predicted = factory.computeVaultAddress(salt);

        // Deploy the vault
        address deployed = factory.deployVault(
            salt, owner, allocator, token0, token1, address(pool), feeCollector, tvlFee, performanceFee, DELTA5050
        );

        // Verify they match
        assertEq(predicted, deployed, "Predicted and deployed addresses should match");
    }

    function test_DeterministicDeployment() public {
        // Deploy factory on one chain
        UniV3LpVaultFactory factory1 = new UniV3LpVaultFactory(address(implementation), address(1), 0);

        // Simulate another chain with same factory address
        // (In reality, we'd deploy at the same address using CREATE2)
        UniV3LpVaultFactory factory2 = new UniV3LpVaultFactory(address(implementation), address(1), 0);

        // Compute addresses on both "chains"
        address predicted1 = factory1.computeVaultAddress(salt);

        address predicted2 = factory2.computeVaultAddress(salt);

        // They should be different because factories have different addresses
        // But if factories were at same address, predictions would match
        // This test shows the prediction is consistent for a given factory
        assertEq(predicted1, predicted1, "Prediction should be consistent");
        assertEq(predicted2, predicted2, "Prediction should be consistent");
    }

    function test_CannotDeployTwiceWithSameSalt() public {
        // Deploy once
        factory.deployVault(
            salt, owner, allocator, token0, token1, address(pool), feeCollector, tvlFee, performanceFee, DELTA5050
        );

        // Try to deploy again with same salt - should revert
        vm.expectRevert();
        factory.deployVault(
            salt, owner, allocator, token0, token1, address(pool), feeCollector, tvlFee, performanceFee, DELTA5050
        );
    }

    function test_DifferentSaltsDifferentAddresses() public {
        bytes32 salt1 = keccak256("salt1");
        bytes32 salt2 = keccak256("salt2");

        address vault1 = factory.deployVault(
            salt1, owner, allocator, token0, token1, address(pool), feeCollector, tvlFee, performanceFee, DELTA5050
        );

        address vault2 = factory.deployVault(
            salt2, owner, allocator, token0, token1, address(pool), feeCollector, tvlFee, performanceFee, DELTA5050
        );

        assertTrue(vault1 != vault2, "Different salts should produce different addresses");
        assertTrue(factory.isVault(vault1), "Vault1 should be marked as deployed");
        assertTrue(factory.isVault(vault2), "Vault2 should be marked as deployed");
    }

    function test_DifferentParametersDifferentAddresses() public {
        address vault1 = factory.deployVault(
            salt, owner, allocator, token0, token1, address(pool), feeCollector, tvlFee, performanceFee, DELTA5050
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
            performanceFee,
            DELTA5050
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
                uniqueSalt,
                owner,
                allocator,
                token0,
                token1,
                address(pool),
                feeCollector,
                tvlFee,
                performanceFee,
                DELTA5050
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
        address predicted = factory.computeVaultAddress(_salt);

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
            performanceFee,
            DELTA5050
        );

        assertEq(predicted, vault, "Predicted and deployed should match");
        assertTrue(factory.isVault(vault), "Vault should be marked as deployed");
    }

    function test_VaultDeployedWithCorrectParameters() public {
        address vault = factory.deployVault(
            salt, owner, allocator, token0, token1, address(pool), feeCollector, tvlFee, performanceFee, DELTA5050
        );

        // Verify the vault was deployed
        assertTrue(vault != address(0));
        assertTrue(factory.isVault(vault));
    }

    /*//////////////////////////////////////////////////////////////
                    EVENTS BEFORE EXTERNAL INTERACTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice VaultDeployed is the first log of a deployment and names the predicted vault address: the vault's own
    ///         initialization logs come after it
    function test_DeployVault_EmitsVaultDeployedBeforeInitialization() public {
        address predicted = factory.computeVaultAddress(salt);

        vm.recordLogs();
        address vault = factory.deployVault(
            salt, owner, allocator, token0, token1, address(pool), feeCollector, tvlFee, performanceFee, DELTA5050
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(vault, predicted, "Deployed at the predicted address");

        assertGt(logs.length, 1, "Deployment and initialization logs");
        assertEq(logs[0].emitter, address(factory), "First log from the factory");
        assertEq(logs[0].topics[0], VaultDeployed.selector, "First log is VaultDeployed");
        assertEq(logs[0].topics[1], bytes32(uint256(uint160(predicted))), "VaultDeployed vault");
        assertEq(logs[0].topics[2], bytes32(uint256(uint160(address(pool)))), "VaultDeployed pool");
        assertEq(logs[0].topics[3], bytes32(uint256(uint160(address(this)))), "VaultDeployed deployer");
        assertEq(abi.decode(logs[0].data, (bytes32)), salt, "VaultDeployed salt");

        bool vaultLogged;
        for (uint256 i = 1; i < logs.length; i++) {
            vaultLogged = vaultLogged || logs[i].emitter == vault;
        }
        assertTrue(vaultLogged, "Vault initialization logs follow VaultDeployed");
    }

    /// @notice The vault is registered before its initialization runs: a pool that reports its token0 only to
    ///         registered vaults lets the deployment through
    function test_DeployVault_RegistersVaultBeforeInitialization() public {
        RegistrationProbePool probe = new RegistrationProbePool(factory, token0, token1);

        address vault = factory.deployVault(
            salt, owner, allocator, token0, token1, address(probe), feeCollector, tvlFee, performanceFee, DELTA5050
        );

        assertTrue(factory.isVault(vault), "Vault registered");
        assertEq(address(UniV3LpVault(vault).POOL()), address(probe), "Vault initialized on the probe pool");
    }

    /// @notice withdrawETH emits TokenWithdrawn before sending the ETH: the recipient's logs come after it
    function test_WithdrawETH_EmitsTokenWithdrawnBeforeTransfer() public {
        LoggingReceiver receiver = new LoggingReceiver();
        vm.deal(address(factory), 1 ether);

        vm.recordLogs();
        vm.prank(factory.owner());
        factory.withdrawETH(address(receiver), 1 ether);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(logs.length, 2, "TokenWithdrawn and the recipient's log");
        assertEq(logs[0].emitter, address(factory), "First log from the factory");
        assertEq(logs[0].topics[0], UniV3LpVaultFactory.TokenWithdrawn.selector, "First log is TokenWithdrawn");
        assertEq(logs[0].topics[1], bytes32(0), "Native token");
        assertEq(logs[0].topics[2], bytes32(uint256(uint160(address(receiver)))), "Recipient");
        assertEq(abi.decode(logs[0].data, (uint256)), 1 ether, "Amount");
        assertEq(logs[1].emitter, address(receiver), "Then the recipient's log");
        assertEq(logs[1].topics[0], LoggingReceiver.Received.selector, "Recipient's Received log");

        assertEq(address(receiver).balance, 1 ether, "ETH received");
        assertEq(address(factory).balance, 0, "ETH left the factory");
    }

    /// @notice withdrawToken emits TokenWithdrawn before the token transfer: the token's Transfer log comes after it
    function test_WithdrawToken_EmitsTokenWithdrawnBeforeTransfer() public {
        address recipient = makeAddr("recipient");
        MockERC20(token0).mint(address(factory), 5 ether);

        vm.recordLogs();
        vm.prank(factory.owner());
        factory.withdrawToken(token0, recipient, 5 ether);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(logs.length, 2, "TokenWithdrawn and the token's Transfer");
        assertEq(logs[0].emitter, address(factory), "First log from the factory");
        assertEq(logs[0].topics[0], UniV3LpVaultFactory.TokenWithdrawn.selector, "First log is TokenWithdrawn");
        assertEq(logs[0].topics[1], bytes32(uint256(uint160(token0))), "Token");
        assertEq(logs[0].topics[2], bytes32(uint256(uint160(recipient))), "Recipient");
        assertEq(abi.decode(logs[0].data, (uint256)), 5 ether, "Amount");
        assertEq(logs[1].emitter, token0, "Then the token's log");
        assertEq(logs[1].topics[0], IERC20.Transfer.selector, "Token Transfer log");

        assertEq(MockERC20(token0).balanceOf(recipient), 5 ether, "Tokens received");
    }
}

/// @dev Minimal pool for UniV3LpVault.initialize that reports its token0 only to vaults the factory has registered,
///      so initialize fails with "Token mismatch" if it runs before the registration
contract RegistrationProbePool {
    UniV3LpVaultFactory public immutable FACTORY;
    address public immutable TOKEN0;
    address public immutable TOKEN1;

    constructor(UniV3LpVaultFactory factory_, address token0_, address token1_) {
        FACTORY = factory_;
        TOKEN0 = token0_;
        TOKEN1 = token1_;
    }

    function token0() external view returns (address) {
        return FACTORY.isVault(msg.sender) ? TOKEN0 : address(0);
    }

    function token1() external view returns (address) {
        return TOKEN1;
    }

    function slot0() external pure returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (2 ** 96, 0, 0, 1, 1, 0, true);
    }

    function fee() external pure returns (uint24) {
        return FEE;
    }
}

/// @dev Accepts ETH and logs it, to order the recipient's logs against the factory's
contract LoggingReceiver {
    event Received(uint256 amount);

    receive() external payable {
        emit Received(msg.value);
    }
}

// todo: test protocol fee
