// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.27;

import {UniswapV4SwapProxy} from "./UniswapV4SwapProxy.sol";
import {PoolRegistry} from "./base/PoolRegistry.sol";
import {
    IPoolManagerMinimal,
    Currency,
    BalanceDelta,
    PoolKey,
    ModifyLiquidityParams
} from "./interfaces/uniswapV4/IPoolManagerMinimal.sol";
import {IRoles, ICustomCondition, Operation} from "./interfaces/zodiac/IRoles.sol";
import {BalanceDeltaLibrary} from "./libraries/uniswapV4/BalanceDeltaLibrary.sol";
import {TransferHelper} from "./libraries/uniswapV3/TransferHelper.sol";

/// @notice One liquidity operation on a V4 position owned by the vault
struct V4LiquidityOp {
    /// @dev Hookless pools only
    PoolKey key;
    int24 tickLower;
    int24 tickUpper;
    /// @dev > 0 adds liquidity (needs `PERMISSION_MINT` on the pool), < 0 removes it, 0 only
    /// collects fees
    int256 liquidityDelta;
    /// @dev The vault's free choice; lets it hold several positions over the same range
    bytes32 salt;
    /// @dev Adding: the most the vault pays of currency0. Removing or collecting: the least it
    /// receives, fees included.
    uint128 amount0Limit;
    /// @dev Same, for currency1
    uint128 amount1Limit;
}

/// @title Uniswap V4 liquidity for vaults that own their positions
/// @notice Lets a vault (a Safe) add and remove Uniswap V4 liquidity and collect fees, with the
/// positions owned by the vault itself in the PoolManager, exactly like its V3 positions. No
/// PositionManager, no NFT, and the proxy never holds a position or funds between transactions.
/// @dev THE PROBLEM. In V4 a position belongs to whoever calls `PoolManager.modifyLiquidity`, and that
/// call only works while the PoolManager is unlocked, i.e. from inside some contract's
/// `unlockCallback`. A Safe cannot implement that callback.
///
/// THE TRAMPOLINE. `modifyLiquidityV4`, called by the vault:
/// 1. checks the operations, then opens an unlock;
/// 2. inside the callback, makes the VAULT ITSELF call `modifyLiquidity`, through the vault's own
///    Zodiac Roles modifier, on which this contract holds a dedicated role. `onlyWhenUnlocked` only
///    checks that the manager is unlocked, not by whom, and deltas are booked per caller, so the
///    position and its deltas are the vault's;
/// 3. reads the vault's resulting deltas from the PoolManager itself, never from return data. It pays
///    what the vault owes (`sync`, `transferFrom(vault)`, `settleFor(vault)`; native ETH with
///    `settleFor{value}` from msg.value), then has the vault `take` what it is owed, through Roles.
///
/// WHO CAN DO WHAT.
/// - Only the vault can start an operation on its own positions: the modifier used is the one the
///   vault configured for itself ({setV4Roles}), re-checked on every call to have the vault as both
///   avatar and target. No caller can point this contract at another vault's modifier.
/// - Only an unlock opened by `modifyLiquidityV4` reaches the liquidity branch of `unlockCallback`:
///   the call must come from the PoolManager, carry `LIQUIDITY_TAG`, and find the context
///   `modifyLiquidityV4` stored in transient storage.
/// - Adding liquidity needs `PERMISSION_MINT` on the pool's V4 key (its PoolId) in the vault's own
///   {PoolRegistry} entries, and the pool's current tick inside the vault's price band for that key.
///   Removing and collecting never depend on the registry or the band: a vault can always exit, even
///   a pool it has de-registered.
///
/// SETUP, per vault:
/// - the vault approves this contract for the ERC20s it will provide as liquidity;
/// - the vault's owners call `setV4Roles(modifier, roleKey)` from the Safe;
/// - on the vault's Roles modifier (configured by the backend):
///   - the executor's role: `allowFunction(this, modifyLiquidityV4)`, with Send allowed if the vault
///     should pay native ETH. NEVER `setV4Roles`;
///   - this contract: enabled as a module (`enableModule`), and the only member of a dedicated role
///     (`assignRoles(this, [roleKey], [true])`) that allows exactly:
///     - `PoolManager.modifyLiquidity`, with a Custom condition pointing at this contract's {check};
///     - `PoolManager.take`, with `to` (its 2nd parameter) EqualToAvatar;
///     - nothing else: no value, no token transfers. Payments go through `transferFrom` (the
///       approval above) and `settleFor`.
///
/// Abstract on purpose: this is a mixin combined into {LobsterProxy}. Deploy that rather than this.
abstract contract UniswapV4LiquidityProxy is UniswapV4SwapProxy, PoolRegistry, ICustomCondition {
    using BalanceDeltaLibrary for BalanceDelta;

    /// @dev Transient context of the operation in progress: keccak256("lobster.V4LiquidityProxy.context")
    /// and the next three slots hold the vault, its Roles modifier, the role key and msg.value.
    uint256 private constant CONTEXT_SLOT = 0xc99a7bc870431655f3b19b4b23bc3dc010e0d34c076f3ad995b7245c6c505391;

    /// @dev `modifyLiquidity(PoolKey,ModifyLiquidityParams,bytes)` with empty hook data: selector, five
    /// words of key, four of params, the bytes offset and the bytes length
    uint256 private constant MODIFY_LIQUIDITY_CALLDATA_LENGTH = 4 + 11 * 32;

    struct V4Roles {
        address rolesModifier;
        bytes32 roleKey;
    }

    mapping(address vault => V4Roles) private _v4Roles;

    event V4RolesSet(address indexed vault, address indexed rolesModifier, bytes32 roleKey);

    // ---------------------------------------------------------------------------------------------
    // Configuration (the vault's owners, never the executor)
    // ---------------------------------------------------------------------------------------------

    /// @notice Sets the Roles modifier, and the role on it, through which this contract makes the
    /// caller call the PoolManager. `address(0)` clears it.
    /// @dev The modifier must have the caller as both avatar and target, so a vault can only ever
    /// point this contract at its own modifier.
    function setV4Roles(address rolesModifier, bytes32 roleKey) external nonReentrant {
        if (rolesModifier != address(0)) _requireRolesOf(rolesModifier, msg.sender);
        _v4Roles[msg.sender] = V4Roles({rolesModifier: rolesModifier, roleKey: roleKey});
        emit V4RolesSet(msg.sender, rolesModifier, roleKey);
    }

    /// @notice The Roles modifier and role key `vault` configured; zero if none
    function v4RolesOf(address vault) external view returns (address rolesModifier, bytes32 roleKey) {
        V4Roles memory roles = _v4Roles[vault];
        return (roles.rolesModifier, roles.roleKey);
    }

    // ---------------------------------------------------------------------------------------------
    // The entry point (the vault: msg.sender is the Safe)
    // ---------------------------------------------------------------------------------------------

    /// @notice Adds or removes liquidity and collects fees on the caller's own V4 positions, in one
    /// unlock. Operations run in order and are settled together, so a rebalance (remove one range,
    /// add another) only moves the net amounts.
    /// @dev Payable for native-ETH pools: what the vault owes in ETH is paid from msg.value, and the
    /// rest is refunded to the caller.
    /// @return amounts0 Per operation, the vault's currency0 delta, fees included: negative = paid,
    /// positive = received
    /// @return amounts1 Same, for currency1
    function modifyLiquidityV4(
        V4LiquidityOp[] calldata ops,
        uint256 deadline
    )
        external
        payable
        nonReentrant
        checkDeadline(deadline)
        returns (int256[] memory amounts0, int256[] memory amounts1)
    {
        V4Roles memory roles = _v4Roles[msg.sender];
        require(roles.rolesModifier != address(0), V4RolesNotSet());
        _requireRolesOf(roles.rolesModifier, msg.sender);

        for (uint256 i = 0; i < ops.length; i++) {
            require(address(ops[i].key.hooks) == address(0), HooksNotSupported());
            if (ops[i].liquidityDelta > 0) {
                bytes32 poolId = keccak256(abi.encode(ops[i].key));
                require(_canAdd(msg.sender, poolId), PoolNotAllowed());
                // Checked once, up front: the unlock below only modifies liquidity, which never moves
                // a pool's price, so the tick read here is the one every operation runs at
                _requireInPriceBand(msg.sender, poolId, _currentTick(poolId));
            }
        }

        _setContext(msg.sender, roles.rolesModifier, roles.roleKey, msg.value);
        bytes memory result = POOL_MANAGER.unlock(bytes.concat(LIQUIDITY_TAG, abi.encode(ops)));
        _setContext(address(0), address(0), bytes32(0), 0);

        (amounts0, amounts1) = abi.decode(result, (int256[], int256[]));

        // Unspent ETH is the caller's change: the PoolManager pays what the vault is owed to the
        // vault directly, never to the proxy (see {UniswapV4SwapProxy-_refundExcessNative})
        _refundExcessNative();
    }

    // ---------------------------------------------------------------------------------------------
    // The callback
    // ---------------------------------------------------------------------------------------------

    /// @inheritdoc UniswapV4SwapProxy
    /// @dev {UniswapV4SwapProxy-unlockCallback} has checked that the PoolManager is the caller and that
    /// the data carries `LIQUIDITY_TAG`; `data` is what follows the tag.
    function _liquidityCallback(bytes calldata data) internal override returns (bytes memory) {
        (address vault, address rolesModifier, bytes32 roleKey, uint256 value) = _context();
        require(vault != address(0), NoLiquidityOperation());

        V4LiquidityOp[] memory ops = abi.decode(data, (V4LiquidityOp[]));
        uint256 n = ops.length;
        int256[] memory amounts0 = new int256[](n);
        int256[] memory amounts1 = new int256[](n);
        // Each operation touches two currencies
        address[] memory currencies = new address[](2 * n);
        uint256 count;

        // 1. The vault modifies its own positions
        for (uint256 i = 0; i < n; i++) {
            (amounts0[i], amounts1[i]) = _modifyAsVault(rolesModifier, roleKey, ops[i]);
            count = _addCurrency(currencies, count, Currency.unwrap(ops[i].key.currency0));
            count = _addCurrency(currencies, count, Currency.unwrap(ops[i].key.currency1));
        }

        // 2. Settle the vault's net deltas, as the PoolManager books them. Payments first, then
        // takes, which re-read each delta after any payment.
        for (uint256 i = 0; i < count; i++) {
            int256 delta = _deltaOf(vault, currencies[i]);
            // forge-lint: disable-next-line(unsafe-typecast)
            if (delta < 0) _payFor(vault, currencies[i], uint256(-delta), value);
        }
        for (uint256 i = 0; i < count; i++) {
            int256 delta = _deltaOf(vault, currencies[i]);
            // forge-lint: disable-next-line(unsafe-typecast)
            if (delta > 0) _takeAsVault(rolesModifier, roleKey, vault, currencies[i], uint256(delta));
        }

        // 3. Every delta, the vault's and this contract's, must now be zero; the PoolManager reverts
        // the whole unlock otherwise (`CurrencyNotSettled`).
        return abi.encode(amounts0, amounts1);
    }

    /// @dev The vault calls `modifyLiquidity` through its Roles modifier; checks the op's limits
    function _modifyAsVault(
        address rolesModifier,
        bytes32 roleKey,
        V4LiquidityOp memory op
    )
        private
        returns (int256 amount0, int256 amount1)
    {
        (, bytes memory returnData) = IRoles(rolesModifier)
            .execTransactionWithRoleReturnData(
                address(POOL_MANAGER),
                0,
                abi.encodeCall(
                    IPoolManagerMinimal.modifyLiquidity,
                    (
                        op.key,
                        ModifyLiquidityParams({
                            tickLower: op.tickLower,
                            tickUpper: op.tickUpper,
                            liquidityDelta: op.liquidityDelta,
                            salt: op.salt
                        }),
                        ""
                    )
                ),
                Operation.Call,
                roleKey,
                true
            );
        (BalanceDelta callerDelta,) = abi.decode(returnData, (BalanceDelta, BalanceDelta));
        amount0 = callerDelta.amount0();
        amount1 = callerDelta.amount1();
        _checkLimit(op.liquidityDelta, amount0, op.amount0Limit);
        _checkLimit(op.liquidityDelta, amount1, op.amount1Limit);
    }

    /// @dev The vault takes what it is owed, to itself, through its Roles modifier
    function _takeAsVault(
        address rolesModifier,
        bytes32 roleKey,
        address vault,
        address currency,
        uint256 amount
    )
        private
    {
        IRoles(rolesModifier)
            .execTransactionWithRole(
                address(POOL_MANAGER),
                0,
                abi.encodeCall(IPoolManagerMinimal.take, (Currency.wrap(currency), vault, amount)),
                Operation.Call,
                roleKey,
                true
            );
    }

    /// @dev Pays `owed` of `currency` to the PoolManager on the vault's behalf
    function _payFor(address vault, address currency, uint256 owed, uint256 value) private {
        if (currency == address(0)) {
            require(owed <= value, NotEnoughEthSent());
            // Native settlement needs no synced currency; reset whatever may be there
            POOL_MANAGER.sync(Currency.wrap(address(0)));
            POOL_MANAGER.settleFor{value: owed}(vault);
        } else {
            POOL_MANAGER.sync(Currency.wrap(currency));
            TransferHelper.safeTransferFrom(currency, vault, address(POOL_MANAGER), owed);
            POOL_MANAGER.settleFor(vault);
        }
    }

    /// @dev Adding: `limit` is the most the vault pays. Removing or collecting: the least it receives.
    function _checkLimit(int256 liquidityDelta, int256 amount, uint128 limit) private pure {
        if (liquidityDelta > 0) {
            // forge-lint: disable-next-line(unsafe-typecast)
            if (amount < 0) require(uint256(-amount) <= limit, TooMuchRequested());
        } else {
            // forge-lint: disable-next-line(unsafe-typecast)
            require(amount >= 0 && uint256(amount) >= limit, TooLittleReceived());
        }
    }

    /// @dev The vault's current delta in `currency`, as the PoolManager books it (v4-core
    /// `TransientStateLibrary.currencyDelta`)
    function _deltaOf(address vault, address currency) private view returns (int256) {
        return int256(uint256(POOL_MANAGER.exttload(keccak256(abi.encode(vault, currency)))));
    }

    function _addCurrency(address[] memory currencies, uint256 count, address currency) private pure returns (uint256) {
        for (uint256 i = 0; i < count; i++) {
            if (currencies[i] == currency) return count;
        }
        currencies[count] = currency;
        return count + 1;
    }

    function _requireRolesOf(address rolesModifier, address vault) private view {
        require(
            IRoles(rolesModifier).avatar() == vault && IRoles(rolesModifier).target() == vault,
            RolesModifierNotTheVaults()
        );
    }

    /// @dev The pool's current tick, read from its Slot0 in the PoolManager (v4-core `StateLibrary`:
    /// `pools` is storage slot 6, the tick sits at bits 160-183 of Slot0)
    function _currentTick(bytes32 poolId) internal view returns (int24) {
        bytes32 slot0 = POOL_MANAGER.extsload(keccak256(abi.encodePacked(poolId, uint256(6))));
        // forge-lint: disable-next-line(unsafe-typecast)
        return int24(uint24(uint256(slot0) >> 160));
    }

    function _canAdd(address vault, bytes32 poolId) private view returns (bool) {
        return _hasPermission(vault, poolId, PERMISSION_MINT);
    }

    function _setContext(address vault, address rolesModifier, bytes32 roleKey, uint256 value) private {
        assembly ("memory-safe") {
            tstore(CONTEXT_SLOT, vault)
            tstore(add(CONTEXT_SLOT, 1), rolesModifier)
            tstore(add(CONTEXT_SLOT, 2), roleKey)
            tstore(add(CONTEXT_SLOT, 3), value)
        }
    }

    function _context() private view returns (address vault, address rolesModifier, bytes32 roleKey, uint256 value) {
        assembly ("memory-safe") {
            vault := tload(CONTEXT_SLOT)
            rolesModifier := tload(add(CONTEXT_SLOT, 1))
            roleKey := tload(add(CONTEXT_SLOT, 2))
            value := tload(add(CONTEXT_SLOT, 3))
        }
    }

    // ---------------------------------------------------------------------------------------------
    // The Roles custom condition
    // ---------------------------------------------------------------------------------------------

    /// @notice Roles custom condition for this contract's `PoolManager.modifyLiquidity` permission
    /// @dev Called by a vault's Roles modifier (msg.sender) while it authorizes the vault's
    /// `modifyLiquidity` call, i.e. in the middle of `modifyLiquidityV4`: deliberately `view` and not
    /// behind the reentrancy lock. Decodes the whole calldata itself and never reverts, whatever the
    /// input. Allows the call only if it is a plain call of `modifyLiquidity` on the PoolManager, with
    /// no value, a hookless pool and empty hook data, and, when it adds liquidity, the vault (the
    /// modifier's avatar) has `PERMISSION_MINT` on the pool.
    function check(
        address to,
        uint256 value,
        bytes calldata data,
        uint8 operation,
        uint256,
        uint256,
        bytes12
    )
        external
        view
        override
        returns (bool, bytes32)
    {
        if (to != address(POOL_MANAGER)) return (false, "Not the PoolManager");
        if (value != 0) return (false, "Value not allowed");
        if (operation != uint8(Operation.Call)) return (false, "Not a call");
        if (data.length != MODIFY_LIQUIDITY_CALLDATA_LENGTH) return (false, "Malformed calldata");
        if (bytes4(data[:4]) != IPoolManagerMinimal.modifyLiquidity.selector) return (false, "Not modifyLiquidity");

        // key: currency0, currency1, fee, tickSpacing, hooks; params: tickLower, tickUpper,
        // liquidityDelta, salt; then the hook data's offset and length
        if (
            !_isAddress(_calldataWord(data, 0)) || !_isAddress(_calldataWord(data, 1))
                || _calldataWord(data, 2) >> 24 != 0 || !_isInt24(_calldataWord(data, 3))
                || !_isAddress(_calldataWord(data, 4)) || !_isInt24(_calldataWord(data, 5))
                || !_isInt24(_calldataWord(data, 6))
        ) return (false, "Malformed calldata");
        if (_calldataWord(data, 9) != 0x140 || _calldataWord(data, 10) != 0) return (false, "Hook data not empty");
        if (_calldataWord(data, 4) != 0) return (false, "Hooks not supported");

        // forge-lint: disable-next-line(unsafe-typecast)
        if (int256(_calldataWord(data, 7)) > 0) {
            (bool ok, address vault) = _avatarOfCaller();
            if (!ok) return (false, "No avatar");
            // The PoolId: keccak256 of the five key words, validated above, hence canonical
            if (!_canAdd(vault, keccak256(data[4:164]))) return (false, "Pool not allowed");
        }
        return (true, bytes32(0));
    }

    /// @dev The `i`-th 32-byte word after the selector. The caller has checked the length.
    function _calldataWord(bytes calldata data, uint256 i) private pure returns (uint256) {
        return uint256(bytes32(data[4 + 32 * i:36 + 32 * i]));
    }

    function _isAddress(uint256 word) private pure returns (bool) {
        return word >> 160 == 0;
    }

    function _isInt24(uint256 word) private pure returns (bool) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return int256(word) == int256(int24(int256(word)));
    }

    /// @dev `IRoles(msg.sender).avatar()`, without reverting if msg.sender is not a modifier
    function _avatarOfCaller() private view returns (bool ok, address avatar) {
        bytes memory returnData;
        (ok, returnData) = msg.sender.staticcall(abi.encodeCall(IRoles.avatar, ()));
        if (!ok || returnData.length < 32) return (false, address(0));
        uint256 word = abi.decode(returnData, (uint256));
        if (!_isAddress(word)) return (false, address(0));
        // forge-lint: disable-next-line(unsafe-typecast)
        return (true, address(uint160(word))); // upper bits checked just above
    }
}
