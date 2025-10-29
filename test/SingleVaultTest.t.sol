// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {SingleVault} from "../src/vaults/SingleVault.sol";
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
    address public allocator = makeAddr("allocator");
    address public user1 = makeAddr("user1");
    address public user2 = makeAddr("user2");
    address public attacker = makeAddr("attacker");

    uint256 public constant INITIAL_SUPPLY = 1_000_000 * 1e18;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event AllocatorUpdated(address indexed newAllocator);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    /*//////////////////////////////////////////////////////////////
                                SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() public {
        mockToken = new ERC20Mock();
        mockToken.mint(address(this), INITIAL_SUPPLY);

        vault = new SingleVault(owner, allocator);

        // Fund test addresses with ETH
        vm.deal(address(vault), 10 ether);
        vm.deal(owner, 10 ether);
        vm.deal(allocator, 10 ether);
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
        SingleVault newVault = new SingleVault(owner, allocator);

        assertEq(newVault.owner(), owner);
        assertEq(newVault.allocator(), allocator);
    }

    function test_Constructor_RevertIf_ZeroOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new SingleVault(address(0), allocator);
    }

    function test_Constructor_RevertIf_ZeroAllocator() public {
        vm.expectRevert(SingleVault.ZeroAddress.selector);

        new SingleVault(owner, address(0));
    }

    /*//////////////////////////////////////////////////////////////
                        EXECUTOR MANAGEMENT TESTS
    //////////////////////////////////////////////////////////////*/

    function test_SetAllocator_ByOwner() public {
        address newAllocator = makeAddr("newAllocator");

        vm.expectEmit(true, false, false, false);
        emit AllocatorUpdated(newAllocator);

        vm.prank(owner);
        vault.setAllocator(newAllocator);

        assertEq(vault.allocator(), newAllocator);
    }

    function test_SetAllocator_RevertIf_Unauthorized() public {
        address newAllocator = makeAddr("newAllocator");

        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", attacker));
        vm.prank(attacker);
        vault.setAllocator(newAllocator);
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

    function test_OnlyOwnerOrAllocator_Modifier() public {
        // This modifier is defined but not used in any function in the contract
        // We can test it by creating a test contract that uses it
        TestVault testVault = new TestVault(owner, allocator);

        // Owner should be able to call
        vm.prank(owner);
        testVault.testOnlyOwnerOrAllocator();

        // Allocator should be able to call
        vm.prank(allocator);
        testVault.testOnlyOwnerOrAllocator();

        // Others should not be able to call
        vm.expectRevert();
        vm.prank(attacker);
        testVault.testOnlyOwnerOrAllocator();
    }

    /*//////////////////////////////////////////////////////////////
                            FUZZ TESTS
    //////////////////////////////////////////////////////////////*/

    function testFuzz_SetAllocator(address newAllocator) public {
        vm.assume(newAllocator != address(0));

        vm.prank(owner);
        vault.setAllocator(newAllocator);

        assertEq(vault.allocator(), newAllocator);
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
        // Only owner can lock, not allocator
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", allocator));
        vm.prank(allocator);
        vault.lock(true);

        vm.prank(owner);
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

        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", allocator));
        vm.prank(allocator);
        vault.lock(true);
    }

    function test_InheritingContract_UseWhenNotLocked() public {
        // Test that inheriting contracts can properly use the whenNotLocked modifier
        TestVaultWithLock testVault = new TestVaultWithLock(owner, allocator);

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
        TestVaultWithLock testVault = new TestVaultWithLock(owner, allocator);

        // Test function that combines onlyOwnerOrAllocator and whenNotLocked
        vm.prank(owner);
        testVault.testOnlyOwnerOrAllocatorWhenNotLocked();

        vm.prank(allocator);
        testVault.testOnlyOwnerOrAllocatorWhenNotLocked();

        // Lock the vault
        vm.prank(owner);
        testVault.lock(true);

        // Should revert due to lock, even for authorized users
        vm.expectRevert(SingleVault.ContractLocked.selector);
        vm.prank(owner);
        testVault.testOnlyOwnerOrAllocatorWhenNotLocked();

        vm.expectRevert(SingleVault.ContractLocked.selector);
        vm.prank(allocator);
        testVault.testOnlyOwnerOrAllocatorWhenNotLocked();

        // Unauthorized users should still be rejected (access control checked first)
        vm.expectRevert();
        vm.prank(attacker);
        testVault.testOnlyOwnerOrAllocatorWhenNotLocked();
    }

    function test_SetAllocator_WorksWhenLocked() public {
        // Lock the vault
        vm.prank(owner);
        vault.lock(true);

        // Base SingleVault functions don't use whenNotLocked modifier
        // They should work when locked since the modifier is for inheriting contracts
        address newAllocator = makeAddr("newAllocator");

        vm.prank(owner);
        vault.setAllocator(newAllocator);
        assertEq(vault.allocator(), newAllocator);
    }

    /*//////////////////////////////////////////////////////////////
                            INHERITING CONTRACT TESTS
    //////////////////////////////////////////////////////////////*/

    function test_InheritingContract_DepositWithdrawWhenLocked() public {
        // Test a more realistic inheriting contract with deposit/withdraw functions
        VaultWithDepositWithdraw depositVault = new VaultWithDepositWithdraw(owner, allocator);

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
        // 1. Change allocator
        address newAllocator = makeAddr("newAllocator");
        vm.prank(owner);
        vault.setAllocator(newAllocator);
        assertEq(vault.allocator(), newAllocator);

        // 2. Transfer ownership
        address newOwner = makeAddr("newOwner");
        vm.prank(owner);
        vault.transferOwnership(newOwner);
        vm.prank(newOwner);
        vault.acceptOwnership();
        assertEq(vault.owner(), newOwner);

        // 3. New owner can lock
        vm.prank(newOwner);
        vault.lock(true);
        assertEq(vault.locked(), true);
    }
}

/**
 * @dev Helper contract for testing the onlyOwnerOrAllocator modifier
 */
contract TestVault is SingleVault {
    constructor(address initialOwner, address initialAllocator) SingleVault(initialOwner, initialAllocator) {}

    function testOnlyOwnerOrAllocator() external onlyOwnerOrAllocator {
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
    constructor(address initialOwner, address initialAllocator) SingleVault(initialOwner, initialAllocator) {}

    function testWhenNotLocked() external whenNotLocked {
        // This function exists solely to test the modifier
    }

    function testOnlyOwnerOrAllocatorWhenNotLocked() external onlyOwnerOrAllocator whenNotLocked {
        // Test combination of modifiers
    }
}

/**
 * @dev More realistic example of inheriting contract with deposit/withdraw
 */
contract VaultWithDepositWithdraw is SingleVault {
    constructor(address initialOwner, address initialAllocator) SingleVault(initialOwner, initialAllocator) {}

    function deposit(uint256) external whenNotLocked {}

    function withdraw(uint256) external whenNotLocked {}

    function balanceOf(address) external pure returns (uint256) {
        return 42;
    }
}
