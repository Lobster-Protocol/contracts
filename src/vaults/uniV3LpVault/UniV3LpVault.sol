// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.28;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {SingleVault} from "../SingleVault.sol";
import {IUniswapV3PoolMinimal} from "../../interfaces/uniswapV3/IUniswapV3PoolMinimal.sol";
import {LiquidityAmounts} from "../../libraries/uniswapV3/LiquidityAmounts.sol";
import {TickMath} from "../../libraries/uniswapV3/TickMath.sol";
import {FeeParams} from "../../libraries/uniswapV3/PositionValue.sol";
import {PositionKey} from "../../libraries/uniswapV3/PositionKey.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MintCallbackData} from "../../interfaces/uniswapV3/IUniswapV3MintCallback.sol";
import {PoolAddress} from "../../libraries/uniswapV3/PoolAddress.sol";
import {UniswapV3Calculator} from "../../utils/UniswapV3Calculator.sol";
import {UniswapUtils} from "../../libraries/uniswapV3/UniswapUtils.sol";
import {SCALING_FACTOR, TWAP_SECONDS_AGO, MAX_SCALED_PERCENTAGE, MIN_OBSERVATION_CARDINALITY} from "./constants.sol";
import {WithdrawParams, MinimalMintParams, Position} from "./structs.sol";
import {UniV3LpVaultVariables} from "./UniV3LpVaultVariables.sol";

/**
 * @title UniV3LpVault
 * @author Elli <nathan@lobster-protocol.com>
 * @notice A vault for managing liquidity provision on Uniswap V3 pools with fee collection
 * @dev Manages multiple liquidity positions, collects trading fees, and charges management/performance fees
 * @dev Requires the pool to have existed for at least TWAP_SECONDS_AGO with swap activity for accurate pricing
 * @dev This contract is designed to be deployed as a proxy via factory using OpenZeppelin's proxy pattern
 */
contract UniV3LpVault is Initializable, UniV3LpVaultVariables, UniswapV3Calculator {
    using Math for uint256;

    // ========== CONSTRUCTOR ==========

    /**
     * @notice Constructor for the implementation contract
     * @dev Disables initializers to prevent the implementation contract from being initialized
     *      This is the standard OpenZeppelin pattern for upgradeable contracts
     */
    constructor() SingleVault(address(0xdead), address(0xdead)) {
        _disableInitializers();
    }

    // ========== INITIALIZER ==========

    /**
     * @notice Initializes the UniswapV3 LP vault proxy
     * @dev Can only be called once per proxy. Validates all parameters and sets initial state.
     * @param initialOwner Address that will own the vault
     * @param initialAllocator Address that can execute vault strategies
     * @param token0 Address of the first token (must be < token1 address)
     * @param token1 Address of the second token (must be > token0 address)
     * @param pool Address of the UniswapV3 pool
     * @param protocolAddress used to collect the protocol fee (can be address(0) if protocolFee = 0)
     * @param protocolFee represents a cut from the fees sent to the feeCollector (tvl & performance)
     * @param initialFeeCollector Address authorized to collect fees
     * @param initialtvlFee Initial annualized TVL management fee (scaled)
     * @param initialPerformanceFee Initial performance fee on profits (scaled)
     * @param delta Token ratio weight for performance fee calculation (0 to 1e18)
     */
    function initialize(
        address initialOwner,
        address initialAllocator,
        address token0,
        address token1,
        address pool,
        address initialFeeCollector,
        address protocolAddress,
        uint256 protocolFee,
        uint256 initialtvlFee,
        uint256 initialPerformanceFee,
        uint256 delta
    )
        external
        initializer
    {
        // Validate parameters
        require(uint160(token0) < uint160(token1), "Wrong token 0 & 1 order");
        require(initialOwner != address(0), ZeroAddress());
        require(initialAllocator != address(0), ZeroAddress());
        require(initialFeeCollector != address(0), ZeroAddress());
        require(delta <= SCALING_FACTOR && protocolFee <= MAX_SCALED_PERCENTAGE, InvalidValue());
        require((protocolFee != 0 && protocolAddress != address(0)) || protocolFee == 0, "Invalid protocol fee");
        require(initialPerformanceFee <= MAX_FEE && initialtvlFee <= MAX_FEE, "Fees > max");

        // Initialize ownership (from Ownable)
        _transferOwnership(initialOwner);

        // Initialize allocator
        allocator = initialAllocator;

        // Initialize pool and tokens
        POOL = IUniswapV3PoolMinimal(pool);
        require(POOL.token0() == token0 && POOL.token1() == token1, "Token mismatch");
        (,,, uint16 observationCardinality,,,) = POOL.slot0();
        require(MIN_OBSERVATION_CARDINALITY >= observationCardinality, "Not enough cardinality");

        TOKEN0 = IERC20(token0);
        TOKEN1 = IERC20(token1);
        POOL_FEE = POOL.fee();

        // Initialize fee parameters
        DELTA = delta;
        feeCollector = initialFeeCollector;
        tvlFeeScaled = initialtvlFee;
        tvlFeeCollectedAt = block.timestamp;
        performanceFeeScaled = initialPerformanceFee;
    }

    // ========== OWNER FUNCTIONS ==========

    /**
     * @notice Deposits tokens into the vault
     * @dev Collects any pending fees before depositing and updates vault TVL
     * @param assets0 Amount of token0 to deposit
     * @param assets1 Amount of token1 to deposit
     */
    function deposit(uint256 assets0, uint256 assets1) external onlyOwner {
        if (assets0 == 0 && assets1 == 0) revert ZeroValue();

        _collectFees();

        // Execute the deposit
        if (assets0 > 0) {
            SafeERC20.safeTransferFrom(TOKEN0, msg.sender, address(this), assets0);
        }
        if (assets1 > 0) {
            SafeERC20.safeTransferFrom(TOKEN1, msg.sender, address(this), assets1);
        }

        emit Deposit(assets0, assets1);

        // Always update vault tvl in token0
        (lastVaultTvl0, lastQuoteScaled) = _getNewVaultTvl0();
    }

    /**
     * @notice Withdraws a percentage of vault assets
     * @dev Automatically collects pending fees before withdrawal
     * @param scaledPercentage Percentage to withdraw (scaled by SCALING_FACTOR, e.g., 50e18 = 50%)
     * @param recipient Address to receive the withdrawn tokens
     * @return amount0 Amount of token0 withdrawn
     * @return amount1 Amount of token1 withdrawn
     */
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

        (uint256 performanceFeeScaledPercent, uint256 newTvlInToken0) = _pendingRelativePerformanceFeeAndNewTvl();

        (amount0, amount1) = _withdraw(
            WithdrawParams({
                userScaledPercent: scaledPercentage,
                tvlFeeScaledPercent: _pendingRelativeTvlFee(),
                performanceFeeScaledPercent: performanceFeeScaledPercent,
                newTvlInToken0: newTvlInToken0.mulDiv(
                    MAX_SCALED_PERCENTAGE - performanceFeeScaledPercent, MAX_SCALED_PERCENTAGE
                ),
                recipient: recipient
            })
        );
    }

    // ========== EXECUTOR FUNCTIONS ==========

    /**
     * @notice Mints a new liquidity position in the UniswapV3 pool
     * @dev Can be called by owner or allocator when vault is not locked
     * @param params Minting parameters including tick range and amounts
     * @return amount0 Actual amount of token0 added to position
     * @return amount1 Actual amount of token1 added to position
     */
    function mint(MinimalMintParams calldata params)
        external
        onlyOwnerOrAllocator
        whenNotLocked
        returns (uint256 amount0, uint256 amount1)
    {
        return _mint(params);
    }

    /**
     * @notice Burns liquidity from an existing position
     * @dev Can be called by owner or allocator when vault is not locked
     * @param tickLower Lower tick boundary of the position to burn
     * @param tickUpper Upper tick boundary of the position to burn
     * @param amount Amount of liquidity to burn
     * @return amount0 Amount of token0 removed from position
     * @return amount1 Amount of token1 removed from position
     */
    function burn(
        int24 tickLower,
        int24 tickUpper,
        uint128 amount
    )
        external
        onlyOwnerOrAllocator
        whenNotLocked
        returns (uint256 amount0, uint256 amount1)
    {
        return _burn(tickLower, tickUpper, amount);
    }

    /**
     * @notice Collects accumulated trading fees from a position
     * @dev Can be called by owner or allocator when vault is not locked
     * @param tickLower Lower tick boundary of the position
     * @param tickUpper Upper tick boundary of the position
     * @param amount0Requested Maximum amount of token0 to collect
     * @param amount1Requested Maximum amount of token1 to collect
     * @return amount0 Actual amount of token0 collected
     * @return amount1 Actual amount of token1 collected
     */
    function collect(
        int24 tickLower,
        int24 tickUpper,
        uint128 amount0Requested,
        uint128 amount1Requested
    )
        external
        onlyOwnerOrAllocator
        whenNotLocked
        returns (uint128 amount0, uint128 amount1)
    {
        return _collect(tickLower, tickUpper, amount0Requested, amount1Requested);
    }

    // ======== FEE COLLECTOR FUNCTIONS ========

    /**
     * @notice Allows fee collector to trigger collection of pending fees
     * @dev Collects both pending TVL management fees and performance fees if applicable
     */
    function collectPendingFees() external onlyFeeCollector {
        _collectFees();
    }

    // ========== CALLBACK FUNCTIONS ==========

    /**
     * @notice Callback function called by UniswapV3 pool during liquidity minting
     * @dev Verifies caller is the pool and transfers required tokens
     * @param amount0Owed Amount of token0 owed to the pool
     * @param amount1Owed Amount of token1 owed to the pool
     * @param data Encoded callback data containing pool key and payer info
     */
    function uniswapV3MintCallback(uint256 amount0Owed, uint256 amount1Owed, bytes calldata data) external {
        MintCallbackData memory decoded = abi.decode(data, (MintCallbackData));

        if (msg.sender != address(POOL)) revert NotPool();
        // Payer must alway be this vault
        if (decoded.payer != address(this)) revert WrongPayer();

        _safeTransferBoth(msg.sender, amount0Owed, amount1Owed);
    }

    // ========== VIEW FUNCTIONS ==========

    /**
     * @notice Returns total value locked in LP positions
     * @return totalAssets0 Total token0 in LP positions (principal + uncollected fees)
     * @return totalAssets1 Total token1 in LP positions (principal + uncollected fees)
     */
    function totalLpValue() external view returns (uint256 totalAssets0, uint256 totalAssets1) {
        (uint160 sqrtPriceX96, int24 tickCurrent,,,,,) = POOL.slot0();

        return _totalLpValue(sqrtPriceX96, tickCurrent);
    }

    /**
     * @notice Returns net asset value after deducting pending fees
     * @dev This represents the actual value owned by the vault users
     * @return totalAssets0 Net amount of token0 (after fees)
     * @return totalAssets1 Net amount of token1 (after fees)
     */
    function netAssetsValue() external view returns (uint256 totalAssets0, uint256 totalAssets1) {
        (totalAssets0, totalAssets1) = _rawAssetsValue();

        (uint256 pendingRelativePerfFee,) = _pendingRelativePerformanceFeeAndNewTvl();

        // Apply TVL fee deduction
        uint256 tokensLeft = _pendingRelativeTvlFee() + pendingRelativePerfFee > MAX_SCALED_PERCENTAGE
            ? MAX_SCALED_PERCENTAGE
            : MAX_SCALED_PERCENTAGE - _pendingRelativeTvlFee() - pendingRelativePerfFee;

        totalAssets0 = totalAssets0.mulDiv(tokensLeft, MAX_SCALED_PERCENTAGE);
        totalAssets1 = totalAssets1.mulDiv(tokensLeft, MAX_SCALED_PERCENTAGE);

        return (totalAssets0, totalAssets1);
    }

    /**
     * @notice Returns total vault assets before fee deductions
     * @dev Includes LP positions, uncollected fees, and free balances
     * @return totalAssets0 Total token0 assets
     * @return totalAssets1 Total token1 assets
     */
    function rawAssetsValue() external view returns (uint256 totalAssets0, uint256 totalAssets1) {
        return _rawAssetsValue();
    }

    /**
     * @notice Calculates pending TVL management fees
     * @dev Fees accrue continuously based on time elapsed since last collection
     * @dev This function assumes the vault has always owned the current assets value since last tvl collection
     * @return amount0 Pending TVL fee in token0
     * @return amount1 Pending TVL fee in token1
     */
    function pendingTvlFee() external view returns (uint256 amount0, uint256 amount1) {
        (uint256 nav0, uint256 nav1) = _rawAssetsValue();
        return _pendingTvlFee(nav0, nav1);
    }

    /**
     * @notice Calculates pending performance fees
     * @dev Only charged when vault TVL increases
     * @return amount0 Pending performance fee in token0
     * @return amount1 Pending performance fee in token1
     */
    function pendingPerformanceFee() external view returns (uint256 amount0, uint256 amount1) {
        if (performanceFeeScaled == 0) return (0, 0);

        (uint256 perfFeePercent,) = _pendingRelativePerformanceFeeAndNewTvl();

        (amount0, amount1) = _rawAssetsValue();

        amount0 = amount0.mulDiv(perfFeePercent, MAX_SCALED_PERCENTAGE);
        amount1 = amount1.mulDiv(perfFeePercent, MAX_SCALED_PERCENTAGE);
    }

    /**
     * @notice Returns details of a specific position
     * @param index Index of the position in the positions array
     * @return Position struct containing tick range and liquidity
     */
    function getPosition(uint256 index) external view returns (Position memory) {
        return positions[index];
    }

    /**
     * @notice Returns the number of active positions
     * @return Number of positions in the vault
     */
    function positionsLength() external view returns (uint256) {
        return positions.length;
    }

    /**
     * @notice Returns pending fee update details
     * @return tvlFee Pending TVL fee percentage
     * @return perfFee Pending performance fee percentage
     * @return activatableAfter Timestamp after which update can be enforced
     */
    function pendingFeeUpdate() external view returns (uint80 tvlFee, uint80 perfFee, uint96 activatableAfter) {
        return _unpackFeesWithTimestamp(packedPendingFees);
    }

    // ========== INTERNAL FUNCTIONS ==========

    /**
     * @notice Internal function to collect both TVL and performance fees
     * @dev Updates tvlFeeCollectedAt timestamp and lastVaultTvl0 if fees were collected
     */
    function _collectFees() internal {
        uint256 tvlToCollect = _pendingRelativeTvlFee();

        (uint256 performanceFeeToCollect, uint256 newTvlInToken0) = _pendingRelativePerformanceFeeAndNewTvl();

        if (tvlToCollect == 0 && performanceFeeToCollect == 0) {
            tvlFeeCollectedAt = block.timestamp;
            return;
        }

        WithdrawParams memory withdrawParams = WithdrawParams({
            userScaledPercent: 0,
            tvlFeeScaledPercent: tvlToCollect,
            performanceFeeScaledPercent: performanceFeeToCollect,
            newTvlInToken0: newTvlInToken0,
            recipient: address(0) // Ok since userScaledPercent = 0
        });

        _withdraw(withdrawParams);
    }

    /**
     * @notice Internal function to execute withdrawals and fee collections
     * @dev Handles burning liquidity, collecting fees, and distributing tokens
     *      The function follows this sequence:
     *      1. Collects all uncollected fees from positions
     *      2. Calculates fee percentages (TVL + performance, capped at 100%)
     *      3. Adjusts user percentage to account for fees
     *      4. Burns liquidity proportionally from all positions
     *      5. Distributes tokens to fee collector and user based on calculated percentages
     *      6. Updates lastVaultTvl0 if performance fees were collected
     * @param withdrawParams Struct containing all withdrawal parameters
     * @return amount0 Amount of token0 withdrawn for the user
     * @return amount1 Amount of token1 withdrawn for the user
     */
    function _withdraw(WithdrawParams memory withdrawParams) internal returns (uint256 amount0, uint256 amount1) {
        if (withdrawParams.userScaledPercent > MAX_SCALED_PERCENTAGE) {
            revert InvalidScalingFactor();
        }

        // Collect for all positions
        uint256 posLen = positions.length;
        for (uint256 i = 0; i < posLen; i++) {
            Position storage position = positions[i];

            _collect(
                position.lowerTick,
                position.upperTick,
                type(uint128).max, // collect all amount0
                type(uint128).max // collect all amount1
            );
        }

        uint256 userScaledPercent = withdrawParams.userScaledPercent;
        uint256 tvlFeeScaledPercent = withdrawParams.tvlFeeScaledPercent;
        uint256 performanceFeeScaledPercent = withdrawParams.performanceFeeScaledPercent;

        // Cap total fees at 100% to prevent overflow
        if (tvlFeeScaledPercent + performanceFeeScaledPercent > MAX_SCALED_PERCENTAGE) {
            performanceFeeScaledPercent = 0;
            tvlFeeScaledPercent = MAX_SCALED_PERCENTAGE;
        }

        // Calculate user's share after fees: user% * (100% - fees%)
        userScaledPercent = (MAX_SCALED_PERCENTAGE - tvlFeeScaledPercent - performanceFeeScaledPercent)
        .mulDiv(userScaledPercent, MAX_SCALED_PERCENTAGE);

        uint256 totalToWithdrawScaledPercent = userScaledPercent + tvlFeeScaledPercent + performanceFeeScaledPercent;

        uint256 initialToken0Balance = TOKEN0.balanceOf(address(this));
        uint256 initialToken1Balance = TOKEN1.balanceOf(address(this));

        (uint256 withdrawn0, uint256 withdrawn1) = _withdrawFromPositions(totalToWithdrawScaledPercent);

        // Extract the fees
        uint256 protocolFee0 = 0;
        uint256 protocolFee1 = 0;

        // TVL
        if (tvlFeeScaledPercent > 0) {
            // Calculate TVL fee from withdrawn amounts
            uint256 tvlFeeFromWithdrawn0 = totalToWithdrawScaledPercent > 0
                ? withdrawn0.mulDiv(tvlFeeScaledPercent, totalToWithdrawScaledPercent)
                : 0;
            uint256 tvlFeeFromWithdrawn1 = totalToWithdrawScaledPercent > 0
                ? withdrawn1.mulDiv(tvlFeeScaledPercent, totalToWithdrawScaledPercent)
                : 0;

            // Add TVL fee from free balance
            uint256 fullTvlFeeAssets0 =
                initialToken0Balance.mulDiv(tvlFeeScaledPercent, MAX_SCALED_PERCENTAGE) + tvlFeeFromWithdrawn0;
            uint256 fullTvlFeeAssets1 =
                initialToken1Balance.mulDiv(tvlFeeScaledPercent, MAX_SCALED_PERCENTAGE) + tvlFeeFromWithdrawn1;

            uint256 tvlFeeAssets0 =
                fullTvlFeeAssets0.mulDiv(MAX_SCALED_PERCENTAGE - PROTOCOL_FEE, MAX_SCALED_PERCENTAGE);
            uint256 tvlFeeAssets1 =
                fullTvlFeeAssets1.mulDiv(MAX_SCALED_PERCENTAGE - PROTOCOL_FEE, MAX_SCALED_PERCENTAGE);

            protocolFee0 += fullTvlFeeAssets0.mulDiv(PROTOCOL_FEE, MAX_SCALED_PERCENTAGE);
            protocolFee1 += fullTvlFeeAssets1.mulDiv(PROTOCOL_FEE, MAX_SCALED_PERCENTAGE);

            _safeTransferBoth(feeCollector, tvlFeeAssets0, tvlFeeAssets1);

            emit TvlFeeCollected(tvlFeeAssets0, tvlFeeAssets1, feeCollector);

            tvlFeeCollectedAt = block.timestamp;
        }
        // Performance
        if (performanceFeeScaledPercent > 0) {
            // Calculate performance fee from withdrawn amounts
            uint256 perfFeeFromWithdrawn0 = totalToWithdrawScaledPercent > 0
                ? withdrawn0.mulDiv(performanceFeeScaledPercent, totalToWithdrawScaledPercent)
                : 0;
            uint256 perfFeeFromWithdrawn1 = totalToWithdrawScaledPercent > 0
                ? withdrawn1.mulDiv(performanceFeeScaledPercent, totalToWithdrawScaledPercent)
                : 0;

            // Add performance fee from free balance
            uint256 fullPerfFeeAssets0 =
                initialToken0Balance.mulDiv(performanceFeeScaledPercent, MAX_SCALED_PERCENTAGE) + perfFeeFromWithdrawn0;
            uint256 fullPerfFeeAssets1 =
                initialToken1Balance.mulDiv(performanceFeeScaledPercent, MAX_SCALED_PERCENTAGE) + perfFeeFromWithdrawn1;

            uint256 perfFeeAssets0 =
                fullPerfFeeAssets0.mulDiv(MAX_SCALED_PERCENTAGE - PROTOCOL_FEE, MAX_SCALED_PERCENTAGE);
            uint256 perfFeeAssets1 =
                fullPerfFeeAssets1.mulDiv(MAX_SCALED_PERCENTAGE - PROTOCOL_FEE, MAX_SCALED_PERCENTAGE);

            protocolFee0 += fullPerfFeeAssets0.mulDiv(PROTOCOL_FEE, MAX_SCALED_PERCENTAGE);
            protocolFee1 += fullPerfFeeAssets1.mulDiv(PROTOCOL_FEE, MAX_SCALED_PERCENTAGE);

            _safeTransferBoth(feeCollector, perfFeeAssets0, perfFeeAssets1);

            emit PerformanceFeeCollected(perfFeeAssets0, perfFeeAssets1, feeCollector);
        }

        // Collect protocol fee
        if (protocolFee0 > 0 || protocolFee1 > 0) {
            _safeTransferBoth(PROTOCOL_ADDR, protocolFee0, protocolFee1);

            emit ProtocolFeeCollected(protocolFee0, protocolFee1, PROTOCOL_ADDR);
        }

        // User Withdraw
        // Calculate user's share from withdrawn amounts
        uint256 fromWithdrawn0 =
            totalToWithdrawScaledPercent > 0 ? withdrawn0.mulDiv(userScaledPercent, totalToWithdrawScaledPercent) : 0;
        uint256 fromWithdrawn1 =
            totalToWithdrawScaledPercent > 0 ? withdrawn1.mulDiv(userScaledPercent, totalToWithdrawScaledPercent) : 0;

        // Add user's share from free balance
        uint256 assets0ToWithdrawForUser =
            initialToken0Balance.mulDiv(userScaledPercent, MAX_SCALED_PERCENTAGE) + fromWithdrawn0;

        uint256 assets1ToWithdrawForUser =
            initialToken1Balance.mulDiv(userScaledPercent, MAX_SCALED_PERCENTAGE) + fromWithdrawn1;

        // Execute user withdraw
        _safeTransferBoth(withdrawParams.recipient, assets0ToWithdrawForUser, assets1ToWithdrawForUser);

        if (assets0ToWithdrawForUser > 0 || assets1ToWithdrawForUser > 0) {
            emit Withdraw(assets0ToWithdrawForUser, assets1ToWithdrawForUser, withdrawParams.recipient);
        }

        // If needed, update the lastVaultTvl0
        if (performanceFeeScaledPercent > 0) {
            (lastVaultTvl0, lastQuoteScaled) = _getNewVaultTvl0();
        }

        return (assets0ToWithdrawForUser, assets1ToWithdrawForUser);
    }

    /**
     * @notice Burns liquidity from all positions proportionally
     * @dev Creates a snapshot of positions array to safely iterate while modifying the actual positions
     *      Burns the specified percentage from each position and accumulates withdrawn amounts
     * @param scaledPercentage Percentage of liquidity to burn from each position (scaled by SCALING_FACTOR)
     * @return withdrawn0 Total token0 withdrawn from all positions
     * @return withdrawn1 Total token1 withdrawn from all positions
     */
    function _withdrawFromPositions(uint256 scaledPercentage) private returns (uint256 withdrawn0, uint256 withdrawn1) {
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
                _burn(position.lowerTick, position.upperTick, liquidityToWithdraw);

            withdrawn0 += amount0Burnt;
            withdrawn1 += amount1Burnt;
        }
    }

    /**
     * @notice Internal function to mint liquidity to the pool
     * @dev Creates or adds to existing position, includes deadline check
     *      The function:
     *      1. Calculates required liquidity based on desired amounts and current price
     *      2. Calls the Uniswap V3 pool's mint function
     *      3. Verifies slippage constraints (amount0Min, amount1Min)
     *      4. Updates or creates position record in the positions array
     * @param params Minting parameters
     * @return amount0 Amount of token0 actually added
     * @return amount1 Amount of token1 actually added
     */
    function _mint(MinimalMintParams calldata params)
        internal
        checkDeadline(params.deadline)
        returns (uint256 amount0, uint256 amount1)
    {
        // Compute the liquidity amount
        uint128 liquidity;
        {
            (uint160 sqrtPriceX96,,,,,,) = POOL.slot0();
            uint160 sqrtRatioAX96 = TickMath.getSqrtRatioAtTick(params.tickLower);
            uint160 sqrtRatioBX96 = TickMath.getSqrtRatioAtTick(params.tickUpper);

            liquidity = LiquidityAmounts.getLiquidityForAmounts(
                sqrtPriceX96, sqrtRatioAX96, sqrtRatioBX96, params.amount0Desired, params.amount1Desired
            );
        }

        PoolAddress.PoolKey memory poolKey =
            PoolAddress.PoolKey({token0: address(TOKEN0), token1: address(TOKEN1), fee: POOL_FEE});

        (amount0, amount1) = POOL.mint(
            address(this),
            params.tickLower,
            params.tickUpper,
            liquidity,
            abi.encode(MintCallbackData({poolKey: poolKey, payer: address(this)}))
        );

        require(amount0 >= params.amount0Min && amount1 >= params.amount1Min, "Price slippage check");

        Position memory newPosition =
            Position({upperTick: params.tickUpper, lowerTick: params.tickLower, liquidity: liquidity});

        // Check if position already exists, if so add liquidity, otherwise create new position
        bool isPositionCreation = true;
        uint256 posLen = positions.length;
        for (uint256 i = 0; i < posLen; i++) {
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

    /**
     * @notice Internal function to burn liquidity from the pool
     * @dev Automatically collects tokens and updates position records
     *      The function:
     *      1. Burns the specified liquidity amount from the pool
     *      2. Automatically collects the resulting tokens (principal + fees)
     *      3. Updates the positions array (removes if fully burned, decreases liquidity otherwise)
     * @param tickLower Lower tick boundary
     * @param tickUpper Upper tick boundary
     * @param amount Amount of liquidity to burn
     * @return amount0 Amount of token0 removed
     * @return amount1 Amount of token1 removed
     */
    function _burn(
        int24 tickLower,
        int24 tickUpper,
        uint128 amount
    )
        internal
        returns (uint256 amount0, uint256 amount1)
    {
        // Burn the liquidity
        (amount0, amount1) = POOL.burn(tickLower, tickUpper, amount);

        // Automatically collect the tokens
        POOL.collect(
            address(this),
            tickLower,
            tickUpper,
            type(uint128).max, // collect all amount0
            type(uint128).max // collect all amount1
        );

        Position memory refPosition = Position({upperTick: tickUpper, lowerTick: tickLower, liquidity: 0});

        // Properly remove from array by swapping with last element
        uint256 posLen = positions.length;
        for (uint256 i = 0; i < posLen; i++) {
            Position memory position = positions[i];
            if (haveSameRange(position, refPosition)) {
                if (position.liquidity == amount) {
                    // Fully burned: swap with last element and pop
                    positions[i] = positions[posLen - 1];
                    positions.pop();
                } else {
                    // Partially burned: decrease liquidity
                    positions[i].liquidity -= amount;
                }
                break;
            }
        }
    }

    /**
     * @notice Internal function to collect fees from a position
     * @dev Calls the Uniswap V3 pool's collect function to retrieve accumulated trading fees
     * @param tickLower Lower tick boundary
     * @param tickUpper Upper tick boundary
     * @param amount0Requested Maximum token0 to collect
     * @param amount1Requested Maximum token1 to collect
     * @return amount0 Actual token0 collected
     * @return amount1 Actual token1 collected
     */
    function _collect(
        int24 tickLower,
        int24 tickUpper,
        uint128 amount0Requested,
        uint128 amount1Requested
    )
        internal
        returns (uint128 amount0, uint128 amount1)
    {
        return POOL.collect(address(this), tickLower, tickUpper, amount0Requested, amount1Requested);
    }

    // ========== INTERNAL VIEW FUNCTIONS ==========

    /**
     * @notice Calculates absolute amounts for pending TVL fees
     * @dev Applies the pending relative TVL fee percentage to the provided amounts
     * @param amount0 Total amount of token0 to calculate fee from
     * @param amount1 Total amount of token1 to calculate fee from
     * @return tvlFee0 TVL fee in token0
     * @return tvlFee1 TVL fee in token1
     */
    function _pendingTvlFee(
        uint256 amount0,
        uint256 amount1
    )
        internal
        view
        returns (uint256 tvlFee0, uint256 tvlFee1)
    {
        uint256 pendingRelativeTvlFee = _pendingRelativeTvlFee();

        return (
            amount0.mulDiv(pendingRelativeTvlFee, MAX_SCALED_PERCENTAGE),
            amount1.mulDiv(pendingRelativeTvlFee, MAX_SCALED_PERCENTAGE)
        );
    }

    /**
     * @notice Calculates pending TVL fee as a percentage
     * @dev Fees accrue linearly over time based on annualized rate
     *      Formula: fee = tvlFeeScaled * (timeElapsed / 365 days), capped at 100%
     * @return Pending TVL fee percentage (scaled by SCALING_FACTOR)
     */
    function _pendingRelativeTvlFee() internal view returns (uint256) {
        uint256 deltaT = block.timestamp - tvlFeeCollectedAt;

        return Math.min(tvlFeeScaled.mulDiv(deltaT, 365 days), MAX_SCALED_PERCENTAGE);
    }

    /**
     * @notice Calculates pending performance fee and updated TVL
     * @dev Only charges fee on positive performance (TVL growth)
     *      Performance is calculated using a delta-weighted formula that accounts for relative price changes:
     *      baseTvl0 = lastVaultTvl0 * (delta * (lastQuote / currentQuote)^2 + (1 - delta))
     *      If newTvl0 > baseTvl0, performance fee = (newTvl0 - baseTvl0) * performanceFeeScaled / newTvl0
     * @return feePercent Performance fee as percentage of total assets (scaled)
     * @return newTvl0 Updated vault TVL in token0 (before deducting performance fee)
     */
    function _pendingRelativePerformanceFeeAndNewTvl() internal view returns (uint256 feePercent, uint256 newTvl0) {
        if (performanceFeeScaled == 0 || lastVaultTvl0 == 0) return (0, 0);

        uint256 quoteScaled;
        (newTvl0, quoteScaled) = _getNewVaultTvl0();

        // Calculate squared quotes for delta weighting
        uint256 lastQuoteSquared = lastQuoteScaled ** 2;
        uint256 currentQuoteSquared = quoteScaled ** 2;

        // Calculate delta-weighted component: delta * (lastQuote^2 / currentQuote^2)
        uint256 part1 = DELTA.mulDiv(lastQuoteSquared, currentQuoteSquared);

        // Calculate (1 - delta) component
        uint256 part2 = SCALING_FACTOR - DELTA;

        // Calculate baseline TVL adjusted for price changes
        uint256 baseTvl0 = lastVaultTvl0.mulDiv(part1 + part2, SCALING_FACTOR);

        // No performance fee if TVL hasn't grown
        if (newTvl0 <= baseTvl0) {
            return (0, 0);
        }

        // Calculate performance fee as percentage of current TVL
        uint256 relativePerfScaledPercent = (newTvl0 - baseTvl0).mulDiv(performanceFeeScaled, newTvl0);

        return (Math.min(relativePerfScaledPercent, MAX_SCALED_PERCENTAGE), newTvl0);
    }

    /**
     * @notice Converts token1 amount to equivalent token0 using TWAP
     * @dev Uses 7-day TWAP for price stability to prevent manipulation
     * @param amount1 Amount of token1 to convert
     * @return amount0 Equivalent amount in token0
     * @return quoteScaled The token1/token0 price quote (scaled by SCALING_FACTOR)
     */
    function _convertToToken0(uint256 amount1) internal view returns (uint256 amount0, uint256 quoteScaled) {
        quoteScaled = UniswapUtils.getTwap(
            POOL,
            TWAP_SECONDS_AGO,
            // forge-lint: disable-next-line(unsafe-typecast)
            uint128(SCALING_FACTOR),
            true
        );

        amount0 = quoteScaled.mulDiv(amount1, SCALING_FACTOR);
    }

    /**
     * @notice Calculates vault TVL denominated in token0
     * @dev Converts all assets to token0 using TWAP, excludes pending TVL fees
     *      This provides a unified measure of vault value for performance fee calculation
     * @return newVaultTvl0 Total vault value in token0 (after TVL fees, before performance fees)
     * @return quoteScaled The token1/token0 price quote used for conversion (scaled by SCALING_FACTOR)
     */
    function _getNewVaultTvl0() internal view returns (uint256 newVaultTvl0, uint256 quoteScaled) {
        (uint256 tvl0, uint256 tvl1) = _rawAssetsValue();

        // remove pending management fee
        if (tvlFeeScaled > 0) {
            (uint256 tvlFee0, uint256 tvlFee1) = _pendingTvlFee(tvl0, tvl1);
            tvl0 -= tvlFee0;
            tvl1 -= tvlFee1;
        }

        (newVaultTvl0, quoteScaled) = _convertToToken0(tvl1);
        newVaultTvl0 += tvl0;
    }

    /**
     * @notice Returns total vault assets without fee deductions
     * @dev Includes LP positions, uncollected fees, and free balances
     *      This is the gross asset value before any fee calculations
     * @return totalAssets0 Total token0 assets
     * @return totalAssets1 Total token1 assets
     */
    function _rawAssetsValue() internal view returns (uint256 totalAssets0, uint256 totalAssets1) {
        (uint160 sqrtPriceX96, int24 tickCurrent,,,,,) = POOL.slot0();

        (totalAssets0, totalAssets1) = _totalLpValue(sqrtPriceX96, tickCurrent);

        totalAssets0 += TOKEN0.balanceOf(address(this));
        totalAssets1 += TOKEN1.balanceOf(address(this));
    }

    /**
     * @notice Calculates total value in LP positions
     * @dev Aggregates principal amounts and uncollected fees across all positions
     * @param sqrtPriceX96 Current pool price in sqrt(token1/token0) * 2^96 format
     * @param currentTick Current pool tick
     * @return amount0 Total token0 in positions (principal + fees)
     * @return amount1 Total token1 in positions (principal + fees)
     */
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

    /**
     * @notice Calculates detailed LP state for all positions
     * @dev Iterates through all positions and calculates principal and uncollected fees separately
     *      Uses Uniswap V3 position data and internal calculation functions
     * @param sqrtPriceX96 Current pool price in sqrt(token1/token0) * 2^96 format
     * @param currentTick Current pool tick
     * @return assets0 Token0 principal across all positions
     * @return assets1 Token1 principal across all positions
     * @return uncollected0 Uncollected token0 fees across all positions
     * @return uncollected1 Uncollected token1 fees across all positions
     */
    function _totalLpState(
        uint160 sqrtPriceX96,
        int24 currentTick
    )
        private
        view
        returns (uint256 assets0, uint256 assets1, uint256 uncollected0, uint256 uncollected1)
    {
        uint256 posLen = positions.length;
        for (uint256 i = 0; i < posLen;) {
            Position memory position = positions[i];

            bytes32 positionKey = PositionKey.compute(address(this), position.lowerTick, position.upperTick);

            (
                uint128 liquidity,
                uint256 feeGrowthInside0LastX128,
                uint256 feeGrowthInside1LastX128,
                uint128 tokensOwed0,
                uint128 tokensOwed1
            ) = POOL.positions(positionKey);

            // Calculate principal amounts in position
            (uint256 positiontAssets0, uint256 positiontAssets1) =
                _principalPosition(sqrtPriceX96, position.lowerTick, position.upperTick, liquidity);

            // Calculate uncollected fees
            (uint256 uncollectedAssets0, uint256 uncollectedAssets1) = _feePosition(
                POOL,
                FeeParams({
                    token0: address(TOKEN0),
                    token1: address(TOKEN1),
                    fee: POOL_FEE,
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

            unchecked {
                assets0 += positiontAssets0;
                assets1 += positiontAssets1;
                uncollected0 += uncollectedAssets0;
                uncollected1 += uncollectedAssets1;
                ++i;
            }
        }
    }

    // ========== UTILITY FUNCTIONS ==========

    /**
     * @notice Checks if two positions have the same tick range
     * @param pos1 First position
     * @param pos2 Second position
     * @return true if tick ranges match, false otherwise
     */
    function haveSameRange(Position memory pos1, Position memory pos2) internal pure returns (bool) {
        if (pos1.lowerTick == pos2.lowerTick && pos1.upperTick == pos2.upperTick) return true;
        return false;
    }

    /**
     * @notice Safely transfers both tokens if amounts are non-zero
     * @dev Uses SafeERC20 to handle various token implementations safely
     * @param to Recipient address
     * @param amount0 Amount of token0 to transfer
     * @param amount1 Amount of token1 to transfer
     * @return transferred True if any transfer occurred
     */
    function _safeTransferBoth(address to, uint256 amount0, uint256 amount1) internal returns (bool transferred) {
        if (amount0 > 0) {
            SafeERC20.safeTransfer(TOKEN0, to, amount0);
            transferred = true;
        }
        if (amount1 > 0) {
            SafeERC20.safeTransfer(TOKEN1, to, amount1);
            transferred = true;
        }
    }

    /**
     * @notice Packs fee values and timestamp into a single uint256
     * @dev Format: [80 bits tvlFee][80 bits perfFee][96 bits timestamp]
     * @param tvlFee TVL fee percentage (scaled)
     * @param perfFee Performance fee percentage (scaled)
     * @param timestamp Activation timestamp
     * @return packed Encoded value
     */
    function _packFeesWithTimestamp(
        uint80 tvlFee,
        uint80 perfFee,
        uint96 timestamp
    )
        internal
        pure
        returns (uint256 packed)
    {
        packed = (uint256(tvlFee) << 176) | (uint256(perfFee) << 96) | uint256(timestamp);
    }

    /**
     * @notice Unpacks fee values and timestamp from uint256
     * @dev Reverses the packing done by _packFeesWithTimestamp
     * @param packed Encoded value
     * @return tvlFee TVL fee percentage
     * @return perfFee Performance fee percentage
     * @return timestamp Activation timestamp
     */
    function _unpackFeesWithTimestamp(uint256 packed)
        internal
        pure
        returns (uint80 tvlFee, uint80 perfFee, uint96 timestamp)
    {
        tvlFee = uint80((packed >> 176) & 0xFFFFFFFFFFFFFFFFFFFF); // Mask to get 80 bits
        perfFee = uint80((packed >> 96) & 0xFFFFFFFFFFFFFFFFFFFF); // Mask to get 80 bits
        // forge-lint: disable-next-line(unsafe-typecast)
        timestamp = uint96(packed & 0xFFFFFFFFFFFFFFFFFFFFFFFF); // Mask to get 96 bits
    }

    // ========== FEE UPDATE FUNCTIONS ==========

    /**
     * @notice Initiates a fee update with a timelock
     * @dev Fees cannot exceed MAX_FEE and require FEE_UPDATE_MIN_DELAY before enforcement
     *      This two-step process protects users from sudden fee changes
     * @param newTvlFee New TVL management fee (scaled by SCALING_FACTOR)
     * @param newPerformanceFee New performance fee (scaled by SCALING_FACTOR)
     * @return true if update was successfully initiated
     */
    function updateFees(uint80 newTvlFee, uint80 newPerformanceFee) external onlyFeeCollector returns (bool) {
        require(newTvlFee <= MAX_FEE && newPerformanceFee <= MAX_FEE, "Fees > max");

        uint96 timestamp = uint96(block.timestamp) + FEE_UPDATE_MIN_DELAY;

        packedPendingFees = _packFeesWithTimestamp(newTvlFee, newPerformanceFee, timestamp);

        emit FeeUpdateInitialized(newTvlFee, newPerformanceFee, timestamp);

        return true;
    }

    /**
     * @notice Enforces a pending fee update after timelock expires
     * @dev Collects all pending fees before applying new rates to ensure clean transition
     *      Clears the pending fee update after enforcement
     * @return newTvlFee The newly activated TVL fee
     * @return newPerformanceFee The newly activated performance fee
     */
    function enforceFeeUpdate() external onlyFeeCollector returns (uint80 newTvlFee, uint80 newPerformanceFee) {
        uint256 pendingFees = packedPendingFees;
        if (pendingFees == 0) revert NoPendingFeeUpdate();

        uint96 timestamp;
        (newTvlFee, newPerformanceFee, timestamp) = _unpackFeesWithTimestamp(pendingFees);

        if (timestamp > block.timestamp) revert Unauthorized();

        // Collect pending fees before changing rates
        _collectFees();

        tvlFeeScaled = newTvlFee;
        performanceFeeScaled = newPerformanceFee;

        emit FeeUpdateEnforced(newTvlFee, newPerformanceFee);

        packedPendingFees = 0;
    }
}
