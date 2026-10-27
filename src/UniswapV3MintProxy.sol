// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.20;

import {IUniswapV3MintCallback, MintParams, MintCallbackData} from "./interfaces/uniswapV3/IUniswapV3MintCallback.sol";
import {IUniswapV3PoolMinimal} from "./interfaces/uniswapV3/IUniswapV3PoolMinimal.sol";
import {TransferHelper} from "./libraries/uniswapV3/TransferHelper.sol";
import {PoolAddress} from "./libraries/uniswapV3/PoolAddress.sol";
import {TickMath} from "./libraries/uniswapV3/TickMath.sol";
import {LiquidityAmounts} from "./libraries/uniswapV3/LiquidityAmounts.sol";
import {CallbackValidation} from "./libraries/uniswapV3/CallbackValidation.sol";
import {UniswapV3ProxyBase} from "./base/UniswapV3ProxyBase.sol";

/// @title Uniswap V3 liquidity provision
/// @notice Mints a position directly on a V3 pool and pays for it from the caller's balance. The
/// position belongs to the recipient inside the pool itself; there is no NFT.
/// A mint only goes through while the pool's current tick is inside the caller's price band for
/// that pool (see `setPriceBand`).
/// @dev Abstract on purpose: this is a mixin combined into {UniswapProxy}, which owns the
/// constructor. Deploy {UniswapProxy} rather than this.
abstract contract UniswapV3MintProxy is UniswapV3ProxyBase, IUniswapV3MintCallback {
    /// @notice Price range, as pool ticks, in which a caller allows minting into a pool
    /// @dev Both bounds are inclusive. The default (0, 0) means not configured: minting into that pool reverts.
    struct PriceBand {
        int24 minTick;
        int24 maxTick;
    }

    /// @notice The price band each caller (vault) allows per pool
    mapping(address vault => mapping(address pool => PriceBand)) public priceBands;

    event PriceBandSet(address indexed vault, address indexed pool, int24 minTick, int24 maxTick);

    /// @notice Sets the price band the caller allows when minting into `pool`: the pool's current tick must be
    /// within [minTick, maxTick]
    /// @dev Settings are keyed by msg.sender, so each vault only ever configures its own mints. A vault whose
    /// mints are made by a delegate (e.g. a Zodiac Roles manager) must not let that delegate call this.
    /// @param pool The Uniswap V3 pool the setting applies to
    /// @param minTick Lowest allowed pool tick (inclusive)
    /// @param maxTick Highest allowed pool tick (inclusive), greater than `minTick`.
    /// (0, 0) clears the band, which blocks minting into `pool` for the caller
    function setPriceBand(address pool, int24 minTick, int24 maxTick) external nonReentrant {
        require(
            (minTick == 0 && maxTick == 0)
                || (minTick < maxTick && minTick >= TickMath.MIN_TICK && maxTick <= TickMath.MAX_TICK),
            "Invalid price band"
        );
        priceBands[msg.sender][pool] = PriceBand({minTick: minTick, maxTick: maxTick});
        emit PriceBandSet(msg.sender, pool, minTick, maxTick);
    }

    /// @notice Mints liquidity to a Uniswap V3 pool, owned by `params.recipient`. Reverts unless the
    /// pool's current tick is inside the caller's price band for that pool (see `setPriceBand`).
    /// @dev READ BEFORE CHOOSING A RECIPIENT. Unlike Uniswap's NonfungiblePositionManager, no NFT
    /// is minted and nothing about the position is recorded here. It lives in the pool, keyed by
    /// (recipient, tickLower, tickUpper), and the pool lets only that owner act on it: `burn` and
    /// `collect` both identify the owner by `msg.sender`. This proxy has neither function, so it
    /// cannot withdraw a position for anyone, and positions cannot be transferred.
    ///
    /// The recipient must therefore be able to call `burn` and `collect` on the pool itself:
    /// - an EOA, or a smart account that can make arbitrary calls (e.g. a Safe): fine;
    /// - a contract written to call `burn` and `collect` (e.g. a vault built for it): fine;
    /// - any other contract: the liquidity, and every fee it earns, is locked permanently.
    /// The proxy itself is rejected for exactly this reason. Other contracts cannot be told apart
    /// on-chain, so choosing a recipient that can exit is the integrator's responsibility.
    ///
    /// Exiting is two calls, made by the owner directly on the pool. `burn` makes the principal and
    /// fees owed to the owner, and `collect` sends them to `to`:
    ///   pool.burn(tickLower, tickUpper, liquidity);
    ///   pool.collect(to, tickLower, tickUpper, type(uint128).max, type(uint128).max);
    /// Fees alone can be claimed the same way with `burn(tickLower, tickUpper, 0)` first.
    function mint(MintParams calldata params)
        external
        nonReentrant
        checkDeadline(params.deadline)
        returns (uint256 amount0, uint256 amount1)
    {
        _checkRecipient(params.recipient);

        PoolAddress.PoolKey memory poolKey =
            PoolAddress.PoolKey({token0: params.token0, token1: params.token1, fee: params.fee});

        // Get the pool address
        IUniswapV3PoolMinimal pool = IUniswapV3PoolMinimal(PoolAddress.computeAddress(UNI_V3_FACTORY, poolKey));

        PriceBand memory band = priceBands[msg.sender][address(pool)];
        // a configured band always has minTick < maxTick, the default (0, 0) does not
        require(band.minTick < band.maxTick, "Price band not set");

        // compute the liquidity amount
        uint128 liquidity;
        {
            (uint160 sqrtPriceX96, int24 tick,,,,,) = pool.slot0();
            require(tick >= band.minTick && tick <= band.maxTick, "Price out of band");

            uint160 sqrtRatioAX96 = TickMath.getSqrtRatioAtTick(params.tickLower);
            uint160 sqrtRatioBX96 = TickMath.getSqrtRatioAtTick(params.tickUpper);

            liquidity = LiquidityAmounts.getLiquidityForAmounts(
                sqrtPriceX96, sqrtRatioAX96, sqrtRatioBX96, params.amount0Desired, params.amount1Desired
            );
        }

        (amount0, amount1) = pool.mint(
            params.recipient,
            params.tickLower,
            params.tickUpper,
            liquidity,
            abi.encode(MintCallbackData({poolKey: poolKey, payer: msg.sender}))
        );

        require(amount0 >= params.amount0Min && amount1 >= params.amount1Min, "Price slippage check");
    }

    function uniswapV3MintCallback(uint256 amount0Owed, uint256 amount1Owed, bytes calldata data) external override {
        MintCallbackData memory decoded = abi.decode(data, (MintCallbackData));

        // Make sure caller is a contract deployed by the Uniswap V3 factory
        CallbackValidation.verifyCallback(UNI_V3_FACTORY, decoded.poolKey);

        if (amount0Owed > 0) {
            TransferHelper.safeTransferFrom(decoded.poolKey.token0, decoded.payer, msg.sender, amount0Owed);
        }
        if (amount1Owed > 0) {
            TransferHelper.safeTransferFrom(decoded.poolKey.token1, decoded.payer, msg.sender, amount1Owed);
        }
    }
}
