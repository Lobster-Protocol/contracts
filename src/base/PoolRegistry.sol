// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.27;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Guards} from "./Guards.sol";
import {PoolKey} from "../interfaces/uniswapV4/IPoolManagerMinimal.sol";
import {TickMath} from "../libraries/uniswapV3/TickMath.sol";

/// @title Per-vault pool registry
/// @notice Each vault (any account, in practice a Lobster Safe) records which Uniswap V3 and V4 pools it
/// allows itself to mint on and swap on through {LobsterProxy}. Everything not registered is
/// denied.
/// @dev Unlike the rest of the proxy code, this holds persistent state: per (vault, key), the
/// permission bits and the price band, packed into one storage slot ({Entry}) so that a check reads
/// a single slot; plus an enumerable list of each vault's keys so a backend can read the whole
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
/// (every swap leg, checked before and after it runs). Both are refused when no band
/// is set or the pool's current tick is outside it, so a vault cannot be made to deposit or trade at
/// a manipulated price. Removing liquidity and collecting fees ignore bands.
abstract contract PoolRegistry is Guards {
    /// @notice Permission bit: the vault may add liquidity to the pool: `mint` on a V3 key here, and
    /// `modifyLiquidityV4` with a positive delta on a V4 key ({UniswapV4LiquidityProxy}). Removing liquidity and collecting fees never need it.
    uint8 public constant PERMISSION_MINT = 1;
    /// @notice Permission bit: the vault may swap on the pool, in either direction
    uint8 public constant PERMISSION_SWAP = 2;
    uint8 private constant NO_PERMISSION = 0;
    uint8 private constant ALL_PERMISSIONS = PERMISSION_MINT | PERMISSION_SWAP;

    /// @dev Everything the registry holds for one (vault, key), in one storage slot
    struct Entry {
        uint8 permissions;
        /// @dev Price band, both bounds inclusive. The default (0, 0) means not set.
        int24 minTick;
        int24 maxTick;
        /// @dev 1-based index of the key in `_keys[vault]`; 0 means not listed
        uint32 position;
    }

    mapping(address vault => mapping(bytes32 key => Entry)) private _entries;
    /// @dev Every key with non-zero permissions, per vault. Unordered: removal swaps in the last entry.
    mapping(address vault => bytes32[]) private _keys;

    event PoolPermissionsSet(address indexed vault, bytes32 indexed key, uint8 permissions);
    event PriceBandSet(address indexed vault, bytes32 indexed key, int24 minTick, int24 maxTick);

    /// @notice Sets the caller's permissions for each of `keys`
    /// @dev Writes only `msg.sender`'s entries. Each entry overwrites what was there; 0 removes the
    /// key; keys not listed are unchanged. Applied in order, so a key listed twice ends up with its
    /// last value. Atomic: an invalid entry reverts the whole call. A key's price band is left as it
    /// is, including when the key is removed.
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
        return _entries[vault][key].permissions;
    }

    /// @notice Every key `vault` has registered, with its permission bits. Order is not meaningful
    /// and changes when a key is removed.
    function poolsOf(address vault) external view returns (bytes32[] memory keys, uint8[] memory permissions) {
        keys = _keys[vault];
        permissions = new uint8[](keys.length);
        for (uint256 i = 0; i < keys.length; i++) {
            permissions[i] = _entries[vault][keys[i]].permissions;
        }
    }

    /// @notice Sets the price band the caller allows when adding liquidity to, or swapping on, the
    /// pool `key`
    /// @dev Writes only `msg.sender`'s entry, and only its band. Like `setPools`, meant for the vault's
    /// owners, never its executor: an executor allowed to call this could widen the band and switch the
    /// protection off.
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
        Entry storage entry = _entries[msg.sender][key];
        entry.minTick = minTick;
        entry.maxTick = maxTick;
        emit PriceBandSet(msg.sender, key, minTick, maxTick);
    }

    /// @notice The price band `vault` has set for `key`; (0, 0) if none
    function priceBandOf(address vault, bytes32 key) external view returns (int24 minTick, int24 maxTick) {
        Entry memory entry = _entries[vault][key];
        return (entry.minTick, entry.maxTick);
    }

    /// @notice The registry key of a V3 pool: its address, left-padded with zeros
    function v3Key(address pool) public pure returns (bytes32) {
        return bytes32(uint256(uint160(pool)));
    }

    /// @notice The registry key of a V4 pool: its PoolId, as the PoolManager computes it
    function v4Key(PoolKey calldata key) external pure returns (bytes32) {
        return keccak256(abi.encode(key));
    }

    // Checks that every swap leg, liquidity operation and setPools entry must pass: one failing item
    // reverts the whole call, which is all or nothing
    // forge-lint: disable-start(require-revert-in-loop)
    /// @dev Reverts unless `vault` registered `key` with `permission` and set a price band for it, and
    /// returns the band: one SLOAD
    function _requireAllowed(
        address vault,
        bytes32 key,
        uint8 permission
    )
        internal
        view
        returns (int24 minTick, int24 maxTick)
    {
        Entry memory entry = _entries[vault][key];
        require(entry.permissions & permission != 0, PoolNotAllowed());
        // a set band always has minTick < maxTick, the default (0, 0) does not
        require(entry.minTick < entry.maxTick, PriceBandNotSet());
        return (entry.minTick, entry.maxTick);
    }

    /// @dev {_requireAllowed}, returning the band as one word: minTick | maxTick << 24, each as 24 bits.
    /// Reads the entry's slot directly: permissions in bits 0-7, minTick 8-31, maxTick 32-55 (the order
    /// Solidity packs {Entry} in).
    function _requireAllowedWord(address vault, bytes32 key, uint8 permission) internal view returns (uint256 band) {
        uint256 entry;
        assembly ("memory-safe") {
            mstore(0, vault)
            mstore(0x20, _entries.slot)
            mstore(0x20, keccak256(0, 0x40))
            mstore(0, key)
            entry := sload(keccak256(0, 0x40))
        }
        require(entry & permission != 0, PoolNotAllowed());
        int24 minTick;
        int24 maxTick;
        assembly ("memory-safe") {
            minTick := signextend(2, shr(8, entry))
            maxTick := signextend(2, shr(32, entry))
            band := and(shr(8, entry), 0xffffffffffff)
        }
        // a set band always has minTick < maxTick, the default (0, 0) does not
        require(minTick < maxTick, PriceBandNotSet());
    }

    function _hasPermission(address vault, bytes32 key, uint8 permission) internal view returns (bool) {
        return _entries[vault][key].permissions & permission != 0;
    }

    /// @dev Reverts unless `tick` is inside the band
    function _requireInBand(int24 tick, int24 minTick, int24 maxTick) internal pure {
        require(tick >= minTick && tick <= maxTick, PriceOutOfBand());
    }

    /// @dev Field by field, so that each write keeps the entry's other fields (a key's band survives
    /// its removal, and moving the last key in the list only rewrites its position)
    function _setPool(address vault, bytes32 key, uint8 permissions) private {
        require(permissions & ~ALL_PERMISSIONS == 0, InvalidPermissions());

        Entry storage entry = _entries[vault][key];
        uint32 position = entry.position;
        if (permissions == NO_PERMISSION) {
            if (position != 0) {
                // Swap-and-pop: move the last key into the removed one's slot
                bytes32[] storage list = _keys[vault];
                bytes32 last = list[list.length - 1];
                list[position - 1] = last;
                _entries[vault][last].position = position;
                list.pop();
                entry.position = 0;
            }
        } else if (position == 0) {
            _keys[vault].push(key);
            entry.position = SafeCast.toUint32(_keys[vault].length);
        }

        entry.permissions = permissions;
        emit PoolPermissionsSet(vault, key, permissions);
    }
    // forge-lint: disable-end(require-revert-in-loop)
}
