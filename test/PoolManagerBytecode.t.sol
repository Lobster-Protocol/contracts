// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.24;

import "forge-std/Test.sol";
import {POOL_MANAGER_BYTECODE} from "./Mocks/uniswapV4/bytecodes/poolManager.sol";

/// @notice The committed PoolManager creation code is exactly what this repo builds from lib/v4-core
contract PoolManagerBytecodeTest is Test {
    function test_committedBytecodeMatchesFreshBuild() public {
        // The artifact comes from `forge build` (CI runs it before the tests). A bare `forge test`
        // only compiles what the tests import, which excludes PoolManagerBuild.sol: then this skips.
        try vm.getCode("out/PoolManager.sol/PoolManager.json") returns (bytes memory fresh) {
            assertEq(keccak256(POOL_MANAGER_BYTECODE), keccak256(fresh), "regenerate bytecodes/poolManager.sol");
        } catch {
            vm.skip(true);
        }
    }
}
