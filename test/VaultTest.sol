// SPDX-License-Identifier: GNU AGPL v3.0
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../src/Vault/Vault.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {MockERC20} from "./Mocks/MockERC20.sol";
import {LobsterOpValidator as OpValidator} from "../src/Validator/OpValidator.sol";
import {MockPositionsManager} from "./Mocks/MockPositionsManager.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {Counter} from "./Mocks/Counter.sol";

enum RebaseType {
    DEPOSIT,
    MINT,
    WITHDRAW,
    REDEEM
}

contract VaultTest is Test {
    LobsterVault public vault;
    Counter public counter;
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
        counter = new Counter(asset);
        // whitelist the asset address and the transfer function
        address[] memory validTargets = new address[](2);
        bytes4[][] memory validSelectors = new bytes4[][](2);
        validTargets[0] = address(asset);
        validSelectors[0] = new bytes4[](1);
        validSelectors[0][0] = asset.transfer.selector;
        validTargets[1] = address(counter);
        validSelectors[1] = new bytes4[](1);
        validSelectors[1][0] = counter.incrementAndClaim.selector;

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

        // Setup initial state
        asset.mint(alice, 10000 ether);
        asset.mint(bob, 10000 ether);

        vm.startPrank(alice);
        asset.approve(address(vault), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(bob);
        asset.approve(address(vault), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(owner);
        vault.setRebaser(lobsterRebaser, true);
        vm.stopPrank();
    }

    /* -------------- Helper Functions -------------- */
    function getValidRebaseData(
        address vault_,
        uint256 valueOutsideVault,
        uint256 expirationBlock,
        uint256 minEthAmountToRetrieve,
        RebaseType rebaseType,
        bytes memory withdrawOperations
    ) public view returns (bytes memory) {
        bytes32 messageToBeSigned = MessageHashUtils.toEthSignedMessageHash(
            keccak256(
                abi.encode(
                    valueOutsideVault,
                    expirationBlock,
                    withdrawOperations,
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
                rebaseType == RebaseType.DEPOSIT ||
                    rebaseType == RebaseType.MINT
                    ? hex"00"
                    : hex"01",
                minEthAmountToRetrieve,
                vault_,
                abi.encode(
                    valueOutsideVault,
                    expirationBlock,
                    withdrawOperations,
                    signature
                )
            );
    }

    function rebaseVault(uint256 amount, uint256 expirationDelay) public {
        vm.startPrank(lobsterRebaser);
        bytes memory rebaseData = getValidRebaseData(
            address(vault),
            amount,
            block.number + expirationDelay,
            0,
            RebaseType.DEPOSIT,
            new bytes(0)
        );
        vault.rebase(rebaseData);
        vm.stopPrank();
    }

    function bridge(uint256 value, address receiver) public {
        // Simulate some value being bridged by the algorithm
        vm.startPrank(lobsterAlgorithm);
        vault.executeOp(
            Op({
                target: address(asset),
                value: 0,
                data: abi.encodeWithSignature(
                    "transfer(address,uint256)",
                    receiver,
                    value
                )
            })
        );
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

    function testDepositWithRebaseZeroAmount() public {
        vm.startPrank(alice);
        vault.depositWithRebase(
            0,
            alice,
            getValidRebaseData(
                address(vault),
                0,
                block.number + 1,
                0,
                RebaseType.DEPOSIT,
                new bytes(0)
            )
        );
        assertEq(vault.balanceOf(alice), 0);
        vm.stopPrank();
    }

    function testDepositWithRebaseInvalidReceiver() public {
        vm.startPrank(alice);
        vm.expectRevert();
        vault.depositWithRebase(
            1 ether,
            address(0),
            getValidRebaseData(
                address(vault),
                0,
                block.number + 1,
                0,
                RebaseType.DEPOSIT,
                new bytes(0)
            )
        );
        vm.stopPrank();
    }

    function testDepositWithRebaseExpiredSignature() public {
        vm.startPrank(alice);
        bytes memory rebaseData = getValidRebaseData(
            address(vault),
            0,
            block.number,
            0,
            RebaseType.DEPOSIT,
            new bytes(0)
        );
        vm.roll(block.number + 2);
        vm.expectRevert();
        vault.depositWithRebase(1 ether, alice, rebaseData);
        vm.stopPrank();
    }

    /* -----------------------DEPOSIT WITHOUT REBASE----------------------- */
    function testDepositWithoutRebase() public {
        rebaseVault(0, block.number + 1);

        // wait for rebase expiration
        vm.roll(vault.rebaseExpiresAt() + 1);

        vm.startPrank(alice);
        vm.expectRevert(LobsterVault.RebaseExpired.selector);
        vault.deposit(1 ether, alice);
        vm.stopPrank();
    }

    /* -----------------------DEPOSIT WITH REBASE----------------------- */
    function testDepositWithRebase() public {
        // no rebase yet
        vm.startPrank(alice);
        vault.depositWithRebase(
            1 ether,
            alice,
            getValidRebaseData(
                address(vault),
                0 ether,
                block.number + 1,
                0,
                RebaseType.DEPOSIT,
                new bytes(0)
            )
        );
        assertEq(vault.balanceOf(alice), 1 ether);
        vm.stopPrank();
    }

    /* -----------------------MINT----------------------- */
    function testMint() public {
        rebaseVault(0, block.number + 1);

        vm.startPrank(alice);
        uint256 previewedAssets = vault.previewMint(1 ether);
        vault.mint(1 ether, alice);
        assertEq(vault.balanceOf(alice), 1 ether);
        assertEq(asset.balanceOf(address(vault)), previewedAssets);
        vm.stopPrank();
    }

    // Should revert if rebase is too old (> MAX_DEPOSIT_DELAY)
    function testMintAfterLimit() public {
        rebaseVault(10, block.number + 1);

        vm.roll(vault.rebaseExpiresAt() + 1);

        vm.startPrank(alice);
        vm.expectRevert(LobsterVault.RebaseExpired.selector);
        vault.mint(1 ether, alice);
        vm.stopPrank();
    }

    // multiple mints
    function testMultipleMints() public {
        rebaseVault(0, 1);

        // alice mints 100.33 shares
        vm.startPrank(alice);
        vault.mint(100.33 ether, alice);
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

        // bob mints 1 and 2 shares
        vm.startPrank(bob);
        vault.mint(1 ether, bob);
        vm.assertEq(vault.maxWithdraw(bob), 1 ether);

        vault.mint(2 ether, bob);
        vm.assertEq(vault.maxWithdraw(bob), 3 ether);
        vm.stopPrank();

        vm.assertEq(vault.totalAssets(), 103.33 ether);
        vm.assertEq(vault.localTotalAssets(), 3.33 ether);
    }

    function testMintWithRebaseZeroAmount() public {
        vm.startPrank(alice);
        vault.mintWithRebase(
            0,
            alice,
            getValidRebaseData(
                address(vault),
                0,
                block.number + 1,
                0,
                RebaseType.DEPOSIT,
                new bytes(0)
            )
        );
        assertEq(vault.balanceOf(alice), 0);
        assertEq(vault.totalAssets(), 0);
        vm.stopPrank();
    }

    function testMintWithRebaseInvalidReceiver() public {
        vm.startPrank(alice);
        vm.expectRevert();
        vault.mintWithRebase(
            1 ether,
            address(0),
            getValidRebaseData(
                address(vault),
                0,
                block.number + 1,
                0,
                RebaseType.DEPOSIT,
                new bytes(0)
            )
        );
        vm.stopPrank();
    }

    function testMintWithRebaseExpiredSignature() public {
        vm.startPrank(alice);
        bytes memory rebaseData = getValidRebaseData(
            address(vault),
            0,
            block.number,
            0,
            RebaseType.DEPOSIT,
            new bytes(0)
        );
        vm.roll(block.number + 2);
        vm.expectRevert();
        vault.mintWithRebase(1 ether, alice, rebaseData);
        vm.stopPrank();
    }

    /* -----------------------MINT WITHOUT REBASE----------------------- */
    function testMintWithoutRebase() public {
        rebaseVault(0, block.number + 1);

        // wait for rebase expiration
        vm.roll(vault.rebaseExpiresAt() + 1);

        vm.startPrank(alice);
        vm.expectRevert(LobsterVault.RebaseExpired.selector);
        vault.mint(1 ether, alice);
        vm.stopPrank();
    }

    /* -----------------------MINT WITH REBASE----------------------- */
    function testMintWithRebase() public {
        // no rebase yet
        vm.startPrank(alice);
        uint256 initialBalance = asset.balanceOf(alice);
        uint256 sharesToMint = 1 ether;
        uint256 assets = vault.mintWithRebase(
            sharesToMint,
            alice,
            getValidRebaseData(
                address(vault),
                0 ether,
                block.number + 1,
                0,
                RebaseType.DEPOSIT,
                new bytes(0)
            )
        );
        assertEq(vault.balanceOf(alice), sharesToMint);
        assertEq(asset.balanceOf(alice), initialBalance - assets);
        vm.stopPrank();
    }

    function testMintWithRebasePreviewAccuracy() public {
        vm.startPrank(alice);
        uint256 sharesToMint = 1 ether;
        uint256 previewedAssets = vault.previewMint(sharesToMint);
        uint256 actualAssets = vault.mintWithRebase(
            sharesToMint,
            alice,
            getValidRebaseData(
                address(vault),
                0 ether,
                block.number + 1,
                0,
                RebaseType.DEPOSIT,
                new bytes(0)
            )
        );
        assertEq(
            previewedAssets,
            actualAssets,
            "Preview mint should match actual mint"
        );
        vm.stopPrank();
    }

    function testMintWithRebaseAfterBridge() public {
        // Initial mint
        vm.startPrank(alice);
        vault.mintWithRebase(
            5 ether,
            alice,
            getValidRebaseData(
                address(vault),
                0 ether,
                block.number + 1,
                0,
                RebaseType.DEPOSIT,
                new bytes(0)
            )
        );
        vm.stopPrank();

        // Bridge simulation
        vm.startPrank(lobsterAlgorithm);
        vault.executeOp(
            Op({
                target: address(asset),
                value: 0,
                data: abi.encodeWithSignature(
                    "transfer(address,uint256)",
                    address(1),
                    2 ether
                )
            })
        );
        vm.stopPrank();

        // Update rebase value
        rebaseVault(2 ether, 2);

        // New mint after bridge
        vm.startPrank(bob);
        uint256 mintAmount = 1 ether;
        uint256 previewedAssets = vault.previewMint(mintAmount);
        uint256 actualAssets = vault.mintWithRebase(
            mintAmount,
            bob,
            getValidRebaseData(
                address(vault),
                2 ether,
                block.number + 3,
                0,
                RebaseType.DEPOSIT,
                new bytes(0)
            )
        );
        assertEq(previewedAssets, actualAssets);
        assertEq(vault.balanceOf(bob), mintAmount);
        vm.stopPrank();
    }

    /* -----------------------WITHDRAW----------------------- */
    function testWithdraw() public {
        // Setup initial state
        rebaseVault(0, block.number + 1);

        vm.startPrank(alice);
        vault.deposit(10 ether, alice);
        uint256 initialBalance = asset.balanceOf(alice);

        // Withdraw half the assets
        vault.withdraw(5 ether, alice, alice);

        assertEq(vault.balanceOf(alice), 5 ether);
        assertEq(asset.balanceOf(alice), initialBalance + 5 ether);
        assertEq(vault.totalAssets(), 5 ether);
        vm.stopPrank();
    }

    // Should revert if rebase is too old
    function testWithdrawAfterLimit() public {
        rebaseVault(0, block.number + 1);

        vm.startPrank(alice);
        vault.deposit(10 ether, alice);
        vm.roll(vault.rebaseExpiresAt() + 1);

        vm.expectRevert(LobsterVault.RebaseExpired.selector);
        vault.withdraw(5 ether, alice, alice);
        vm.stopPrank();
    }

    function testWithdrawWithRebaseStableValueOnL3() public {
        // Initial setup
        vm.startPrank(alice);
        uint256 initialDeposit = 10 ether;
        vault.depositWithRebase(
            initialDeposit,
            alice,
            getValidRebaseData(
                address(vault),
                0,
                block.number + 1,
                0,
                RebaseType.DEPOSIT,
                new bytes(0)
            )
        );
        vm.stopPrank();

        uint256 bridgeAmount = 5 ether;

        bridge(bridgeAmount, address(1));

        // Withdraw with rebase data
        vm.startPrank(alice);
        uint256 initialBalance = asset.balanceOf(alice);
        uint256 withdrawAmount = 5 ether;

        uint256 shares = vault.withdrawWithRebase(
            withdrawAmount,
            alice,
            alice,
            getValidRebaseData(
                address(vault),
                bridgeAmount,
                block.number + 3,
                withdrawAmount, // min amount = withdraw amount here (don't expect slippage)
                RebaseType.WITHDRAW,
                new bytes(0)
            )
        );

        assertEq(asset.balanceOf(alice), initialBalance + withdrawAmount);
        assertEq(vault.totalAssets(), initialDeposit - withdrawAmount);
        assertEq(vault.maxWithdraw(alice), initialDeposit - withdrawAmount);
        assertEq(shares, withdrawAmount);

        vm.stopPrank();
    }

    function testWithdrawWithRebaseWithL3ValueIncrease() public {
        // Initial setup
        vm.startPrank(alice);
        uint256 initialDeposit = 10 ether;
        vault.depositWithRebase(
            initialDeposit,
            alice,
            getValidRebaseData(
                address(vault),
                0,
                block.number + 1,
                0,
                RebaseType.DEPOSIT,
                new bytes(0)
            )
        );
        vm.stopPrank();

        uint256 bridgeAmount = 5 ether;

        bridge(bridgeAmount, address(1));

        // Withdraw with rebase data
        vm.startPrank(alice);
        uint256 initialBalance = asset.balanceOf(alice);
        uint256 withdrawAmount = 5 ether;
        uint256 updatedBridgeAmount = bridgeAmount * 2; // value on L3 doubled

        vault.withdrawWithRebase(
            withdrawAmount,
            alice,
            alice,
            getValidRebaseData(
                address(vault),
                updatedBridgeAmount,
                block.number + 3,
                withdrawAmount, // min amount = withdraw amount here (don't expect slippage)
                RebaseType.WITHDRAW,
                new bytes(0)
            )
        );

        assertEq(asset.balanceOf(alice), initialBalance + withdrawAmount);
        assertEq(
            vault.totalAssets(),
            initialDeposit - bridgeAmount + updatedBridgeAmount - withdrawAmount
        );
        assertEq(
            vault.maxWithdraw(alice),
            initialDeposit -
                bridgeAmount +
                updatedBridgeAmount -
                withdrawAmount -
                1
        ); // 1 less because of floating point precision

        vm.stopPrank();
    }

    function testWithdrawWithRebaseMinAmountNotMet() public {
        // Initial setup with 10 ETH deposit
        vm.startPrank(alice);
        uint256 initialDeposit = 10 ether;
        vault.depositWithRebase(
            initialDeposit,
            alice,
            getValidRebaseData(
                address(vault),
                0,
                block.number + 1,
                0,
                RebaseType.DEPOSIT,
                new bytes(0)
            )
        );

        // Bridge out most assets, leaving less than minAmount
        uint256 bridgedAmount = 9 ether;
        bridge(bridgedAmount, address(1));

        // Try to withdraw with high minAmount requirement
        vm.startPrank(alice);
        uint256 withdrawnAmount = 5 ether;
        vm.expectRevert(LobsterVault.NotEnoughAssets.selector);
        vault.withdrawWithRebase(
            withdrawnAmount,
            alice,
            alice,
            getValidRebaseData(
                address(vault),
                bridgedAmount,
                block.number + 2,
                2 ether, // min amount higher than available balance
                RebaseType.WITHDRAW,
                new bytes(0) // suppose whatever we do here, there are not enough funds in the current chain to withdraw
            )
        );
        vm.stopPrank();
    }

    function testWithdrawWithRebasePartialWithdraw() public {
        // Initial setup
        vm.startPrank(alice);
        uint256 initialDeposit = 9.2 ether;
        vault.depositWithRebase(
            initialDeposit,
            alice,
            getValidRebaseData(
                address(vault),
                0,
                block.number + 1,
                0,
                RebaseType.DEPOSIT,
                new bytes(0)
            )
        );

        // Bridge some assets
        uint256 bridgedAmount = 5.1 ether;
        bridge(bridgedAmount, address(1));

        // Try to withdraw more than local balance but accept partial withdraw
        vm.startPrank(alice);
        uint256 initialBalance = asset.balanceOf(alice);
        uint256 localBalance = asset.balanceOf(address(vault)); // Should be initialDeposit - bridgedAmount

        uint256 minAmountToReceive = localBalance - 1; // min amount < available balance
        uint256 amountToWithdraw = localBalance + 1; // Try to withdraw more eth than available locally

        assertGt(amountToWithdraw, localBalance);
        assertLt(minAmountToReceive, localBalance);

        vault.withdrawWithRebase(
            amountToWithdraw,
            alice,
            alice,
            getValidRebaseData(
                address(vault),
                bridgedAmount,
                block.number + 2,
                minAmountToReceive,
                RebaseType.WITHDRAW,
                new bytes(0)
            )
        );

        // Should only withdraw what's available locally
        assertEq(asset.balanceOf(alice), initialBalance + localBalance);
        vm.stopPrank();
    }

    /* -----------------------REDEEM----------------------------- */
    /* -----------------------REBASE----------------------------- */
    function testRebase() public {
        // Initial setup
        vm.startPrank(alice);
        uint256 initialDeposit = 150 ether;
        vault.depositWithRebase(
            initialDeposit,
            alice,
            getValidRebaseData(
                address(vault),
                0,
                block.number + 1,
                0,
                RebaseType.DEPOSIT,
                new bytes(0)
            )
        );

        // Algo bridges 10 eth
        uint256 bridgedAmount = 10 ether;
        bridge(bridgedAmount, address(1));

        // 10 eth become 20 in the other chain
        uint256 updatedBridgedAmount = 20 ether;
        rebaseVault(updatedBridgedAmount, 2);

        // ensure the vault value is updated after rebase
        assertEq(
            vault.maxWithdraw(alice),
            initialDeposit - bridgedAmount + updatedBridgedAmount - 1
        ); // -1 because of floating point precision
        assertEq(vault.localTotalAssets(), initialDeposit - bridgedAmount);
        assertEq(vault.valueOutsideVault(), updatedBridgedAmount);
        assertEq(
            vault.totalAssets(),
            initialDeposit - bridgedAmount + updatedBridgedAmount
        );
    }

    function testValueUpdateAfterRebase() public {
        // rebase to 0
        rebaseVault(0 ether, 1);

        // alice deposit 60 eth
        vm.startPrank(alice);
        vault.deposit(60 ether, alice); // no rebase since last rebase is still valid
        vm.stopPrank();

        // bob deposit 40 eth
        vm.startPrank(bob);
        vault.deposit(40 ether, bob); // no rebase since last rebase is still valid
        vm.stopPrank();

        // Algo bridges 10 eth
        bridge(10 ether, address(1));

        // 10 eth become 20 in the other chain
        rebaseVault(20 ether, 2);

        // ensure alice's assets is updated after rebase
        assertEq(vault.maxWithdraw(alice), 66 ether - 1); // -1 because of floating point precision
        assertEq(vault.maxWithdraw(bob), 44 ether - 1); // -1 because of floating point precision
        assertEq(vault.localTotalAssets(), 90 ether);
        assertEq(vault.valueOutsideVault(), 20 ether);
        assertEq(vault.totalAssets(), 110 ether); // 5 from the vault, 10 from rebase
    }

    function testRebaseWithWithdrawOperations() public {
        // Initial setup
        vm.startPrank(alice);
        uint256 initialDeposit = 150 ether;
        vault.depositWithRebase(
            initialDeposit,
            alice,
            getValidRebaseData(
                address(vault),
                0,
                block.number + 1,
                0,
                RebaseType.DEPOSIT,
                new bytes(0)
            )
        );

        // Algo bridges 10 eth
        uint256 bridgedAmount = 10 ether;
        bridge(bridgedAmount, address(1));

        // algo moves 100 eth to another contract
        uint256 amountMoved = 100 ether;
        vm.startPrank(lobsterAlgorithm);
        vault.executeOp(
            Op({
                target: address(asset),
                value: 0,
                data: abi.encodeWithSignature(
                    "transfer(address,uint256)",
                    counter,
                    amountMoved
                )
            })
        );
        vm.stopPrank();

        // ALice wants to withdraw 50 eth so we need to get some eth back from the other contract
        uint256 amountToWithdraw = 50 ether;
        uint256 amountToGetFromThirdParty = amountToWithdraw -
            (initialDeposit - bridgedAmount - amountMoved);
        Op[] memory withdrawOperations = new Op[](1);
        withdrawOperations[0] = Op({
            target: address(counter),
            value: 0,
            data: abi.encodeWithSignature(
                "incrementAndClaim(uint256)",
                amountToGetFromThirdParty
            )
        });

        uint256 alicesBalanceBefore = asset.balanceOf(alice);

        // withdraw
        vm.startPrank(alice);
        vault.withdrawWithRebase(
            amountToWithdraw,
            alice,
            alice,
            getValidRebaseData(
                address(vault),
                bridgedAmount + amountMoved,
                block.number + 2,
                50, // no slippage expected
                RebaseType.WITHDRAW,
                abi.encode(withdrawOperations)
            )
        );
        vm.stopPrank();

        assertEq(asset.balanceOf(alice), alicesBalanceBefore + amountToWithdraw);
        // assertEq();

    }

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
