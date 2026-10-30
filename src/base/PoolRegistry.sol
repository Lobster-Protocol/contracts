// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.27;

import {Guards} from "./Guards.sol";
import {PoolKey} from "../interfaces/uniswapV4/IPoolManagerMinimal.sol";
import {TickMath} from "../libraries/uniswapV3/TickMath.sol";

/// @title Per-vault pool registry
/// @notice Each vault (any account, in practice a Lobster Safe) records which Uniswap V3 and V4 pools it
/// allows itself to mint on and swap on through {LobsterProxy}. Everything not registered is
/// denied.
/// @dev Unlike the rest of the proxy code, this holds persistent state: one permission byte per
/// (vault, key), plus an enumerable list of each vault's keys so a backend can read the whole
/// registry with a single `eth_call`. Entries are only ever written by the vault they belong to;
/// there is no owner, admin, upgrade or pause.
///
/// KEYS. One `bytes32` key type covers both versions (see {v3Key} and {v4Key}):
/// - a V3 pool: its address, left-padded with 12 zero bytes: `bytes32(uint256(uint160(pool)))`;
/// - a V4 pool: its PoolId, `keccak256(abi.encode(poolKey))`, exactly as the PoolManager computes it.
/// A V4 key collides with a V3 key only if a keccak output starts with 96 zero bits: infeasible.
/// So a permission granted on one version's key can never authorize the other version's pool.
/// Keys are not verified against the factory or the PoolManager, and need not be: a key that is
/// not a pool's can never match one the proxy computes from a call.
///
/// PRICE BANDS. Per (vault, key), the vault also sets the price range, as pool ticks, inside which
/// it allows adding liquidity (V3 `mint`, V4 `modifyLiquidityV4` with a positive delta) and swapping
/// (every swap, single or batch leg, checked before and after it runs). Both are refused when no band
/// is set or the pool's current tick is outside it, so a vault cannot be made to deposit or trade at
/// a manipulated price. Removing liquidity and collecting fees ignore bands.
abstract contract PoolRegistry is Guards {
    /// @notice Permission bit: the vault may add liquidity to the pool: `mint` on a V3 key here, and
    /// `modifyLiquidityV4` with a positive delta on a V4 key ({UniswapV4LiquidityProxy}). Removing liquidity and collecting fees never need it.
    uint8 public constant PERMISSION_MINT = 1;
    /// @notice Permission bit: the vault may swap on the pool, in either direction
    uint8 public constant PERMISSION_SWAP = 2;
    uint8 private constant ALL_PERMISSIONS = PERMISSION_MINT | PERMISSION_SWAP;

    mapping(address vault => mapping(bytes32 key => uint8)) private _permissions;
    /// @dev Every key with non-zero permissions, per vault. Unordered: removal swaps in the last entry.
    mapping(address vault => bytes32[]) private _keys;
    /// @dev 1-based index of a key in `_keys[vault]`; 0 means not listed
    mapping(address vault => mapping(bytes32 key => uint256)) private _positions;

    event PoolPermissionsSet(address indexed vault, bytes32 indexed key, uint8 permissions);

    /// @notice Price range, as pool ticks, in which a vault allows adding liquidity to a pool
    /// @dev Both bounds are inclusive. The default (0, 0) means not set: adding liquidity reverts.
    struct PriceBand {
        int24 minTick;
        int24 maxTick;
    }

    mapping(address vault => mapping(bytes32 key => PriceBand)) private _priceBands;

    event PriceBandSet(address indexed vault, bytes32 indexed key, int24 minTick, int24 maxTick);

    /// @notice Sets the caller's permissions for each of `keys`
    /// @dev Writes only `msg.sender`'s entries. Each entry overwrites what was there; 0 removes the
    /// key; keys not listed are unchanged. Applied in order, so a key listed twice ends up with its
    /// last value. Atomic: an invalid entry reverts the whole call.
    ///
    /// Meant to be called by the vault's owners, never by its executor: an executor allowed to call
    /// this could register any pool for the vault, which is exactly what the registry prevents.
    /// @param keys Pool keys, see {v3Key} and {v4Key}
    /// @param permissions For each key, a combination of `PERMISSION_MINT` and `PERMISSION_SWAP`, or 0
    function setPools(bytes32[] calldata keys, uint8[] calldata permissions) external nonReentrant {
        require(keys.length == permissions.length, LengthMismatch());
        for (uint256 i = 0; i < keys.length; i++) {
            _setPool(msg.sender, keys[i], permissions[i]);
        }
    }

    /// @notice The permission bits `vault` has set for `key`; 0 if none
    function permissionsOf(address vault, bytes32 key) external view returns (uint8) {
        return _permissions[vault][key];
    }

    /// @notice Every key `vault` has registered, with its permission bits. Order is not meaningful
    /// and changes when a key is removed.
    function poolsOf(address vault) external view returns (bytes32[] memory keys, uint8[] memory permissions) {
        keys = _keys[vault];
        permissions = new uint8[](keys.length);
        for (uint256 i = 0; i < keys.length; i++) {
            permissions[i] = _permissions[vault][keys[i]];
        }
    }

    /// @notice Sets the price band the caller allows when adding liquidity to, or swapping on, the
    /// pool `key`
    /// @dev Writes only `msg.sender`'s entry. Like `setPools`, meant for the vault's owners, never its
    /// executor: an executor allowed to call this could widen the band and switch the protection off.
    /// @param key Pool key, see {v3Key} and {v4Key}
    /// @param minTick Lowest allowed pool tick (inclusive)
    /// @param maxTick Highest allowed pool tick (inclusive), greater than `minTick`. (0, 0) clears the
    /// band, which blocks adding liquidity to, and swapping on, that pool
    function setPriceBand(bytes32 key, int24 minTick, int24 maxTick) external nonReentrant {
        require(
            (minTick == 0 && maxTick == 0)
                || (minTick < maxTick && minTick >= TickMath.MIN_TICK && maxTick <= TickMath.MAX_TICK),
            InvalidPriceBand()
        );
        _priceBands[msg.sender][key] = PriceBand({minTick: minTick, maxTick: maxTick});
        emit PriceBandSet(msg.sender, key, minTick, maxTick);
    }

    /// @notice The price band `vault` has set for `key`; (0, 0) if none
    function priceBandOf(address vault, bytes32 key) external view returns (int24 minTick, int24 maxTick) {
        PriceBand memory band = _priceBands[vault][key];
        return (band.minTick, band.maxTick);
    }

    /// @notice The registry key of a V3 pool: its address, left-padded with zeros
    function v3Key(address pool) public pure returns (bytes32) {
        return bytes32(uint256(uint160(pool)));
    }

    /// @notice The registry key of a V4 pool: its PoolId, as the PoolManager computes it
    function v4Key(PoolKey calldata key) external pure returns (bytes32) {
        return _v4Key(key);
    }

    function _v4Key(PoolKey memory key) internal pure returns (bytes32) {
        return keccak256(abi.encode(key));
    }

    /// @dev Reverts unless the caller has registered `key` with `permission`
    function _requirePermission(bytes32 key, uint8 permission) internal view {
        require(_hasPermission(msg.sender, key, permission), PoolNotAllowed());
    }

    function _hasPermission(address vault, bytes32 key, uint8 permission) internal view returns (bool) {
        return _permissions[vault][key] & permission != 0;
    }

    /// @dev Reverts unless `vault` has a price band for `key` and `tick` is inside it
    function _requireInPriceBand(address vault, bytes32 key, int24 tick) internal view {
        PriceBand memory band = _priceBands[vault][key];
        // a set band always has minTick < maxTick, the default (0, 0) does not
        require(band.minTick < band.maxTick, PriceBandNotSet());
        require(tick >= band.minTick && tick <= band.maxTick, PriceOutOfBand());
    }

    /// @dev Stricter than {Guards-_checkRecipient}: a vault may only mint to itself and receive swap
    /// output itself. This also rules out address(0), the proxy and `Chaining.ADDRESS_THIS`, since
    /// none of them can be `msg.sender`.
    function _requireRecipientIsCaller(address recipient) internal view {
        require(recipient == msg.sender, RecipientMustBeCaller());
    }

    function _setPool(address vault, bytes32 key, uint8 permissions) private {
        require(permissions & ~ALL_PERMISSIONS == 0, InvalidPermissions());

        uint256 position = _positions[vault][key];
        if (permissions == 0) {
            if (position != 0) {
                // Swap-and-pop: move the last key into the removed one's slot
                bytes32[] storage list = _keys[vault];
                bytes32 last = list[list.length - 1];
                list[position - 1] = last;
                _positions[vault][last] = position;
                list.pop();
                delete _positions[vault][key];
            }
        } else if (position == 0) {
            _keys[vault].push(key);
            _positions[vault][key] = _keys[vault].length;
        }

        _permissions[vault][key] = permissions;
        emit PoolPermissionsSet(vault, key, permissions);
    }
}
