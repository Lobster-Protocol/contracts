// SPDX-License-Identifier: GPL-3.0
pragma solidity =0.8.26;

import {UniswapProxy} from "../../../src/UniswapProxy.sol";
import {MintCallbackData} from "../../../src/interfaces/uniswapV3/IUniswapV3MintCallback.sol";
import {SwapCallbackData, ExactInputSingleParams} from "../../../src/interfaces/uniswapV3/IUniswapV3SwapCallback.sol";
import {PoolAddress} from "../../../src/libraries/uniswapV3/PoolAddress.sol";

/// @notice Invokes the proxy's payment callbacks directly while impersonating a pool, naming an
/// arbitrary account as payer.
/// @dev The callbacks are `external` and take `payer` from decoded calldata, so `CallbackValidation`
/// is the check that has to hold. This exists to assert that it does.
contract PoolImpersonator {
    UniswapProxy public immutable PROXY;

    constructor(UniswapProxy _proxy) {
        PROXY = _proxy;
    }

    function callViaMintCallback(
        address token0,
        address token1,
        uint24 fee,
        address approver,
        uint256 amount0,
        uint256 amount1
    )
        external
    {
        PROXY.uniswapV3MintCallback(
            amount0,
            amount1,
            abi.encode(
                MintCallbackData({
                    poolKey: PoolAddress.PoolKey({token0: token0, token1: token1, fee: fee}), payer: approver
                })
            )
        );
    }

    function callViaSwapCallback(
        address tokenIn,
        address tokenOut,
        uint24 fee,
        address approver,
        int256 amount0Delta,
        int256 amount1Delta
    )
        external
    {
        PROXY.uniswapV3SwapCallback(
            amount0Delta,
            amount1Delta,
            abi.encode(SwapCallbackData({tokenIn: tokenIn, tokenOut: tokenOut, fee: fee, payer: approver}))
        );
    }

    function callViaUnlockCallback(bytes calldata data) external {
        PROXY.unlockCallback(data);
    }
}

/// @notice A token that re-enters the proxy from inside `transferFrom`.
/// @dev Models the case an integrator cannot prevent: a V3 pool pairing a real token with an
/// arbitrary one is still factory-derived, so it passes `verifyCallback`. Used to assert that
/// re-entering from inside a legitimate pool callback cannot change which account settles.
contract ReentrantToken {
    string public name = "Reentrant";
    string public symbol = "RENT";
    uint8 public decimals = 18;
    uint256 public totalSupply;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    UniswapProxy public proxy;
    address public approver;
    address public outsider;
    /// @dev A *different*, unlocked pool to re-enter through. Re-entering the pool we are currently
    /// inside would just hit that pool's own `lock` modifier and tell us nothing about the proxy.
    address public reenterTokenIn;
    address public reenterTokenOut;
    uint24 public reenterFee;
    bool public armed;

    /// @notice Set if either re-entrant call returned without reverting.
    bool public entryPointReentrySucceeded;
    bool public directCallbackReentrySucceeded;
    bytes public entryPointRevertData;
    bytes public directCallbackRevertData;
    uint256 public reentryAttempts;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
        emit Transfer(address(0), to, amount);
    }

    function arm(
        UniswapProxy _proxy,
        address _approver,
        address _outsider,
        address _reenterTokenIn,
        address _reenterTokenOut,
        uint24 _reenterFee
    )
        external
    {
        proxy = _proxy;
        approver = _approver;
        outsider = _outsider;
        reenterTokenIn = _reenterTokenIn;
        reenterTokenOut = _reenterTokenOut;
        reenterFee = _reenterFee;
        armed = true;
    }

    function disarm() external {
        armed = false;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _move(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (armed) _reenter();
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        _move(from, to, amount);
        return true;
    }

    /// @dev Runs from inside the proxy's own mint/swap callback, i.e. the deepest point of a
    /// legitimate, factory-verified pool interaction. Two calls, probing different assumptions:
    ///
    ///  1. A normal entry point. The proxy stamps `payer = msg.sender`, which here is THIS token,
    ///     so it should fail for lack of *our* funds — the payer is the immediate caller at any
    ///     call depth.
    ///  2. The raw callback, naming a third-party account as payer. Being mid-callback should not
    ///     weaken `CallbackValidation`.
    function _reenter() internal {
        reentryAttempts++;

        try proxy.exactInputSingle(
            ExactInputSingleParams({
                tokenIn: reenterTokenIn,
                tokenOut: reenterTokenOut,
                fee: reenterFee,
                recipient: outsider,
                deadline: block.timestamp,
                amountIn: 1000e6,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        ) {
            entryPointReentrySucceeded = true;
        } catch (bytes memory err) {
            entryPointRevertData = err;
        }

        try proxy.uniswapV3MintCallback(
            1000e6,
            0,
            abi.encode(
                MintCallbackData({
                    poolKey: PoolAddress.getPoolKey(reenterTokenIn, reenterTokenOut, reenterFee), payer: approver
                })
            )
        ) {
            directCallbackReentrySucceeded = true;
        } catch (bytes memory err) {
            directCallbackRevertData = err;
        }
    }

    function _move(address from, address to, uint256 amount) internal {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
    }
}
