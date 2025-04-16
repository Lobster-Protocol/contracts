// SPDX-License-Identifier: GNU AGPL v3.0
pragma solidity ^0.8.28;

import {INav} from "../../../src/interfaces/modules/INav.sol";

uint256 constant DUMMY_NAV_AMOUNT = 123456789;

contract DummyNav is INav {
    function totalAssets() external pure returns (uint256) {
        return DUMMY_NAV_AMOUNT;
    }
}
