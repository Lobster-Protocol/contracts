// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.20;

import {UniswapV3MintProxy} from "../../src/UniswapV3MintProxy.sol";
import {UniswapV3SwapProxy} from "../../src/UniswapV3SwapProxy.sol";
import {UniswapV3ProxyBase} from "../../src/base/UniswapV3ProxyBase.sol";

/// @title Deployable V3-only proxy, for tests
/// @notice The V3 mixins in src/ are abstract; {UniswapProxy} is the only deployable combination and
/// it is pinned to solc 0.8.26. The V3 test suites pull in `UniswapV3Infra` and the vault contracts,
/// which are `^0.8.28`, so those compilation units can never contain {UniswapProxy}. This harness
/// gives them a concrete V3 surface with a floating pragma instead.
/// @dev Test-only. Not part of the deployed system — deploy {UniswapProxy}.
contract UniswapV3ProxyHarness is UniswapV3MintProxy, UniswapV3SwapProxy {
    constructor(address _uniV3Factory) UniswapV3ProxyBase(_uniV3Factory) {}
}
