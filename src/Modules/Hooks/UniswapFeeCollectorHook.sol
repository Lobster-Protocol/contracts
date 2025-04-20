// SPDX-License-Identifier: GNUv3
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import {IHook} from "../../interfaces/modules/IHook.sol";
import {IUniswapV3PoolMinimal} from "../../interfaces/IUniswapV3PoolMinimal.sol";
import {Op} from "../../interfaces/modules/IOpValidatorModule.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {LobsterVault} from "../../../src/Vault/Vault.sol";

uint256 constant BASIS_POINT_SCALE = 10_000;

// Hook used to take a fee when the vault collect its fees from a uniswap pool
contract UniswapFeeCollectorHook is IHook, Ownable {
    using Math for uint256;
    using SafeERC20 for IERC20;

    IUniswapV3PoolMinimal public pool;
    IERC20 public token0;
    IERC20 public token1;

    address public feeReceiver;

    uint256 public feeBasisPoint;

    event UniswapPositionPerformanceFee(address indexed receiver, uint256 indexed feeToken0, uint256 indexed feeToken1);

    constructor(
        IUniswapV3PoolMinimal pool_,
        address initialOwner,
        uint256 initialFee,
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

    function preCheck(Op calldata op, address) external view returns (bytes memory context) {
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

    function postCheck(bytes memory ctx) external returns (bool success) {
        if (ctx.length == 0) return true;

        (uint256 oldBalanceToken0, uint256 oldBalanceToken1) = abi.decode(ctx, (uint256, uint256));

        // get the current vault balance for both tokens
        uint256 token0Balance = token0.balanceOf(msg.sender);
        uint256 token1Balance = token1.balanceOf(msg.sender);

        bool feeCollected = false;

        // If the token balances increased for a token, a cut is taken
        uint256 token0Fee = 0;
        if (token0Balance > oldBalanceToken0) {
            token0Fee = (token0Balance - oldBalanceToken0).mulDiv(feeBasisPoint, BASIS_POINT_SCALE, Math.Rounding.Floor);

            // Setup the vault op to extract the fees
            Op memory collectLobsterFee = Op(
                address(token0),
                0,
                abi.encodeWithSelector(token0.transfer.selector, feeReceiver, token0Fee),
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
                address(token1),
                0,
                abi.encodeWithSelector(token1.transfer.selector, feeReceiver, token1Fee),
                "" // no need for validation data, msg.sender will be the hook
            );

            LobsterVault(msg.sender).executeOp(collectLobsterFee);

            feeCollected = true;
        }

        if (feeCollected) {
            console.log();
            emit UniswapPositionPerformanceFee(feeReceiver, token0Fee, token1Fee);
        }
    }
}
