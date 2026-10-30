// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.20;

import {UniswapV3MintProxy} from "../../src/UniswapV3MintProxy.sol";
import {UniswapV3SwapProxy} from "../../src/UniswapV3SwapProxy.sol";
import {UniswapV3ProxyBase} from "../../src/base/UniswapV3ProxyBase.sol";

/// @title Deployable V3-only composition of the mixins, for tests
/// @notice The V3 mixins in src/ are abstract; {LobsterProxy} is the only deployable combination
/// and it is pinned to solc 0.8.26. The V3 mixin suite (UniswapV3ProxyTest) pulls in `UniswapV3Infra`
/// and the vault contracts, which are `^0.8.28`, so its compilation unit can never contain
/// {LobsterProxy}. This harness gives it the mixins' own V3 entry points, without the registry,
/// under a floating pragma. LobsterProxy's V3 surface is tested in LobsterProxy.t.sol.
/// @dev Test-only. Not part of the deployed system.
contract UniswapV3ProxyHarness is UniswapV3MintProxy, UniswapV3SwapProxy {
    constructor(address _uniV3Factory) UniswapV3ProxyBase(_uniV3Factory) {}
}
