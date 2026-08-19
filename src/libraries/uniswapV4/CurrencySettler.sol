// SPDX-License-Identifier: MIT
pragma solidity >=0.8.20;

import {Currency, IPoolManagerMinimal} from "../../interfaces/uniswapV4/IPoolManagerMinimal.sol";
import {TransferHelper} from "../uniswapV3/TransferHelper.sol";

/// @notice Resolves the currency deltas left open by a v4 operation
/// @dev Mirrors the settle/take pattern used by Uniswap's own periphery (`DeltaResolver`).
library CurrencySettler {
    /// @notice Pays the manager what is owed for `currency`
    /// @dev Native currency is paid from this contract's balance (funded by msg.value); ERC20s are
    /// pulled straight from `payer` into the manager, so the proxy never custodies them.
    /// @param currency The currency owed to the manager
    /// @param manager The PoolManager singleton
    /// @param payer The address to pull ERC20 tokens from. Ignored for the native currency.
    /// @param amount The amount to settle
    function settle(Currency currency, IPoolManagerMinimal manager, address payer, uint256 amount) internal {
        // sync checkpoints the manager's balance so that settle() can measure what arrived
        manager.sync(currency);

        if (isNative(currency)) {
            manager.settle{value: amount}();
        } else {
            TransferHelper.safeTransferFrom(Currency.unwrap(currency), payer, address(manager), amount);
            manager.settle();
        }
    }

    /// @notice Withdraws `amount` of `currency` owed to us, straight to `recipient`
    function take(Currency currency, IPoolManagerMinimal manager, address recipient, uint256 amount) internal {
        manager.take(currency, recipient, amount);
    }

    /// @notice In v4 the zero address is the native currency
    function isNative(Currency currency) internal pure returns (bool) {
        return Currency.unwrap(currency) == address(0);
    }
}
