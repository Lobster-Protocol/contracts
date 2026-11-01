// SPDX-License-Identifier: GPL-3.0
pragma solidity =0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {LobsterProxy} from "../../../src/LobsterProxy.sol";
import {MintCallbackData} from "../../../src/interfaces/uniswapV3/IUniswapV3MintCallback.sol";
import {IPoolManagerMinimal, Currency} from "../../../src/interfaces/uniswapV4/IPoolManagerMinimal.sol";
import {PoolAddress} from "../../../src/libraries/uniswapV3/PoolAddress.sol";
import {SwapCalldata} from "../../helpers/SwapCalldata.sol";
import {PlainToken} from "./Tokens.sol";

/// @notice The data of the proxy's V3 swap callback, in the exact format the proxy writes and reads:
/// tokenIn (20 bytes) | mode (1 byte) | creditIn (32 bytes) (see {UniswapSwapProxy-_v3Swap}). Forging
/// it byte for byte is the strongest attempt a caller can make; the payer is never part of it, the
/// proxy takes it from its reentrancy lock.
library V3CallbackData {
    /// @dev The caller of `swap` pays the pool
    uint8 internal constant PAY_FROM_CALLER = 0;
    /// @dev A HELD leg: the proxy pays from what the call parked (PoolManager credit first)
    uint8 internal constant PAY_FROM_HELD = 1;
    /// @dev The output was sent to the PoolManager and is settled first
    uint8 internal constant SETTLE_TO_MANAGER = 2;

    function encode(address tokenIn, uint8 mode, uint256 creditIn) internal pure returns (bytes memory) {
        return abi.encodePacked(tokenIn, mode, creditIn);
    }
}

/// @notice Invokes the proxy's pool callbacks directly from a contract.
/// @dev The callbacks are `external`. The mint callback takes `payer` from decoded calldata, so
/// `CallbackValidation` is the check that has to hold; the V3 swap callback is honoured only from the
/// pool the proxy is calling at that moment, and `unlockCallback` only from the PoolManager. This exists
/// to assert that each guard does.
contract PoolImpersonator {
    LobsterProxy public immutable PROXY;

    constructor(LobsterProxy _proxy) {
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

    /// @dev `data` as the caller chooses it, e.g. {V3CallbackData-encode}
    function callViaSwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external {
        PROXY.uniswapV3SwapCallback(amount0Delta, amount1Delta, data);
    }

    function callViaUnlockCallback(bytes calldata data) external {
        PROXY.unlockCallback(data);
    }
}

/// @notice A token that re-enters the proxy from inside its own transfers.
/// @dev Models the case an integrator cannot prevent: a V3 pool pairing a real token with an
/// arbitrary one is still factory-derived, so the proxy trades on it and pays it. Used to assert that
/// re-entering from inside a legitimate pool interaction cannot change which account settles, nor
/// reach what the proxy holds for the call in progress.
contract ReentrantToken {
    string public name = "Reentrant";
    string public symbol = "RENT";
    uint8 public decimals = 18;
    uint256 public totalSupply;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    LobsterProxy public proxy;
    address public approver;
    /// @dev A *different*, unlocked pool to re-enter through. Re-entering the pool we are currently
    /// inside would just hit that pool's own `lock` modifier and tell us nothing about the proxy.
    address public reenterTokenIn;
    address public reenterTokenOut;
    uint24 public reenterFee;
    /// @notice Re-enter from `transferFrom`: the proxy paying a pool, inside the pool's callback
    bool public armed;
    /// @notice Re-enter from `transfer` too: a pool paying this token out, before it calls the proxy
    /// back, i.e. while the proxy is waiting for exactly that pool's swap callback
    bool public armedOnTransfer;
    /// @notice A token whose balance in the proxy is recorded at the first re-entry
    address public watchedToken;
    uint256 public watchedProxyBalance;

    /// @notice Set if the corresponding re-entrant call returned without reverting
    bool public entryPointReentrySucceeded;
    bool public directCallbackReentrySucceeded;
    bool public swapCallbackReentrySucceeded;
    bool public unlockCallbackReentrySucceeded;
    bytes public entryPointRevertData;
    bytes public directCallbackRevertData;
    bytes public swapCallbackRevertData;
    bytes public unlockCallbackRevertData;
    uint256 public reentryAttempts;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
        emit Transfer(address(0), to, amount);
    }

    function arm(
        LobsterProxy _proxy,
        address _approver,
        address _reenterTokenIn,
        address _reenterTokenOut,
        uint24 _reenterFee
    )
        external
    {
        proxy = _proxy;
        approver = _approver;
        reenterTokenIn = _reenterTokenIn;
        reenterTokenOut = _reenterTokenOut;
        reenterFee = _reenterFee;
        armed = true;
    }

    function disarm() external {
        armed = false;
        armedOnTransfer = false;
    }

    function setArmedOnTransfer(bool on) external {
        armedOnTransfer = on;
    }

    function watch(address token) external {
        watchedToken = token;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        if (armedOnTransfer) _reenter();
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

    /// @dev Runs in the middle of a legitimate, factory-verified pool interaction the proxy is
    /// making for some vault. Four calls, probing different assumptions:
    ///
    ///  1. The entry point, as anyone would use it: a one-leg `swap` on the other pool. Its payer
    ///     would be msg.sender, THIS token, never the vault whose call is in progress, and in fact the
    ///     lock refuses it outright: the vault's call may hold parked funds.
    ///  2. The raw mint callback, naming a third-party account as payer. Being mid-callback should
    ///     not weaken `CallbackValidation`.
    ///  3. The raw V3 swap callback, in the proxy's own format, asking to be paid by whoever holds the
    ///     lock. Only the pool the proxy is calling may use it, and only once.
    ///  4. The unlock callback, which only the PoolManager may call.
    function _reenter() internal {
        reentryAttempts++;
        if (reentryAttempts == 1 && watchedToken != address(0)) {
            watchedProxyBalance = IERC20(watchedToken).balanceOf(address(proxy));
        }

        SwapCalldata.Leg[] memory legs = new SwapCalldata.Leg[](1);
        legs[0].tokenIn = reenterTokenIn;
        legs[0].tokenOut = reenterTokenOut;
        legs[0].fee = reenterFee;
        legs[0].amount = 1000e6;
        (bool ok, bytes memory ret) = address(proxy).call(SwapCalldata.call(block.timestamp, legs));
        if (ok) entryPointReentrySucceeded = true;
        else entryPointRevertData = ret;

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

        try proxy.uniswapV3SwapCallback(
            1000e6, -1, V3CallbackData.encode(reenterTokenIn, V3CallbackData.PAY_FROM_CALLER, 0)
        ) {
            swapCallbackReentrySucceeded = true;
        } catch (bytes memory err) {
            swapCallbackRevertData = err;
        }

        try proxy.unlockCallback(hex"01") returns (bytes memory) {
            unlockCallbackReentrySucceeded = true;
        } catch (bytes memory err) {
            unlockCallbackRevertData = err;
        }
    }

    function _move(address from, address to, uint256 amount) internal {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
    }
}

/// @notice A token that, when paid to the PoolManager, tries to claim that payment as its own.
/// @dev Targets the V3 -> V4 hand-off. A parked V3 output that a later V4 leg spends is paid by the V3
/// pool straight to the PoolManager: the proxy calls `sync(token)`, the pool transfers its output, then
/// calls the proxy back, which settles. While the PoolManager is unlocked `settle` is open to anyone and
/// credits its caller with everything that arrived since the last `sync`, and the output token's own
/// `transfer` runs inside that window. Armed, this token settles first and takes the vault's output to
/// `sink`. The proxy settles at the very start of the pool's callback and requires the PoolManager to
/// have booked exactly what the pool reports, so the call must revert with `UnexpectedSettlement`.
contract SettlementThiefToken is PlainToken {
    IPoolManagerMinimal public immutable MANAGER;
    address public sink;
    bool public armed;

    constructor(IPoolManagerMinimal manager) PlainToken("Settlement Thief", "THIEF", 18) {
        MANAGER = manager;
    }

    function arm(address _sink) external {
        sink = _sink;
        armed = true;
    }

    function disarm() external {
        armed = false;
    }

    function _move(address from, address to, uint256 amount) internal override {
        super._move(from, to, amount);
        if (armed && to == address(MANAGER)) {
            uint256 claimed = MANAGER.settle();
            if (claimed > 0) MANAGER.take(Currency.wrap(address(this)), sink, claimed);
        }
    }
}
