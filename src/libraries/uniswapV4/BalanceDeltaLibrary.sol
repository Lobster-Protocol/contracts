// SPDX-License-Identifier: MIT
pragma solidity >=0.8.20;

import {BalanceDelta} from "../../interfaces/uniswapV4/IPoolManagerMinimal.sol";

/// @notice Unpacks the two int128 amounts packed into a BalanceDelta
/// @dev Mirrors Uniswap/v4-core `src/types/BalanceDelta.sol`
library BalanceDeltaLibrary {
    /// @notice The upper 128 bits of the delta, i.e. the amount of currency0
    function amount0(BalanceDelta balanceDelta) internal pure returns (int128 _amount0) {
        assembly ("memory-safe") {
            // arithmetic shift right keeps the sign
            _amount0 := sar(128, balanceDelta)
        }
    }

    /// @notice The lower 128 bits of the delta, i.e. the amount of currency1
    function amount1(BalanceDelta balanceDelta) internal pure returns (int128 _amount1) {
        assembly ("memory-safe") {
            // sign extend from the 16th byte (0-indexed), i.e. treat the low 128 bits as int128
            _amount1 := signextend(15, balanceDelta)
        }
    }
}
