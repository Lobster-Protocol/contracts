// SPDX-License-Identifier: GPLv3
pragma solidity ^0.8.28;

import {IHook} from "../../interfaces/modules/IHook.sol";
import {IUniswapV3PoolMinimal} from "../../interfaces/uniswapV3/IUniswapV3PoolMinimal.sol";
import {BaseOp, Op} from "../../interfaces/modules/IOpValidatorModule.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {LobsterVault} from "../../../src/Vault/Vault.sol";

/**
 * @title UniswapFeeCollectorHook
 * @author Lobster
 * @notice A hook that takes a fee when a vault collects fees from a Uniswap V3 pool
 * @dev This hook monitors Uniswap collect operations and takes a percentage of
 *      collected tokens as a performance fee. It is designed to work with the
 *      LobsterVault system's hook mechanism.
 * @dev This contract expect msg.sender to be the vault
 */

/// @dev Denominator for basis point calculations (100% = 10,000 basis points)
uint256 constant BASIS_POINT_SCALE = 10_000;

// Hook used to take a fee when the vault collect its fees from a uniswap pool
contract UniswapFeeCollectorHook is IHook, Ownable {
    using Math for uint256;
    using SafeERC20 for IERC20;

    /// @notice The Uniswap V3 pool that this hook is monitoring
    IUniswapV3PoolMinimal public pool;
    /// @notice The token0 of the Uniswap pool
    IERC20 public token0;
    /// @notice The token1 of the Uniswap pool
    IERC20 public token1;

    /// @notice The address that receives the collected fees
    address public feeReceiver;

    /// @notice The fee percentage in basis points (e.g., 300 = 3%)
    uint16 public feeBasisPoint;
    /// @notice The pending fee percentage in basis points (e.g., 300 = 3%)
    uint16 public pendingFeeBasisPoint = 0;
    uint160 public feeUpdateTimestamp = 0;
    /// @notice The minimal duration between a fee change and its application
    uint256 public constant MIN_FEE_CHANGE_DELAY = 2 weeks;

    /**
     * @notice Emitted when a performance fee is collected
     * @param receiver The address receiving the fee
     * @param feeToken0 The amount of token0 collected as fee
     * @param feeToken1 The amount of token1 collected as fee
     */
    event UniswapPositionPerformanceFee(address indexed receiver, uint256 indexed feeToken0, uint256 indexed feeToken1);

    /**
     * @notice Constructs a new UniswapFeeCollectorHook
     * @param pool_ The Uniswap V3 pool to monitor
     * @param initialOwner The address that will own this contract
     * @param initialFee The initial fee percentage in basis points
     * @param initialFeeReceiver The initial address to receive collected fees
     */
    constructor(
        IUniswapV3PoolMinimal pool_,
        address initialOwner,
        uint16 initialFee,
        address initialFeeReceiver
    )
        Ownable(initialOwner)
    {
        pool = pool_;
        token0 = IERC20(pool.token0());
        token1 = IERC20(pool.token1());
        feeBasisPoint = initialFee;
        feeReceiver = initialFeeReceiver;
    }

    /**
     * @dev See {IHook-preCheck}.
     */
    function preCheck(BaseOp calldata op, address) external view returns (bytes memory context) {
        // check if we are collecting fees for the pool
        if (op.target == address(pool) && op.data.length >= 4) {
            if (bytes4(op.data[:4]) == IUniswapV3PoolMinimal.collect.selector) {
                // get the current vault balance for both tokens
                uint256 token0Balance = token0.balanceOf(msg.sender);
                uint256 token1Balance = token1.balanceOf(msg.sender);

                return abi.encode(token0Balance, token1Balance);
            }
        }

        return "";
    }

    /**
     * @dev See {IHook-postCheck}.
     */
    function postCheck(bytes memory ctx) external returns (bool success) {
        if (ctx.length == 0) return true;

        (uint256 oldBalanceToken0, uint256 oldBalanceToken1) = abi.decode(ctx, (uint256, uint256));

        // get the current vault balance for both tokens
        uint256 token0Balance = token0.balanceOf(msg.sender);
        uint256 token1Balance = token1.balanceOf(msg.sender);

        bool feeCollected = false;

        // todo: we might do this in 1 batched call to the vault

        // If the token balances increased for a token, a cut is taken
        uint256 token0Fee = 0;
        if (token0Balance > oldBalanceToken0) {
            token0Fee = (token0Balance - oldBalanceToken0).mulDiv(feeBasisPoint, BASIS_POINT_SCALE, Math.Rounding.Floor);

            // Setup the vault op to extract the fees
            Op memory collectLobsterFee = Op(
                BaseOp(address(token0), 0, abi.encodeWithSelector(token0.transfer.selector, feeReceiver, token0Fee)),
                "" // no need for validation data, msg.sender will be the hook
            );

            LobsterVault(msg.sender).executeOp(collectLobsterFee);

            feeCollected = true;
        }

        uint256 token1Fee = 0;
        if (token1Balance > oldBalanceToken1) {
            token1Fee = (token1Balance - oldBalanceToken1).mulDiv(feeBasisPoint, BASIS_POINT_SCALE, Math.Rounding.Floor);
            // Setup the vault op to extract the fees
            Op memory collectLobsterFee = Op(
                BaseOp(address(token1), 0, abi.encodeWithSelector(token1.transfer.selector, feeReceiver, token1Fee)),
                "" // no need for validation data, msg.sender will be the hook
            );

            LobsterVault(msg.sender).executeOp(collectLobsterFee);

            feeCollected = true;
        }

        if (feeCollected) {
            emit UniswapPositionPerformanceFee(feeReceiver, token0Fee, token1Fee);
        }

        return true;
    }

    /**
     * @notice Sets the fee percentage
     * @param newFeeBasisPoint The new fee percentage in basis points
     */
    function setFeeBasisPoint(uint16 newFeeBasisPoint) external onlyOwner {
        require(newFeeBasisPoint <= BASIS_POINT_SCALE, "Fee too high");
        pendingFeeBasisPoint = newFeeBasisPoint;
        feeUpdateTimestamp = uint160(block.timestamp);
    }

    /**
     * @notice Sets the fee receiver address
     * @param newFeeReceiver The new address to receive collected fees
     */
    function setFeeReceiver(address newFeeReceiver) external onlyOwner {
        require(newFeeReceiver != address(0), "Zero address");
        feeReceiver = newFeeReceiver;
    }

    /**
     * @notice Applies the pending fee change after the delay period
     */
    function applyPendingFeeChange() external onlyOwner {
        require(pendingFeeBasisPoint != 0, "No pending fee change");
        require(block.timestamp >= feeUpdateTimestamp + MIN_FEE_CHANGE_DELAY, "Delay not passed");

        feeBasisPoint = pendingFeeBasisPoint;
        pendingFeeBasisPoint = 0;
        feeUpdateTimestamp = 0;
    }
}
