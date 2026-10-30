// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.20;

import {Operation} from "../../../src/interfaces/zodiac/IRoles.sol";

/// @notice The part of a Safe that modules use: enabled modules may make the Safe call anything.
/// @dev Faithful to Safe 1.4.1's `ModuleManager` for plain calls: `execTransactionFromModule*` never
/// revert on a failed call, they return `success = false`. Owner-signed transactions are simulated in
/// tests with `vm.prank(address(safe))`. Delegatecalls are not supported (never used here).
contract MockSafe {
    address private immutable _deployer;
    mapping(address module => bool) public isModuleEnabled;

    constructor() {
        _deployer = msg.sender;
    }

    /// @dev On a real Safe, an owner transaction calling itself; here, the deployer or the Safe
    function enableModule(address module) external {
        require(msg.sender == _deployer || msg.sender == address(this), "GS031");
        isModuleEnabled[module] = true;
    }

    function execTransactionFromModule(
        address to,
        uint256 value,
        bytes calldata data,
        Operation operation
    )
        external
        returns (bool success)
    {
        (success,) = _exec(to, value, data, operation);
    }

    function execTransactionFromModuleReturnData(
        address to,
        uint256 value,
        bytes calldata data,
        Operation operation
    )
        external
        returns (bool success, bytes memory returnData)
    {
        return _exec(to, value, data, operation);
    }

    function _exec(
        address to,
        uint256 value,
        bytes calldata data,
        Operation operation
    )
        private
        returns (bool, bytes memory)
    {
        require(isModuleEnabled[msg.sender], "GS104");
        require(operation == Operation.Call, "MockSafe: calls only");
        return to.call{value: value}(data);
    }

    receive() external payable {}
}
