// SPDX-License-Identifier: GNUv3
pragma solidity ^0.8.28;

import {Op} from "./IOpValidatorModule.sol";

interface INav {
    // returns the total assets (whatever this means) owned by the caller
    function totalAssets() external view returns (uint256);
}
