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
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/**
 * @title UniV3LobsterVault
 * @author Lobster
 * @notice A modular ERC4626 vault designed to manage Uniswap V3 positions with dual-token assets.
 * This vault holds Uniswap V3 NFT positions on behalf of share holders and manages liquidity
 * operations while implementing a fee structure for collected trading fees.
 */
contract UniV3LobsterVault is LobsterVault, Ownable2Step {
    using Math for uint256;

    /// @dev Q128 constant for fixed-point arithmetic in Uniswap V3 fee calculations
    uint256 internal constant Q128 = 0x100000000000000000000000000000000;

    /// @notice The Uniswap V3 position manager contract for handling NFT positions
    INonFungiblePositionManager public immutable positionManager;

    /// @notice The specific Uniswap V3 pool this vault operates on
    IUniswapV3PoolMinimal public immutable pool;

    /// @notice The fee cut taken from collected fees, expressed in basis points
    uint256 public immutable feeCutBasisPoint;

    /// @notice Address that receives the protocol fee cuts
    address public feeCollector;

    /// @dev The fee tier of the pool (cached for gas optimization)
    uint24 private immutable poolFee;

    /**
     * @dev Struct to avoid stack too deep errors in _withdraw function
     * Contains all variables needed during the withdrawal process
     */
    struct WithdrawVars {
        uint256 tokensCount;
        uint256 initialToken0Balance;
        uint256 initialToken1Balance;
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

    /**
     * @dev Struct to avoid stack too deep errors when processing individual positions
     * Contains all variables needed for a single position's operations
     */
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

    /**
     * @notice Emitted when the vault is successfully set up with core parameters
     * @param opValidator The operation validator module address
     * @param pool The Uniswap V3 pool address
     * @param positionManager The position manager address
     */
    event UniV3LobsterVaultSetUp(
        IOpValidatorModule indexed opValidator,
        IUniswapV3PoolMinimal indexed pool,
        INonFungiblePositionManager indexed positionManager
    );

    /**
     * @notice Emitted when fees are collected from all positions
     * @param totalFees0 Total fees collected in token0
     * @param totalFees1 Total fees collected in token1
     */
    event FeesCollected(uint256 totalFees0, uint256 totalFees1);

    /**
     * @notice Emitted when the fee collector address is updated
     * @param newFeeCollector The new fee collector address
     */
    event FeeCollectorUpdated(address indexed newFeeCollector);

    /**
     * @notice Emitted when fee parameters are set
     * @param feeCollector_ The address that will receive fee cuts
     * @param feeCutBasisPoint_ The fee cut percentage in basis points
     */
    event FeeSet(address indexed feeCollector_, uint256 indexed feeCutBasisPoint_);

    /**
     * @notice Constructs a new UniV3LobsterVault
     * @param opValidator_ The operation validator module for transaction validation
     * @param pool_ The Uniswap V3 pool to operate on
     * @param positionManager_ The Uniswap V3 position manager contract
     * @param feeCollector_ Address that will receive protocol fee cuts
     * @param feeCutBasisPoint_ Fee cut percentage in basis points (must be <= BASIS_POINT_SCALE)
     */
    constructor(
        IOpValidatorModule opValidator_,
        IUniswapV3PoolMinimal pool_,
        INonFungiblePositionManager positionManager_,
        address feeCollector_,
        uint256 feeCutBasisPoint_,
        address initialOwner_
    )
        LobsterVault(opValidator_, IERC20(pool_.token0()), IERC20(pool_.token1()))
        Ownable(initialOwner_)
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
     * @dev Handles the withdrawal flow for Uniswap V3 positions:
     * - Processes all vault's Uniswap V3 positions
     * - Decreases liquidity proportionally based on shares being withdrawn
     * - Collects tokens and fees from positions
     * - Burns shares from the owner
     * - Transfers fee cuts to the fee collector
     * - Transfers remaining assets to the receiver
     * @param caller Address initiating the withdrawal
     * @param receiver Address to receive the withdrawn assets
     * @param owner Address that owns the shares being burned
     * @param assets Packed uint256 containing both asset amounts to withdraw
     * @param shares Amount of shares to burn
     */
    function _withdraw(
        address caller,
        address receiver,
        address owner,
        uint256 assets,
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

        // Process all positions
        _processPositions(shares, vars);

        // Calculate total withdrawal amounts
        (vars.valueToWithdraw0, vars.valueToWithdraw1) = unpackUint128(assets);

        // Burn shares before transfers to avoid reentrancy
        _burn(owner, shares);

        // Calculate and distribute fees and withdrawals
        _transferWithdraws(receiver, vars);

        emit IERC4626.Withdraw(caller, receiver, owner, vars.withdrawnAssets, shares);
    }

    /**
     * @dev Check if a position belongs to this vault's designated pool
     * @param token0 The first token of the position
     * @param token1 The second token of the position
     * @param fee The fee tier of the position
     * @return result True if the position matches this vault's pool parameters
     */
    function _isPositionInPool(address token0, address token1, uint24 fee) internal view returns (bool result) {
        return token0 == address(asset0) && token1 == address(asset1) && fee == poolFee;
    }

    /**
     * @dev Execute decrease liquidity and collect operations for a single position
     * First decreases liquidity by the calculated withdrawal amounts, then collects
     * both the withdrawn tokens and any accumulated fees
     * @param posVars The position variables containing all necessary data for the operations
     */
    function _executePositionWithdrawal(PositionVars memory posVars) internal {
        // todo: if the position is left with low liquidity, burn it

        // Decrease liquidity if there are amounts to withdraw
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

        // Collect tokens and fees (total = principal + fees)
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
     * @dev Calculate protocol fee cuts from collected fees and transfer assets to receiver
     * Separates collected fees into protocol cuts (sent to fee collector) and user portions
     * @param receiver Address to receive the withdrawn assets
     * @param vars The withdrawal variables containing all calculated amounts
     */
    function _transferWithdraws(address receiver, WithdrawVars memory vars) internal {
        // Calculate protocol fee cuts from total collected fees
        vars.feeCut0 = vars.allCollectedFee0.mulDiv(feeCutBasisPoint, BASIS_POINT_SCALE);
        vars.feeCut1 = vars.allCollectedFee1.mulDiv(feeCutBasisPoint, BASIS_POINT_SCALE);

        // Transfer protocol fee cuts to collector
        if (vars.feeCut0 > 0) {
            SafeERC20.safeTransfer(asset0, feeCollector, vars.feeCut0);
        }
        if (vars.feeCut1 > 0) {
            SafeERC20.safeTransfer(asset1, feeCollector, vars.feeCut1);
        }

        // Transfer withdrawn assets to receiver
        if (vars.valueToWithdraw0 > 0) {
            SafeERC20.safeTransfer(asset0, receiver, vars.valueToWithdraw0);
        }
        if (vars.valueToWithdraw1 > 0) {
            SafeERC20.safeTransfer(asset1, receiver, vars.valueToWithdraw1);
        }

        vars.withdrawnAssets = packUint128(uint128(vars.valueToWithdraw0), uint128(vars.valueToWithdraw1));
    }

    /**
     * @dev Calculates the total value of assets controlled by the vault
     * This includes:
     * - Direct token holdings in the vault
     * - Value locked in active Uniswap V3 positions (principal amounts)
     * - Uncollected fees from positions (minus the protocol fee cut)
     * @return totalValue The total value packed as uint256: (token0Value << 128) | token1Value
     */
    function totalAssets() public view override returns (uint256 totalValue) {
        // Get direct token balances held by the vault
        uint256 amount0 = asset0.balanceOf(address(this));
        uint256 amount1 = asset1.balanceOf(address(this));

        // Get aggregated position values (includes principal + fees minus fee cuts)
        (
            Position memory position0, // contains fees - fee cut
            Position memory position1 // contains fees - fee cut
        ) = getAllUniswapV3Positions(address(this));

        // Pack the combined values into a single uint256
        totalValue = packUint128(uint128(amount0 + position0.value), uint128(amount1 + position1.value));
    }

    /**
     * @dev Calculates the total value of a user's Uniswap V3 positions in this vault's pool
     * Includes both the principal token amounts and uncollected fees (minus the protocol fee cut)
     * Only positions that match this vault's pool (token0, token1, fee) are included
     * @param user The address whose positions to calculate
     * @return position0 The total value in token0 (principal + fees - fee cut)
     * @return position1 The total value in token1 (principal + fees - fee cut)
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

        // Iterate through all positions owned by the user
        for (uint256 i = 0; i < balance; i++) {
            // Get the tokenId for the current position
            uint256 tokenId = positionManager.tokenOfOwnerByIndex(user, i);

            // Process each position individually to avoid stack too deep
            _processPosition(tokenId, position0, position1);
        }

        return (position0, position1);
    }

    /**
     * @dev Internal helper to process a single position and update totals
     * @param tokenId The NFT token ID of the position
     * @param position0 Reference to position0 total (will be modified)
     * @param position1 Reference to position1 total (will be modified)
     */
    function _processPosition(uint256 tokenId, Position memory position0, Position memory position1) internal view {
        // Get position data in a struct to reduce stack usage
        PositionData memory posData = _getPositionData(tokenId);

        // Only count positions that belong to this vault's pool
        if (_isPositionInPool(posData.token0, posData.token1, posData.fee)) {
            // Get current pool state for position valuation
            (uint160 sqrtPriceX96, int24 tickCurrent,,,,,) = pool.slot0();

            // Calculate and add principal amounts
            (uint256 amount0, uint256 amount1) =
                _principalPosition(sqrtPriceX96, posData.tickLower, posData.tickUpper, posData.liquidity);

            position0.value += amount0;
            position1.value += amount1;

            // Calculate and add fees (minus protocol cut)
            _addFeesToPosition(posData, tickCurrent, position0, position1);
        }
    }

    /**
     * @dev Struct to hold position data and reduce stack usage
     */
    struct PositionData {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint256 feeGrowthInside0LastX128;
        uint256 feeGrowthInside1LastX128;
        uint256 tokensOwed0;
        uint256 tokensOwed1;
    }

    /**
     * @dev Get position data from position manager
     * @param tokenId The NFT token ID of the position
     * @return posData Struct containing all position data
     */
    function _getPositionData(uint256 tokenId) internal view returns (PositionData memory posData) {
        (
            ,
            ,
            posData.token0,
            posData.token1,
            posData.fee,
            posData.tickLower,
            posData.tickUpper,
            posData.liquidity,
            posData.feeGrowthInside0LastX128,
            posData.feeGrowthInside1LastX128,
            posData.tokensOwed0,
            posData.tokensOwed1
        ) = positionManager.positions(tokenId);
    }

    /**
     * @dev Calculate and add fees to position totals
     * @param posData Position data struct
     * @param tickCurrent Current pool tick
     * @param position0 Reference to position0 total (will be modified)
     * @param position1 Reference to position1 total (will be modified)
     */
    function _addFeesToPosition(
        PositionData memory posData,
        int24 tickCurrent,
        Position memory position0,
        Position memory position1
    )
        internal
        view
    {
        // Calculate uncollected fees for the position
        (uint256 fee0, uint256 fee1) = _feePosition(
            FeeParams({
                token0: posData.token0,
                token1: posData.token1,
                fee: posData.fee,
                tickLower: posData.tickLower,
                tickUpper: posData.tickUpper,
                liquidity: posData.liquidity,
                positionFeeGrowthInside0LastX128: posData.feeGrowthInside0LastX128,
                positionFeeGrowthInside1LastX128: posData.feeGrowthInside1LastX128,
                tokensOwed0: posData.tokensOwed0,
                tokensOwed1: posData.tokensOwed1
            }),
            tickCurrent
        );

        // For fees, subtract the protocol fee cut before adding to position value
        // Users get (100% - feeCutBasisPoint) of the fees
        position0.value += fee0.mulDiv(BASIS_POINT_SCALE - feeCutBasisPoint, BASIS_POINT_SCALE);
        position1.value += fee1.mulDiv(BASIS_POINT_SCALE - feeCutBasisPoint, BASIS_POINT_SCALE);
    }

    /**
     * @dev Internal function to execute operations via the validator module
     * @param op The operation to execute containing target, value, and calldata
     * @return result The return data from the operation
     */
    function call_(BaseOp memory op) internal returns (bytes memory result) {
        (bool success, bytes memory returnData) = op.target.call{value: op.value}(op.data);
        require(success, "UniV3LobsterVault: call failed");
        return returnData;
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

        fee0 = uint256(poolFeeGrowthInside0LastX128 - feeParams.positionFeeGrowthInside0LastX128).mulDiv(
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

    /**
     * @dev Process all Uniswap V3 positions owned by the vault for withdrawal
     * Iterates through each position, calculates withdrawal amounts, and executes operations
     * @param shares The number of shares being withdrawn (used for proportional calculations)
     * @param vars The withdrawal variables struct to accumulate totals
     */
    function _processPositions(uint256 shares, WithdrawVars memory vars) internal {
        // Get current pool state
        (uint160 sqrtPriceX96, int24 tickCurrent,,,,,) = pool.slot0();
        uint256 totalSupply = totalSupply();

        for (uint256 i = 0; i < vars.tokensCount; ++i) {
            uint256 tokenId = positionManager.tokenOfOwnerByIndex(address(this), i);
            _processSinglePosition(tokenId, shares, totalSupply, sqrtPriceX96, tickCurrent, vars);
        }
    }

    /**
     * @dev Process a single position for withdrawal
     * @param tokenId The NFT token ID of the position
     * @param shares The number of shares being withdrawn
     * @param totalSupplyValue Total supply value
     * @param sqrtPriceX96 Current pool price
     * @param tickCurrent Current pool tick
     * @param vars The withdrawal variables struct to accumulate totals
     */
    function _processSinglePosition(
        uint256 tokenId,
        uint256 shares,
        uint256 totalSupplyValue,
        uint160 sqrtPriceX96,
        int24 tickCurrent,
        WithdrawVars memory vars
    )
        internal
    {
        PositionVars memory posVars;
        posVars.tokenId = tokenId;

        // Get position details in isolated scope
        {
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
            ) = positionManager.positions(tokenId);
        }

        // Skip if not in our pool
        if (!_isPositionInPool(posVars.token0, posVars.token1, posVars.fee)) {
            return;
        }

        // Calculate position values in separate scope
        {
            (posVars.position0, posVars.position1) =
                _principalPosition(sqrtPriceX96, posVars.tickLower, posVars.tickUpper, posVars.liquidity);
        }

        // Calculate fees in separate scope
        uint256 fee0;
        uint256 fee1;
        {
            (fee0, fee1) = _feePosition(
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
        }

        // Calculate withdrawal amounts and update totals
        posVars.toWithdraw0 = posVars.position0.mulDiv(shares, totalSupplyValue);
        posVars.toWithdraw1 = posVars.position1.mulDiv(shares, totalSupplyValue);

        vars.allCollectedFee0 += fee0;
        vars.allCollectedFee1 += fee1;
        vars.totalWithdrawnFromPosition0 += posVars.toWithdraw0;
        vars.totalWithdrawnFromPosition1 += posVars.toWithdraw1;

        // Store fees for execution
        posVars.fee0 = fee0;
        posVars.fee1 = fee1;

        // Execute withdrawal
        _executePositionWithdrawal(posVars);
    }

    /**
     * @notice Collects all pending fees from the vault's Uniswap V3 positions
     * Iterates through all positions, collects fees, and transfers them to the fee collector
     * @return totalFee0 Total fees collected in token0
     * @return totalFee1 Total fees collected in token1
     */
    function collectPendingFees() external onlyOwner returns (uint256 totalFee0, uint256 totalFee1) {
        if (feeCutBasisPoint == 0) {
            emit FeesCollected(totalFee0, totalFee1);
            return (totalFee0, totalFee1);
        }

        // Collect fees from all positions
        uint256 balance = positionManager.balanceOf(address(this));
        for (uint256 i = 0; i < balance; i++) {
            uint256 tokenId = positionManager.tokenOfOwnerByIndex(address(this), i);
            PositionData memory posData = _getPositionData(tokenId);

            if (_isPositionInPool(posData.token0, posData.token1, posData.fee)) {
                // fees to collect
                (uint256 fee0, uint256 fee1) = PositionValue.fees(positionManager, tokenId);

                // Collect fees for this position
                INonFungiblePositionManager.CollectParams memory params = INonFungiblePositionManager.CollectParams({
                    recipient: address(this),
                    tokenId: tokenId,
                    amount0Max: uint128(fee0),
                    amount1Max: uint128(fee1)
                });

                BaseOp memory collectOp = BaseOp({
                    target: address(positionManager),
                    value: 0,
                    data: abi.encodeCall(positionManager.collect, (params))
                });

                call_(collectOp);

                totalFee0 += fee0;
                totalFee1 += fee1;
            }
        }

        totalFee0 = totalFee0.mulDiv(feeCutBasisPoint, BASIS_POINT_SCALE);
        totalFee1 = totalFee1.mulDiv(feeCutBasisPoint, BASIS_POINT_SCALE);

        // Transfer collected fees to the fee collector
        if (totalFee0 > 0) {
            SafeERC20.safeTransfer(asset0, feeCollector, totalFee0);
        }
        if (totalFee1 > 0) {
            SafeERC20.safeTransfer(asset1, feeCollector, totalFee1);
        }
        emit FeesCollected(totalFee0, totalFee1);
    }

    /**
     * @notice Sets the fee collector address
     * Can only be called by the owner of the vault
     * @param feeCollector_ The new fee collector address
     */
    function setFeeCollector(address feeCollector_) external onlyOwner {
        require(feeCollector_ != address(0), ZeroAddress());
        feeCollector = feeCollector_;
        emit FeeCollectorUpdated(feeCollector_);
    }
}
