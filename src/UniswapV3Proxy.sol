// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.20;

import {IUniswapV3MintCallback, MintParams, MintCallbackData} from "./interfaces/uniswapV3/IUniswapV3MintCallback.sol";
import {
    IUniswapV3SwapCallback,
    SwapCallbackData,
    ExactInputSingleParams,
    ExactOutputSingleParams
} from "./interfaces/uniswapV3/IUniswapV3SwapCallback.sol";
import {IUniswapV3PoolMinimal} from "./interfaces/uniswapV3/IUniswapV3PoolMinimal.sol";
import {TransferHelper} from "./libraries/uniswapV3/TransferHelper.sol";
import {PoolAddress} from "./libraries/uniswapV3/PoolAddress.sol";
import {TickMath} from "./libraries/uniswapV3/TickMath.sol";
import {LiquidityAmounts} from "./libraries/uniswapV3/LiquidityAmounts.sol";
import {CallbackValidation} from "./libraries/uniswapV3/CallbackValidation.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract UniswapV3Proxy is IUniswapV3MintCallback, IUniswapV3SwapCallback {
    address public immutable UNI_V3_FACTORY;

    /// @notice Window of the TWAP the spot price is checked against on mint
    uint32 public constant TWAP_PERIOD = 10 minutes;
    /// @notice Upper bound for a configured price deviation (100%)
    uint256 public constant MAX_DEVIATION_BPS = 10_000;

    uint256 private constant BPS = 10_000;
    uint256 private constant Q96 = 2 ** 96;

    /// @notice Max allowed deviation, in bps, between the spot price and the TWAP when `vault` mints into `pool`.
    /// 0 means not configured, in which case minting into that pool reverts.
    mapping(address vault => mapping(address pool => uint256 maxDeviationBps)) public maxPriceDeviationBps;

    event MaxPriceDeviationSet(address indexed vault, address indexed pool, uint256 maxDeviationBps);

    modifier checkDeadline(uint256 deadline) {
        _checkDeadline(deadline);
        _;
    }

    constructor(address _uniV3Factory) {
        UNI_V3_FACTORY = _uniV3Factory;
    }

    /// @notice Sets the max deviation between spot price and TWAP the caller accepts when minting into `pool`
    /// @dev Settings are keyed by msg.sender, so each vault only ever configures its own mints
    /// @param pool The Uniswap V3 pool the setting applies to
    /// @param maxDeviationBps Max deviation in bps (100 = 1%). 0 disables minting into `pool` for the caller
    function setMaxPriceDeviation(address pool, uint256 maxDeviationBps) external {
        require(maxDeviationBps <= MAX_DEVIATION_BPS, "Invalid deviation");
        maxPriceDeviationBps[msg.sender][pool] = maxDeviationBps;
        emit MaxPriceDeviationSet(msg.sender, pool, maxDeviationBps);
    }

    /// @notice Mints liquidity to a Uniswap V3 pool
    /// @dev Reverts if the pool spot price deviates from its TWAP over `TWAP_PERIOD` by more than the
    /// caller's configured `maxPriceDeviationBps` for that pool
    function mint(MintParams calldata params)
        external
        checkDeadline(params.deadline)
        returns (uint256 amount0, uint256 amount1)
    {
        require(params.recipient != address(0));

        PoolAddress.PoolKey memory poolKey =
            PoolAddress.PoolKey({token0: params.token0, token1: params.token1, fee: params.fee});

        // Get the pool address
        IUniswapV3PoolMinimal pool = IUniswapV3PoolMinimal(PoolAddress.computeAddress(UNI_V3_FACTORY, poolKey));

        uint256 maxDeviationBps = maxPriceDeviationBps[msg.sender][address(pool)];
        require(maxDeviationBps != 0, "Price deviation not set");

        // compute the liquidity amount
        uint128 liquidity;
        {
            (uint160 sqrtPriceX96,,,,,,) = pool.slot0();
            _checkPriceDeviation(pool, sqrtPriceX96, maxDeviationBps);

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

    function uniswapV3MintCallback(
        uint256 amount0Owed,
        uint256 amount1Owed,
        bytes calldata data
    )
        external
        override
    {
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

    /// @notice Swaps `amountIn` of one token for as much as possible of another token (single pool)
    function exactInputSingle(ExactInputSingleParams calldata params)
        external
        checkDeadline(params.deadline)
        returns (uint256 amountOut)
    {
        require(params.recipient != address(0));

        bool zeroForOne = params.tokenIn < params.tokenOut;

        (int256 amount0, int256 amount1) = _getPool(params.tokenIn, params.tokenOut, params.fee)
            .swap(
                params.recipient,
                zeroForOne,
                int256(params.amountIn),
                params.sqrtPriceLimitX96 == 0
                    ? (zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1)
                    : params.sqrtPriceLimitX96,
                abi.encode(
                    SwapCallbackData({
                        tokenIn: params.tokenIn, tokenOut: params.tokenOut, fee: params.fee, payer: msg.sender
                    })
                )
            );

        amountOut = uint256(-(zeroForOne ? amount1 : amount0));
        require(amountOut >= params.amountOutMinimum, "Too little received");
    }

    /// @notice Swaps as little as possible of one token for `amountOut` of another token (single pool)
    function exactOutputSingle(ExactOutputSingleParams calldata params)
        external
        checkDeadline(params.deadline)
        returns (uint256 amountIn)
    {
        require(params.recipient != address(0));

        bool zeroForOne = params.tokenIn < params.tokenOut;

        (int256 amount0, int256 amount1) = _getPool(params.tokenIn, params.tokenOut, params.fee)
            .swap(
                params.recipient,
                zeroForOne,
                -int256(params.amountOut),
                params.sqrtPriceLimitX96 == 0
                    ? (zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1)
                    : params.sqrtPriceLimitX96,
                abi.encode(
                    SwapCallbackData({
                        tokenIn: params.tokenIn, tokenOut: params.tokenOut, fee: params.fee, payer: msg.sender
                    })
                )
            );

        amountIn = uint256(zeroForOne ? amount0 : amount1);
        require(amountIn <= params.amountInMaximum, "Too much requested");
    }

    /// @inheritdoc IUniswapV3SwapCallback
    function uniswapV3SwapCallback(
        int256 amount0Delta,
        int256 amount1Delta,
        bytes calldata _data
    )
        external
        override
    {
        require(amount0Delta > 0 || amount1Delta > 0); // swaps entirely within 0-liquidity regions are not supported
        SwapCallbackData memory data = abi.decode(_data, (SwapCallbackData));
        CallbackValidation.verifyCallback(UNI_V3_FACTORY, data.tokenIn, data.tokenOut, data.fee);

        // casting to uint256 is safe because the require above guarantees at least one delta is positive,
        // and the ternary only casts the positive value
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 amountToPay = amount0Delta > 0 ? uint256(amount0Delta) : uint256(amount1Delta);
        TransferHelper.safeTransferFrom(data.tokenIn, data.payer, msg.sender, amountToPay);
    }

    function _getPool(address tokenA, address tokenB, uint24 fee) private view returns (IUniswapV3PoolMinimal) {
        return
            IUniswapV3PoolMinimal(
                PoolAddress.computeAddress(UNI_V3_FACTORY, PoolAddress.getPoolKey(tokenA, tokenB, fee))
            );
    }

    /// @dev Reverts if the spot price is not within `maxDeviationBps` of the TWAP over `TWAP_PERIOD`.
    /// Reverts with "OLD" (from the pool) if the pool's oracle does not cover `TWAP_PERIOD`.
    function _checkPriceDeviation(
        IUniswapV3PoolMinimal pool,
        uint160 sqrtPriceX96,
        uint256 maxDeviationBps
    )
        private
        view
    {
        uint160 twapSqrtPriceX96 = TickMath.getSqrtRatioAtTick(_twapTick(pool));

        // price = sqrtPrice^2, so spot / twap = (sqrtPriceX96 / twapSqrtPriceX96)^2
        uint256 sqrtRatioX96 = Math.mulDiv(sqrtPriceX96, Q96, twapSqrtPriceX96);
        // maxDeviationBps <= 100% caps the allowed price ratio at 2, so a sqrt ratio >= 2 always fails.
        // Bailing out here also keeps the squaring below from overflowing.
        require(sqrtRatioX96 < 2 * Q96, "Price deviation too high");
        uint256 priceRatioX96 = Math.mulDiv(sqrtRatioX96, sqrtRatioX96, Q96);

        require(
            priceRatioX96 * BPS <= (BPS + maxDeviationBps) * Q96
                && priceRatioX96 * BPS >= (BPS - maxDeviationBps) * Q96,
            "Price deviation too high"
        );
    }

    /// @dev Arithmetic mean tick over the last `TWAP_PERIOD` seconds, rounded towards negative infinity
    /// (same as Uniswap's OracleLibrary.consult)
    function _twapTick(IUniswapV3PoolMinimal pool) private view returns (int24 twapTick) {
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = TWAP_PERIOD;
        secondsAgos[1] = 0;

        (int56[] memory tickCumulatives,) = pool.observe(secondsAgos);

        int56 tickCumulativesDelta = tickCumulatives[1] - tickCumulatives[0];
        int56 period = int56(uint56(TWAP_PERIOD));

        // the mean of valid ticks is itself a valid tick, so it fits in int24
        // forge-lint: disable-next-line(unsafe-typecast)
        twapTick = int24(tickCumulativesDelta / period);
        if (tickCumulativesDelta < 0 && (tickCumulativesDelta % period != 0)) twapTick--;
    }

    function _checkDeadline(uint256 deadline) internal view {
        require(block.timestamp <= deadline, "Transaction too old");
    }
}
