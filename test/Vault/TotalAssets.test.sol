// SPDX-License-Identifier: GNU AGPL v3.0
pragma solidity ^0.8.28;

import {SimpleVaultTestSetup} from "./VaultSetups/SimpleVaultTestSetup.sol";
import {VaultWithNavModuleTestSetup} from "./VaultSetups/WithDummyModules/VaultWithNavModuleTestSetup.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {DUMMY_NAV_AMOUNT} from "../Mocks/modules/DummyNav.sol";

contract TotalAssetsNoNavModuleTest is SimpleVaultTestSetup {
    function testTotalAssets() public view {
        assertEq(vault.totalAssets(), IERC20(vault.asset()).balanceOf(address(vault)));
    }
}

contract TotalAssetsWithNavModuleTest is VaultWithNavModuleTestSetup {
    function testTotalAssets() public view {
        assertEq(vault.totalAssets(), DUMMY_NAV_AMOUNT);
    }
}
