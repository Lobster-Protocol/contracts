// // SPDX-License-Identifier: GNU AGPL v3.0
// pragma solidity ^0.8.28;

// import {ERC4626WithOpValidator} from "../../../../src/Vault/ERC4626WithOpValidator.sol";
// import {Counter} from "../../../Mocks/Counter.sol";
// import {MockERC20} from "../../../Mocks/MockERC20.sol";
// import {Test} from "forge-std/Test.sol";

// // Vault base setup with validator function to be used in other test files
// contract VaultWithValidatorTestSetup is Test {
//     ERC4626WithOpValidator public vault;
//     MockERC20 public asset;
//     Counter public counter;
//     address public owner;
//     address public alice;
//     address public bob;

//     function setUp() public {
//         owner = makeAddr("owner");
//         alice = makeAddr("alice");
//         bob = makeAddr("bob");

//         // Deploy contracts
//         asset = new MockERC20();
//         counter = new Counter();

//         vault = new ERC4626WithOpValidator(
//             owner,
//             "receiptTokenName_",
//             "receiptTokenSymbol_",
//             asset
//         );

//         // Setup initial state
//         asset.mint(alice, 10000 ether);
//         asset.mint(bob, 10000 ether);

//         vm.startPrank(alice);
//         asset.approve(address(vault), type(uint256).max);
//         vm.stopPrank();

//         vm.startPrank(bob);
//         asset.approve(address(vault), type(uint256).max);
//         vm.stopPrank();
//     }
// }
