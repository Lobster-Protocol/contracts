// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {IUniswapV3PoolMinimal} from "../../interfaces/uniswapV3/IUniswapV3PoolMinimal.sol";
import {Position} from "./structs.sol";
import {MAX_FEE_SCALED} from "./constants.sol";
import {SingleVault} from "../SingleVault.sol";

abstract contract UniV3LpVaultVariables is SingleVault {
    // ========== STATE VARIABLES ==========

    /// @notice Minimum delay before fee updates can be enforced (14 days timelock)
    uint96 public constant FEE_UPDATE_MIN_DELAY = 14 days;

    /**
     * @notice Token ratio weight for performance fee calculation (0 to 1e18)
     * @dev Controls how the performance fee accounts for relative token value changes:
     *              - delta = 0 -> performance fee based entirely on token0 accumulation relative to token1
     *              - delta = 1e18 -> performance fee based entirely on token1 accumulation relative to token0
     *              - delta = 0.5e18 -> equal weighting of both tokens (50% - 50% hold value)
     *
     *      Used in formula: baseTvl0 = lastVaultTvl0 * (delta * (lastQuote / currentQuote)^2 + (1 - delta))
     */
    uint256 public DELTA;

    /// @notice First token in the UniswapV3 pair (lower address)
    IERC20 public TOKEN0;

    /// @notice Second token in the UniswapV3 pair (higher address)
    IERC20 public TOKEN1;

    /// @notice The UniswapV3 pool where liquidity is provided
    IUniswapV3PoolMinimal public POOL;

    /// @notice Fee tier of the pool (e.g., 500 = 0.05%, 3000 = 0.3%)
    uint24 internal POOL_FEE;

    /// @notice Maximum allowed fee percentage (scaled by SCALING_FACTOR)
    uint256 public constant MAX_FEE = MAX_FEE_SCALED;

    /// @notice Protocol address which receives the protocol fees
    address immutable PROTOCOL_ADDR;

    /// @notice Protocol fee scaled by 1e18. Represent a fixed percentage of the fees collected by the feeCollector
    uint256 immutable PROTOCOL_FEE;

    /// @notice Timestamp of the last TVL fee collection
    uint256 public tvlFeeCollectedAt;

    /// @notice Annualized management fee as percentage of TVL (scaled by SCALING_FACTOR)
    uint256 public tvlFeeScaled;

    /// @notice Performance fee as percentage of profits (scaled by SCALING_FACTOR)
    uint256 public performanceFeeScaled;

    /// @notice Last recorded vault TVL denominated in token0 (used for performance fee calculation)
    uint256 public lastVaultTvl0;

    /**
     * @notice Last recorded token1/token0 price quote (scaled by SCALING_FACTOR)
     * @dev Used in performance fee calculation to adjust for relative price changes between tokens
     *      Represents how many token0 units equal 1 token1 unit, scaled by SCALING_FACTOR
     */
    uint256 public lastQuoteScaled;

    /// @notice Address authorized to collect accumulated fees
    address public feeCollector;

    /**
     * @notice Packed storage of pending fee updates with activation timestamp
     * @dev Format: [80 bits tvlFee][80 bits perfFee][96 bits timestamp]
     *      Bit layout (256 bits total):
     *      - Bits 176-255 (80 bits): TVL fee value
     *      - Bits 96-175 (80 bits): Performance fee value
     *      - Bits 0-95 (96 bits): Activation timestamp
     */
    uint256 internal packedPendingFees;

    /// @notice Array of active liquidity positions (Not designed to hold more than 3 positions even if it is technically possible)
    Position[] internal positions;

    // ========== ERRORS ==========

    /// @notice Thrown when a call is made from an address other than the pool
    error NotPool();

    /// @notice Thrown when the payer in callback data doesn't match expected address
    error WrongPayer();

    /// @notice Thrown when an invalid value is provided
    error InvalidValue();

    /// @notice Thrown when trying to enforce fee update with no pending update
    error NoPendingFeeUpdate();

    /// @notice Thrown when a scaling factor exceeds maximum allowed percentage
    error InvalidScalingFactor();

    /// @notice Thrown when trying to initialize an already initialized contract
    error AlreadyInitialized();

    // ========== EVENTS ==========

    /// @notice Emitted when tokens are deposited into the vault
    /// @param assets0 Amount of token0 deposited
    /// @param assets1 Amount of token1 deposited
    event Deposit(uint256 indexed assets0, uint256 indexed assets1);

    /// @notice Emitted when tokens are withdrawn from the vault
    /// @param assets0 Amount of token0 withdrawn
    /// @param assets1 Amount of token1 withdrawn
    /// @param receiver Address receiving the withdrawn tokens
    event Withdraw(uint256 indexed assets0, uint256 indexed assets1, address indexed receiver);

    /// @notice Emitted when TVL management fees are collected
    /// @param tvlFeeAssets0 Amount of token0 collected as TVL fee
    /// @param tvlFeeAssets1 Amount of token1 collected as TVL fee
    /// @param feeCollector Address receiving the fees
    event TvlFeeCollected(uint256 indexed tvlFeeAssets0, uint256 indexed tvlFeeAssets1, address indexed feeCollector);

    /// @notice Emitted when performance fees are collected
    /// @param assets0 Amount of token0 collected as performance fee
    /// @param assets1 Amount of token1 collected as performance fee
    /// @param feeCollector Address receiving the fees
    event PerformanceFeeCollected(uint256 indexed assets0, uint256 indexed assets1, address indexed feeCollector);

    event ProtocolFeeCollected(uint256 indexed assets0, uint256 indexed assets1, address indexed collector);

    /// @notice Emitted when a fee update is initiated (timelock started)
    /// @param tvlfee New TVL fee percentage
    /// @param performanceFee New performance fee percentage
    /// @param activatableAfter Timestamp after which the update can be enforced
    event FeeUpdateInitialized(uint80 indexed tvlfee, uint80 indexed performanceFee, uint96 indexed activatableAfter);

    /// @notice Emitted when a pending fee update is enforced
    /// @param tvlfee New active TVL fee percentage
    /// @param performanceFee New active performance fee percentage
    event FeeUpdateEnforced(uint80 indexed tvlfee, uint80 indexed performanceFee);

    // ========== MODIFIERS ==========

    /**
     * @notice Ensures transaction hasn't exceeded its deadline
     * @param deadline Maximum timestamp for transaction execution
     */
    modifier checkDeadline(uint256 deadline) {
        _checkDeadline(deadline);
        _;
    }

    /**
     * @notice Restricts function access to the fee collector address
     */
    modifier onlyFeeCollector() {
        _onlyFeeCollector();
        _;
    }

    /**
     * @notice Validates transaction hasn't exceeded deadline
     * @dev Reverts if current timestamp is past the deadline
     * @param deadline Maximum timestamp for transaction
     */
    function _checkDeadline(uint256 deadline) internal view {
        require(block.timestamp <= deadline, "Transaction too old");
    }

    /**
     * @notice Validates caller is the fee collector
     * @dev Reverts with Unauthorized error if caller is not the fee collector
     */
    function _onlyFeeCollector() internal view {
        if (msg.sender != feeCollector) revert Unauthorized();
    }
}
