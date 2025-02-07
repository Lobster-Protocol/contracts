// SPDX-License-Identifier: GNU AGPL v3.0
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import {LobsterVault, Op} from "../../src/Vault/Vault.sol";
import {Counter} from "../Mocks/Counter.sol";
import {MockERC20} from "../Mocks/MockERC20.sol";
import {MockPositionsManager} from "../Mocks/MockPositionsManager.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

enum RebaseType {
    DEPOSIT,
    MINT,
    WITHDRAW,
    REDEEM
}

// Vault base setup & utils function to be used in other test files
contract VaultTestSetup is Test {
    MockPositionsManager public positionManager;
    LobsterVault public vault;
    MockERC20 public asset;
    Counter public counter;
    address public owner;
    address public alice;
    address public bob;
    address public lobsterAlgorithm;
    address public lobsterRebaser;
    uint256 public lobsterRebaserPrivateKey;

    // fees
    address public entryFeeCollector;
    address public exitFeeCollector;
    uint256 public entryFeeBasisPoints = 0;
    uint256 public exitFeeBasisPoints = 0;
    //

    function setUp() public {
        owner = makeAddr("owner");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        lobsterAlgorithm = makeAddr("lobsterAlgorithm");
        entryFeeCollector = makeAddr("entryFeeCollector");
        exitFeeCollector = makeAddr("exitFeeCollector");
        lobsterRebaserPrivateKey = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
        lobsterRebaser = vm.addr(lobsterRebaserPrivateKey);

        // Deploy contracts
        asset = new MockERC20();
        positionManager = new MockPositionsManager();
        counter = new Counter(asset);

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
            validTargetsAndSelectorsData,
            entryFeeCollector,
            exitFeeCollector
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

    // Simulate a rebase operation
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

    // Simulate some value being bridged / sent to another protocol by the algorithm
    function bridge(uint256 value, address receiver) public {
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
}
