// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.27;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {
    IPoolManagerMinimal,
    Currency,
    BalanceDelta,
    PoolKey,
    SwapParams
} from "./interfaces/uniswapV4/IPoolManagerMinimal.sol";
import {
    IUnlockCallback,
    V4SwapCallbackData,
    V4Leg,
    V4UnlockData,
    V4ExactInputSingleParams,
    V4ExactOutputSingleParams
} from "./interfaces/uniswapV4/IUnlockCallback.sol";
import {BalanceDeltaLibrary} from "./libraries/uniswapV4/BalanceDeltaLibrary.sol";
import {CurrencySettler} from "./libraries/uniswapV4/CurrencySettler.sol";
import {TransferHelper} from "./libraries/uniswapV3/TransferHelper.sol";
import {Guards} from "./base/Guards.sol";

/// @title Uniswap V4 single-pool swaps
/// @notice Exact input/output swaps against the Uniswap V4 PoolManager singleton.
/// @dev V4 differs from V3 in three ways that matter here:
/// - V3 pools are individual contracts derived by CREATE2, so callbacks are authenticated by
///   recomputing the pool address. V4 has one PoolManager singleton, so `msg.sender == POOL_MANAGER`
///   is the whole check.
/// - V3 calls back per-swap. V4 calls back once per `unlock`, and everything happens inside it.
/// - `amountSpecified` is positive for exact input in V3, but negative for exact input in V4.
///
/// TWO WAYS THROUGH AN UNLOCK.
/// - A single swap gets an unlock of its own, with compact static callback data
///   ({V4SwapCallbackData}). This is the common case and the cheapest path, used by the direct entry
///   points and by every batched V4 swap that is not part of a chain.
/// - A chain ({_runChain}), consecutive swaps each spending exactly what the previous one parked,
///   shares one unlock. Inside an unlock the PoolManager only tracks, per currency, what the proxy
///   owes or is owed (flash accounting), so a parked output is not transferred at all: it stays as
///   credit and the next swap spends it. The chain's intermediate currencies never move.
/// A chain's unlock data starts with `CHAIN_TAG`, a single swap's never can, and `unlockCallback`
/// dispatches on that first byte. A third kind of unlock, V4 liquidity, starts with `LIQUIDITY_TAG`
/// and is handed to {_liquidityCallback} (implemented by {UniswapV4LiquidityProxy}).
///
/// HOOKED POOLS ARE NOT SUPPORTED. Only `poolKey.hooks == address(0)` is accepted. A hook executes
/// third-party code during the swap and may adjust the caller's balance delta
/// (`swapDelta = swapDelta - hookDelta`, see v4-core Hooks.sol). Restricting to hookless pools keeps
/// the swap paths as predictable as their v3 equivalents.
///
/// Abstract on purpose: this is a mixin combined into {LobsterProxy}. Deploy that rather than this.
abstract contract UniswapV4SwapProxy is Guards, IUnlockCallback {
    using BalanceDeltaLibrary for BalanceDelta;
    using CurrencySettler for Currency;

    /// @dev v4-core renamed TickMath.MIN_SQRT_RATIO / MAX_SQRT_RATIO to MIN_SQRT_PRICE / MAX_SQRT_PRICE.
    /// Values are unchanged, so these match `TickMath` in libraries/uniswapV3.
    uint160 internal constant MIN_SQRT_PRICE = 4295128739;
    uint160 internal constant MAX_SQRT_PRICE = 1461446703485210103287273052203988822378723970342;

    /// @dev First byte of a chain's unlock data. A single swap's data always starts with 0x00: its
    /// first word is `poolKey.currency0`, an address, whose top byte is zero.
    bytes1 private constant CHAIN_TAG = 0x01;
    /// @dev First byte of a liquidity unlock, see {UniswapV4LiquidityProxy}
    bytes1 internal constant LIQUIDITY_TAG = 0x02;

    IPoolManagerMinimal public immutable POOL_MANAGER;

    /// @dev Credit per currency that parked legs of the current chain have left in the PoolManager and
    /// no later leg has spent yet. Lives in memory for the duration of one `unlockCallback`.
    struct Ledger {
        address[] currencies;
        uint256[] credits;
        uint256 length;
    }

    constructor(address _poolManager) {
        POOL_MANAGER = IPoolManagerMinimal(_poolManager);
    }

    /// @notice Swaps `amountIn` of one currency for as much as possible of another (single V4 pool)
    /// @dev Payable so that native-currency pools can be used directly, without wrapping to WETH.
    /// Any unspent ETH is refunded to msg.sender.
    function exactInputSingleV4(V4ExactInputSingleParams calldata params)
        external
        payable
        virtual
        nonReentrant
        returns (uint256 amountOut)
    {
        _checkRecipient(params.recipient);
        amountOut = _exactInputSingleV4(params, msg.sender);
        _refundExcessNative();
    }

    /// @notice Swaps as little as possible of one currency for `amountOut` of another (single V4 pool)
    function exactOutputSingleV4(V4ExactOutputSingleParams calldata params)
        external
        payable
        virtual
        nonReentrant
        returns (uint256 amountIn)
    {
        _checkRecipient(params.recipient);
        amountIn = _exactOutputSingleV4(params, msg.sender);
        _refundExcessNative();
    }

    /// @notice Accepts ETH from the PoolManager only
    /// @dev ETH reaches the proxy this way only when a swap inside a batch parks native output, to be
    /// spent by a later swap of the same batch. Direct entry points refuse the proxy as recipient, and
    /// `batchSwap` reverts unless everything it parked here is spent, so the proxy still holds no ETH
    /// between transactions.
    receive() external payable {
        require(msg.sender == address(POOL_MANAGER), NotPoolManager());
    }

    // ---------------------------------------------------------------------------------------------
    // A single swap: one unlock of its own
    // ---------------------------------------------------------------------------------------------

    /// @dev Body of {exactInputSingleV4}, shared with {UniswapBatchSwapProxy-batchSwap}. The caller of
    /// this body has already validated or resolved `params.recipient`. `payer` is who settles the
    /// input: `msg.sender`, or the proxy for a chained swap spending what an earlier swap produced.
    /// Native input is always settled from the proxy's balance (see {CurrencySettler-settle}).
    /// Never refunds: that belongs to the payable entry points, the only paths that take ETH in.
    function _exactInputSingleV4(
        V4ExactInputSingleParams memory params,
        address payer
    )
        internal
        returns (uint256 amountOut)
    {
        _checkDeadline(params.deadline);

        uint256 amountIn;
        // negative amountSpecified == exact input in v4
        (amountIn, amountOut) = _unlockAndSwap(
            params.poolKey,
            params.zeroForOne,
            -int256(uint256(params.amountIn)),
            params.sqrtPriceLimitX96,
            payer,
            params.recipient
        );

        // Hookless pools consume at most the specified input, so this holds by construction. Kept as
        // a cheap assertion of the function's contract rather than as load-bearing protection.
        require(amountIn <= params.amountIn, TooMuchRequested());
        require(amountOut >= params.amountOutMinimum, TooLittleReceived());
    }

    /// @dev Body of {exactOutputSingleV4}, shared with {UniswapBatchSwapProxy-batchSwap}. Same contract
    /// for `params.recipient` and `payer` as {_exactInputSingleV4}. Never refunds.
    function _exactOutputSingleV4(
        V4ExactOutputSingleParams memory params,
        address payer
    )
        internal
        returns (uint256 amountIn)
    {
        _checkDeadline(params.deadline);

        uint256 amountOut;
        // positive amountSpecified == exact output in v4
        (amountIn, amountOut) = _unlockAndSwap(
            params.poolKey,
            params.zeroForOne,
            int256(uint256(params.amountOut)),
            params.sqrtPriceLimitX96,
            payer,
            params.recipient
        );

        require(amountIn <= params.amountInMaximum, TooMuchRequested());
        // A swap can stop early on the price limit and deliver less than requested. When the caller
        // did not ask for a limit, that outcome is never intended, so reject it.
        if (params.sqrtPriceLimitX96 == 0) require(amountOut == params.amountOut, TooLittleReceived());
    }

    /// @dev Opens an unlock for one swap and unpacks the result
    function _unlockAndSwap(
        PoolKey memory poolKey,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        address payer,
        address recipient
    )
        private
        returns (uint256 amountIn, uint256 amountOut)
    {
        _requireHookless(poolKey);
        // The swap is the unlock's only action on this pool, so its price at both ends of the unlock
        // is its price at both ends of the swap
        _checkV4SwapPrice(msg.sender, poolKey);

        bytes memory result = POOL_MANAGER.unlock(
            abi.encode(
                V4SwapCallbackData({
                    poolKey: poolKey,
                    swapParams: SwapParams({
                        zeroForOne: zeroForOne,
                        amountSpecified: amountSpecified,
                        sqrtPriceLimitX96: sqrtPriceLimitX96 == 0
                            ? (zeroForOne ? MIN_SQRT_PRICE + 1 : MAX_SQRT_PRICE - 1)
                            : sqrtPriceLimitX96
                    }),
                    payer: payer,
                    recipient: recipient
                })
            )
        );

        (amountIn, amountOut) = abi.decode(result, (uint256, uint256));
        _checkV4SwapPrice(msg.sender, poolKey);
    }

    // ---------------------------------------------------------------------------------------------
    // A chain: one unlock for consecutive swaps, each spending what the previous one parked
    // ---------------------------------------------------------------------------------------------

    /// @dev A chain leg from exact-input params. The caller has already resolved the recipient.
    function _exactInputLeg(V4ExactInputSingleParams memory params, bool fromHeld)
        internal
        view
        returns (V4Leg memory)
    {
        _checkDeadline(params.deadline);
        return V4Leg({
            poolKey: params.poolKey,
            zeroForOne: params.zeroForOne,
            exactInput: true,
            fromHeld: fromHeld,
            amount: params.amountIn,
            bound: params.amountOutMinimum,
            sqrtPriceLimitX96: params.sqrtPriceLimitX96,
            recipient: params.recipient
        });
    }

    /// @dev A chain leg from exact-output params. The caller has already resolved the recipient.
    function _exactOutputLeg(V4ExactOutputSingleParams memory params) internal view returns (V4Leg memory) {
        _checkDeadline(params.deadline);
        return V4Leg({
            poolKey: params.poolKey,
            zeroForOne: params.zeroForOne,
            exactInput: false,
            fromHeld: false,
            amount: params.amountOut,
            bound: params.amountInMaximum,
            sqrtPriceLimitX96: params.sqrtPriceLimitX96,
            recipient: params.recipient
        });
    }

    /// @dev Runs `legs` in one unlock and returns, per leg, what its single-swap entry point would
    /// return. Every leg not `fromHeld` is paid by `payer`.
    function _runChain(address payer, V4Leg[] memory legs) internal returns (uint256[] memory amounts) {
        for (uint256 i = 0; i < legs.length; i++) {
            _requireHookless(legs[i].poolKey);
        }
        bytes memory result =
            POOL_MANAGER.unlock(bytes.concat(CHAIN_TAG, abi.encode(V4UnlockData({payer: payer, legs: legs}))));
        amounts = abi.decode(result, (uint256[]));
    }

    // ---------------------------------------------------------------------------------------------
    // The callback
    // ---------------------------------------------------------------------------------------------

    /// @inheritdoc IUnlockCallback
    /// @dev The only entry point the PoolManager uses. Every currency delta must be back to zero by the
    /// end, or the manager reverts the whole unlock with `CurrencyNotSettled`.
    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        require(msg.sender == address(POOL_MANAGER), NotPoolManager());

        if (data[0] == CHAIN_TAG) return _chainCallback(abi.decode(data[1:], (V4UnlockData)));
        if (data[0] == LIQUIDITY_TAG) return _liquidityCallback(data[1:]);

        V4SwapCallbackData memory decoded = abi.decode(data, (V4SwapCallbackData));
        (Currency inputCurrency, Currency outputCurrency) = _currencies(decoded.poolKey, decoded.swapParams.zeroForOne);
        (uint256 amountIn, uint256 amountOut) = _swap(decoded.poolKey, decoded.swapParams);

        if (amountIn > 0) inputCurrency.settle(POOL_MANAGER, decoded.payer, amountIn);
        if (amountOut > 0) outputCurrency.take(POOL_MANAGER, decoded.recipient, amountOut);

        return abi.encode(amountIn, amountOut);
    }

    /// @dev The body of a liquidity unlock; `data` is what follows `LIQUIDITY_TAG`
    function _liquidityCallback(bytes calldata data) internal virtual returns (bytes memory);

    /// @dev Runs every leg of a chain, then moves any parked credit no leg spent into the proxy, where a
    /// later V3 swap of the batch can spend it and where the batch's end-of-batch check sees it.
    function _chainCallback(V4UnlockData memory chain) private returns (bytes memory) {
        uint256 n = chain.legs.length;
        uint256[] memory amounts = new uint256[](n);
        // Each leg touches at most two currencies
        Ledger memory ledger = Ledger({currencies: new address[](2 * n), credits: new uint256[](2 * n), length: 0});

        for (uint256 i = 0; i < n; i++) {
            amounts[i] = _runLeg(chain.legs[i], chain.payer, ledger);
        }

        for (uint256 i = 0; i < ledger.length; i++) {
            if (ledger.credits[i] > 0) {
                Currency.wrap(ledger.currencies[i]).take(POOL_MANAGER, address(this), ledger.credits[i]);
            }
        }

        return abi.encode(amounts);
    }

    /// @dev One leg of a chain: swap, check its bounds, pay its input, deliver its output. The bounds
    /// are the same as the single-swap path's. `payer` is the account that opened the chain (a chain is
    /// only ever run for `msg.sender` of `batchSwap`), so it is also whose price band applies: inside
    /// the unlock msg.sender is the PoolManager.
    function _runLeg(V4Leg memory leg, address payer, Ledger memory ledger) private returns (uint256) {
        (Currency inputCurrency, Currency outputCurrency) = _currencies(leg.poolKey, leg.zeroForOne);
        uint256 inSlot = _slot(ledger, Currency.unwrap(inputCurrency));

        // "Everything the proxy holds" includes credit parked by earlier legs of this chain, which has
        // not been taken out of the PoolManager, on top of the proxy's own balance.
        uint256 amountIn = leg.amount;
        if (leg.fromHeld) {
            amountIn = ledger.credits[inSlot] + _heldBalance(Currency.unwrap(inputCurrency));
            require(amountIn != 0, NothingHeld());
        }

        _checkV4SwapPrice(payer, leg.poolKey);
        (uint256 paid, uint256 received) = _swap(
            leg.poolKey,
            SwapParams({
                zeroForOne: leg.zeroForOne,
                // negative amountSpecified == exact input in v4, positive == exact output
                amountSpecified: leg.exactInput
                    ? -int256(uint256(SafeCast.toUint128(amountIn)))
                    : int256(uint256(leg.amount)),
                sqrtPriceLimitX96: leg.sqrtPriceLimitX96 == 0
                    ? (leg.zeroForOne ? MIN_SQRT_PRICE + 1 : MAX_SQRT_PRICE - 1)
                    : leg.sqrtPriceLimitX96
            })
        );
        _checkV4SwapPrice(payer, leg.poolKey);

        if (leg.exactInput) {
            require(paid <= amountIn, TooMuchRequested()); // holds by construction for hookless pools
            require(received >= leg.bound, TooLittleReceived());
        } else {
            require(paid <= leg.bound, TooMuchRequested());
            if (leg.sqrtPriceLimitX96 == 0) require(received == leg.amount, TooLittleReceived());
        }

        // Pay the input. A held leg spends parked credit first, which needs no transfer at all, then
        // the proxy's own balance. Every other leg is paid by the payer.
        if (leg.fromHeld) {
            uint256 credit = ledger.credits[inSlot];
            uint256 fromCredit = paid < credit ? paid : credit;
            ledger.credits[inSlot] = credit - fromCredit;
            if (paid > fromCredit) inputCurrency.settle(POOL_MANAGER, address(this), paid - fromCredit);
        } else if (paid > 0) {
            inputCurrency.settle(POOL_MANAGER, payer, paid);
        }

        // Deliver the output. A parked output stays in the PoolManager as credit.
        if (leg.recipient == address(this)) {
            ledger.credits[_slot(ledger, Currency.unwrap(outputCurrency))] += received;
        } else if (received > 0) {
            outputCurrency.take(POOL_MANAGER, leg.recipient, received);
        }

        return leg.exactInput ? received : paid;
    }

    // ---------------------------------------------------------------------------------------------
    // Shared pieces
    // ---------------------------------------------------------------------------------------------

    /// @dev Called with the pool right before and right after every swap. `account` is the one swapping.
    /// No check here; {LobsterProxy} enforces `account`'s price band. A swap moves the price one
    /// way only, so a price inside the band at both ends means the whole trade executed inside it.
    function _checkV4SwapPrice(address account, PoolKey memory poolKey) internal view virtual {}

    /// @dev Everything downstream assumes a plain constant-product pool, so hooked pools are refused
    /// before any unlock. Both paths route through here.
    function _requireHookless(PoolKey memory poolKey) private pure {
        require(address(poolKey.hooks) == address(0), HooksNotSupported());
    }

    function _currencies(PoolKey memory key, bool zeroForOne) private pure returns (Currency input, Currency output) {
        return zeroForOne ? (key.currency0, key.currency1) : (key.currency1, key.currency0);
    }

    /// @dev Runs the swap and returns what the proxy owes (`paid`) and is owed (`received`)
    function _swap(PoolKey memory key, SwapParams memory params) private returns (uint256 paid, uint256 received) {
        // Empty hookData: only hookless pools get this far, so there is nothing to pass it to
        BalanceDelta delta = POOL_MANAGER.swap(key, params, "");
        (int128 inputDelta, int128 outputDelta) =
            params.zeroForOne ? (delta.amount0(), delta.amount1()) : (delta.amount1(), delta.amount0());
        // A hookless pool always leaves us owing the input and owed the output. The casts below rely
        // on it, so assert rather than assume.
        require(inputDelta <= 0 && outputDelta >= 0, UnexpectedDelta());
        // forge-lint: disable-next-line(unsafe-typecast)
        paid = uint256(uint128(-inputDelta));
        // forge-lint: disable-next-line(unsafe-typecast)
        received = uint256(uint128(outputDelta));
    }

    /// @dev Index of `currency` in the ledger, adding it with zero credit if absent
    function _slot(Ledger memory ledger, address currency) private pure returns (uint256 i) {
        for (; i < ledger.length; i++) {
            if (ledger.currencies[i] == currency) return i;
        }
        ledger.currencies[i] = currency;
        ledger.length++;
    }

    /// @dev Returns ETH that was sent in but not consumed by the swap.
    /// The proxy is not meant to hold a balance between calls, so anything left here at the end of a
    /// direct call is this caller's change.
    /// INVARIANT: this holds only while (1) the only ETH the proxy can receive outside a payable entry
    /// point is ETH the PoolManager sends it mid-batch (`receive` admits nothing else), (2) every
    /// batch spends all the ETH it parked here before returning, and (3) no direct entry point can run
    /// while a batch is in progress (`nonReentrant`), so this never sees a batch's parked ETH.
    /// {UniswapBatchSwapProxy-batchSwap} is also non-payable and never calls this. Revisit all three
    /// before changing any of them.
    function _refundExcessNative() internal {
        uint256 balance = address(this).balance;
        if (balance > 0) TransferHelper.safeTransferETH(msg.sender, balance);
    }
}
