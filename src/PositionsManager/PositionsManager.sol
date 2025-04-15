// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {UniswapV3Position} from "./uniswap/UniswapV3Position.sol";
import {AaveV3Position} from "./aave/AaveV3Position.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ILobsterPositionsManager as IPositionsManager} from "../interfaces/IPositionsManager.sol";

/**
 * @title EthValueRetriever
 * @author Elli610
 * @notice This contract is used to retrieve the total value (in ETH) held by a specific address across multiple protocols on the same chain.
 */
contract LobsterPositionsManager is IPositionsManager, UniswapV3Position, AaveV3Position {
    string public constant supportedProtocols = "UniswapV3 | Aave | WETH";

    constructor(
        address uniswapPositionManagerAddress,
        address uniswapV3Factory_,
        address weth_,
        address aaveLendingPoolAddress,
        address aavePriceOracle
    )
        UniswapV3Position(uniswapPositionManagerAddress, uniswapV3Factory_, weth_)
        AaveV3Position(aaveLendingPoolAddress, aavePriceOracle, weth_)
    {}

    function getTotalValueInETH(address user) public view returns (uint256) {
        uint256 userWETHBalance = IERC20(wethAddress).balanceOf(user);
        uint256 userNativeBalance = user.balance;

        return
        // add any protocol as needed
        getUniswapV3PositionValueInETH(user) + getAaveV3NetPositionValueInETH(user) // aave deposits - aave debts
            + userWETHBalance + userNativeBalance;
    }
}
