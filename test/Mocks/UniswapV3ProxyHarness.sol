// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.20;

import {UniswapV3MintProxy} from "../../src/UniswapV3MintProxy.sol";
import {UniswapV3ProxyBase} from "../../src/base/UniswapV3ProxyBase.sol";
import {MintParams} from "../../src/interfaces/uniswapV3/IUniswapV3MintCallback.sol";

/// @title Deployable V3 mint, without the registry, for tests
/// @notice {LobsterProxy} only mints on pools a vault registered, with a price band, to the vault itself.
/// This harness exposes the same mint body ({UniswapV3MintProxy-_mint}) and callback without those
/// checks, as `mintUnchecked` (the inherited, checked `mint` and `mintWithRecording` are still there), so the vault suites (via TestHelper) and the V3 mint tests can seed and inspect positions on
/// any pool, for any recipient.
/// @dev Test-only. Not part of the deployed system.
contract UniswapV3ProxyHarness is UniswapV3MintProxy {
    /// @notice The recipient is address(0) or this harness (the position could never be withdrawn)
    error InvalidRecipient();

    constructor(address _uniV3Factory) UniswapV3ProxyBase(_uniV3Factory) {}

    function mintUnchecked(MintParams calldata params)
        external
        nonReentrant
        checkDeadline(params.deadline)
        returns (uint256 amount0, uint256 amount1)
    {
        require(params.recipient != address(0) && params.recipient != address(this), InvalidRecipient());
        return _mint(params);
    }
}
