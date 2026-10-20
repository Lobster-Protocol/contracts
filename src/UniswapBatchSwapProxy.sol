// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.24;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ExactInputSingleParams, ExactOutputSingleParams} from "./interfaces/uniswapV3/IUniswapV3SwapCallback.sol";
import {V4Leg, V4ExactInputSingleParams, V4ExactOutputSingleParams} from "./interfaces/uniswapV4/IUnlockCallback.sol";
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
/// @dev Each element is `abi.encodePacked(uint8 swapType, abi.encode(params))`. Each swap is checked
/// (deadline, slippage, hooks) exactly as if it had been called on its own. If any swap reverts, the
/// whole batch reverts with that swap's reason.
///
/// CHAINING, with the two values in {Chaining}:
/// - `recipient = ADDRESS_THIS` parks a swap's output in the proxy instead of sending it out.
/// - `amountIn = HELD_BALANCE` (exact-input swaps only) spends everything the proxy holds of the
///   input token, and the proxy pays for it. Every other swap is paid by the caller.
/// Several parked outputs of the same token merge into one balance, so routes can converge. Splitting
/// a parked balance across swaps, and exact-output swaps paid from parked funds, are not supported.
///
/// CHAINED V4 SWAPS share one PoolManager `unlock` (see {UniswapV4SwapProxy}): consecutive V4 swaps
/// where each spends (`HELD_BALANCE`) exactly the token the previous one parked. Between them the
/// parked output is not transferred at all: it stays as credit in the PoolManager and the next swap
/// spends it. Any other V4 swap gets an unlock of its own, which is cheaper when nothing is saved.
/// Results are identical either way; only gas differs.
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
        uint256 n = swaps.length;
        amounts = new uint256[](n);
        // Every token this batch parks in the proxy, so it can insist they are all spent by the end.
        // Native ETH is address(0), hence the explicit count rather than a zero terminator.
        address[] memory parked = new address[](n);
        uint256 parkedCount;

        uint256 i = 0;
        while (i < n) {
            uint8 swapType = _swapType(swaps[i]);
            if (swapType == SwapType.V3_EXACT_INPUT || swapType == SwapType.V3_EXACT_OUTPUT) {
                parkedCount = _runV3Item(swaps[i], i, amounts, parked, parkedCount);
                i++;
            } else if (_isV4(swapType)) {
                // A chain starts here only if this swap parks its output and the next one spends exactly
                // that. Otherwise the swap runs alone, on the cheaper single-swap path.
                uint256 end = i + 1;
                while (end < n && _chainsOnto(swaps[end - 1], swaps[end])) end++;
                parkedCount = end == i + 1
                    ? _runV4Item(swaps[i], i, amounts, parked, parkedCount)
                    : _runV4Chain(swaps, i, end, amounts, parked, parkedCount);
                i = end;
            } else {
                revert("Invalid swap type");
            }
        }

        for (uint256 j = 0; j < parkedCount; j++) {
            require(_heldBalance(parked[j]) == 0, "Funds left in proxy");
        }
    }

    function _swapType(bytes calldata item) private pure returns (uint8) {
        require(item.length != 0, "Invalid swap type");
        return uint8(item[0]);
    }

    function _isV4(uint8 swapType) private pure returns (bool) {
        return swapType == SwapType.V4_EXACT_INPUT || swapType == SwapType.V4_EXACT_OUTPUT;
    }

    /// @dev Whether `next` spends exactly what `prev` parks: `prev` sends its output to
    /// `ADDRESS_THIS`, and `next` is a V4 exact-input swap of that same currency for `HELD_BALANCE`.
    /// `prev` is known to be a V4 swap.
    ///
    /// Reads raw words instead of decoding, because this runs between every pair of consecutive V4
    /// swaps. Both V4 param structs are static, so each field sits at a fixed word (see {_word}). The
    /// answer only decides how swaps are grouped into unlocks, never what they do: every item is fully
    /// decoded and validated before it runs, and a chain unlock handles any sequence of legs correctly.
    /// A wrong answer could only cost gas.
    function _chainsOnto(bytes calldata prev, bytes calldata next) private pure returns (bool) {
        if (_swapType(next) != SwapType.V4_EXACT_INPUT) return false;
        if (address(uint160(_word(prev, RECIPIENT_WORD))) != Chaining.ADDRESS_THIS) return false;
        if (_word(next, AMOUNT_WORD) != Chaining.HELD_BALANCE) return false;
        return _v4CurrencyAt(next, true) == _v4CurrencyAt(prev, false);
    }

    // Word positions in the abi encoding of V4ExactInputSingleParams / V4ExactOutputSingleParams:
    // poolKey (currency0, currency1, fee, tickSpacing, hooks), zeroForOne, recipient, deadline, amount...
    uint256 private constant CURRENCY0_WORD = 0;
    uint256 private constant CURRENCY1_WORD = 1;
    uint256 private constant ZERO_FOR_ONE_WORD = 5;
    uint256 private constant RECIPIENT_WORD = 6;
    uint256 private constant AMOUNT_WORD = 8;

    /// @dev The `index`th 32-byte word of an item's params (after its SwapType byte)
    function _word(bytes calldata item, uint256 index) private pure returns (uint256) {
        uint256 start = 1 + 32 * index;
        return uint256(bytes32(item[start:start + 32]));
    }

    /// @dev The input (`input == true`) or output currency of a V4 item, from its raw words
    function _v4CurrencyAt(bytes calldata item, bool input) private pure returns (uint256) {
        bool zeroForOne = _word(item, ZERO_FOR_ONE_WORD) != 0;
        return _word(item, zeroForOne == input ? CURRENCY0_WORD : CURRENCY1_WORD);
    }

    /// @dev Runs one V3 item. Results go into `amounts[index]`; a parked output is recorded in `parked`.
    /// Returns the new number of parked entries.
    function _runV3Item(
        bytes calldata item,
        uint256 index,
        uint256[] memory amounts,
        address[] memory parked,
        uint256 parkedCount
    )
        private
        returns (uint256)
    {
        bytes calldata data = item[1:];
        bool parks;
        if (uint8(item[0]) == SwapType.V3_EXACT_INPUT) {
            ExactInputSingleParams memory p = abi.decode(data, (ExactInputSingleParams));
            address payer;
            (payer, p.amountIn) = _resolveInput(p.tokenIn, p.amountIn);
            (p.recipient, parks) = _resolveRecipient(p.recipient);
            if (parks) parked[parkedCount++] = p.tokenOut;
            amounts[index] = _exactInputSingle(p, payer);
        } else {
            ExactOutputSingleParams memory p = abi.decode(data, (ExactOutputSingleParams));
            (p.recipient, parks) = _resolveRecipient(p.recipient);
            if (parks) parked[parkedCount++] = p.tokenOut;
            amounts[index] = _exactOutputSingle(p, msg.sender);
        }
        return parkedCount;
    }

    /// @dev Runs one V4 item that is not part of a chain, in its own unlock. A held amount is the
    /// proxy's balance of the input token (nothing can be parked as credit outside a chain). Same
    /// conventions as {_runV3Item}.
    function _runV4Item(
        bytes calldata item,
        uint256 index,
        uint256[] memory amounts,
        address[] memory parked,
        uint256 parkedCount
    )
        private
        returns (uint256)
    {
        bytes calldata data = item[1:];
        address tokenIn;
        address tokenOut;
        bool parks;
        if (uint8(item[0]) == SwapType.V4_EXACT_INPUT) {
            V4ExactInputSingleParams memory p = abi.decode(data, (V4ExactInputSingleParams));
            (tokenIn, tokenOut) = _v4Tokens(p.poolKey, p.zeroForOne);
            (address payer, uint256 amountIn) = _resolveInput(tokenIn, p.amountIn);
            _requireNativeInputIsParked(tokenIn, payer == address(this));
            p.amountIn = SafeCast.toUint128(amountIn);
            (p.recipient, parks) = _resolveRecipient(p.recipient);
            if (parks) parked[parkedCount++] = tokenOut;
            amounts[index] = _exactInputSingleV4(p, payer);
        } else {
            V4ExactOutputSingleParams memory p = abi.decode(data, (V4ExactOutputSingleParams));
            (tokenIn, tokenOut) = _v4Tokens(p.poolKey, p.zeroForOne);
            _requireNativeInputIsParked(tokenIn, false);
            (p.recipient, parks) = _resolveRecipient(p.recipient);
            if (parks) parked[parkedCount++] = tokenOut;
            amounts[index] = _exactOutputSingleV4(p, msg.sender);
        }
        return parkedCount;
    }

    /// @dev Runs items[start..end), a chain, in one unlock. Same conventions as {_runV3Item}.
    function _runV4Chain(
        bytes[] calldata items,
        uint256 start,
        uint256 end,
        uint256[] memory amounts,
        address[] memory parked,
        uint256 parkedCount
    )
        private
        returns (uint256)
    {
        V4Leg[] memory legs = new V4Leg[](end - start);
        for (uint256 k = 0; k < legs.length; k++) {
            address tokenOut;
            (legs[k], tokenOut) = _v4Leg(items[start + k]);
            if (legs[k].recipient == address(this)) parked[parkedCount++] = tokenOut;
        }
        uint256[] memory legAmounts = _runChain(msg.sender, legs);
        for (uint256 k = 0; k < legs.length; k++) {
            amounts[start + k] = legAmounts[k];
        }
        return parkedCount;
    }

    /// @dev Decodes and validates one V4 item of a chain into a leg, resolving `ADDRESS_THIS` and
    /// `HELD_BALANCE`. A held leg's amount is resolved inside the unlock, where parked credit is known.
    function _v4Leg(bytes calldata item) private view returns (V4Leg memory leg, address tokenOut) {
        bytes calldata data = item[1:];
        address tokenIn;
        if (uint8(item[0]) == SwapType.V4_EXACT_INPUT) {
            V4ExactInputSingleParams memory p = abi.decode(data, (V4ExactInputSingleParams));
            (tokenIn, tokenOut) = _v4Tokens(p.poolKey, p.zeroForOne);
            bool fromHeld = p.amountIn == Chaining.HELD_BALANCE;
            _requireNativeInputIsParked(tokenIn, fromHeld);
            (p.recipient,) = _resolveRecipient(p.recipient);
            leg = _exactInputLeg(p, fromHeld);
        } else {
            V4ExactOutputSingleParams memory p = abi.decode(data, (V4ExactOutputSingleParams));
            (tokenIn, tokenOut) = _v4Tokens(p.poolKey, p.zeroForOne);
            _requireNativeInputIsParked(tokenIn, false);
            (p.recipient,) = _resolveRecipient(p.recipient);
            leg = _exactOutputLeg(p);
        }
    }

    /// @dev An exact-input swap with `amountIn == HELD_BALANCE` spends everything the proxy holds of
    /// `tokenIn`, paid by the proxy. Any other amount is paid by the caller. (Inside a V4 chain this is
    /// resolved in the unlock instead, to include parked credit.)
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
    /// msg.value, so inside a batch it can only legitimately be ETH an earlier swap parked, spent
    /// through `HELD_BALANCE`. Any other native-input swap would quietly draw on that parked ETH while
    /// presenting itself as paid by the caller.
    function _requireNativeInputIsParked(address tokenIn, bool fromHeld) private pure {
        if (tokenIn == address(0)) require(fromHeld, "Native input must come from a previous swap");
    }

    function _v4Tokens(PoolKey memory key, bool zeroForOne) private pure returns (address tokenIn, address tokenOut) {
        (Currency currencyIn, Currency currencyOut) =
            zeroForOne ? (key.currency0, key.currency1) : (key.currency1, key.currency0);
        return (Currency.unwrap(currencyIn), Currency.unwrap(currencyOut));
    }
}
