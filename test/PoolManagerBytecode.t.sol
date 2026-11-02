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
            assertEq(_codeHash(POOL_MANAGER_BYTECODE), _codeHash(fresh), "regenerate bytecodes/poolManager.sol");
        } catch {
            vm.skip(true);
        }
    }

    /// @dev keccak256 of `code` without the CBOR metadata solc appends to it. The metadata hashes the
    /// compiler input, which includes remappings that forge writes with absolute paths, so it differs from
    /// one checkout and forge version to another while the code itself does not. Its length is in the
    /// last 2 bytes.
    function _codeHash(bytes memory code) internal pure returns (bytes32 hash) {
        uint256 length = code.length;
        require(length >= 2, "no metadata");
        uint256 metadataLength = (uint256(uint8(code[length - 2])) << 8) | uint8(code[length - 1]);
        require(metadataLength + 2 <= length, "no metadata");
        assembly ("memory-safe") {
            hash := keccak256(add(code, 0x20), sub(length, add(metadataLength, 2)))
        }
    }
}
