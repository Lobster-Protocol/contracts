// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.28;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {SingleVault} from "./SingleVault.sol";
import {IUniswapV3PoolMinimal} from "../interfaces/uniswapV3/IUniswapV3PoolMinimal.sol";
import {LiquidityAmounts} from "../libraries/uniswapV3/LiquidityAmounts.sol";
import {TickMath} from "../libraries/uniswapV3/TickMath.sol";
import {FeeParams} from "../libraries/uniswapV3/PositionValue.sol";
import {PositionKey} from "../libraries/uniswapV3/PositionKey.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IUniswapV3MintCallback, MintCallbackData} from "../interfaces/uniswapV3/IUniswapV3MintCallback.sol";
import {PoolAddress} from "../libraries/uniswapV3/PoolAddress.sol";
import {TransferHelper} from "../libraries/uniswapV3/TransferHelper.sol";
import {InternalMulticall} from "../utils/InternalMulticall.sol";

uint256 constant SCALING_FACTOR = 1e18;

struct Position {
    int24 lowerTick;
    int24 upperTick;
    uint128 liquidity;
}

struct MinimalMintParams {
    int24 tickLower;
    int24 tickUpper;
    uint256 amount0Desired;
    uint256 amount1Desired;
    uint256 amount0Min;
    uint256 amount1Min;
    address recipient;
    uint256 deadline;
}

/**
 * @title
 * @author Elli <nathan@lobster-protocol.com>
 * @notice Allows to do lp on a uniswap v3 pool
 */
contract UniV3LpVault is SingleVault, InternalMulticall {
    using Math for uint256;

    /// @dev Q128 constant for fixed-point arithmetic in Uniswap V3 fee calculations
    uint256 internal constant Q128 = 0x100000000000000000000000000000000;

    IERC20 public immutable token0;
    IERC20 public immutable token1;
    address public immutable uniV3Factory;
    IUniswapV3PoolMinimal public immutable pool;
    uint24 private immutable pool_fee;

    Position[] public positions;
    uint8 public positionCount;

    error NotPool();
    error InvalidScalingFactor();

    event Deposit(uint256 indexed assets0, uint256 indexed assets1);
    event Withdraw(uint256 indexed assets0, uint256 indexed assets1, address indexed receiver);

    modifier checkDeadline(uint256 deadline) {
        require(block.timestamp <= deadline, "Transaction too old");
        _;
    }

    constructor(
        address initialOwner,
        address initialExecutor,
        address initialExecutorManager,
        address token0_,
        address token1_,
        address pool_
    )
        SingleVault(initialOwner, initialExecutor, initialExecutorManager)
    {
        require(uint160(token0_) < uint160(token1_), "Wrong token 0 & 1 order");

        pool = IUniswapV3PoolMinimal(pool_);
        require(pool.token0() == token0_ && pool.token1() == token1_, "Token mismatch");

        uniV3Factory = pool.factory();

        token0 = IERC20(token0_);
        token1 = IERC20(token1_);
        pool_fee = pool.fee();
    }

    /* ------------------OWNER ACTIONS------------------ */
    function deposit(uint256 assets0, uint256 assets1) external onlyOwner {
        if (assets0 == 0 && assets1 == 0) revert ZeroValue();

        // Execute the deposit
        if (assets0 > 0) {
            SafeERC20.safeTransferFrom(token0, msg.sender, address(this), assets0);
        }
        if (assets1 > 0) {
            SafeERC20.safeTransferFrom(token1, msg.sender, address(this), assets1);
        }

        emit Deposit(assets0, assets1);
    }

    function withdraw(uint256 scaledPercentage, address recipient) external onlyOwner {
        if (scaledPercentage > 100 * SCALING_FACTOR) {
            revert InvalidScalingFactor();
        }
        if (scaledPercentage == 0) revert ZeroValue();

        // Collect for all positions
        for (uint256 i = 0; i < positions.length; i++) {
            Position memory position = positions[i];

            collect(
                recipient,
                position.lowerTick,
                position.upperTick,
                type(uint128).max, // collect all amount0
                type(uint128).max // collect all amount1
            );
        }

        uint256 initialToken0Balance = token0.balanceOf(address(this));
        uint256 initialToken1Balance = token1.balanceOf(address(this));

        (uint256 withdrawn0, uint256 withdrawn1) = _withdrawFromPositions(scaledPercentage);

        uint256 assets0ToWithdraw = initialToken0Balance.mulDiv(scaledPercentage, SCALING_FACTOR) + withdrawn0;
        uint256 assets1ToWithdraw = initialToken1Balance.mulDiv(scaledPercentage, SCALING_FACTOR) + withdrawn1;

        // Execute withdraw
        if (assets0ToWithdraw > 0) {
            SafeERC20.safeTransfer(token0, recipient, assets0ToWithdraw);
        }
        if (assets1ToWithdraw > 0) {
            SafeERC20.safeTransfer(token1, recipient, assets1ToWithdraw);
        }

        emit Withdraw(assets0ToWithdraw, assets1ToWithdraw, recipient);
    }

    /* ------------------EXECUTOR ACTIONS------------------ */

    /// @notice Burns liquidity to a Uniswap V3 pool
    function burn(
        int24 tickLower,
        int24 tickUpper,
        uint128 amount
    )
        public
        onlyOwner
        returns (uint256 amount0, uint256 amount1)
    {
        // Burn the liquidity
        (amount0, amount1) = pool.burn(tickLower, tickUpper, amount);

        // Automatically collect the tokens
        pool.collect(
            address(this),
            tickLower,
            tickUpper,
            type(uint128).max, // collect all amount0
            type(uint128).max // collect all amount1
        );

        Position memory refPosition = Position({upperTick: tickUpper, lowerTick: tickLower, liquidity: 0});

        // Properly remove from array by swapping with last element
        for (uint256 i = 0; i < positions.length; i++) {
            Position memory position = positions[i];
            if (haveSameRange(position, refPosition)) {
                if (position.liquidity == amount) {
                    positions[i] = positions[positions.length - 1];
                    positions.pop();
                } else {
                    positions[i].liquidity -= amount;
                }
                break;
            }
        }
    }

    /// @notice Mints liquidity to a Uniswap V3 pool
    function mint(MinimalMintParams memory params)
        external
        onlyOwner
        checkDeadline(params.deadline)
        returns (uint256 amount0, uint256 amount1)
    {
        PoolAddress.PoolKey memory poolKey =
            PoolAddress.PoolKey({token0: address(token0), token1: address(token1), fee: pool_fee});

        // compute the liquidity amount
        uint128 liquidity;
        {
            (uint160 sqrtPriceX96,,,,,,) = pool.slot0();
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

        Position memory newPosition =
            Position({upperTick: params.tickUpper, lowerTick: params.tickLower, liquidity: liquidity});

        bool isPositionCreation = true;
        for (uint256 i = 0; i < positions.length; i++) {
            Position memory position = positions[i];

            if (haveSameRange(position, newPosition)) {
                positions[i].liquidity += liquidity;
                isPositionCreation = false;
                break;
            }
        }
        if (isPositionCreation) positions.push(newPosition);

        require(amount0 >= params.amount0Min && amount1 >= params.amount1Min, "Price slippage check");
    }

    function uniswapV3MintCallback(uint256 amount0Owed, uint256 amount1Owed, bytes calldata data) external {
        MintCallbackData memory decoded = abi.decode(data, (MintCallbackData));

        if (msg.sender != address(pool)) revert NotPool();
        if (amount0Owed > 0) {
            TransferHelper.safeTransferFrom(decoded.poolKey.token0, decoded.payer, msg.sender, amount0Owed);
        }
        if (amount1Owed > 0) {
            TransferHelper.safeTransferFrom(decoded.poolKey.token1, decoded.payer, msg.sender, amount1Owed);
        }
    }

    /// @notice Collects liquidity to a Uniswap V3 pool
    function collect(
        address recipient,
        int24 tickLower,
        int24 tickUpper,
        uint128 amount0Requested,
        uint128 amount1Requested
    )
        public
        returns (uint128 amount0, uint128 amount1)
    {
        return pool.collect(recipient, tickLower, tickUpper, amount0Requested, amount1Requested);
    }

    /* ------------------UTILS------------------ */

    function _withdrawFromPositions(uint256 scaledPercentage)
        private
        returns (uint256 withdrawn0, uint256 withdrawn1)
    {
        for (uint256 i = 0; i < positions.length; i++) {
            Position memory position = positions[i];

            uint128 liquidityToWithdraw = uint128(uint256(position.liquidity).mulDiv(scaledPercentage, SCALING_FACTOR));

            (uint256 amount0Burnt, uint256 amount1Burnt) =
                burn(position.lowerTick, position.upperTick, liquidityToWithdraw);

            withdrawn0 += amount0Burnt;
            withdrawn1 += amount1Burnt;
        }
    }

    function totalLpState(
        uint160 sqrtPriceX96,
        int24 currentTick
    )
        private
        view
        returns (uint256 assets0, uint256 assets1, uint256 uncollected0, uint256 uncollected1)
    {
        for (uint256 i = 0; i < positions.length; i++) {
            Position memory position = positions[i];

            bytes32 positionKey = PositionKey.compute(address(this), position.lowerTick, position.upperTick);

            (
                uint128 liquidity,
                uint256 feeGrowthInside0LastX128,
                uint256 feeGrowthInside1LastX128,
                uint128 tokensOwed0,
                uint128 tokensOwed1
            ) = pool.positions(positionKey);

            (uint256 positiontAssets0, uint256 positiontAssets1) =
                _principalPosition(sqrtPriceX96, position.lowerTick, position.upperTick, liquidity);

            (uint256 uncollectedAssets0, uint256 uncollectedAssets1) = _feePosition(
                FeeParams({
                    token0: address(token0),
                    token1: address(token1),
                    fee: pool_fee,
                    tickLower: position.lowerTick,
                    tickUpper: position.upperTick,
                    liquidity: liquidity,
                    positionFeeGrowthInside0LastX128: feeGrowthInside0LastX128,
                    positionFeeGrowthInside1LastX128: feeGrowthInside1LastX128,
                    tokensOwed0: tokensOwed0,
                    tokensOwed1: tokensOwed1
                }),
                currentTick
            );

            assets0 += positiontAssets0;
            assets1 += positiontAssets1;
            uncollected0 += uncollectedAssets0;
            uncollected1 += uncollectedAssets1;
        }
    }

    function _totalLpValue(uint160 sqrtPriceX96, int24 currentTick) internal view returns (uint256, uint256) {
        (uint256 position0, uint256 position1, uint256 uncollected0, uint256 uncollected1) =
            totalLpState(sqrtPriceX96, currentTick);

        return (position0 + uncollected0, position1 + uncollected1);
    }

    function totalLpValue() external view returns (uint256 totalAssets0, uint256 totalAssets1) {
        (uint160 sqrtPriceX96, int24 tickCurrent,,,,,) = pool.slot0();

        return _totalLpValue(sqrtPriceX96, tickCurrent);
    }

    /**
     * @dev Calculate the principal token amounts for a position at the current price
     * @param sqrtRatioX96 The current sqrt price of the pool
     * @param tickLower The lower tick boundary of the position
     * @param tickUpper The upper tick boundary of the position
     * @param liquidity The liquidity amount of the position
     * @return amount0 The amount of token0 in the position
     * @return amount1 The amount of token1 in the position
     */
    function _principalPosition(
        uint160 sqrtRatioX96,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity
    )
        internal
        pure
        returns (uint256 amount0, uint256 amount1)
    {
        return LiquidityAmounts.getAmountsForLiquidity(
            sqrtRatioX96, TickMath.getSqrtRatioAtTick(tickLower), TickMath.getSqrtRatioAtTick(tickUpper), liquidity
        );
    }

    /**
     * @dev Calculate the uncollected fees for a position
     * @param feeParams Struct containing all fee calculation parameters
     * @param tickCurrent The current tick of the pool
     * @return fee0 The uncollected fees in token0
     * @return fee1 The uncollected fees in token1
     */
    function _feePosition(
        FeeParams memory feeParams,
        int24 tickCurrent
    )
        internal
        view
        returns (uint256 fee0, uint256 fee1)
    {
        (uint256 poolFeeGrowthInside0LastX128, uint256 poolFeeGrowthInside1LastX128) =
            _getFeeGrowthInside(tickCurrent, feeParams.tickLower, feeParams.tickUpper);

        fee0 = (poolFeeGrowthInside0LastX128 - feeParams.positionFeeGrowthInside0LastX128).mulDiv(
            feeParams.liquidity, Q128
        ) + feeParams.tokensOwed0;

        fee1 = (poolFeeGrowthInside1LastX128 - feeParams.positionFeeGrowthInside1LastX128).mulDiv(
            feeParams.liquidity, Q128
        ) + feeParams.tokensOwed1;
    }

    /**
     * @dev Calculate the fee growth inside a position's tick range
     * This is a core Uniswap V3 calculation that determines how much fees have
     * accrued within the position's active range
     * @param tickCurrent The current tick of the pool
     * @param tickLower The lower tick boundary of the position
     * @param tickUpper The upper tick boundary of the position
     * @return feeGrowthInside0X128 Fee growth inside the range for token0
     * @return feeGrowthInside1X128 Fee growth inside the range for token1
     */
    function _getFeeGrowthInside(
        int24 tickCurrent,
        int24 tickLower,
        int24 tickUpper
    )
        private
        view
        returns (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128)
    {
        // Get fee growth data from the pool's tick boundaries
        (,, uint256 lowerFeeGrowthOutside0X128, uint256 lowerFeeGrowthOutside1X128,,,,) = pool.ticks(tickLower);
        (,, uint256 upperFeeGrowthOutside0X128, uint256 upperFeeGrowthOutside1X128,,,,) = pool.ticks(tickUpper);

        // Calculate fee growth inside based on current tick position
        if (tickCurrent < tickLower) {
            // Current price is below the position range
            feeGrowthInside0X128 = lowerFeeGrowthOutside0X128 - upperFeeGrowthOutside0X128;
            feeGrowthInside1X128 = lowerFeeGrowthOutside1X128 - upperFeeGrowthOutside1X128;
        } else if (tickCurrent < tickUpper) {
            // Current price is within the position range (position is active)
            uint256 feeGrowthGlobal0X128 = pool.feeGrowthGlobal0X128();
            uint256 feeGrowthGlobal1X128 = pool.feeGrowthGlobal1X128();
            feeGrowthInside0X128 = feeGrowthGlobal0X128 - lowerFeeGrowthOutside0X128 - upperFeeGrowthOutside0X128;
            feeGrowthInside1X128 = feeGrowthGlobal1X128 - lowerFeeGrowthOutside1X128 - upperFeeGrowthOutside1X128;
        } else {
            // Current price is above the position range
            feeGrowthInside0X128 = upperFeeGrowthOutside0X128 - lowerFeeGrowthOutside0X128;
            feeGrowthInside1X128 = upperFeeGrowthOutside1X128 - lowerFeeGrowthOutside1X128;
        }
    }

    function haveSameRange(Position memory pos1, Position memory pos2) internal pure returns (bool) {
        if (pos1.lowerTick == pos2.lowerTick && pos1.upperTick == pos2.upperTick) return true;
        return false;
    }
}
