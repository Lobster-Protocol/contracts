// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import "../../src/Vault/Vault.sol";
import {VaultTestSetup} from "./VaultTestSetup.sol";

contract VaultInAndOutFeesTest is VaultTestSetup {
    // the default fess are set to 0

    /* -----------------------HELPER FUNCTIONS TO SET VAULT FEES----------------------- */
    function setEntryFeeBasisPoint(uint256 fee) public returns (bool) {
        vm.startPrank(owner);
        vault.setEntryFee(fee);
        vm.stopPrank();

        return true;
    }

    function setExitFeeBasisPoint(uint256 fee) public returns (bool) {
        vm.startPrank(owner);
        vault.setExitFee(fee);
        vm.stopPrank();

        return true;
    }
}
