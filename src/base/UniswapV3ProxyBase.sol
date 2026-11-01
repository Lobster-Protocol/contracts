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
        UNI_V3_FACTORY = _uniV3Factory;
    }
}
