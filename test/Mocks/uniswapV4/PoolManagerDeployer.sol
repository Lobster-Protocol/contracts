// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.24;

import {POOL_MANAGER_BYTECODE} from "./bytecodes/poolManager.sol";

/// @notice Deploys a real v4-core PoolManager from its committed 0.8.26 creation code, so tests built
/// with another compiler (the Lobster contracts need 0.8.28) can use one through `IPoolManager`.
library PoolManagerDeployer {
    function deploy(address owner) internal returns (address manager) {
        bytes memory code = abi.encodePacked(POOL_MANAGER_BYTECODE, abi.encode(owner));
        assembly {
            manager := create(0, add(code, 0x20), mload(code))
        }
        require(manager != address(0), "PoolManager deployment failed");
    }
}
