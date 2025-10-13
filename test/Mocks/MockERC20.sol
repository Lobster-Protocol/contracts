// SPDX-License-Identifier: GNU AGPL v3.0
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockERC20 is ERC20 {
    constructor() ERC20("Mock Token", "MTK") {
        _mint(msg.sender, 1000000 ether);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(address owner, uint256 amount) external {
        _burn(owner, amount);
    }
}
