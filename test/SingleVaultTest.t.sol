// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {SingleVault} from "../src/vaults/SingleVault.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/**
 * @title SingleVaultTest
 * @notice Comprehensive test suite for SingleVault contract
 */
contract SingleVaultTest is Test {
    SingleVault public vault;
    ERC20Mock public mockToken;

    address public owner = makeAddr("owner");
    address public executor = makeAddr("executor");
    address public executorManager = makeAddr("executorManager");
    address public user1 = makeAddr("user1");
    address public user2 = makeAddr("user2");
    address public attacker = makeAddr("attacker");

    uint256 public constant INITIAL_SUPPLY = 1_000_000 * 1e18;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event ExecutorUpdated(address indexed newExecutor);
    event ExecutorManagerUpdated(address indexed newManager);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    /*//////////////////////////////////////////////////////////////
                                SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() public {
        mockToken = new ERC20Mock();
        mockToken.mint(address(this), INITIAL_SUPPLY);

        vault = new SingleVault(owner, executor, executorManager);

        // Fund test addresses with ETH
        vm.deal(address(vault), 10 ether);
        vm.deal(owner, 10 ether);
        vm.deal(executor, 10 ether);
        vm.deal(executorManager, 10 ether);
        vm.deal(user1, 10 ether);
        vm.deal(user2, 10 ether);
        vm.deal(attacker, 10 ether);

        // Fund addresses with mock tokens
        mockToken.mint(address(vault), 1000 * 1e18);
        mockToken.mint(user1, 1000 * 1e18);
        mockToken.mint(user2, 1000 * 1e18);
    }

    /*//////////////////////////////////////////////////////////////
                            CONSTRUCTOR TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Constructor_Success() public {
        SingleVault newVault = new SingleVault(owner, executor, executorManager);

        assertEq(newVault.owner(), owner);
        assertEq(newVault.executor(), executor);
        assertEq(newVault.executorManager(), executorManager);
    }

    function test_Constructor_RevertIf_ZeroOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new SingleVault(address(0), executor, executorManager);
    }

    function test_Constructor_RevertIf_ZeroExecutor() public {
        vm.expectRevert(SingleVault.ZeroAddress.selector);

        new SingleVault(owner, address(0), executorManager);
    }

    function test_Constructor_RevertIf_ZeroExecutorManager() public {
        vm.expectRevert(SingleVault.ZeroAddress.selector);
        new SingleVault(owner, executor, address(0));
    }

    /*//////////////////////////////////////////////////////////////
                        EXECUTOR MANAGEMENT TESTS
    //////////////////////////////////////////////////////////////*/

    function test_SetExecutor_ByOwner() public {
        address newExecutor = makeAddr("newExecutor");

        vm.expectEmit(true, false, false, false);
        emit ExecutorUpdated(newExecutor);

        vm.prank(owner);
        vault.setExecutor(newExecutor);

        assertEq(vault.executor(), newExecutor);
    }

    function test_SetExecutor_ByExecutorManager() public {
        address newExecutor = makeAddr("newExecutor");

        vm.expectEmit(true, false, false, false);
        emit ExecutorUpdated(newExecutor);

        vm.prank(executorManager);
        vault.setExecutor(newExecutor);

        assertEq(vault.executor(), newExecutor);
    }

    function test_SetExecutor_RevertIf_Unauthorized() public {
        address newExecutor = makeAddr("newExecutor");

        vm.expectRevert(SingleVault.Unauthorized.selector);
        vm.prank(attacker);
        vault.setExecutor(newExecutor);
    }

    /*//////////////////////////////////////////////////////////////
                    EXECUTOR MANAGER MANAGEMENT TESTS
    //////////////////////////////////////////////////////////////*/

    function test_SetExecutorManager_ByOwner() public {
        address newManager = makeAddr("newManager");

        vm.expectEmit(true, false, false, false);
        emit ExecutorManagerUpdated(newManager);

        vm.prank(owner);
        vault.setExecutorManager(newManager);

        assertEq(vault.executorManager(), newManager);
    }

    function test_SetExecutorManager_RevertIf_NotOwner() public {
        address newManager = makeAddr("newManager");

        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", executorManager));
        vm.prank(executorManager);
        vault.setExecutorManager(newManager);
    }

    /*//////////////////////////////////////////////////////////////
                        OWNERSHIP TRANSFER TESTS
    //////////////////////////////////////////////////////////////*/

    function test_TransferOwnership_TwoStep() public {
        address newOwner = makeAddr("newOwner");

        // Start ownership transfer
        vm.expectEmit(true, true, false, false);
        emit OwnershipTransferStarted(owner, newOwner);

        vm.prank(owner);
        vault.transferOwnership(newOwner);

        // Ownership should not change yet
        assertEq(vault.owner(), owner);
        assertEq(vault.pendingOwner(), newOwner);

        // Accept ownership
        vm.expectEmit(true, true, false, false);
        emit OwnershipTransferred(owner, newOwner);

        vm.prank(newOwner);
        vault.acceptOwnership();

        assertEq(vault.owner(), newOwner);
        assertEq(vault.pendingOwner(), address(0));
    }

    function test_TransferOwnership_RevertIf_NotPendingOwner() public {
        address newOwner = makeAddr("newOwner");

        vm.prank(owner);
        vault.transferOwnership(newOwner);

        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", attacker));
        vm.prank(attacker);
        vault.acceptOwnership();
    }

    /*//////////////////////////////////////////////////////////////
                        RECEIVE FUNCTION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_ReceiveETH() public {
        vm.prank(user1);
        (bool success,) = payable(address(vault)).call{value: 1 ether}("");

        assertFalse(success);
    }

    /*//////////////////////////////////////////////////////////////
                            ACCESS CONTROL TESTS
    //////////////////////////////////////////////////////////////*/

    function test_OnlyOwnerOrExecutor_Modifier() public {
        // This modifier is defined but not used in any function in the contract
        // We can test it by creating a test contract that uses it
        TestVault testVault = new TestVault(owner, executor, executorManager);

        // Owner should be able to call
        vm.prank(owner);
        testVault.testOnlyOwnerOrExecutor();

        // Executor should be able to call
        vm.prank(executor);
        testVault.testOnlyOwnerOrExecutor();

        // Others should not be able to call
        vm.expectRevert();
        vm.prank(attacker);
        testVault.testOnlyOwnerOrExecutor();
    }

    /*//////////////////////////////////////////////////////////////
                            FUZZ TESTS
    //////////////////////////////////////////////////////////////*/

    function testFuzz_SetExecutor(address newExecutor) public {
        vm.assume(newExecutor != address(0));

        vm.prank(owner);
        vault.setExecutor(newExecutor);

        assertEq(vault.executor(), newExecutor);
    }

    function testFuzz_SetExecutorManager(address newManager) public {
        vm.assume(newManager != address(0));

        vm.prank(owner);
        vault.setExecutorManager(newManager);

        assertEq(vault.executorManager(), newManager);
    }

    /*//////////////////////////////////////////////////////////////
                            LOCK FUNCTIONALITY TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Lock_ByOwner() public {
        // Initially not locked
        assertFalse(vault.locked());

        // Owner can lock
        vm.expectEmit(true, false, false, false);
        emit SingleVault.VaultLocked(true);

        vm.prank(owner);
        vault.lock(true);

        assertTrue(vault.locked());
    }

    function test_Lock_OnlyOwnerCanLock() public {
        // Only owner can lock, not executor or executorManager
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", executor));
        vm.prank(executor);
        vault.lock(true);

        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", executorManager));
        vm.prank(executorManager);
        vault.lock(true);
    }

    function test_Unlock_ByOwner() public {
        // First lock the vault
        vm.prank(owner);
        vault.lock(true);
        assertTrue(vault.locked());

        // Then unlock
        vm.expectEmit(true, false, false, false);
        emit SingleVault.VaultLocked(false);

        vm.prank(owner);
        vault.lock(false);

        assertFalse(vault.locked());
    }

    function test_Lock_RevertIf_Unauthorized() public {
        // Only owner can lock/unlock
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", attacker));
        vm.prank(attacker);
        vault.lock(true);

        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", executor));
        vm.prank(executor);
        vault.lock(true);

        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", executorManager));
        vm.prank(executorManager);
        vault.lock(true);
    }

    function test_InheritingContract_UseWhenNotLocked() public {
        // Test that inheriting contracts can properly use the whenNotLocked modifier
        TestVaultWithLock testVault = new TestVaultWithLock(owner, executor, executorManager);

        // When not locked, functions with whenNotLocked should work
        vm.prank(owner);
        testVault.testWhenNotLocked();

        // Lock the vault
        vm.prank(owner);
        testVault.lock(true);

        // Now functions with whenNotLocked should revert
        vm.expectRevert(SingleVault.ContractLocked.selector);
        vm.prank(owner);
        testVault.testWhenNotLocked();

        // Unlock and it should work again
        vm.prank(owner);
        testVault.lock(false);

        vm.prank(owner);
        testVault.testWhenNotLocked();
    }

    function test_InheritingContract_CombinedModifiers() public {
        TestVaultWithLock testVault = new TestVaultWithLock(owner, executor, executorManager);

        // Test function that combines onlyOwnerOrExecutor and whenNotLocked
        vm.prank(owner);
        testVault.testOnlyOwnerOrExecutorWhenNotLocked();

        vm.prank(executor);
        testVault.testOnlyOwnerOrExecutorWhenNotLocked();

        // Lock the vault
        vm.prank(owner);
        testVault.lock(true);

        // Should revert due to lock, even for authorized users
        vm.expectRevert(SingleVault.ContractLocked.selector);
        vm.prank(owner);
        testVault.testOnlyOwnerOrExecutorWhenNotLocked();

        vm.expectRevert(SingleVault.ContractLocked.selector);
        vm.prank(executor);
        testVault.testOnlyOwnerOrExecutorWhenNotLocked();

        // Unauthorized users should still be rejected (access control checked first)
        vm.expectRevert();
        vm.prank(attacker);
        testVault.testOnlyOwnerOrExecutorWhenNotLocked();
    }

    function test_SetExecutor_WorksWhenLocked() public {
        // Lock the vault
        vm.prank(owner);
        vault.lock(true);

        // Base SingleVault functions don't use whenNotLocked modifier
        // They should work when locked since the modifier is for inheriting contracts
        address newExecutor = makeAddr("newExecutor");

        vm.prank(owner);
        vault.setExecutor(newExecutor);
        assertEq(vault.executor(), newExecutor);
    }

    function test_SetExecutorManager_WorksWhenLocked() public {
        // Lock the vault
        vm.prank(owner);
        vault.lock(true);

        // Base SingleVault functions don't use whenNotLocked modifier
        // They should work when locked since the modifier is for inheriting contracts
        address newManager = makeAddr("newManager");

        vm.prank(owner);
        vault.setExecutorManager(newManager);
        assertEq(vault.executorManager(), newManager);
    }

    /*//////////////////////////////////////////////////////////////
                            INHERITING CONTRACT TESTS
    //////////////////////////////////////////////////////////////*/

    function test_InheritingContract_DepositWithdrawWhenLocked() public {
        // Test a more realistic inheriting contract with deposit/withdraw functions
        VaultWithDepositWithdraw depositVault = new VaultWithDepositWithdraw(owner, executor, executorManager);

        // Deposit should work when unlocked
        depositVault.deposit(100e18);
        // No revert

        // Lock the vault
        vm.prank(owner);
        depositVault.lock(true);

        // Deposit should fail when locked
        vm.expectRevert(SingleVault.ContractLocked.selector);
        depositVault.deposit(50e18);

        // Withdraw should also fail when locked
        vm.expectRevert(SingleVault.ContractLocked.selector);
        depositVault.withdraw(50e18);

        // Unlock
        vm.prank(owner);
        depositVault.lock(false);

        // Operations should work again
        depositVault.deposit(50e18);
        // No revert

        depositVault.withdraw(100e18);
        // No revert
    }

    /*//////////////////////////////////////////////////////////////
                                FUZZ TESTS FOR LOCK
    //////////////////////////////////////////////////////////////*/

    function testFuzz_Lock_ToggleLockState(bool lockState) public {
        vm.prank(owner);
        vault.lock(lockState);

        assertEq(vault.locked(), lockState);
    }

    function testFuzz_Lock_MultipleToggle(bool[] memory lockStates) public {
        vm.assume(lockStates.length > 0 && lockStates.length <= 10);

        for (uint256 i = 0; i < lockStates.length; i++) {
            vm.prank(owner);
            vault.lock(lockStates[i]);
            assertEq(vault.locked(), lockStates[i]);
        }
    }

    /*//////////////////////////////////////////////////////////////
                            INTEGRATION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_FullWorkflow() public {
        // 1. Change executor
        address newExecutor = makeAddr("newExecutor");
        vm.prank(executorManager);
        vault.setExecutor(newExecutor);
        assertEq(vault.executor(), newExecutor);

        // 2. Change executor manager
        address newManager = makeAddr("newManager");
        vm.prank(owner);
        vault.setExecutorManager(newManager);
        assertEq(vault.executorManager(), newManager);

        // 3. Transfer ownership
        address newOwner = makeAddr("newOwner");
        vm.prank(owner);
        vault.transferOwnership(newOwner);
        vm.prank(newOwner);
        vault.acceptOwnership();
        assertEq(vault.owner(), newOwner);

        // 5. New owner can lock
        vm.prank(newOwner);
        vault.lock(true);
        assertEq(vault.locked(), true);
    }
}

/**
 * @dev Helper contract for testing the onlyOwnerOrExecutor modifier
 */
contract TestVault is SingleVault {
    constructor(
        address initialOwner,
        address initialExecutor,
        address initialExecutorManager
    )
        SingleVault(initialOwner, initialExecutor, initialExecutorManager)
    {}

    function testOnlyOwnerOrExecutor() external onlyOwnerOrExecutor {
        // This function exists solely to test the modifier
    }
}

/*//////////////////////////////////////////////////////////////
                        HELPER CONTRACT FOR TESTING
//////////////////////////////////////////////////////////////*/

/**
 * @dev Helper contract for testing the whenNotLocked modifier
 */
contract TestVaultWithLock is SingleVault {
    constructor(
        address initialOwner,
        address initialExecutor,
        address initialExecutorManager
    )
        SingleVault(initialOwner, initialExecutor, initialExecutorManager)
    {}

    function testWhenNotLocked() external whenNotLocked {
        // This function exists solely to test the modifier
    }

    function testOnlyOwnerOrExecutorWhenNotLocked() external onlyOwnerOrExecutor whenNotLocked {
        // Test combination of modifiers
    }
}

/**
 * @dev More realistic example of inheriting contract with deposit/withdraw
 */
contract VaultWithDepositWithdraw is SingleVault {
    constructor(
        address initialOwner,
        address initialExecutor,
        address initialExecutorManager
    )
        SingleVault(initialOwner, initialExecutor, initialExecutorManager)
    {}

    function deposit(uint256) external whenNotLocked {}

    function withdraw(uint256) external whenNotLocked {}

    function balanceOf(address) external pure returns (uint256) {
        return 42;
    }
}
