// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import {IAaveV3Pool} from "./lib/IAaveV3Pool.sol";
import {IAaveOracle} from "./lib/IAaveOracle.sol";

contract AaveV3Position {
    IAaveV3Pool public immutable pool;
    IAaveOracle public immutable oracle;
    address public immutable weth;

    constructor(address _pool, address _oracle, address _weth) {
        pool = IAaveV3Pool(_pool);
        oracle = IAaveOracle(_oracle);
        weth = _weth;
    }

    struct UserAssetData {
        uint256 deposited;
        uint256 borrowed;
        uint256 collateral;
        bool isCollateral;
    }

    function getUserAssetData(address user, address asset) public view returns (UserAssetData memory) {
        (
            uint256 currentATokenBalance,
            uint256 currentStableDebt,
            uint256 currentVariableDebt,
            ,  // principalStableDebt
            ,  // scaledVariableDebt
            ,  // stableBorrowRate
            ,  // liquidityRate
            ,  // stableRateLastUpdated
            bool usageAsCollateralEnabled
        ) = pool.getUserReserveData(asset, user);

        return UserAssetData({
            deposited: currentATokenBalance,
            borrowed: currentStableDebt + currentVariableDebt,
            collateral: usageAsCollateralEnabled ? currentATokenBalance : 0,
            isCollateral: usageAsCollateralEnabled
        });
    }

    function getAllUserAssets(address user) external view returns (address[] memory assets, UserAssetData[] memory data) {
        assets = pool.getReservesList();
        data = new UserAssetData[](assets.length);

        for (uint256 i = 0; i < assets.length; i++) {
            data[i] = getUserAssetData(user, assets[i]);
        }
    }

    function getUserTotalCollateralAndDebt(address user) external view returns (
        uint256 totalCollateralBase,
        uint256 totalCollateralBaseInEth,
        uint256 totalDebtBase,
        uint256 healthFactor
    ) {
        (
            totalCollateralBase, // 8 decimals 
            totalDebtBase,
            ,  // availableBorrowsBase
            ,  // currentLiquidationThreshold
            ,  // ltv
            healthFactor
        ) = pool.getUserAccountData(user);
        
        uint256 wethPrice = oracle.getAssetPrice(weth); // 8 decimals
        
        // convert the totalCollateralBase to eth
        totalCollateralBaseInEth = (totalCollateralBase * 1e18) / wethPrice;
    }
}
