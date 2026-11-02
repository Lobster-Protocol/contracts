// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.27;

import {IUniswapV3SwapCallback} from "./interfaces/uniswapV3/IUniswapV3SwapCallback.sol";
import {UniswapV3ProxyBase} from "./base/UniswapV3ProxyBase.sol";
import {PoolManagerBase} from "./base/PoolManagerBase.sol";
import {PoolRegistry} from "./base/PoolRegistry.sol";
import {SwapFlags} from "./libraries/SwapFlags.sol";
import {PoolAddress} from "./libraries/uniswapV3/PoolAddress.sol";

/// @title Uniswap V3 and V4 swaps, single or chained, in one packed call
/// @notice `swap(data)` runs the legs encoded in `data` ({SwapFlags}) in order, on V3 pools and V4 pools
/// alike, for the caller only. Every input is paid by the caller, except a HELD leg's, which spends what
/// earlier legs of the same call parked. Every output goes to the caller, except a PARK leg's, which
/// stays for a later leg. Each leg's pool must be registered for the caller with `PERMISSION_SWAP` and
/// a price band set ({PoolRegistry}), checked for every leg before anything runs; and the pool's tick
/// must be inside that band both before and after the leg runs. A swap moves the price one way only,
/// so a price inside the band at both ends means the whole leg executed inside it.
/// @dev ONE UNLOCK. When a call has a V4 leg, the whole call, V3 legs included, runs inside a single
/// PoolManager unlock, and the PoolManager is the proxy's bank for parked funds:
/// - a parked V4 output is credit in the PoolManager and is never transferred;
/// - a parked V3 output that a V4 leg will spend is paid by the V3 pool straight to the PoolManager
///   (sync, then settled in the pool's callback before anything else runs, and required to match what
///   the pool reports);
/// - a V3 leg spending credit is paid by the PoolManager straight to the V3 pool (`take`).
/// Only a V3 output that a V3 leg will spend sits in the proxy itself, where a hand-off costs less.
/// Every amount parked is tracked exactly, per token, in a ledger that lives in memory for the duration
/// of the call and must be back to zero at its end (`FundsLeftInProxy`); the PoolManager independently
/// requires every one of the proxy's deltas to be zero (`CurrencyNotSettled`).
///
/// CALLBACKS. A V3 pool's swap callback is honoured only from the pool the proxy is calling at that
/// moment, once (`EXPECTED_POOL_SLOT`, transient, cleared on use; a canonical pool always calls back
/// before its `swap` returns); the PoolManager's only from the PoolManager ({PoolManagerBase}) and only
/// while an entry point holds the lock (in practice `swap`, the only one that opens a swap unlock).
/// Both pay for the account holding the lock ({Guards}), i.e. the caller of `swap`, never for anyone
/// named in calldata. Like all V3 authentication, this assumes `UNI_V3_FACTORY` is Uniswap's: a
/// contract at a CREATE2 address of another factory could ask for any amount in its callback.
///
/// KNOWN BEHAVIOURS:
/// - native ETH input is paid from the caller's msg.value only, and what is left of it is refunded;
///   ETH force-fed to the proxy between calls belongs to no one and is neither spent nor refunded (ETH
///   a selfdestruct run by the call itself pushes in mid-call is refunded with the change);
/// - tokens sent to the proxy outside a call belong to no one: a HELD leg spends what the call parked, as
///   the pools report it, and nothing else;
/// - a token that delivers less than a pool reports (fee-on-transfer, rounding) makes a hand-off through
///   it revert rather than spend anything else, with one exception: a token that delivers less into the
///   proxy than out of it (a fee on one direction only) can make a V3 to V3 hand-off draw the
///   difference from tokens of its own sent to the proxy outside a call;
/// - in a call with a V4 leg, every leg runs inside the proxy's unlock. A traded token whose transfers
///   run outside code can therefore trade on the PoolManager for the rest of the call, paying only at
///   its end, and so against the call's later legs: each leg's bound and band are what limit that, so
///   register only tokens whose transfers run no outside code, and give every leg a real bound. For the
///   same reason, a token whose own transfer opens a PoolManager unlock cannot be traded in such a call
///   (only in a V3-only one).
abstract contract UniswapSwapProxy is UniswapV3ProxyBase, PoolManagerBase, PoolRegistry, IUniswapV3SwapCallback {
    /// @dev keccak256("lobster.proxy.expectedPool") - 1
    uint256 private constant EXPECTED_POOL_SLOT = 0x81f6439a152a2e49b796da8b15878f81ed1ae1f01d0b6a0484a086a9ad2b2e80;

    /// @dev V3 TickMath.MIN_SQRT_RATIO + 1 and MAX_SQRT_RATIO - 1, the defaults for "no price limit"
    uint160 private constant V3_MIN_LIMIT = 4295128740;
    uint160 private constant V3_MAX_LIMIT = 1461446703485210103287273052203988822378723970341;

    /// @dev Plan word bit: this V3 leg's parked output goes to the PoolManager (a V4 leg spends it)
    uint256 private constant TO_MANAGER = 1 << 48;

    /// @dev V3 callback modes
    uint256 private constant MODE_HELD = 1;
    uint256 private constant MODE_TO_MANAGER = 2;

    /// @dev What {_prepare} learnt about a call, before anything runs. Per leg, two words: the pool's
    /// registry key (the V3 pool address, or the V4 PoolId), then the caller's band for it
    /// (minTick | maxTick << 24, as uint24) and the TO_MANAGER bit.
    struct Plan {
        uint256 legs;
        /// @dev Some leg parks or spends parked funds
        bool usesLedger;
        uint256[] words;
    }

    /// @dev One leg, as {_execute} parses it
    struct Leg {
        uint256 flags;
        uint256 inIndex;
        uint256 outIndex;
        address tokenIn;
        address tokenOut;
        uint24 fee;
        int24 tickSpacing;
        /// @dev amountIn, resolved for HELD; amountOut with EXACT_OUT
        uint256 amount;
        /// @dev amountOutMinimum; amountInMaximum with EXACT_OUT
        uint256 bound;
        /// @dev 0 means no limit
        uint160 sqrtPriceLimitX96;
    }

    /// @dev What the current call has parked, per token index, and what is left of its msg.value
    struct Ledger {
        /// @dev Owed to the proxy by the PoolManager: a parked V4 output, or a V3 output paid to it
        uint256[] credit;
        /// @dev In the proxy's own balance: a parked V3 output
        uint256[] held;
        /// @dev Native ETH the caller sent that no leg has spent yet
        uint256 value;
    }

    /// @notice Runs the swap legs encoded in `data` ({SwapFlags}), in order, for the caller
    /// @dev Payable for native-ETH input on V4 legs, which is paid from msg.value only; what is left of
    /// msg.value is refunded to the caller.
    /// @return amounts Per leg: the amount received for exact input, the amount paid for exact output
    function swap(bytes calldata data) external payable nonReentrant returns (uint256[] memory amounts) {
        // What the proxy held before msg.value arrived: no leg may spend it
        uint256 heldBefore = address(this).balance - msg.value;
        (Plan memory plan, bool anyV4) = _prepare(data);
        if (anyV4) {
            // The callback returns the amounts as raw words ({_swapCallback}): reinterpret them in place
            bytes memory words = POOL_MANAGER.unlock(_unlockPayload(data, plan, msg.value));
            assembly ("memory-safe") {
                amounts := words
                mstore(amounts, shr(5, mload(words)))
            }
        } else {
            amounts = _execute(data, plan, msg.sender, msg.value);
        }
        _refundExcessNative(heldBefore);
    }

    /// @dev The swap unlock opened by {swap}: `payload` is {_unlockPayload}'s, written by the proxy itself.
    /// Only while an entry point holds the lock (in practice `swap`, the only one that opens a swap
    /// unlock): with no lock held, this reverts.
    function _swapCallback(bytes calldata payload) internal override returns (bytes memory) {
        address vault = _lockHolder();
        uint256 legs;
        uint256 valueAndLedger;
        assembly ("memory-safe") {
            legs := calldataload(payload.offset)
            valueAndLedger := calldataload(add(payload.offset, 0x20))
        }
        uint256 wordsSize = legs * 64;
        uint256[] memory words = new uint256[](legs * 2);
        assembly ("memory-safe") {
            calldatacopy(add(words, 0x20), add(payload.offset, 0x40), wordsSize)
        }
        Plan memory plan = Plan({legs: legs, usesLedger: valueAndLedger & 1 != 0, words: words});
        uint256[] memory amounts = _execute(payload[64 + wordsSize:], plan, vault, valueAndLedger >> 1);
        // Raw words, the array without its length: {swap} reinterprets them in place
        bytes memory raw;
        assembly ("memory-safe") {
            raw := amounts
            mstore(raw, shl(5, mload(amounts)))
        }
        return raw;
    }

    /// @dev SWAP_TAG | legs | msg.value << 1 | usesLedger | plan words | data
    function _unlockPayload(
        bytes calldata data,
        Plan memory plan,
        uint256 value
    )
        private
        pure
        returns (bytes memory payload)
    {
        uint256 legs = plan.legs;
        bool usesLedger = plan.usesLedger;
        uint256[] memory words = plan.words;
        uint256 wordsSize = legs * 64;
        payload = new bytes(65 + wordsSize + data.length);
        assembly ("memory-safe") {
            let p := add(payload, 0x20)
            mstore8(p, 0x01) // SWAP_TAG
            mstore(add(p, 0x01), legs)
            mstore(add(p, 0x21), or(shl(1, value), usesLedger))
            mcopy(add(p, 0x41), add(words, 0x20), wordsSize)
            calldatacopy(add(add(p, 0x41), wordsSize), data.offset, data.length)
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Before anything runs
    // ---------------------------------------------------------------------------------------------

    // Every leg of a swap call is checked as it runs, and a failing check (or a failing pool,
    // PoolManager or token call) reverts the whole call: a call is all or nothing, and skipping a leg
    // would skip its price band and slippage checks.
    // forge-lint: disable-start(require-revert-in-loop)
    /// @dev Validates the whole call before anything runs: the deadline, the layout ({SwapFlags}), and
    /// for every leg that the caller registered its pool with `PERMISSION_SWAP` and set a band for it.
    /// Also decides where each parked V3 output goes: to the PoolManager when the first later leg that
    /// spends it is a V4 leg, to the proxy otherwise. Runs in the caller's frame: msg.sender is the vault.
    function _prepare(bytes calldata data) private view returns (Plan memory plan, bool anyV4) {
        uint256 length = data.length;
        require(length > SwapFlags.HEADER_SIZE, MalformedSwap());
        uint256 header = _wordAt(data, 0);
        _checkDeadline(header >> 224);
        uint256 tokenCount = (header >> 216) & 0xff;
        uint256 pos;
        uint256[] memory words;
        unchecked {
            pos = SwapFlags.HEADER_SIZE + 20 * tokenCount;
            require(pos < length, MalformedSwap());
            uint256 maxLegs = (length - pos) / SwapFlags.MIN_LEG_SIZE;
            words = new uint256[](2 * (maxLegs < 255 ? maxLegs : 255));
        }
        // Per token: the V3 legs that parked it since its last HELD leg, as a bit mask of leg indices.
        // Allocated by the first leg that parks or spends parked funds.
        uint256[] memory parkedByV3;
        uint256 legs = 0;
        while (pos < length) {
            require(legs < 255, MalformedSwap());
            uint256 word;
            (word, pos) = _prepareLeg(data, pos, length, tokenCount, words, legs);
            uint256 flags = word >> 248;
            if (flags & SwapFlags.V4 != 0) anyV4 = true;
            if (flags & (SwapFlags.HELD | SwapFlags.PARK) != 0) {
                if (parkedByV3.length == 0) parkedByV3 = new uint256[](tokenCount);
                if (flags & SwapFlags.HELD != 0) {
                    // This leg spends everything parked of tokenIn: the V3 legs that parked it pay the
                    // PoolManager directly if this leg is a V4 one
                    uint256 inIndex = (word >> 240) & 0xff;
                    uint256 producers = parkedByV3[inIndex];
                    if (producers != 0 && flags & SwapFlags.V4 != 0) _markToManager(words, producers);
                    parkedByV3[inIndex] = 0;
                }
                if (flags & (SwapFlags.PARK | SwapFlags.V4) == SwapFlags.PARK) {
                    parkedByV3[(word >> 232) & 0xff] |= uint256(1) << legs;
                }
            }
            unchecked {
                legs++;
            }
        }
        assembly ("memory-safe") {
            mstore(words, mul(2, legs)) // the array was sized for the most legs `data` could hold
        }
        plan = Plan({legs: legs, usesLedger: parkedByV3.length != 0, words: words});
    }

    /// @dev Validates the leg at `pos`, checks its pool in the caller's registry and writes its plan words.
    /// Returns the leg's first word and the position of the next leg.
    function _prepareLeg(
        bytes calldata data,
        uint256 pos,
        uint256 length,
        uint256 tokenCount,
        uint256[] memory words,
        uint256 legIndex
    )
        private
        view
        returns (uint256 word, uint256 next)
    {
        word = _wordAt(data, pos);
        uint256 flags = word >> 248;
        require(
            flags & ~uint256(SwapFlags.ALL) == 0
                && flags & (SwapFlags.HELD | SwapFlags.EXACT_OUT) != (SwapFlags.HELD | SwapFlags.EXACT_OUT),
            MalformedSwap()
        );
        unchecked {
            next = pos + _legSize(flags);
            require(next <= length, MalformedSwap());
            if (flags & SwapFlags.PRICE_LIMIT != 0) require(_wordAt(data, next - 20) >> 96 != 0, MalformedSwap());
        }
        uint256 inIndex = (word >> 240) & 0xff;
        uint256 outIndex = (word >> 232) & 0xff;
        require(inIndex < tokenCount && outIndex < tokenCount, MalformedSwap());
        address tokenIn = _tokenAt(data, inIndex);
        address tokenOut = _tokenAt(data, outIndex);
        require(tokenIn != tokenOut, MalformedSwap());
        (address token0, address token1) = tokenIn < tokenOut ? (tokenIn, tokenOut) : (tokenOut, tokenIn);

        bytes32 key;
        if (flags & SwapFlags.V4 != 0) {
            key = _v4PoolId(token0, token1, word);
        } else {
            require(token0 != address(0), MalformedSwap());
            key = bytes32(uint256(uint160(_v3PoolAddress(token0, token1, word))));
        }
        uint256 band = _requireAllowedWord(msg.sender, key, PERMISSION_SWAP);
        assembly ("memory-safe") {
            let at := add(add(words, 0x20), shl(6, legIndex))
            mstore(at, key)
            mstore(add(at, 0x20), band)
        }
    }

    /// @dev Sets TO_MANAGER on the band word of every leg in `producers` (a bit mask of leg indices)
    function _markToManager(uint256[] memory words, uint256 producers) private pure {
        for (uint256 j = 0; producers != 0; j++) {
            if (producers & 1 != 0) words[2 * j + 1] |= TO_MANAGER;
            producers >>= 1;
        }
    }

    function _legSize(uint256 flags) private pure returns (uint256 size) {
        size = 22; // flags, tokenIn, tokenOut, fee, bound
        if (flags & SwapFlags.V4 != 0) size += 3;
        if (flags & SwapFlags.HELD == 0) size += 16;
        if (flags & SwapFlags.PRICE_LIMIT != 0) size += 20;
    }

    function _wordAt(bytes calldata data, uint256 pos) private pure returns (uint256 word) {
        assembly ("memory-safe") {
            word := calldataload(add(data.offset, pos))
        }
    }

    function _tokenAt(bytes calldata data, uint256 index) private pure returns (address token) {
        assembly ("memory-safe") {
            // the token table starts right after the 5-byte header
            token := shr(96, calldataload(add(data.offset, add(5, mul(20, index)))))
        }
    }

    /// @dev Leg `i`'s two plan words; `i` < `legs`, and the array holds 2 * `legs` words
    function _planWords(uint256[] memory words, uint256 i) private pure returns (uint256 key, uint256 band) {
        assembly ("memory-safe") {
            let at := add(add(words, 0x20), shl(6, i))
            key := mload(at)
            band := mload(add(at, 0x20))
        }
    }

    /// @dev A V3 leg's plan key: the pool address
    function _asAddress(uint256 word) private pure returns (address pool) {
        assembly ("memory-safe") {
            pool := and(word, 0xffffffffffffffffffffffffffffffffffffffff)
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Running
    // ---------------------------------------------------------------------------------------------

    /// @dev Runs every leg of a call {_prepare} validated, for `vault`, the account holding the lock,
    /// which sent `value` in native ETH. A call with a V4 leg runs inside the swap unlock.
    function _execute(
        bytes calldata data,
        Plan memory plan,
        address vault,
        uint256 value
    )
        private
        returns (uint256[] memory amounts)
    {
        uint256 tokenCount = _wordAt(data, 4) >> 248;
        uint256 legs = plan.legs;
        amounts = new uint256[](legs);
        Ledger memory ledger;
        if (plan.usesLedger) {
            ledger.credit = new uint256[](tokenCount);
            ledger.held = new uint256[](tokenCount);
        }
        ledger.value = value;
        Leg memory leg;
        uint256 pos = SwapFlags.HEADER_SIZE + 20 * tokenCount;
        for (uint256 i = 0; i < legs; i++) {
            pos = _parse(data, pos, ledger, leg);
            (uint256 key, uint256 band) = _planWords(plan.words, i);
            if (leg.flags & SwapFlags.V4 != 0) {
                amounts[i] = _v4Leg(leg, bytes32(key), band, vault, ledger);
            } else {
                amounts[i] = _v3Leg(leg, _asAddress(key), band, vault, ledger);
            }
        }
        if (plan.usesLedger) {
            for (uint256 t = 0; t < tokenCount; t++) {
                require(ledger.credit[t] == 0 && ledger.held[t] == 0, FundsLeftInProxy());
            }
        }
    }

    /// @dev Parses the leg at `pos` into `leg` and returns the position of the next one. A HELD leg's
    /// amount is resolved here, from the ledger: everything the call parked of its input.
    function _parse(
        bytes calldata data,
        uint256 pos,
        Ledger memory ledger,
        Leg memory leg
    )
        private
        pure
        returns (uint256)
    {
        uint256 word = _wordAt(data, pos);
        uint256 flags = word >> 248;
        uint256 inIndex = (word >> 240) & 0xff;
        uint256 outIndex = (word >> 232) & 0xff;
        uint24 fee;
        int24 tickSpacing;
        assembly ("memory-safe") {
            fee := and(shr(208, word), 0xffffff)
            tickSpacing := signextend(2, shr(184, word))
        }
        leg.flags = flags;
        leg.inIndex = inIndex;
        leg.outIndex = outIndex;
        leg.tokenIn = _tokenAt(data, inIndex);
        leg.tokenOut = _tokenAt(data, outIndex);
        leg.fee = fee;
        pos += 6;
        if (flags & SwapFlags.V4 != 0) {
            leg.tickSpacing = tickSpacing;
            pos += 3;
        }
        if (flags & SwapFlags.HELD != 0) {
            uint256 amountIn = ledger.credit[inIndex] + ledger.held[inIndex];
            require(amountIn != 0, NothingHeld());
            require(amountIn <= type(uint128).max, MalformedSwap());
            leg.amount = amountIn;
        } else {
            leg.amount = _wordAt(data, pos) >> 128;
            pos += 16;
        }
        leg.bound = _wordAt(data, pos) >> 128;
        pos += 16;
        uint160 limit = 0;
        if (flags & SwapFlags.PRICE_LIMIT != 0) {
            assembly ("memory-safe") {
                limit := shr(96, calldataload(add(data.offset, pos)))
            }
            pos += 20;
        }
        leg.sqrtPriceLimitX96 = limit;
        return pos;
    }

    /// @dev One V3 leg on `pool`, which {_prepare} derived and checked
    function _v3Leg(
        Leg memory leg,
        address pool,
        uint256 band,
        address vault,
        Ledger memory ledger
    )
        private
        returns (uint256)
    {
        _requireInBandWord(_v3Tick(pool), band);

        bool held = leg.flags & SwapFlags.HELD != 0;
        bool park = leg.flags & SwapFlags.PARK != 0;
        // Set only when a later V4 leg spends this output, so only inside the swap unlock
        bool toManager = band & TO_MANAGER != 0;
        address recipient = !park ? vault : toManager ? address(POOL_MANAGER) : address(this);
        // The output is settled at the start of the pool's callback, so sync now, before it arrives
        if (toManager) _sync(leg.tokenOut);
        uint256 creditIn = held ? ledger.credit[leg.inIndex] : 0;
        uint256 mode = (held ? MODE_HELD : 0) | (toManager ? MODE_TO_MANAGER : 0);

        (uint256 paid, uint256 received) = _v3Swap(pool, recipient, leg.tokenIn < leg.tokenOut, leg, mode, creditIn);
        _requireInBandWord(_v3Tick(pool), band);
        _checkBounds(leg, paid, received);

        if (held) _spend(ledger, leg.inIndex, paid);
        if (toManager) ledger.credit[leg.outIndex] += received;
        else if (park) ledger.held[leg.outIndex] += received;
        return leg.flags & SwapFlags.EXACT_OUT != 0 ? paid : received;
    }

    /// @dev One V4 leg on pool `poolId`, which {_prepare} derived and checked; inside the swap unlock
    function _v4Leg(
        Leg memory leg,
        bytes32 poolId,
        uint256 band,
        address vault,
        Ledger memory ledger
    )
        private
        returns (uint256)
    {
        bytes32 stateSlot = _poolStateSlot(poolId);
        _requireInBandWord(_tickAt(stateSlot), band);
        (uint256 paid, uint256 received) = _v4Swap(leg);
        _requireInBandWord(_tickAt(stateSlot), band);
        _checkBounds(leg, paid, received);

        // Pay the input. A HELD leg spends parked credit first, which needs no transfer at all, then what
        // is parked in the proxy. Every other leg is paid by the caller, native ETH from msg.value.
        if (leg.flags & SwapFlags.HELD != 0) {
            uint256 fromProxy = _spend(ledger, leg.inIndex, paid);
            if (fromProxy > 0) _payFromProxy(leg.tokenIn, fromProxy);
        } else if (paid > 0) {
            if (leg.tokenIn == address(0)) _settleNative(ledger, paid);
            else _payFromVault(leg.tokenIn, vault, paid);
        }

        // Deliver the output. A parked output stays in the PoolManager as credit.
        if (leg.flags & SwapFlags.PARK != 0) ledger.credit[leg.outIndex] += received;
        else if (received > 0) _take(leg.tokenOut, vault, received);
        return leg.flags & SwapFlags.EXACT_OUT != 0 ? paid : received;
    }

    /// @dev The bounds every swap entry point has always had: exact input spends at most `amount` and
    /// gets at least `bound`; exact output spends at most `bound` and, without a price limit, gets exactly
    /// `amount` (a pool that runs dry must not spend the maximum on a partial fill)
    function _checkBounds(Leg memory leg, uint256 paid, uint256 received) private pure {
        if (leg.flags & SwapFlags.EXACT_OUT != 0) {
            require(paid <= leg.bound, TooMuchRequested());
            if (leg.sqrtPriceLimitX96 == 0) require(received == leg.amount, TooLittleReceived());
        } else {
            require(paid <= leg.amount, TooMuchRequested());
            require(received >= leg.bound, TooLittleReceived());
        }
    }

    /// @dev A HELD leg paid `paid`: from the parked credit first, then from what is parked in the proxy.
    /// Returns the part taken from the proxy. Reverts if the leg spent more than was parked.
    function _spend(Ledger memory ledger, uint256 index, uint256 paid) private pure returns (uint256 fromProxy) {
        uint256 credit = ledger.credit[index];
        uint256 fromCredit = paid < credit ? paid : credit;
        ledger.credit[index] = credit - fromCredit;
        fromProxy = paid - fromCredit;
        ledger.held[index] -= fromProxy;
    }

    /// @dev Reverts unless `tick` is inside a plan word's band
    function _requireInBandWord(int24 tick, uint256 band) private pure {
        int24 minTick;
        int24 maxTick;
        assembly ("memory-safe") {
            minTick := signextend(2, band)
            maxTick := signextend(2, shr(24, band))
        }
        _requireInBand(tick, minTick, maxTick);
    }

    // ---------------------------------------------------------------------------------------------
    // V3
    // ---------------------------------------------------------------------------------------------

    /// @dev CREATE2 address of the V3 pool of sorted tokens `token0` < `token1` and the fee of the leg
    /// word `legWord`, as {PoolAddress-computeAddress} derives it
    function _v3PoolAddress(address token0, address token1, uint256 legWord) private view returns (address pool) {
        address factory = UNI_V3_FACTORY;
        bytes32 initCodeHash = PoolAddress.POOL_INIT_CODE_HASH;
        assembly ("memory-safe") {
            let m := mload(0x40)
            mstore(m, token0)
            mstore(add(m, 0x20), token1)
            mstore(add(m, 0x40), and(shr(208, legWord), 0xffffff)) // fee
            let salt := keccak256(m, 0x60)
            mstore(m, or(shl(160, 0xff), factory))
            mstore(add(m, 0x20), salt)
            mstore(add(m, 0x40), initCodeHash)
            pool := and(keccak256(add(m, 11), 85), 0xffffffffffffffffffffffffffffffffffffffff)
        }
    }

    /// @dev The pool's current tick. Reverts if `pool` returns no Slot0 (no code there: no pool was ever
    /// deployed at this address), so a leg can never "swap" on such an address.
    function _v3Tick(address pool) private view returns (int24 tick) {
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
            tick := signextend(2, mload(0x20))
        }
    }

    /// @dev Calls `pool.swap` and returns what the pool was paid and what it paid out
    function _v3Swap(
        address pool,
        address recipient,
        bool zeroForOne,
        Leg memory leg,
        uint256 mode,
        uint256 creditIn
    )
        private
        returns (uint256 paid, uint256 received)
    {
        uint256 amount = leg.amount;
        bool exactOut = leg.flags & SwapFlags.EXACT_OUT != 0;
        uint160 limit = leg.sqrtPriceLimitX96;
        if (limit == 0) limit = zeroForOne ? V3_MIN_LIMIT : V3_MAX_LIMIT;
        address tokenIn = leg.tokenIn;
        assembly ("memory-safe") {
            tstore(EXPECTED_POOL_SLOT, pool)
            let m := mload(0x40)
            mstore(m, shl(224, 0x128acb08)) // swap(address,bool,int256,uint160,bytes)
            mstore(add(m, 0x04), recipient)
            mstore(add(m, 0x24), zeroForOne)
            // V3: a positive amountSpecified is exact input. `amount` < 2**128, so neither sign wraps.
            switch exactOut
            case 0 { mstore(add(m, 0x44), amount) }
            default { mstore(add(m, 0x44), sub(0, amount)) }
            mstore(add(m, 0x64), limit)
            mstore(add(m, 0x84), 0xa0)
            // Callback data: tokenIn (20) | mode (1) | creditIn (32), zero-padded to 64 bytes
            mstore(add(m, 0xa4), 53)
            mstore(add(m, 0xe4), 0)
            mstore(add(m, 0xc4), shl(96, tokenIn))
            mstore8(add(m, 0xd8), mode)
            mstore(add(m, 0xd9), creditIn)
            if iszero(call(gas(), pool, 0, m, 0x104, 0, 0x40)) {
                returndatacopy(m, 0, returndatasize())
                revert(m, returndatasize())
            }
            if lt(returndatasize(), 0x40) {
                mstore(0, 0x2bab4241) // NotAPool()
                revert(0x1c, 0x04)
            }
            let inDelta := mload(0x20)
            let outDelta := mload(0)
            if zeroForOne {
                inDelta := mload(0)
                outDelta := mload(0x20)
            }
            // A pool is always paid the input and pays out the output
            if or(slt(inDelta, 0), sgt(outDelta, 0)) {
                mstore(0, 0x29a70758) // UnexpectedDelta()
                revert(0x1c, 0x04)
            }
            paid := inDelta
            received := sub(0, outDelta)
        }
    }

    /// @inheritdoc IUniswapV3SwapCallback
    /// @dev Honoured only from the pool {_v3Swap} is calling right now, and only once. A parked output
    /// sent to the PoolManager is settled first, before any other code runs, and must match the pool's
    /// report. Then the input is paid: by the caller of `swap` (the lock holder), or, for a HELD leg, from
    /// what the call parked, PoolManager credit first (paid by the PoolManager straight to the pool), then
    /// the proxy's own balance.
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external override {
        address pool;
        assembly ("memory-safe") {
            pool := tload(EXPECTED_POOL_SLOT)
        }
        require(pool != address(0) && msg.sender == pool, UnexpectedCallback());
        // swaps entirely within 0-liquidity regions are not supported
        require(amount0Delta > 0 || amount1Delta > 0, UnexpectedDelta());
        uint256 amountToPay;
        uint256 amountOut = 0;
        address tokenIn;
        uint256 mode;
        uint256 creditIn;
        assembly ("memory-safe") {
            tstore(EXPECTED_POOL_SLOT, 0)
            switch sgt(amount0Delta, 0)
            case 1 {
                amountToPay := amount0Delta
                if slt(amount1Delta, 0) { amountOut := sub(0, amount1Delta) }
            }
            default {
                amountToPay := amount1Delta
                if slt(amount0Delta, 0) { amountOut := sub(0, amount0Delta) }
            }
            tokenIn := shr(96, calldataload(data.offset))
            mode := byte(0, calldataload(add(data.offset, 20)))
            creditIn := calldataload(add(data.offset, 21))
        }
        if (mode & MODE_TO_MANAGER != 0) require(_settle() == amountOut, UnexpectedSettlement());
        if (mode & MODE_HELD == 0) {
            // The expected pool is only set while `_v3Swap` runs, inside a locked entry point (a canonical
            // pool calls back before its `swap` returns), so the lock is held
            _transferFrom(tokenIn, _lockedBy(), msg.sender, amountToPay);
            return;
        }
        uint256 fromCredit = amountToPay < creditIn ? amountToPay : creditIn;
        if (fromCredit > 0) _take(tokenIn, msg.sender, fromCredit);
        if (amountToPay > fromCredit) _transfer(tokenIn, msg.sender, amountToPay - fromCredit);
    }

    // ---------------------------------------------------------------------------------------------
    // V4
    // ---------------------------------------------------------------------------------------------

    /// @dev The PoolId of the hookless pool of the leg word `legWord`: `keccak256(abi.encode(poolKey))`
    function _v4PoolId(address currency0, address currency1, uint256 legWord) private pure returns (bytes32 id) {
        assembly ("memory-safe") {
            let m := mload(0x40)
            mstore(m, currency0)
            mstore(add(m, 0x20), currency1)
            mstore(add(m, 0x40), and(shr(208, legWord), 0xffffff)) // fee
            mstore(add(m, 0x60), signextend(2, shr(184, legWord))) // tickSpacing
            mstore(add(m, 0x80), 0)
            id := keccak256(m, 0xa0)
        }
    }

    /// @dev `PoolManager.swap` on the leg's hookless pool; returns what the proxy owes (`paid`) and is
    /// owed (`received`)
    function _v4Swap(Leg memory leg) private returns (uint256 paid, uint256 received) {
        address manager = address(POOL_MANAGER);
        bool zeroForOne = leg.tokenIn < leg.tokenOut;
        (address currency0, address currency1) = zeroForOne ? (leg.tokenIn, leg.tokenOut) : (leg.tokenOut, leg.tokenIn);
        uint256 amount = leg.amount;
        bool exactOut = leg.flags & SwapFlags.EXACT_OUT != 0;
        uint160 limit = leg.sqrtPriceLimitX96;
        if (limit == 0) limit = zeroForOne ? MIN_SQRT_PRICE + 1 : MAX_SQRT_PRICE - 1;
        uint24 fee = leg.fee;
        int24 tickSpacing = leg.tickSpacing;
        assembly ("memory-safe") {
            let m := mload(0x40)
            mstore(m, shl(224, 0xf3cd914c)) // swap((address,address,uint24,int24,address),(bool,int256,uint160),bytes)
            mstore(add(m, 0x04), currency0)
            mstore(add(m, 0x24), currency1)
            mstore(add(m, 0x44), fee)
            mstore(add(m, 0x64), signextend(2, tickSpacing))
            mstore(add(m, 0x84), 0) // hooks
            mstore(add(m, 0xa4), zeroForOne)
            // V4: a negative amountSpecified is exact input. `amount` < 2**128, so neither sign wraps.
            switch exactOut
            case 0 { mstore(add(m, 0xc4), sub(0, amount)) }
            default { mstore(add(m, 0xc4), amount) }
            mstore(add(m, 0xe4), limit)
            mstore(add(m, 0x104), 0x120) // hookData: empty
            mstore(add(m, 0x124), 0)
            if iszero(call(gas(), manager, 0, m, 0x144, 0, 0x20)) {
                returndatacopy(m, 0, returndatasize())
                revert(m, returndatasize())
            }
            let delta := mload(0)
            let inDelta := signextend(15, delta)
            let outDelta := sar(128, delta)
            if zeroForOne {
                inDelta := sar(128, delta)
                outDelta := signextend(15, delta)
            }
            // A hookless pool always leaves the proxy owing the input and owed the output
            if or(sgt(inDelta, 0), slt(outDelta, 0)) {
                mstore(0, 0x29a70758) // UnexpectedDelta()
                revert(0x1c, 0x04)
            }
            paid := sub(0, inDelta)
            received := outDelta
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Moving funds
    // ---------------------------------------------------------------------------------------------

    /// @dev Pays the PoolManager `amount` of ERC20 `token` from `vault`; the settlement must match
    function _payFromVault(address token, address vault, uint256 amount) private {
        _sync(token);
        _transferFrom(token, vault, address(POOL_MANAGER), amount);
        require(_settle() == amount, UnexpectedSettlement());
    }

    /// @dev Pays the PoolManager `amount` of ERC20 `token` parked in the proxy; the settlement must
    /// match. Never native ETH: only V3 outputs are parked in the proxy, and V3 legs have no native ETH.
    function _payFromProxy(address token, uint256 amount) private {
        _sync(token);
        _transfer(token, address(POOL_MANAGER), amount);
        require(_settle() == amount, UnexpectedSettlement());
    }

    /// @dev Pays the PoolManager `amount` of ETH out of what is left of the caller's msg.value, never out
    /// of anything else the proxy holds. `sync(address(0))` first, as v4-core requires: an ERC20 left
    /// synced by anyone would make a native settle revert.
    function _settleNative(Ledger memory ledger, uint256 amount) private {
        uint256 value = ledger.value;
        require(amount <= value, NotEnoughEthSent());
        ledger.value = value - amount;
        _sync(address(0));
        address manager = address(POOL_MANAGER);
        assembly ("memory-safe") {
            mstore(0, 0x11da60b4) // settle()
            if iszero(call(gas(), manager, amount, 0x1c, 0x04, 0, 0x20)) {
                returndatacopy(0, 0, returndatasize())
                revert(0, returndatasize())
            }
        }
    }

    function _sync(address token) private {
        address manager = address(POOL_MANAGER);
        assembly ("memory-safe") {
            mstore(0, 0xa5841194) // sync(address)
            mstore(0x20, token)
            if iszero(call(gas(), manager, 0, 0x1c, 0x24, 0, 0)) {
                returndatacopy(0, 0, returndatasize())
                revert(0, returndatasize())
            }
        }
    }

    function _settle() private returns (uint256 paid) {
        address manager = address(POOL_MANAGER);
        assembly ("memory-safe") {
            mstore(0, 0x11da60b4) // settle()
            if iszero(call(gas(), manager, 0, 0x1c, 0x04, 0, 0x20)) {
                returndatacopy(0, 0, returndatasize())
                revert(0, returndatasize())
            }
            if lt(returndatasize(), 0x20) { revert(0, 0) }
            paid := mload(0)
        }
    }

    function _take(address token, address to, uint256 amount) private {
        address manager = address(POOL_MANAGER);
        assembly ("memory-safe") {
            let m := mload(0x40)
            mstore(m, shl(224, 0x0b0d9c09)) // take(address,address,uint256)
            mstore(add(m, 0x04), token)
            mstore(add(m, 0x24), to)
            mstore(add(m, 0x44), amount)
            if iszero(call(gas(), manager, 0, m, 0x64, 0, 0)) {
                returndatacopy(m, 0, returndatasize())
                revert(m, returndatasize())
            }
        }
    }

    /// @dev As TransferHelper.safeTransferFrom: reverts "STF" unless the call succeeds and returns
    /// nothing or true
    function _transferFrom(address token, address from, address to, uint256 amount) private {
        assembly ("memory-safe") {
            let m := mload(0x40)
            mstore(m, shl(224, 0x23b872dd)) // transferFrom(address,address,uint256)
            mstore(add(m, 0x04), from)
            mstore(add(m, 0x24), to)
            mstore(add(m, 0x44), amount)
            let ok := call(gas(), token, 0, m, 0x64, 0, 0x20)
            if iszero(and(ok, or(iszero(returndatasize()), and(gt(returndatasize(), 0x1f), eq(mload(0), 1))))) {
                mstore(m, shl(224, 0x08c379a0)) // Error(string)
                mstore(add(m, 0x04), 0x20)
                mstore(add(m, 0x24), 3)
                mstore(add(m, 0x44), shl(232, 0x535446)) // "STF"
                revert(m, 0x64)
            }
        }
    }

    /// @dev As TransferHelper.safeTransfer: reverts "ST" unless the call succeeds and returns nothing or
    /// true
    function _transfer(address token, address to, uint256 amount) private {
        assembly ("memory-safe") {
            let m := mload(0x40)
            mstore(m, shl(224, 0xa9059cbb)) // transfer(address,uint256)
            mstore(add(m, 0x04), to)
            mstore(add(m, 0x24), amount)
            let ok := call(gas(), token, 0, m, 0x44, 0, 0x20)
            if iszero(and(ok, or(iszero(returndatasize()), and(gt(returndatasize(), 0x1f), eq(mload(0), 1))))) {
                mstore(m, shl(224, 0x08c379a0)) // Error(string)
                mstore(add(m, 0x04), 0x20)
                mstore(add(m, 0x24), 2)
                mstore(add(m, 0x44), shl(240, 0x5354)) // "ST"
                revert(m, 0x64)
            }
        }
    }
    // forge-lint: disable-end(require-revert-in-loop)
}
