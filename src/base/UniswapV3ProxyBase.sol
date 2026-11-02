// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.20;

import {Guards} from "./Guards.sol";

/// @title State shared by every Uniswap V3 mixin
/// @notice Holds the factory address, from which every V3 pool address is derived (CREATE2).
/// @dev The constructor lives here rather than in the mixins so that {LobsterProxy} can inherit both
/// {UniswapV3MintProxy} and {UniswapSwapProxy} without passing base constructor arguments twice.
/// The factory is also what pool addresses, hence registry keys and the mint callback's
/// authentication (`CallbackValidation`), derive from, so a wrong value here breaks the whole V3
/// surface rather than degrading it.
abstract contract UniswapV3ProxyBase is Guards {
    address public immutable UNI_V3_FACTORY;

    constructor(address _uniV3Factory) {
        require(_uniV3Factory != address(0), ZeroAddress());
        UNI_V3_FACTORY = _uniV3Factory;
    }

    /// @dev The price and tick in `pool`'s Slot0. Reverts with `NotAPool` unless `pool` returns one (no
    /// code there: no pool was ever deployed at that address).
    function _slot0(address pool) internal view returns (uint160 sqrtPriceX96, int24 tick) {
        assembly ("memory-safe") {
            mstore(0, 0x3850c7bd) // slot0()
            if iszero(staticcall(gas(), pool, 0x1c, 0x04, 0, 0x40)) {
                returndatacopy(0, 0, returndatasize())
                revert(0, returndatasize())
            }
            if lt(returndatasize(), 0x40) {
                mstore(0, 0x2bab4241) // NotAPool()
                revert(0x1c, 0x04)
            }
            sqrtPriceX96 := and(mload(0), 0xffffffffffffffffffffffffffffffffffffffff)
            tick := signextend(2, mload(0x20))
        }
    }
}
