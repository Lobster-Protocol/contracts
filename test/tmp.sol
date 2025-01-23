// SPDX-License-Identifier: GNU AGPL v3.0
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import {AaveQueries} from "../src/PositionsManager/aave/AavePosition.sol";

contract AaveTest is Test {
    AaveQueries queries;

    function setUp() public {
        address aavePool = address(0x6Ae43d3271ff6888e7Fc43Fd7321a503ff738951);
        address aavePriceOracle = address(0x2da88497588bf89281816106C7259e31AF45a663);
        address weth = address(0xC558DBdd856501FCd9aaF1E62eae57A9F0629a3c);
        queries = new AaveQueries(aavePool, aavePriceOracle, weth);
    }

    function testGet() public view {
        console2.log("start");
        (
            uint256 totalCollateralBase,
            uint256 totalCollateralBaseInEth,
            uint256 totalDebtBase,
            uint256 healthFactor
        ) = queries.getUserTotalCollateralAndDebt(
                address(0x9198aEf8f3019f064d0826eB9e07Fb07a3d3a4BD)
            );

        console2.log("totalCollateralBase", totalCollateralBase);
        console2.log("totalCollateralBaseInEth", totalCollateralBaseInEth);
        console2.log("totalDebtBase", totalDebtBase);
        console2.log("healthFactor", healthFactor);
    }
}
