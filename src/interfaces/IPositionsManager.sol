// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title EthValueRetriever
 * @author Elli610
 */
interface ILobsterPositionsManager {
    function getTotalValueInETH(address user) external view returns (uint256);

    // todo: add a function to handle a withdraw (unlock funds as needed)
}
