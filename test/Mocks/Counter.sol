// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract Counter {
    IERC20 immutable asset;
    uint256 counter = 0;

    constructor(IERC20 asset_) {
        asset = asset_;
    }

    function ping() external pure returns (string memory) {
        return "pong";
    }

    function increment() external {
        counter++;
    }

    function incrementAndClaim(uint256 amount) external returns (uint256) {
        // Check contract's balance first
        uint256 contractBalance = asset.balanceOf(address(this));
        require(contractBalance >= amount, "Contract has insufficient balance");

        counter++;

        bool success = asset.transfer(msg.sender, amount);
        require(success, "Transfer failed");

        return counter;
    }
}
