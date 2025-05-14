// SPDX-License-Identifier: GNU AGPL v3.0

pragma solidity ^0.8.28;

import {LobsterFeesVault} from "../../../src/Vault/VaultFees.sol";
import {Counter} from "../../Mocks/Counter.sol";
import {MockERC20} from "../../Mocks/MockERC20.sol";
import {IHook} from "../../../src/interfaces/modules/IHook.sol";
import {IVaultFlowModule} from "../../../src/interfaces/modules/IVaultFlowModule.sol";
import {INav} from "../../../src/interfaces/modules/INav.sol";
import {IOpValidatorModule} from "../../../src/interfaces/modules/IOpValidatorModule.sol";
import {VaultFeesTestUtils} from "./VaultFeesTestUtils.sol";

// Vault base setup & utils function to be used in other test files
contract SimpleVaultFeesTestSetup is VaultFeesTestUtils {
    function setUp() public {
        owner = makeAddr("owner");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        lobsterAlgorithm = makeAddr("lobsterAlgorithm");
        feeCollector = makeAddr("feeCollector");

        // Deploy contracts
        asset = new MockERC20();
        counter = new Counter();

        vault = new LobsterFeesVault(
            owner,
            asset,
            "Vault Token",
            "vTKN",
            lobsterAlgorithm,
            IOpValidatorModule(address(0)),
            IHook(address(0)),
            INav(address(0)),
            IVaultFlowModule(address(0)),
            0,
            0,
            0
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
