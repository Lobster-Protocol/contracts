// SPDX-License-Identifier: GNUv3
pragma solidity ^0.8.28;

import {IOpValidatorModule} from "../../../../src/interfaces/modules/IOpValidatorModule.sol";
import {MockERC20} from "../../../Mocks/MockERC20.sol";
import {Counter} from "../../../Mocks/Counter.sol";
import {ERC4626WithOpValidator} from "../../../../src/Vault/ERC4626WithOpValidator.sol";
import {Test} from "forge-std/Test.sol";
import {DummyValidator} from "../../../Mocks/modules/DummyValidator.sol";

contract VaultWithOperationModuleTestSetup is Test {
    ERC4626WithOpValidator public vault;
    MockERC20 public asset;
    Counter public counter;
    address public owner;
    address public alice;
    address public bob;

    function setUp() public {
        owner = makeAddr("owner");
        alice = makeAddr("alice");
        bob = makeAddr("bob");

        IOpValidatorModule opValidator = new DummyValidator();

        // Deploy contracts
        asset = new MockERC20();
        counter = new Counter();

        vault = new ERC4626WithOpValidator(
            "receiptTokenName",
            "receiptTokenSymbol",
            asset,
            opValidator
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
}
