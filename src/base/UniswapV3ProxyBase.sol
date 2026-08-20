// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.20;

import {IUniswapV3PoolMinimal} from "../interfaces/uniswapV3/IUniswapV3PoolMinimal.sol";
import {PoolAddress} from "../libraries/uniswapV3/PoolAddress.sol";
import {Deadline} from "./Deadline.sol";

/// @title State shared by every Uniswap V3 mixin
/// @notice Holds the factory address and derives pool addresses from it.
/// @dev The constructor lives here rather than in the mixins so that {UniswapProxy} can inherit both
/// {UniswapV3MintProxy} and {UniswapV3SwapProxy} without passing base constructor arguments twice.
/// The factory is also what authenticates pool callbacks (see `CallbackValidation`), so a wrong
/// value here breaks the whole v3 surface rather than degrading it.
abstract contract UniswapV3ProxyBase is Deadline {
    address public immutable UNI_V3_FACTORY;

    constructor(address _uniV3Factory) {
        UNI_V3_FACTORY = _uniV3Factory;
    }

    /// @dev V3 pools are individual contracts at CREATE2-derivable addresses, so there is no lookup
    function _getPool(address tokenA, address tokenB, uint24 fee) internal view returns (IUniswapV3PoolMinimal) {
        return
            IUniswapV3PoolMinimal(
                PoolAddress.computeAddress(UNI_V3_FACTORY, PoolAddress.getPoolKey(tokenA, tokenB, fee))
            );
    }
}
