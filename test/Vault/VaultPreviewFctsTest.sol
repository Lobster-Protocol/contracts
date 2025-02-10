// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {PendingFeeUpdate} from "../../src/Vault/ERC4626Fees.sol";
import {VaultTestSetup} from "./VaultTestSetup.sol";
import {ERC4626Fees} from "../../src/Vault/ERC4626Fees.sol";

// test deposit / withdraw / mint / redeem fee
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

    function computeFees(
        uint256 amount,
        uint256 fee
    ) public pure returns (uint256) {
        return (amount * fee) / 10000;
    }

    /* -----------------------TEST PREVIEW FUNCTIONS----------------------- */
    // todo

    /* -----------------------TEST MAX FUNCTIONS----------------------- */
    // todo
}
