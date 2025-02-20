// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {PendingFeeUpdate} from "../../src/Vault/ERC4626Fees.sol";
import {VaultTestSetup} from "./VaultTestSetup.sol";
import {ERC4626Fees} from "../../src/Vault/ERC4626Fees.sol";
import {BASIS_POINT_SCALE} from "../../src/Vault/Constants.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

// test deposit / withdraw / mint / redeem max functions
contract VaultMaxFunctions is VaultTestSetup {
    using Math for uint256;

    // the default fess are set to 0

    /* -----------------------TEST MAX FUNCTIONS----------------------- */
    // todo
    /* -----------------------TEST MAX FUNCTIONS WITH FEES----------------------- */
    // todo
}
