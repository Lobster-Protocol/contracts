// SPDX-License-Identifier: GNUv3
pragma solidity ^0.8.28;

import {IOpValidatorModule} from "../interfaces/modules/IOpValidatorModule.sol";

contract Modular {
    IOpValidatorModule immutable opValidator;

    error OpNotApproved();
    error InvalidVault();

    event Executed(address indexed target, uint256 value, bytes4 selector);
}
