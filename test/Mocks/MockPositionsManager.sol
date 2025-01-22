// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ILobsterPositionsManager as IPositionsManager} from "../../src/interfaces/IPositionsManager.sol";

contract MockPositionsManager is IPositionsManager {
    mapping(address => uint256) public totalValueInETH;

    // mock function to update the total value in ETH
    function setTotalValueInETH(uint256 value) external {
        totalValueInETH[msg.sender] = value;
    }

    function getTotalValueInETH(
        address user
    ) external view override returns (uint256) {
        return totalValueInETH[user];
    }
}
