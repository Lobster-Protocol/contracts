// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ExactInputSingleParams, ExactOutputSingleParams} from "./interfaces/uniswapV3/IUniswapV3SwapCallback.sol";
import {V4ExactInputSingleParams, V4ExactOutputSingleParams} from "./interfaces/uniswapV4/IUnlockCallback.sol";
import {Currency, PoolKey} from "./interfaces/uniswapV4/IPoolManagerMinimal.sol";
import {Chaining} from "./libraries/Chaining.sol";
import {UniswapV3SwapProxy} from "./UniswapV3SwapProxy.sol";
import {UniswapV4SwapProxy} from "./UniswapV4SwapProxy.sol";

/// @notice The first byte of every element of a {UniswapBatchSwapProxy-batchSwap} batch.
/// @dev Each value stands for one single-swap entry point, and the bytes after it are that entry
/// point's params, `abi.encode`d. 0x00 is deliberately unused, so a zeroed element is rejected rather
/// than read as a swap.
library SwapType {
    uint8 internal constant V3_EXACT_INPUT = 0x01; // as {UniswapV3SwapProxy-exactInputSingle}
    uint8 internal constant V3_EXACT_OUTPUT = 0x02; // as {UniswapV3SwapProxy-exactOutputSingle}
    uint8 internal constant V4_EXACT_INPUT = 0x03; // as {UniswapV4SwapProxy-exactInputSingleV4}
    uint8 internal constant V4_EXACT_OUTPUT = 0x04; // as {UniswapV4SwapProxy-exactOutputSingleV4}
}

/// @title Batched and chained V3 + V4 swaps
/// @notice Runs several swaps, on either Uniswap version, in one atomic transaction, optionally
/// chaining them so that a later swap spends exactly what an earlier one produced.
/// @dev Each element is `abi.encodePacked(uint8 swapType, abi.encode(params))`. The loop dispatches
/// on the {SwapType} byte to the same internal body the matching single-swap entry point runs, so a
/// batched swap is checked (deadline, slippage, hooks) exactly as if it had been called on its own.
/// If any swap reverts, the whole batch reverts with that swap's reason.
///
/// CHAINING, with the two values in {Chaining}:
/// - `recipient = ADDRESS_THIS` parks a swap's output in the proxy instead of sending it out.
/// - `amountIn = HELD_BALANCE` (exact-input swaps only) spends everything the proxy holds of the
///   input token, and the proxy pays for it. Every other swap is paid by the caller.
/// Several parked outputs of the same token merge into one balance, so routes can converge. Splitting
/// a parked balance across swaps, and exact-output swaps paid from parked funds, are not supported.
///
/// While a batch runs, the proxy holds other people's money. Three rules keep that safe:
/// 1. Everything parked must be spent by the end of the batch, or it reverts ("Funds left in
///    proxy"), so the proxy never carries a balance into the next transaction.
/// 2. Every entry point is `nonReentrant` (see {Guards}), so nothing can call back in mid-batch and
///    spend parked funds.
/// 3. The proxy pays only through `HELD_BALANCE`, and only in a batch.
///
/// Native ETH: a batch is NOT payable and carries no ETH of its own. ETH can be parked (a V4 swap's
/// native output sent to `ADDRESS_THIS`) and then spent through `HELD_BALANCE`, and it can be the
/// final output to any recipient. Native input from anywhere else is rejected. Tokens or ETH that
/// reached the proxy outside the entry points (a direct transfer, a selfdestruct) are not anyone's
/// in particular; a `HELD_BALANCE` swap spends them like any other balance.
///
/// Abstract on purpose: this is a mixin combined into {UniswapProxy}. Deploy that rather than this.
abstract contract UniswapBatchSwapProxy is UniswapV3SwapProxy, UniswapV4SwapProxy {
    /// @notice Executes `swaps` in order, atomically
    /// @param swaps One element per swap: a {SwapType} byte followed by the ABI-encoded params
    /// @return amounts Per swap, what its single-swap entry point would return: the amount received
    /// for an exact-input swap, the amount paid for an exact-output swap
    function batchSwap(bytes[] calldata swaps) external nonReentrant returns (uint256[] memory amounts) {
        amounts = new uint256[](swaps.length);
        // Every token this batch parks in the proxy, so it can insist they are all spent by the end.
        // Native ETH is address(0), hence the explicit count rather than a zero terminator.
        address[] memory parked = new address[](swaps.length);
        uint256 parkedCount;

        for (uint256 i = 0; i < swaps.length; i++) {
            bytes calldata item = swaps[i];
            require(item.length != 0, "Invalid swap type");
            uint8 swapType = uint8(item[0]);
            bytes calldata data = item[1:];
            bool parks;

            if (swapType == SwapType.V3_EXACT_INPUT) {
                ExactInputSingleParams memory p = abi.decode(data, (ExactInputSingleParams));
                address payer;
                (payer, p.amountIn) = _resolveInput(p.tokenIn, p.amountIn);
                (p.recipient, parks) = _resolveRecipient(p.recipient);
                if (parks) parked[parkedCount++] = p.tokenOut;
                amounts[i] = _exactInputSingle(p, payer);
            } else if (swapType == SwapType.V3_EXACT_OUTPUT) {
                ExactOutputSingleParams memory p = abi.decode(data, (ExactOutputSingleParams));
                (p.recipient, parks) = _resolveRecipient(p.recipient);
                if (parks) parked[parkedCount++] = p.tokenOut;
                amounts[i] = _exactOutputSingle(p, msg.sender);
            } else if (swapType == SwapType.V4_EXACT_INPUT) {
                V4ExactInputSingleParams memory p = abi.decode(data, (V4ExactInputSingleParams));
                (address tokenIn, address tokenOut) = _v4Tokens(p.poolKey, p.zeroForOne);
                (address payer, uint256 amountIn) = _resolveInput(tokenIn, p.amountIn);
                _requireNativeInputIsParked(tokenIn, payer);
                p.amountIn = SafeCast.toUint128(amountIn);
                (p.recipient, parks) = _resolveRecipient(p.recipient);
                if (parks) parked[parkedCount++] = tokenOut;
                amounts[i] = _exactInputSingleV4(p, payer);
            } else if (swapType == SwapType.V4_EXACT_OUTPUT) {
                V4ExactOutputSingleParams memory p = abi.decode(data, (V4ExactOutputSingleParams));
                (address tokenIn, address tokenOut) = _v4Tokens(p.poolKey, p.zeroForOne);
                _requireNativeInputIsParked(tokenIn, msg.sender);
                (p.recipient, parks) = _resolveRecipient(p.recipient);
                if (parks) parked[parkedCount++] = tokenOut;
                amounts[i] = _exactOutputSingleV4(p, msg.sender);
            } else {
                revert("Invalid swap type");
            }
        }

        for (uint256 j = 0; j < parkedCount; j++) {
            require(_heldBalance(parked[j]) == 0, "Funds left in proxy");
        }
    }

    /// @dev An exact-input swap with `amountIn == HELD_BALANCE` spends everything the proxy holds of
    /// `tokenIn`, paid by the proxy. Any other amount is paid by the caller.
    function _resolveInput(address tokenIn, uint256 amountIn) private view returns (address payer, uint256 resolved) {
        if (amountIn != Chaining.HELD_BALANCE) return (msg.sender, amountIn);
        resolved = _heldBalance(tokenIn);
        require(resolved != 0, "Nothing held");
        return (address(this), resolved);
    }

    /// @dev `ADDRESS_THIS` parks the output in the proxy. Anything else must be a real recipient.
    function _resolveRecipient(address recipient) private view returns (address resolved, bool parks) {
        if (recipient == Chaining.ADDRESS_THIS) return (address(this), true);
        _checkRecipient(recipient);
        return (recipient, false);
    }

    /// @dev Native input is always settled from the proxy's own balance, and a batch carries no
    /// msg.value, so inside a batch it can only legitimately be ETH an earlier swap parked here, spent
    /// through `HELD_BALANCE`. Any other native-input swap would quietly draw on that parked ETH while
    /// presenting itself as paid by the caller.
    function _requireNativeInputIsParked(address tokenIn, address payer) private view {
        if (tokenIn == address(0)) require(payer == address(this), "Native input must come from a previous swap");
    }

    function _v4Tokens(PoolKey memory key, bool zeroForOne) private pure returns (address tokenIn, address tokenOut) {
        (Currency currencyIn, Currency currencyOut) =
            zeroForOne ? (key.currency0, key.currency1) : (key.currency1, key.currency0);
        return (Currency.unwrap(currencyIn), Currency.unwrap(currencyOut));
    }

    /// @dev What the proxy holds of `token`; address(0) is native ETH, as in V4
    function _heldBalance(address token) private view returns (uint256) {
        return token == address(0) ? address(this).balance : IERC20(token).balanceOf(address(this));
    }
}
