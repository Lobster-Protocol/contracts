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
                        EMERGENCY RECOVERY TESTS
    //////////////////////////////////////////////////////////////*/

    function test_EmergencyRecoverToken() public {
        uint256 amount = 100 * 1e18;
        uint256 initialBalance = mockToken.balanceOf(user1);

        vm.prank(owner);
        vault.emergencyRecoverToken(address(mockToken), user1, amount);

        assertEq(mockToken.balanceOf(user1), initialBalance + amount);
        assertEq(mockToken.balanceOf(address(vault)), 1000 * 1e18 - amount);
    }

    function test_EmergencyRecoverToken_RevertIf_NotOwner() public {
        uint256 amount = 100 * 1e18;

        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", attacker));
        vm.prank(attacker);
        vault.emergencyRecoverToken(address(mockToken), user1, amount);
    }

    function test_EmergencyRecoverToken_RevertIf_ZeroToken() public {
        vm.expectRevert(SingleVault.ZeroAddress.selector);
        vm.prank(owner);
        vault.emergencyRecoverToken(address(0), user1, 100);
    }

    function test_EmergencyRecoverToken_RevertIf_ZeroRecipient() public {
        vm.expectRevert(SingleVault.ZeroAddress.selector);
        vm.prank(owner);
        vault.emergencyRecoverToken(address(mockToken), address(0), 100);
    }

    function test_EmergencyRecoverToken_RevertIf_ZeroAmount() public {
        vm.expectRevert(SingleVault.ZeroValue.selector);
        vm.prank(owner);
        vault.emergencyRecoverToken(address(mockToken), user1, 0);
    }

    function test_EmergencyRecoverETH() public {
        uint256 amount = 1 ether;
        uint256 initialBalance = user1.balance;

        vm.prank(owner);
        vault.emergencyRecoverETH(user1, amount);

        assertEq(user1.balance, initialBalance + amount);
        assertEq(address(vault).balance, 10 ether - amount);
    }

    function test_EmergencyRecoverETH_RevertIf_NotOwner() public {
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", attacker));
        vm.prank(attacker);
        vault.emergencyRecoverETH(user1, 1 ether);
    }

    function test_EmergencyRecoverETH_RevertIf_ZeroRecipient() public {
        vm.expectRevert(SingleVault.ZeroAddress.selector);
        vm.prank(owner);
        vault.emergencyRecoverETH(address(0), 1 ether);
    }

    function test_EmergencyRecoverETH_RevertIf_ZeroAmount() public {
        vm.expectRevert(SingleVault.ZeroValue.selector);
        vm.prank(owner);
        vault.emergencyRecoverETH(user1, 0);
    }

    function test_EmergencyRecoverETH_RevertIf_InsufficientBalance() public {
        uint256 excessiveAmount = 20 ether;

        vm.expectRevert("Insufficient balance");
        vm.prank(owner);
        vault.emergencyRecoverETH(user1, excessiveAmount);
    }

    /*//////////////////////////////////////////////////////////////
                            CALL FUNCTION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Call_Success() public {
        // Test calling a simple contract function
        bytes memory data = abi.encodeWithSignature("transfer(address,uint256)", user1, 100);

        vm.prank(owner);
        bytes memory returnData = vault.call(address(mockToken), 0, data);

        // ERC20 transfer returns true on success
        bool success = abi.decode(returnData, (bool));
        assertTrue(success);
    }

    function test_Call_WithValue() public {
        // Create a simple contract to test calling with ETH
        SimpleReceiver receiver = new SimpleReceiver();
        bytes memory data = abi.encodeWithSignature("receiveETH()");

        vm.prank(owner);
        vault.call(address(receiver), 1 ether, data);

        assertEq(address(receiver).balance, 1 ether);
        assertEq(receiver.received(), true);
    }

    function test_Call_RevertIf_NotOwner() public {
        bytes memory data = abi.encodeWithSignature("transfer(address,uint256)", user1, 100);

        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", attacker));
        vm.prank(attacker);
        vault.call(address(mockToken), 0, data);
    }

    function test_Call_PropagatesRevert() public {
        // Try to call a function that doesn't exist
        bytes memory data = abi.encodeWithSignature("nonExistentFunction()");

        vm.expectRevert();
        vm.prank(owner);
        vault.call(address(mockToken), 0, data);
    }

    /*//////////////////////////////////////////////////////////////
                        BATCH CALL FUNCTION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_BatchCall_Success() public {
        address[] memory targets = new address[](2);
        uint256[] memory values = new uint256[](2);
        bytes[] memory calldatas = new bytes[](2);

        targets[0] = address(mockToken);
        values[0] = 0;
        calldatas[0] = abi.encodeWithSignature("transfer(address,uint256)", user1, 50);

        targets[1] = address(mockToken);
        values[1] = 0;
        calldatas[1] = abi.encodeWithSignature("transfer(address,uint256)", user2, 50);

        uint256 user1InitialBalance = mockToken.balanceOf(user1);
        uint256 user2InitialBalance = mockToken.balanceOf(user2);

        vm.prank(owner);
        vault.batchCall(targets, values, calldatas);

        assertEq(mockToken.balanceOf(user1), user1InitialBalance + 50);
        assertEq(mockToken.balanceOf(user2), user2InitialBalance + 50);
    }

    function test_BatchCall_WithETH() public {
        SimpleReceiver receiver1 = new SimpleReceiver();
        SimpleReceiver receiver2 = new SimpleReceiver();

        address[] memory targets = new address[](2);
        uint256[] memory values = new uint256[](2);
        bytes[] memory calldatas = new bytes[](2);

        targets[0] = address(receiver1);
        values[0] = 1 ether;
        calldatas[0] = abi.encodeWithSignature("receiveETH()");

        targets[1] = address(receiver2);
        values[1] = 2 ether;
        calldatas[1] = abi.encodeWithSignature("receiveETH()");

        vm.prank(owner);
        vault.batchCall{value: 3 ether}(targets, values, calldatas);

        assertEq(address(receiver1).balance, 1 ether);
        assertEq(address(receiver2).balance, 2 ether);
        assertTrue(receiver1.received());
        assertTrue(receiver2.received());
    }

    function test_BatchCall_RevertIf_ArrayLengthMismatch() public {
        address[] memory targets = new address[](2);
        uint256[] memory values = new uint256[](1); // Different length
        bytes[] memory calldatas = new bytes[](2);

        vm.expectRevert("Array length mismatch");
        vm.prank(owner);
        vault.batchCall(targets, values, calldatas);
    }

    function test_BatchCall_RevertIf_NotOwner() public {
        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);

        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", attacker));
        vm.prank(attacker);
        vault.batchCall(targets, values, calldatas);
    }

    function test_BatchCall_RevertsOnFailedCall() public {
        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);

        targets[0] = address(mockToken);
        values[0] = 0;
        calldatas[0] = abi.encodeWithSignature("nonExistentFunction()");

        vm.expectRevert();
        vm.prank(owner);
        vault.batchCall(targets, values, calldatas);
    }

    /*//////////////////////////////////////////////////////////////
                        RECEIVE FUNCTION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_ReceiveETH() public {
        uint256 initialBalance = address(vault).balance;

        vm.prank(user1);
        (bool success,) = payable(address(vault)).call{value: 1 ether}("");

        assertTrue(success);
        assertEq(address(vault).balance, initialBalance + 1 ether);
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

    function testFuzz_EmergencyRecoverETH(uint256 amount) public {
        amount = bound(amount, 1, address(vault).balance);
        uint256 initialBalance = user1.balance;

        vm.prank(owner);
        vault.emergencyRecoverETH(user1, amount);

        assertEq(user1.balance, initialBalance + amount);
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

        // 3. Emergency recover some tokens
        vm.prank(owner);
        vault.emergencyRecoverToken(address(mockToken), user1, 100);

        // 4. Transfer ownership
        address newOwner = makeAddr("newOwner");
        vm.prank(owner);
        vault.transferOwnership(newOwner);
        vm.prank(newOwner);
        vault.acceptOwnership();
        assertEq(vault.owner(), newOwner);

        // 5. New owner can perform emergency functions
        vm.prank(newOwner);
        vault.emergencyRecoverETH(user2, 1 ether);
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

/**
 * @dev Helper contract for testing ETH transfers
 */
contract SimpleReceiver {
    bool public received = false;

    function receiveETH() external payable {
        received = true;
    }

    receive() external payable {
        received = true;
    }
}

// todo: test lock() fct
