// SPDX-License-Identifier: GNUv3
pragma solidity ^0.8.28;

import {IOpValidatorModule} from "../interfaces/modules/IOpValidatorModule.sol";
import {IHook} from "../interfaces/modules/IHook.sol";
import {INav} from "../interfaces/modules/INav.sol";

contract Modular {
    IOpValidatorModule public immutable opValidator;
    // todo: 1 hook for all calls or 1 hook per call?
    IHook public immutable hook;
    INav public immutable navModule;

    error PreHookFailed();
    error PostHookFailed();
    error OpNotApproved();
    error InvalidVault();

    event Executed(address indexed target, uint256 value, bytes4 selector);
    event OpValidatorSet(IOpValidatorModule);
    event HookSet(IHook);
    event NavModuleSet(INav);
}
