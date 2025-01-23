// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import {IAaveV3Pool} from "./lib/IAaveV3Pool.sol";
import {IAaveOracle} from "./lib/IAaveOracle.sol";
import {Constants} from "../Constants.sol";

contract AaveV3Position is Constants {
    IAaveV3Pool public immutable aavePool;
    IAaveOracle public immutable aaveOracle;

    constructor(address _pool, address _oracle, address _weth) {
        aavePool = IAaveV3Pool(_pool);
        aaveOracle = IAaveOracle(_oracle);
        wethAddress = _weth;
    }

    struct UserAssetData {
        uint256 deposited;
        uint256 borrowed;
        uint256 collateral;
        bool isCollateral;
    }

    function getUserAssetData(
        address user,
        address asset
    ) public view returns (UserAssetData memory) {
        (
            uint256 currentATokenBalance,
            uint256 currentStableDebt,
            uint256 currentVariableDebt, // principalStableDebt // scaledVariableDebt // stableBorrowRate // liquidityRate // stableRateLastUpdated
            ,
            ,
            ,
            ,
            ,
            bool usageAsCollateralEnabled
        ) = aavePool.getUserReserveData(asset, user);

        return
            UserAssetData({
                deposited: currentATokenBalance,
                borrowed: currentStableDebt + currentVariableDebt,
                collateral: usageAsCollateralEnabled ? currentATokenBalance : 0,
                isCollateral: usageAsCollateralEnabled
            });
    }

    function getAllUserAssets(
        address user
    )
        external
        view
        returns (address[] memory assets, UserAssetData[] memory data)
    {
        assets = aavePool.getReservesList();
        data = new UserAssetData[](assets.length);

        for (uint256 i = 0; i < assets.length; i++) {
            data[i] = getUserAssetData(user, assets[i]);
        }
    }

    function getUserTotalCollateralAndDebt(
        address user
    ) public view returns (uint256 totalCollateralBase, uint256 totalDebtBase) {
        (
            totalCollateralBase, // 8 decimals
            totalDebtBase, // availableBorrowsBase // currentLiquidationThreshold // ltv
            ,
            ,
            ,

        ) = aavePool.getUserAccountData(user);
    }

    function getAaveV3NetPositionValueInETH(
        address user
    ) public view returns (uint256) {
        (
            uint256 totalCollateralBase,
            uint256 totalDebtBase
        ) = getUserTotalCollateralAndDebt(user);

        uint256 wethPrice = aaveOracle.getAssetPrice(wethAddress); // 8 decimals

        // and convert the remaining value to eth
        return (totalCollateralBase - totalDebtBase * 1e18) / wethPrice;
    }
}
