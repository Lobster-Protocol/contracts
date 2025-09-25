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
import {UniswapV3Calculator} from "../utils/UniswapV3Calculator.sol";

uint256 constant SCALING_FACTOR = 1e18;
uint256 constant MAX_SCALED_PERCENTAGE = 100 * SCALING_FACTOR;

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
    uint256 deadline;
}

struct WithdrawParams {
    uint256 userScaledPercent;
    uint256 tvlFeeScaledPercent;
    address recipient; // recipient for the user's withdrawal
}

/**
 * @title
 * @author Elli <nathan@lobster-protocol.com>
 * @notice Allows to do lp on a uniswap v3 pool
 */
contract UniV3LpVault is SingleVault, UniswapV3Calculator {
    using Math for uint256;

    IERC20 public immutable token0;
    IERC20 public immutable token1;
    IUniswapV3PoolMinimal public immutable pool;
    uint24 private immutable pool_fee;
    Position[] private positions; // Supposed to hold up to 3 positions
    // Last time block management fees were collected
    uint256 public tvlFeeCollectedAt;
    // Annualized management fees, in basis point
    uint256 public tvlFeeScaled;
    address public feeCollector;

    error NotPool();
    error WrongPayer();
    error InvalidScalingFactor();

    event Deposit(uint256 indexed assets0, uint256 indexed assets1);
    event Withdraw(uint256 indexed assets0, uint256 indexed assets1, address indexed receiver);
    event TvlFeeCollected(uint256 indexed tvlFeeAssets0, uint256 indexed tvlFeeAssets1, address indexed feeCollector);

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
        address pool_,
        address initialFeeCollector,
        uint256 initialtvlFee
    )
        SingleVault(initialOwner, initialExecutor, initialExecutorManager)
    {
        require(uint160(token0_) < uint160(token1_), "Wrong token 0 & 1 order");
        require(initialFeeCollector != address(0), ZeroAddress());

        pool = IUniswapV3PoolMinimal(pool_);
        require(pool.token0() == token0_ && pool.token1() == token1_, "Token mismatch");

        token0 = IERC20(token0_);
        token1 = IERC20(token1_);
        pool_fee = pool.fee();
        feeCollector = initialFeeCollector;
        tvlFeeScaled = initialtvlFee;
        tvlFeeCollectedAt = block.timestamp;
    }

    /* ------------------OWNER ACTIONS------------------ */
    function deposit(uint256 assets0, uint256 assets1) external onlyOwner {
        if (assets0 == 0 && assets1 == 0) revert ZeroValue();

        _collectTvlFees();

        // Execute the deposit
        if (assets0 > 0) {
            SafeERC20.safeTransferFrom(token0, msg.sender, address(this), assets0);
        }
        if (assets1 > 0) {
            SafeERC20.safeTransferFrom(token1, msg.sender, address(this), assets1);
        }

        emit Deposit(assets0, assets1);
    }

    function withdraw(
        uint256 scaledPercentage,
        address recipient
    )
        external
        onlyOwner
        returns (uint256 amount0, uint256 amount1)
    {
        if (scaledPercentage == 0) revert ZeroValue();
        if (recipient == address(0)) revert ZeroAddress();

        (amount0, amount1) = _withdraw(
            WithdrawParams({
                userScaledPercent: scaledPercentage,
                tvlFeeScaledPercent: _pendingRelativeTvlFee(),
                recipient: recipient
            })
        );
    }

    /* ------------------EXECUTOR ACTIONS------------------ */

    /// @notice Burns liquidity to a Uniswap V3 pool
    function burn(
        int24 tickLower,
        int24 tickUpper,
        uint128 amount
    )
        public
        onlyOwnerOrExecutor
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
        onlyOwnerOrExecutor
        checkDeadline(params.deadline)
        returns (uint256 amount0, uint256 amount1)
    {
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

        PoolAddress.PoolKey memory poolKey =
            PoolAddress.PoolKey({token0: address(token0), token1: address(token1), fee: pool_fee});

        (amount0, amount1) = pool.mint(
            address(this),
            params.tickLower,
            params.tickUpper,
            liquidity,
            abi.encode(MintCallbackData({poolKey: poolKey, payer: address(this)}))
        );

        require(amount0 >= params.amount0Min && amount1 >= params.amount1Min, "Price slippage check");

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
        if (isPositionCreation) {
            positions.push(newPosition);
        }
    }

    function uniswapV3MintCallback(uint256 amount0Owed, uint256 amount1Owed, bytes calldata data) external {
        MintCallbackData memory decoded = abi.decode(data, (MintCallbackData));

        if (msg.sender != address(pool)) revert NotPool();
        // Payer must alway be this vault
        if (decoded.payer != address(this)) revert WrongPayer();

        if (amount0Owed > 0) {
            TransferHelper.safeTransfer(decoded.poolKey.token0, msg.sender, amount0Owed);
        }
        if (amount1Owed > 0) {
            TransferHelper.safeTransfer(decoded.poolKey.token1, msg.sender, amount1Owed);
        }
    }

    /// @notice Collects liquidity to a Uniswap V3 pool
    function collect(
        int24 tickLower,
        int24 tickUpper,
        uint128 amount0Requested,
        uint128 amount1Requested
    )
        public
        onlyOwnerOrExecutor
        returns (uint128 amount0, uint128 amount1)
    {
        return pool.collect(address(this), tickLower, tickUpper, amount0Requested, amount1Requested);
    }

    /* ------------------UTILS------------------ */

    function _pendingRelativeTvlFee() internal view returns (uint256) {
        uint256 deltaT = block.timestamp - tvlFeeCollectedAt;

        return min(tvlFeeScaled.mulDiv(deltaT, 365 days), MAX_SCALED_PERCENTAGE);
    }

    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? b : a;
    }

    function _collectTvlFees() internal {
        uint256 toCollect = _pendingRelativeTvlFee();

        if (toCollect == 0) return;

        WithdrawParams memory withdrawParams =
            WithdrawParams({userScaledPercent: 0, tvlFeeScaledPercent: toCollect, recipient: address(0)});

        _withdraw(withdrawParams);
    }

    function _withdrawFromPositions(uint256 scaledPercentage)
        private
        returns (uint256 withdrawn0, uint256 withdrawn1)
    {
        uint256 positionsCount = positions.length;
        // Create a copy of positions array to iterate safely
        Position[] memory positionsToProcess = new Position[](positionsCount);
        for (uint256 i = 0; i < positionsCount; i++) {
            positionsToProcess[i] = positions[i];
        }

        for (uint256 i = 0; i < positionsCount; i++) {
            Position memory position = positionsToProcess[i];

            uint128 liquidityToWithdraw =
                uint128(uint256(position.liquidity).mulDiv(scaledPercentage, MAX_SCALED_PERCENTAGE));

            (uint256 amount0Burnt, uint256 amount1Burnt) =
                burn(position.lowerTick, position.upperTick, liquidityToWithdraw);

            withdrawn0 += amount0Burnt;
            withdrawn1 += amount1Burnt;
        }
    }

    // returns raw value, pending fees must be deduced
    function _totalLpState(
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
                pool,
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

    function _withdraw(WithdrawParams memory withdrawParams) internal returns (uint256 amount0, uint256 amount1) {
        if (withdrawParams.userScaledPercent > MAX_SCALED_PERCENTAGE) {
            revert InvalidScalingFactor();
        }

        uint256 userScaledPercent = withdrawParams.userScaledPercent;
        uint256 tvlFeeScaledPercent = withdrawParams.tvlFeeScaledPercent;

        userScaledPercent =
            (MAX_SCALED_PERCENTAGE - tvlFeeScaledPercent).mulDiv(userScaledPercent, MAX_SCALED_PERCENTAGE);

        // Collect for all positions
        for (uint256 i = 0; i < positions.length; i++) {
            Position memory position = positions[i];

            collect(
                position.lowerTick,
                position.upperTick,
                type(uint128).max, // collect all amount0
                type(uint128).max // collect all amount1
            );
        }

        uint256 totalToWithdrawScaledPercent = userScaledPercent + tvlFeeScaledPercent;

        uint256 initialToken0Balance = token0.balanceOf(address(this));
        uint256 initialToken1Balance = token1.balanceOf(address(this));

        (uint256 withdrawn0, uint256 withdrawn1) = _withdrawFromPositions(totalToWithdrawScaledPercent);

        // Extract the fees
        if (tvlFeeScaledPercent > 0) {
            uint256 tvlFeeFromWithdrawn0 = totalToWithdrawScaledPercent > 0
                ? withdrawn0.mulDiv(tvlFeeScaledPercent, totalToWithdrawScaledPercent)
                : 0;
            uint256 tvlFeeFromWithdrawn1 = totalToWithdrawScaledPercent > 0
                ? withdrawn1.mulDiv(tvlFeeScaledPercent, totalToWithdrawScaledPercent)
                : 0;

            uint256 tvlFeeAssets0 =
                initialToken0Balance.mulDiv(tvlFeeScaledPercent, MAX_SCALED_PERCENTAGE) + tvlFeeFromWithdrawn0;
            uint256 tvlFeeAssets1 =
                initialToken1Balance.mulDiv(tvlFeeScaledPercent, MAX_SCALED_PERCENTAGE) + tvlFeeFromWithdrawn1;

            if (tvlFeeAssets0 > 0) {
                SafeERC20.safeTransfer(token0, feeCollector, tvlFeeAssets0);
            }
            if (tvlFeeAssets1 > 0) {
                SafeERC20.safeTransfer(token1, feeCollector, tvlFeeAssets1);
            }

            emit TvlFeeCollected(tvlFeeAssets0, tvlFeeAssets1, feeCollector);

            tvlFeeCollectedAt = block.timestamp;
        }

        // User Withdraw
        uint256 fromWithdrawn0 =
            totalToWithdrawScaledPercent > 0 ? withdrawn0.mulDiv(userScaledPercent, totalToWithdrawScaledPercent) : 0;
        uint256 fromWithdrawn1 =
            totalToWithdrawScaledPercent > 0 ? withdrawn1.mulDiv(userScaledPercent, totalToWithdrawScaledPercent) : 0;

        uint256 assets0ToWithdrawForUser =
            initialToken0Balance.mulDiv(userScaledPercent, MAX_SCALED_PERCENTAGE) + fromWithdrawn0;

        uint256 assets1ToWithdrawForUser =
            initialToken1Balance.mulDiv(userScaledPercent, MAX_SCALED_PERCENTAGE) + fromWithdrawn1;

        // Execute user withdraw
        bool withdrawEvent = false;
        if (assets0ToWithdrawForUser > 0) {
            SafeERC20.safeTransfer(token0, withdrawParams.recipient, assets0ToWithdrawForUser);
            withdrawEvent = true;
        }
        if (assets1ToWithdrawForUser > 0) {
            SafeERC20.safeTransfer(token1, withdrawParams.recipient, assets1ToWithdrawForUser);
            withdrawEvent = true;
        }
        if (withdrawEvent) {
            emit Withdraw(assets0ToWithdrawForUser, assets1ToWithdrawForUser, withdrawParams.recipient);
        }

        return (assets0ToWithdrawForUser, assets1ToWithdrawForUser);
    }

    // pending fees must be deduces from the result
    function _totalLpValue(
        uint160 sqrtPriceX96,
        int24 currentTick
    )
        internal
        view
        returns (uint256 amount0, uint256 amount1)
    {
        (uint256 position0, uint256 position1, uint256 uncollected0, uint256 uncollected1) =
            _totalLpState(sqrtPriceX96, currentTick);

        // raw values
        (amount0, amount1) = (position0 + uncollected0, position1 + uncollected1);
    }

    function totalLpValue() external view returns (uint256 totalAssets0, uint256 totalAssets1) {
        (uint160 sqrtPriceX96, int24 tickCurrent,,,,,) = pool.slot0();

        return _totalLpValue(sqrtPriceX96, tickCurrent);
    }

    function netAssetsValue() external view returns (uint256 totalAssets0, uint256 totalAssets1) {
        (totalAssets0, totalAssets1) = _rawAssetsValue();

        // Apply TVL fee deduction
        uint256 tokensLeft = MAX_SCALED_PERCENTAGE - _pendingRelativeTvlFee();

        totalAssets0 = totalAssets0.mulDiv(tokensLeft, MAX_SCALED_PERCENTAGE);
        totalAssets1 = totalAssets1.mulDiv(tokensLeft, MAX_SCALED_PERCENTAGE);

        return (totalAssets0, totalAssets1);
    }

    function _rawAssetsValue() internal view returns (uint256 totalAssets0, uint256 totalAssets1) {
        (uint160 sqrtPriceX96, int24 tickCurrent,,,,,) = pool.slot0();

        (totalAssets0, totalAssets1) = _totalLpValue(sqrtPriceX96, tickCurrent);

        totalAssets0 += token0.balanceOf(address(this));
        totalAssets1 += token1.balanceOf(address(this));
    }

    function haveSameRange(Position memory pos1, Position memory pos2) internal pure returns (bool) {
        if (pos1.lowerTick == pos2.lowerTick && pos1.upperTick == pos2.upperTick) return true;
        return false;
    }

    function getPosition(uint256 index) external view returns (Position memory) {
        return positions[index];
    }

    function rawAssetsValue() external view returns (uint256 totalAssets0, uint256 totalAssets1) {
        return _rawAssetsValue();
    }

    function pendingTvlFee() external view returns (uint256 amount0, uint256 amount1) {
        uint256 pendingRelativeTvlFee = _pendingRelativeTvlFee();

        (amount0, amount1) = _rawAssetsValue();

        amount0.mulDiv(pendingRelativeTvlFee, MAX_SCALED_PERCENTAGE);
        amount1.mulDiv(pendingRelativeTvlFee, MAX_SCALED_PERCENTAGE);
    }

    function positionsLength() external view returns (uint256) {
        return positions.length;
    }

    // todo: add preview withdraw
    // todo: add fee update fct -> le client doit signer un msg pour approuver + préavis de 14 jours appres publication de la sig
    // todo: collect perf fee & tvl fee monthly ?? demander accord au deploiement via msg signé ?
}
