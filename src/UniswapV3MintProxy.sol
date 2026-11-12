// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.27;

import {IUniswapV3MintCallback, MintParams} from "./interfaces/uniswapV3/IUniswapV3MintCallback.sol";
import {IUniswapV3PoolMinimal} from "./interfaces/uniswapV3/IUniswapV3PoolMinimal.sol";
import {TransferHelper} from "./libraries/uniswapV3/TransferHelper.sol";
import {PoolAddress} from "./libraries/uniswapV3/PoolAddress.sol";
import {TickMath} from "./libraries/uniswapV3/TickMath.sol";
import {LiquidityAmounts} from "./libraries/uniswapV3/LiquidityAmounts.sol";
import {CallbackValidation} from "./libraries/uniswapV3/CallbackValidation.sol";
import {UniswapV3ProxyBase} from "./base/UniswapV3ProxyBase.sol";
import {PoolRegistry} from "./base/PoolRegistry.sol";
import {PositionRecorder, Range} from "./base/PositionRecorder.sol";

/// @title Uniswap V3 liquidity provision
/// @notice Mints a position directly on a V3 pool and pays for it from the caller's balance. The
/// position belongs to the recipient inside the pool itself; there is no NFT. Entry points: `mint`,
/// and `mintWithRecording`, which also lists the range ({PositionRecorder}). Both mint only on a pool
/// the caller registered with `PERMISSION_MINT` ({PoolRegistry}), inside its price band, to itself.
/// @dev Abstract on purpose: this is a mixin combined into {LobsterProxy}, which owns the
/// constructor. Deploy {LobsterProxy} rather than this.
abstract contract UniswapV3MintProxy is UniswapV3ProxyBase, PoolRegistry, PositionRecorder, IUniswapV3MintCallback {
    /// @notice Mints liquidity on a V3 pool the caller registered with `PERMISSION_MINT`, to the caller
    /// @dev See {_mint} for how the position is owned and withdrawn
    function mint(MintParams calldata params) external nonReentrant returns (uint256 amount0, uint256 amount1) {
        (amount0, amount1,) = _checkedMint(params);
    }

    /// @notice {mint}, which also records the range in the caller's list for the pool, and deletes the
    /// ranges of that list that are now empty ({PositionRecorder})
    function mintWithRecording(MintParams calldata params)
        external
        nonReentrant
        returns (uint256 amount0, uint256 amount1)
    {
        address pool;
        (amount0, amount1, pool) = _checkedMint(params);
        _recordRange(
            msg.sender,
            v3Key(pool),
            Range({tickLower: params.tickLower, tickUpper: params.tickUpper, salt: bytes32(0)}),
            _isEmptyV3
        );
    }

    /// @dev The checks of both mint entry points, then the mint. Returns the pool too.
    function _checkedMint(MintParams calldata params) private returns (uint256 amount0, uint256 amount1, address pool) {
        require(params.recipient == msg.sender, RecipientMustBeCaller());
        pool = PoolAddress.computeAddress(
            UNI_V3_FACTORY, PoolAddress.PoolKey({token0: params.token0, token1: params.token1, fee: params.fee})
        );
        (int24 minTick, int24 maxTick) = _requireAllowed(msg.sender, v3Key(pool), PERMISSION_MINT);
        (, int24 tick) = _slot0(pool);
        _requireInBand(tick, minTick, maxTick);
        _checkDeadline(params.deadline);
        (amount0, amount1) = _mint(params);
    }

    /// @dev Whether the vault's position over `range` in the V3 pool `key` holds no liquidity and has
    /// nothing left to collect. Fees are moved into `tokensOwed` whenever the liquidity changes, and a
    /// position with no liquidity earns none, so these three say it all. `key` is a registry key the
    /// vault minted on, so the pool is a genuine one; `range.salt` is always 0 for V3.
    function _isEmptyV3(address vault, bytes32 key, Range memory range) private view returns (bool) {
        // forge-lint: disable-next-line(unsafe-typecast)
        IUniswapV3PoolMinimal pool = IUniswapV3PoolMinimal(address(uint160(uint256(key))));
        (uint128 liquidity,,, uint128 owed0, uint128 owed1) =
            pool.positions(keccak256(abi.encodePacked(vault, range.tickLower, range.tickUpper)));
        return liquidity == 0 && owed0 == 0 && owed1 == 0;
    }

    /// @notice Mints liquidity to a Uniswap V3 pool, owned by `params.recipient`. The body of {mint} and
    /// {mintWithRecording}: {_checkedMint} has already checked the registry, the price band, the
    /// deadline and that the recipient is the caller. The position is paid for by `msg.sender`, the
    /// account holding the lock ({Guards}).
    /// @dev READ BEFORE CHOOSING A RECIPIENT. Unlike Uniswap's NonfungiblePositionManager, no NFT
    /// is minted and the proxy holds no claim on the position (`mintWithRecording` only lists its range
    /// for reading, {PositionRecorder}). It lives in the pool, keyed by (recipient, tickLower,
    /// tickUpper), and the pool lets only that owner act on it: `burn` and `collect` both identify the
    /// owner by `msg.sender`. This proxy has neither function, so it cannot withdraw a position for
    /// anyone, and positions cannot be transferred.
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
    function _mint(MintParams calldata params) internal returns (uint256 amount0, uint256 amount1) {
        PoolAddress.PoolKey memory poolKey =
            PoolAddress.PoolKey({token0: params.token0, token1: params.token1, fee: params.fee});

        // Get the pool address
        IUniswapV3PoolMinimal pool = IUniswapV3PoolMinimal(PoolAddress.computeAddress(UNI_V3_FACTORY, poolKey));

        // compute the liquidity amount
        uint128 liquidity;
        {
            (uint160 sqrtPriceX96,) = _slot0(address(pool));
            uint160 sqrtRatioAX96 = TickMath.getSqrtRatioAtTick(params.tickLower);
            uint160 sqrtRatioBX96 = TickMath.getSqrtRatioAtTick(params.tickUpper);

            liquidity = LiquidityAmounts.getLiquidityForAmounts(
                sqrtPriceX96, sqrtRatioAX96, sqrtRatioBX96, params.amount0Desired, params.amount1Desired
            );
        }

        (amount0, amount1) =
            pool.mint(params.recipient, params.tickLower, params.tickUpper, liquidity, abi.encode(poolKey));

        require(amount0 >= params.amount0Min && amount1 >= params.amount1Min, PriceSlippageCheck());
    }

    /// @inheritdoc IUniswapV3MintCallback
    /// @dev Honoured only from the pool of `data`'s key (CREATE2, `CallbackValidation`) while an entry
    /// point is running, and paid by the account holding the lock: never by anyone named in `data`.
    function uniswapV3MintCallback(uint256 amount0Owed, uint256 amount1Owed, bytes calldata data) external override {
        PoolAddress.PoolKey memory poolKey = abi.decode(data, (PoolAddress.PoolKey));

        // Make sure caller is a contract deployed by the Uniswap V3 factory
        CallbackValidation.verifyCallback(UNI_V3_FACTORY, poolKey);
        address payer = _lockHolder();

        // `payer` holds the reentrancy lock: it is the caller of mint, never an address from calldata
        if (amount0Owed > 0) {
            // forge-lint: disable-next-line(arbitrary-send-erc20)
            TransferHelper.safeTransferFrom(poolKey.token0, payer, msg.sender, amount0Owed);
        }
        if (amount1Owed > 0) {
            // forge-lint: disable-next-line(arbitrary-send-erc20)
            TransferHelper.safeTransferFrom(poolKey.token1, payer, msg.sender, amount1Owed);
        }
    }
}
