// SPDX-License-Identifier: GNU AGPL v3.0
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import "../src/Vault/Vault.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {MockERC20} from "./Mocks/MockERC20.sol";
import {LobsterOpValidator as OpValidator} from "../src/Validator/OpValidator.sol";
import {MockPositionsManager} from "./Mocks/MockPositionsManager.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

contract VaultTest is Test {
    LobsterVault public vault;
    MockERC20 public asset;
    address public owner;
    address public alice;
    address public bob;
    address public lobsterAlgorithm;
    uint256 public lobsterRebaserPrivateKey;
    address public lobsterRebaser;
    MockPositionsManager public positionManager;

    function setUp() public {
        owner = makeAddr("owner");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        lobsterAlgorithm = makeAddr("lobsterAlgorithm");
        // anvil first private key
        lobsterRebaserPrivateKey = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
        lobsterRebaser = vm.addr(lobsterRebaserPrivateKey);

        // Deploy contracts
        asset = new MockERC20();
        positionManager = new MockPositionsManager();
        // whitelist the asset address and the transfer function
        address[] memory validTargets = new address[](1);
        bytes4[][] memory validSelectors = new bytes4[][](1);
        validTargets[0] = address(asset);
        validSelectors[0] = new bytes4[](1);
        validSelectors[0][0] = asset.transfer.selector;
        bytes memory validTargetsAndSelectorsData = abi.encode(
            validTargets,
            validSelectors
        );

        vault = new LobsterVault(
            owner,
            asset,
            "Vault Token",
            "vTKN",
            lobsterAlgorithm,
            address(positionManager),
            validTargetsAndSelectorsData
        );
        console2.log("Vault address: ", address(vault));

        // Setup initial state
        asset.mint(alice, 10000 ether);
        asset.mint(bob, 10000 ether);

        vm.startPrank(alice);
        asset.approve(address(vault), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(bob);
        asset.approve(address(vault), type(uint256).max);
        vm.stopPrank();

        console2.log("Setup done");
        vm.startPrank(owner);
        vault.setRebaser(lobsterRebaser, true);
        vm.stopPrank();

        console2.log("Rebaser set");
    }

    function getValidRebaseData(
        address vault_,
        uint256 valueOutsideChain,
        uint256 expirationBlock
    ) public view returns (bytes memory) {
        bytes32 messageToBeSigned = MessageHashUtils.toEthSignedMessageHash(
            keccak256(
                abi.encode(
                    valueOutsideChain,
                    expirationBlock,
                    block.chainid,
                    vault
                )
            )
        );

        // sign the data using the private key of the rebaser
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(
            lobsterRebaserPrivateKey,
            messageToBeSigned
        );

        // Concatenate the signature components
        bytes memory signature = abi.encodePacked(r, s, v);

        return
            abi.encodePacked(
                vault_,
                abi.encode(valueOutsideChain, expirationBlock, signature)
            );
    }

    function rebaseVault(uint256 amount, uint256 expirationDelay) public {
        vm.startPrank(lobsterRebaser);
        bytes memory rebaseData = getValidRebaseData(
            address(vault),
            amount,
            block.number + expirationDelay
        );
        vault.rebase(rebaseData);
        vm.stopPrank();
    }

    /* -----------------------DEPOSIT----------------------- */
    function testDeposit() public {
        rebaseVault(0, block.number + 1);

        vm.startPrank(alice);
        vault.deposit(1 ether, alice);
        assertEq(vault.balanceOf(alice), 1 ether);
        vm.stopPrank();
    }

    // Should revert if rebase is too old (> MAX_DEPOSIT_DELAY)
    function testDepositAfterLimit() public {
        rebaseVault(10, block.number + 1);

        vm.roll(vault.rebaseExpiresAt() + 1);

        vm.startPrank(alice);
        vm.expectRevert(LobsterVault.RebaseExpired.selector);
        vault.deposit(1 ether, alice);
        vm.stopPrank();
    }

    // multiple deposits
    function testMultipleDeposits() public {
        rebaseVault(0, 1);

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

        // save the new total assets in l3
        rebaseVault(100 ether, 2);
        console2.log("total assets: ", vault.totalAssets());
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

    /* -----------------------DEPOSIT WITH REBASE----------------------- */
        /* -----------------------DEPOSIT WITH REBASE----------------------- */

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
