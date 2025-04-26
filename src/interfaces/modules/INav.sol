// SPDX-License-Identifier: GPLv3
pragma solidity ^0.8.28;

import {Op} from "./IOpValidatorModule.sol";

/**
 * @title INav Interface
 * @author Lobster
 * @notice Module interface which, if set in the vault, replaces the default totalAssets function.
 * This interface is responsible for computing the totalAssets for a vault using custom logic.
 */
interface INav {
    /**
     * @notice Returns the total assets owned by the caller
     * @dev This function overrides the default totalAssets calculation in the vault
     * @return The total asset value in the asset's base units
     */
    function totalAssets() external view returns (uint256);
}
