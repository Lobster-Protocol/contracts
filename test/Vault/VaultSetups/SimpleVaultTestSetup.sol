// SPDX-License-Identifier: GNU AGPL v3.0
pragma solidity ^0.8.28;

import {LobsterVault} from "../../../src/Vault/Vault.sol";
import {Counter} from "../../Mocks/Counter.sol";
import {MockERC20} from "../../Mocks/MockERC20.sol";
import {IHook} from "../../../src/interfaces/modules/IHook.sol";
import {INav} from "../../../src/interfaces/modules/INav.sol";
import {IOpValidatorModule} from "../../../src/interfaces/modules/IOpValidatorModule.sol";
import {VaultTestUtils} from "./VaultTestUtils.sol";

// Vault base setup & utils function to be used in other test files
contract SimpleVaultTestSetup is VaultTestUtils {
    function setUp() public {
        owner = makeAddr("owner");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        lobsterAlgorithm = makeAddr("lobsterAlgorithm");
        feeCollector = makeAddr("feeCollector");
        lobsterRebaserPrivateKey = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
        lobsterRebaser = vm.addr(lobsterRebaserPrivateKey);

        // Deploy contracts
        asset = new MockERC20();
        counter = new Counter();

        vault = new LobsterVault(
            owner,
            asset,
            "Vault Token",
            "vTKN",
            lobsterAlgorithm,
            IOpValidatorModule(address(0)),
            IHook(address(0)),
            INav(address(0))
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
