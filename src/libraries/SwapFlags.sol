// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.20;

/// @title The packed calldata of {UniswapSwapProxy-swap}
/// @notice One call runs one or more swap legs, V3 and V4 mixed, in order:
/// ```
/// data   : header | tokens | leg | leg | ...                    (legs back to back to the end of data)
/// header : uint32 deadline | uint8 tokenCount                    5 bytes
/// tokens : tokenCount x address                                  20 bytes each, address(0) = native ETH
/// leg    : uint8 flags | uint8 tokenIn | uint8 tokenOut          indices into `tokens`
///          | uint24 fee
///          | int24 tickSpacing           V4 only
///          | uint128 amount              amountIn, or amountOut with EXACT_OUT; with HELD | SHARE, the
///                                        Q128 share; absent with HELD alone
///          | uint128 bound               amountOutMinimum, or amountInMaximum with EXACT_OUT
///          | uint160 sqrtPriceLimitX96   PRICE_LIMIT only
/// ```
/// Fields are big-endian and unpadded; a leg is 22 to 61 bytes. A leg's pool is the V3 pool of
/// (tokenIn, tokenOut, fee), or the V4 pool of (tokenIn, tokenOut, fee, tickSpacing) with no hooks:
/// hooks cannot be encoded. The direction follows from the tokens. There is no recipient either: an
/// output goes to the caller, or with PARK stays with the proxy for a later HELD leg of the same call.
///
/// A call reverts with `MalformedSwap` unless: the token table fits; every leg fits and the data ends
/// exactly where the last leg does; there is at least one leg and at most 255; no unknown flag is set;
/// HELD is only used with exact input; SHARE is only used with HELD; a share is not 0; indices are in the
/// table; a leg's two tokens differ; a V3 leg names no address(0); a PRICE_LIMIT is not 0. Amounts are
/// uint128, and so must be what a HELD leg finds parked of its input, before any share is applied (checked
/// when that leg runs, `MalformedSwap`); on V4 what a leg
/// actually swaps must also fit in int128, which the PoolManager enforces. The deadline is a uint32
/// timestamp.
///
/// List each token once: parked amounts are kept per table index, so a token listed twice is two
/// separate balances, and a HELD leg spends only what was parked under its own index.
///
/// Splitting a parked token: every consumer but the last is HELD | SHARE, the last is plain HELD. A share
/// applies to what is parked when the leg runs, not to the token's original total, so consumers at
/// 50/30/20 are encoded as 50%, then 60% (of the remaining 50), then plain HELD. An earlier consumer that
/// stops at its price limit leaves more for the legs after it, whose bounds stay absolute amounts (see
/// KNOWN BEHAVIOURS in {UniswapSwapProxy}).
library SwapFlags {
    /// @notice The leg runs on Uniswap V4 (else V3)
    uint8 internal constant V4 = 0x01;
    /// @notice Exact output (else exact input)
    uint8 internal constant EXACT_OUT = 0x02;
    /// @notice The output stays with the proxy for a later HELD leg of the same call (else it goes to the
    /// caller). Whatever a call parks must be spent by its end, or it reverts with `FundsLeftInProxy`.
    uint8 internal constant PARK = 0x04;
    /// @notice Exact input only: the input is everything earlier legs of the call parked of `tokenIn` and
    /// no leg has spent yet, paid by the proxy; the leg has no `amount` field. Reverts with `NothingHeld` if
    /// that is zero.
    uint8 internal constant HELD = 0x08;
    /// @notice A `sqrtPriceLimitX96` field follows. Without it the swap may run to the pool's price limit,
    /// and an exact-output leg must then deliver its full amount.
    uint8 internal constant PRICE_LIMIT = 0x10;
    /// @notice With HELD only: the input is `parked * share >> 128`, rounded down, where `parked` is what
    /// HELD alone would spend and `share` is the uint128 in the leg's `amount` field. What it does not spend
    /// stays parked for a later leg, or the call reverts with `FundsLeftInProxy`. A share of 0 is
    /// `MalformedSwap`; an input that rounds to 0 is `NothingHeld`. Since a share is below 1, it can never
    /// spend everything: the last consumer of a token uses plain HELD.
    uint8 internal constant SHARE = 0x20;

    uint8 internal constant ALL = V4 | EXACT_OUT | PARK | HELD | PRICE_LIMIT | SHARE;

    /// @notice The flag values a leg may have, as a bitmap: bit `f` is set if and only if `f` sets no unknown
    /// flag, HELD does not come with EXACT_OUT, and SHARE comes with HELD. Checked in one shift, whatever
    /// the leg. A test derives it from these rules.
    uint256 internal constant VALID = 0x3300330033ff33ff;

    /// @notice Size of the header (deadline, tokenCount)
    uint256 internal constant HEADER_SIZE = 5;
    /// @notice Size of the smallest leg: V3, HELD, no price limit
    uint256 internal constant MIN_LEG_SIZE = 22;
}
