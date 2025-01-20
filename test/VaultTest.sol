// SPDX-License-Identifier: GNU AGPL v3.0
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../src/Vault/Vault.sol";
import "../src/interfaces/IValidator.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockERC20 is ERC20 {
    constructor() ERC20("Mock Token", "MTK") {
        _mint(msg.sender, 1000000 ether);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockValidator is IValidator {
    bool public shouldValidate = true;
    uint256 public otherValue = 0;
    uint256 public rebaseExpiresAt = 0;

    function rebase(uint256 _otherValue, uint256 expireAt) external {
        otherValue = _otherValue;
        rebaseExpiresAt = expireAt;
    }

    function setShouldValidate(bool _shouldValidate) external {
        shouldValidate = _shouldValidate;
    }

    function validateOp(Op calldata) external view returns (bool) {
        return shouldValidate;
    }

    function validateBatchedOp(Op[] calldata) external view returns (bool) {
        return shouldValidate;
    }

    function valueOutsideChain() external view returns (uint256) {
        return otherValue;
    }
}

contract VaultTest is Test {
    Vault public vault;
    MockERC20 public asset;
    MockValidator public validator;
    address public owner;
    address public alice;
    address public bob;
    address public lobsterAlgorithm;
    address public lobsterRebaser;

    event Deposit(
        address indexed caller,
        address indexed owner,
        uint256 assets,
        uint256 shares
    );

    event Withdraw(
        address indexed caller,
        address indexed receiver,
        address indexed owner,
        uint256 assets,
        uint256 shares
    );

    event Rebased(uint256 newTotalAssets, uint256 timestamp);

    function setUp() public {
        owner = makeAddr("owner");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        lobsterAlgorithm = makeAddr("lobsterAlgorithm");
        lobsterRebaser = makeAddr("lobsterRebaser");

        // Deploy contracts
        asset = new MockERC20();
        validator = new MockValidator();

        vault = new Vault(
            owner,
            asset,
            "Vault Token",
            "vTKN",
            validator,
            lobsterAlgorithm
        );

        // Setup initial state
        asset.mint(alice, 10000 ether);
        asset.mint(bob, 10000 ether);

        vm.startPrank(alice);
        asset.approve(address(vault), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(bob);
        asset.approve(address(vault), type(uint256).max);
        vm.stopPrank();
    }

    /* -----------------------DEPOSIT----------------------- */
    function testDeposit() public {
        vm.startPrank(lobsterRebaser);
        validator.rebase(10, block.number + 1);
        vm.stopPrank();

        vm.startPrank(alice);
        vault.deposit(1 ether, alice);
        assertEq(vault.balanceOf(alice), 1 ether);
        vm.stopPrank();
    }

    // Should revert if rebase is too old (> MAX_DEPOSIT_DELAY)
    function testDepositAfterLimit() public {
        vm.startPrank(lobsterRebaser);
        validator.rebase(10, block.number + 1);
        vm.stopPrank();

        vm.roll(validator.rebaseExpiresAt() + 1);

        vm.startPrank(alice);
        vm.expectRevert(Vault.RebaseExpired.selector);
        vault.deposit(1 ether, alice);
        vm.stopPrank();
    }

    // multiple deposits
    function testMultipleDeposits() public {
        vm.startPrank(lobsterRebaser);
        validator.rebase(0, block.number + 1);
        vm.stopPrank();

        // alice deposits 100.33 eth
        vm.startPrank(alice);
        vault.deposit(100.33 ether, alice);
        vm.assertEq(vault.maxWithdraw(alice), 100.33 ether);
        vm.stopPrank();

        // lobster algorithm bridges 100 eth to the other chain
        vm.startPrank(lobsterAlgorithm);
        // remove 100 eth from the vault balance (like if they were bridged to the other chain)
        vault.executeOp(
            Op({
                target: address(asset),
                value: 0,
                data: abi.encodeWithSignature(
                    "transfer(address,uint256)",
                    address(1),
                    100 ether
                )
            })
        );

        vm.stopPrank();

        vm.startPrank(lobsterRebaser);
        // save the new total assets in l3
        validator.rebase(100 ether, block.number + 1);
        vm.stopPrank();

        // bob deposits 1 and 2 eth
        vm.startPrank(bob);
        vault.deposit(1 ether, bob);
        vm.assertEq(vault.maxWithdraw(bob), 1 ether);
        vault.deposit(2 ether, bob);
        vm.assertEq(vault.maxWithdraw(bob), 3 ether);
        vm.stopPrank();

        vm.assertEq(vault.totalAssets(), 103.33 ether);
        vm.assertEq(vault.localTotalAssets(), 3.33 ether);
    }

    /* -----------------------MINT----------------------- */
    /* -----------------------MINT & DEPOSIT----------------------- */
    /* ------------------------------------------------------------ */

    // function testFuzz_RebaseAmount(uint256 amount) public {
    //     // First deposit to have some local assets
    //     vm.startPrank(alice);
    //     vault.deposit(100 ether, alice);
    //     vm.stopPrank();

    //     // Bound rebase amount to max 10% of local assets
    //     amount = bound(amount, 0, 10 ether);

    //     vm.startPrank(lobsterRebaser);
    //     vault.rebase(amount);
    //     assertEq(vault.wethBalanceOnOtherChain(), amount);
    //     vm.stopPrank();
    // }
}
