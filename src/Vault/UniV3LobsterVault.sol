// SPDX-License-Identifier: GNU AGPL v3.0
pragma solidity ^0.8.28;

import {IUniswapV3PoolMinimal} from "../interfaces/uniswapV3/IUniswapV3PoolMinimal.sol";
import {LobsterVault} from "./LobsterVault.sol";
import {Position} from "../libraries/uniswapV3/UniswapUtils.sol";
import {PositionValue, FeeParams} from "../libraries/uniswapV3/PositionValue.sol";
import {INonFungiblePositionManager} from "../interfaces/uniswapV3/INonFungiblePositionManager.sol";
import {IOpValidatorModule, BaseOp, Op, BatchOp} from "../interfaces/modules/IOpValidatorModule.sol";
import {BASIS_POINT_SCALE} from "../Modules/Constants.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {LiquidityAmounts} from "../libraries/uniswapV3/LiquidityAmounts.sol";
import {TickMath} from "../libraries/uniswapV3/TickMath.sol";

/**
 * @title UniV3LobsterVault
 * @author Lobster
 * @notice A modular ERC4626 vault with 2 underlying tokens and operation validation mechanism.
 * This vault is specifically designed to hold Uniswap V3 positions on behalf of the share holders.
 */
contract UniV3LobsterVault is LobsterVault {
    using Math for uint256;

    uint256 internal constant Q128 = 0x100000000000000000000000000000000;
    INonFungiblePositionManager public immutable positionManager;
    IUniswapV3PoolMinimal public immutable pool;
    uint256 public immutable feeCutBasisPoint;
    address public immutable feeCollector;

    uint24 private immutable poolFee;

    // Struct to avoid stack too deep errors in _withdraw
    struct WithdrawVars {
        uint256 tokensCount;
        uint256 initialToken0Balance;
        uint256 initialToken1Balance;
        uint160 sqrtPriceX96;
        uint256 allCollectedFee0;
        uint256 allCollectedFee1;
        uint256 totalWithdrawnFromPosition0;
        uint256 totalWithdrawnFromPosition1;
        uint256 feeCut0;
        uint256 feeCut1;
        uint256 valueToWithdraw0;
        uint256 valueToWithdraw1;
        uint256 withdrawnAssets;
    }

    struct PositionVars {
        uint256 tokenId;
        address token0;
        address token1;
        uint24 fee;
        uint128 liquidity;
        address computedPoolAddress;
        uint256 position0;
        uint256 fee0;
        uint256 position1;
        uint256 fee1;
        uint256 toWithdraw0;
        uint256 toWithdraw1;
        uint128 total0;
        uint128 total1;
        int24 tickLower;
        int24 tickUpper;
        uint256 feeGrowthInside0LastX128;
        uint256 feeGrowthInside1LastX128;
        uint256 tokensOwed0;
        uint256 tokensOwed1;
    }

    event UniV3LobsterVaultSetUp(
        IOpValidatorModule indexed opValidator,
        IUniswapV3PoolMinimal indexed pool,
        INonFungiblePositionManager indexed positionManager
    );
    event FeeSet(address indexed feeCollector_, uint256 indexed feeCutBasisPoint_);

    constructor(
        IOpValidatorModule opValidator_,
        IUniswapV3PoolMinimal pool_,
        INonFungiblePositionManager positionManager_,
        address feeCollector_,
        uint256 feeCutBasisPoint_
    )
        LobsterVault(opValidator_, IERC20(pool_.token0()), IERC20(pool_.token1()))
    {
        require(feeCutBasisPoint_ <= BASIS_POINT_SCALE, "UniV3LobsterVault: fee cut too high");
        require(
            address(opValidator_) != address(0) && address(pool_) != address(0)
                && address(positionManager_) != address(0) && address(feeCollector_) != address(0),
            ZeroAddress()
        );

        opValidator = opValidator_;
        pool = pool_;
        positionManager = positionManager_;

        emit UniV3LobsterVaultSetUp(opValidator_, pool_, positionManager_);

        feeCutBasisPoint = feeCutBasisPoint_;
        feeCollector = feeCollector_;
        emit FeeSet(feeCollector_, feeCutBasisPoint_);

        poolFee = pool_.fee();
    }

    /**
     * @dev Handles the withdrawal flow:
     * - Extract the tokens from the Uniswap V3 positions
     * - Burns shares from the caller
     * - Transfers the assets to the receiver
     *
     * @dev Note: This function assumes the caller is the vault itself
     */
    function _withdraw(
        address caller,
        address receiver,
        address owner,
        uint256, /* assets */
        uint256 shares
    )
        internal
        override
    {
        if (caller != owner) {
            _spendAllowance(owner, caller, shares);
        }

        WithdrawVars memory vars;

        // Initialize withdrawal variables
        vars.tokensCount = positionManager.balanceOf(address(this));
        vars.initialToken0Balance = asset0.balanceOf(address(this));
        vars.initialToken1Balance = asset1.balanceOf(address(this));

        (vars.sqrtPriceX96,,,,,,) = pool.slot0();

        // Process all positions
        _processPositions(shares, vars);

        // Calculate total withdrawal amounts
        vars.valueToWithdraw0 = vars.totalWithdrawnFromPosition0
            + vars.initialToken0Balance.mulDiv(shares, totalSupply())
            + (vars.allCollectedFee0 - vars.feeCut0).mulDiv(shares, totalSupply());

        vars.valueToWithdraw1 = vars.totalWithdrawnFromPosition1
            + vars.initialToken1Balance.mulDiv(shares, totalSupply())
            + (vars.allCollectedFee1 - vars.feeCut1).mulDiv(shares, totalSupply());

        // Burn shares before transfers to avoid reentrancy
        _burn(owner, shares);

        // Calculate and distribute fees and withdrawals
        _transferWithdraws(receiver, vars);
        emit IERC4626.Withdraw(caller, receiver, owner, vars.withdrawnAssets, shares);
    }

    /**
     * @dev Process all Uniswap V3 positions for withdrawal
     */
    function _processPositions(uint256 shares, WithdrawVars memory vars) internal {
        for (uint256 i = 0; i < vars.tokensCount; ++i) {
            PositionVars memory posVars;

            posVars.tokenId = positionManager.tokenOfOwnerByIndex(address(this), i);

            // Get position details
            (
                ,
                ,
                posVars.token0,
                posVars.token1,
                posVars.fee,
                posVars.tickLower,
                posVars.tickUpper,
                posVars.liquidity,
                posVars.feeGrowthInside0LastX128,
                posVars.feeGrowthInside1LastX128,
                posVars.tokensOwed0,
                posVars.tokensOwed1
            ) = positionManager.positions(posVars.tokenId);

            // Verify position is in our pool
            if (!_isPositionInPool(posVars.token0, posVars.token1, posVars.fee)) {
                continue;
            }

            (uint160 sqrtPriceX96, int24 tickCurrent,,,,,) = pool.slot0();

            // Get position value and fees
            (posVars.position0, posVars.position1) =
                _principalPosition(sqrtPriceX96, posVars.tickLower, posVars.tickUpper, posVars.liquidity);
            (uint256 fee0, uint256 fee1) = _feePosition(
                FeeParams({
                    token0: posVars.token0,
                    token1: posVars.token1,
                    fee: posVars.fee,
                    tickLower: posVars.tickLower,
                    tickUpper: posVars.tickUpper,
                    liquidity: posVars.liquidity,
                    positionFeeGrowthInside0LastX128: posVars.feeGrowthInside0LastX128,
                    positionFeeGrowthInside1LastX128: posVars.feeGrowthInside1LastX128,
                    tokensOwed0: posVars.tokensOwed0,
                    tokensOwed1: posVars.tokensOwed1
                }),
                tickCurrent
            );

            // Calculate withdrawal amounts
            posVars.toWithdraw0 = posVars.position0.mulDiv(shares, totalSupply());
            posVars.toWithdraw1 = posVars.position1.mulDiv(shares, totalSupply());

            // Accumulate totals
            vars.allCollectedFee0 += fee0;
            vars.allCollectedFee1 += fee1;
            vars.totalWithdrawnFromPosition0 += posVars.toWithdraw0;
            vars.totalWithdrawnFromPosition1 += posVars.toWithdraw1;

            // Execute position operations
            _executePositionWithdrawal(posVars);
        }
    }

    /**
     * @dev Check if position belongs to our pool
     */
    function _isPositionInPool(address token0, address token1, uint24 fee) internal view returns (bool result) {
        return token0 == address(asset0) && token1 == address(asset1) && fee == poolFee;
    }

    /**
     * @dev Execute decrease liquidity and collect operations for a position
     */
    function _executePositionWithdrawal(PositionVars memory posVars) internal {
        // Decrease liquidity if needed
        if (posVars.toWithdraw0 > 0 || posVars.toWithdraw1 > 0) {
            INonFungiblePositionManager.DecreaseLiquidityParams memory params = INonFungiblePositionManager
                .DecreaseLiquidityParams({
                tokenId: posVars.tokenId,
                liquidity: posVars.liquidity,
                amount0Min: posVars.toWithdraw0,
                amount1Min: posVars.toWithdraw1,
                deadline: block.timestamp
            });

            BaseOp memory decreaseLiquidity = BaseOp({
                target: address(positionManager),
                value: 0,
                data: abi.encodeCall(positionManager.decreaseLiquidity, (params))
            });

            call_(decreaseLiquidity);
        }

        // Collect tokens and fees
        posVars.total0 = uint128(posVars.toWithdraw0 + posVars.fee0);
        posVars.total1 = uint128(posVars.toWithdraw1 + posVars.fee1);

        if (posVars.total0 > 0 || posVars.total1 > 0) {
            BaseOp memory collectFees = BaseOp({
                target: address(positionManager),
                value: 0,
                data: abi.encodeCall(
                    positionManager.collect,
                    (
                        INonFungiblePositionManager.CollectParams({
                            recipient: address(this),
                            tokenId: posVars.tokenId,
                            amount0Max: posVars.total0,
                            amount1Max: posVars.total1
                        })
                    )
                )
            });
            call_(collectFees);
        }
    }

    /**
     * @dev Calculate fee cuts and transfer assets to receiver
     */
    function _transferWithdraws(address receiver, WithdrawVars memory vars) internal {
        // Calculate fee cuts
        vars.feeCut0 = vars.allCollectedFee0.mulDiv(feeCutBasisPoint, BASIS_POINT_SCALE);
        vars.feeCut1 = vars.allCollectedFee1.mulDiv(feeCutBasisPoint, BASIS_POINT_SCALE);

        // Transfer fee cuts to collector
        if (vars.feeCut0 > 0) {
            SafeERC20.safeTransfer(asset0, feeCollector, vars.feeCut0);
        }
        if (vars.feeCut1 > 0) {
            SafeERC20.safeTransfer(asset1, feeCollector, vars.feeCut1);
        }

        // Transfer assets to receiver
        if (vars.valueToWithdraw0 > 0) {
            SafeERC20.safeTransfer(asset0, receiver, vars.valueToWithdraw0);
        }
        if (vars.valueToWithdraw1 > 0) {
            SafeERC20.safeTransfer(asset1, receiver, vars.valueToWithdraw1);
        }

        vars.withdrawnAssets = packUint128(uint128(vars.valueToWithdraw0), uint128(vars.valueToWithdraw1));
    }

    /**
     * @dev Calculates the total value of assets in the calling vault
     * This includes:
     * - Direct token holdings
     * - Value locked in active Uniswap V3 positions
     * - Uncollected fees (minus the protocol fee cut)
     * @dev Note: This function assumes the caller is the vault itself
     *
     * @return totalValue The total value of assets in the vault packed as a single uint256 = (token0Value << 128) | token1Value
     */
    function totalAssets() public view override returns (uint256 totalValue) {
        // Get the direct pool token balances owned by the vault
        uint256 amount0 = asset0.balanceOf(address(this));
        uint256 amount1 = asset1.balanceOf(address(this));

        // Get all the positions in the pool (including non-collected fees)
        (
            Position memory position0, // contains fees - fee cut
            Position memory position1 // contains fees - cut
        ) = getAllUniswapV3Positions(address(this));

        // Pack the two uint128 values into a single uint256
        totalValue = packUint128(uint128(amount0 + position0.value), uint128(amount1 + position1.value));
    }

    /**
     * @dev Calculates the total value of a user's Uniswap V3 positions in the specified pool
     * Includes both the principal token amounts and uncollected fees (minus the protocol fee cut)
     *
     * @param user The address whose positions to calculate
     * @return position0 The total value in token0 with fee adjustments
     * @return position1 The total value in token1 with fee adjustments
     */
    function getAllUniswapV3Positions(address user)
        public
        view
        returns (Position memory position0, Position memory position1)
    {
        // Get the total number of NFT positions owned by the user
        uint256 balance = positionManager.balanceOf(user);

        // Initialize position values
        position0 = Position({token: address(asset0), value: 0});
        position1 = Position({token: address(asset1), value: 0});

        // Iterate through all positions
        for (uint256 i = 0; i < balance; i++) {
            // Get the tokenId for the current position
            uint256 tokenId = positionManager.tokenOfOwnerByIndex(user, i);

            // Retrieve position details
            (
                ,
                ,
                address token0,
                address token1,
                uint24 fee,
                int24 tickLower,
                int24 tickUpper,
                uint128 liquidity,
                uint256 feeGrowthInside0LastX128,
                uint256 feeGrowthInside1LastX128,
                uint256 tokensOwed0,
                uint256 tokensOwed1
            ) = positionManager.positions(tokenId);

            // Only count positions in the relevant pool
            // -> OTHER POSITIONS WILL BE IGNORED
            if (_isPositionInPool(token0, token1, fee)) {
                // Get current price to value the position
                // todo: can i manually compute the sqrtPrice and tickCurrent from positionManager.positions(tokenId) ??
                (uint160 sqrtPriceX96, int24 tickCurrent,,,,,) = pool.slot0();

                // Get total position value and fees
                (uint256 amount0, uint256 amount1) = _principalPosition(sqrtPriceX96, tickLower, tickUpper, liquidity);
                (uint256 fee0, uint256 fee1) = _feePosition(
                    FeeParams({
                        token0: token0,
                        token1: token1,
                        fee: fee,
                        tickLower: tickLower,
                        tickUpper: tickUpper,
                        liquidity: liquidity,
                        positionFeeGrowthInside0LastX128: feeGrowthInside0LastX128,
                        positionFeeGrowthInside1LastX128: feeGrowthInside1LastX128,
                        tokensOwed0: tokensOwed0,
                        tokensOwed1: tokensOwed1
                    }),
                    tickCurrent
                );

                // Add principal amounts directly
                position0.value += amount0;
                position1.value += amount1;

                // For fees, apply the fee cut before adding
                position0.value += fee0.mulDiv(BASIS_POINT_SCALE - feeCutBasisPoint, BASIS_POINT_SCALE);
                position1.value += fee1.mulDiv(BASIS_POINT_SCALE - feeCutBasisPoint, BASIS_POINT_SCALE);
            }
        }

        return (position0, position1);
    }

    function call_(BaseOp memory op) internal returns (bytes memory result) {
        (bool success, bytes memory returnData) = op.target.call{value: op.value}(op.data);
        require(success, "UniV3LobsterVault: call failed");
        return returnData;
    }

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

        fee0 = uint256(poolFeeGrowthInside0LastX128 - feeParams.positionFeeGrowthInside0LastX128).mulDiv(
            feeParams.liquidity, Q128
        ) + feeParams.tokensOwed0;

        fee1 = (poolFeeGrowthInside1LastX128 - feeParams.positionFeeGrowthInside1LastX128).mulDiv(
            feeParams.liquidity, Q128
        ) + feeParams.tokensOwed1;
    }

    function _getFeeGrowthInside(
        int24 tickCurrent,
        int24 tickLower,
        int24 tickUpper
    )
        private
        view
        returns (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128)
    {
        (,, uint256 lowerFeeGrowthOutside0X128, uint256 lowerFeeGrowthOutside1X128,,,,) = pool.ticks(tickLower);
        (,, uint256 upperFeeGrowthOutside0X128, uint256 upperFeeGrowthOutside1X128,,,,) = pool.ticks(tickUpper);

        if (tickCurrent < tickLower) {
            feeGrowthInside0X128 = lowerFeeGrowthOutside0X128 - upperFeeGrowthOutside0X128;
            feeGrowthInside1X128 = lowerFeeGrowthOutside1X128 - upperFeeGrowthOutside1X128;
        } else if (tickCurrent < tickUpper) {
            uint256 feeGrowthGlobal0X128 = pool.feeGrowthGlobal0X128();
            uint256 feeGrowthGlobal1X128 = pool.feeGrowthGlobal1X128();
            feeGrowthInside0X128 = feeGrowthGlobal0X128 - lowerFeeGrowthOutside0X128 - upperFeeGrowthOutside0X128;
            feeGrowthInside1X128 = feeGrowthGlobal1X128 - lowerFeeGrowthOutside1X128 - upperFeeGrowthOutside1X128;
        } else {
            feeGrowthInside0X128 = upperFeeGrowthOutside0X128 - lowerFeeGrowthOutside0X128;
            feeGrowthInside1X128 = upperFeeGrowthOutside1X128 - lowerFeeGrowthOutside1X128;
        }
    }

    // todo: add collect fee function
}
