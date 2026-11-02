# Lobster Proxy

`LobsterProxy` is the contract Lobster vaults use to trade and provide liquidity on Uniswap V3 and V4.
A vault is a Safe. Its owners decide which pools the vault may use and inside which price band, and an
executor (the backend, acting through Zodiac Roles) operates the vault within those limits. The proxy
enforces the limits on-chain: an executor that misbehaves cannot send the vault's funds anywhere else or
trade at a price the owners did not accept.

The proxy has no owner, no admin, no upgrade and no pause. Every setting is stored under the address that
wrote it, so a vault can only ever change its own configuration. It holds no funds between transactions.

## What a vault can do

| Action | Uniswap | Entry point |
|---|---|---|
| Swap, exact input or output, single or chained legs | V3 and V4 | `swap` |
| Add liquidity | V3 | `mint` |
| Add or remove liquidity, collect fees | V4 | `modifyLiquidityV4` |
| Remove liquidity, collect fees | V3 | directly on the pool (`burn`, `collect`) |

Every action is limited by three rules:

1. **Registered pools only.** The vault must have registered the pool with `PERMISSION_SWAP` for swaps or
   `PERMISSION_MINT` for adding liquidity.
2. **Everything goes back to the vault.** Swap outputs, LP positions and withdrawn liquidity always belong
   to the vault.
3. **Inside the price band.** Swapping and adding liquidity are refused when the pool's current tick is
   outside the band the owners set for it. Removing liquidity and collecting fees ignore bands, so a vault
   can always exit.

## Setting up a vault

Done by the vault's owners, as Safe transactions:

1. Approve the proxy for the tokens the vault will trade or provide as liquidity.
2. Register pools with `setPools(keys, permissions)`. Keys come from `v3Key(pool)` or `v4Key(poolKey)`;
   permissions are `PERMISSION_MINT` (1), `PERMISSION_SWAP` (2), both (3), or 0 to remove a pool.
3. Set a price band for each pool with `setPriceBand(key, minTick, maxTick)`. Without one, the pool can
   neither be swapped on nor minted into.
4. For V4 liquidity, give the proxy a dedicated role on the vault's Roles modifier and call
   `setV4Roles(rolesModifier, roleKey)`. See `UniswapV4LiquidityProxy` for exactly what the role must allow.
5. Allow the executor's role only `swap`, `mint` and `modifyLiquidityV4` on the proxy.

> Never give the executor `setPools`, `setPriceBand` or `setV4Roles`: it could register any pool or widen
> a band until it protects nothing.

## Layout

| File | Responsibility |
|---|---|
| [`src/LobsterProxy.sol`](src/LobsterProxy.sol) | The deployable contract: composes the mixins and runs the registry, recipient and band checks before every fund-moving call |
| [`src/UniswapSwapProxy.sol`](src/UniswapSwapProxy.sol) | `swap`: V3 and V4 legs, exact input and output, chaining, the V3 swap callback |
| [`src/UniswapV3MintProxy.sol`](src/UniswapV3MintProxy.sol) | V3 `mint` and its payment callback |
| [`src/UniswapV4LiquidityProxy.sol`](src/UniswapV4LiquidityProxy.sol) | V4 liquidity owned by the vault, the Roles custom condition |
| [`src/base/PoolRegistry.sol`](src/base/PoolRegistry.sol) | Per-vault pool permissions and price bands |
| [`src/base/PoolManagerBase.sol`](src/base/PoolManagerBase.sol) | V4 PoolManager unlock callback |
| [`src/base/Guards.sol`](src/base/Guards.sol), [`src/base/Deadline.sol`](src/base/Deadline.sol) | Reentrancy lock, deadline |
| [`src/interfaces/IProxyErrors.sol`](src/interfaces/IProxyErrors.sol) | Every custom error, in one place |
| [`src/libraries/`](src/libraries/) | `SwapFlags`, and Uniswap libraries vendored from v3-core and v3-periphery |

The NatSpec in each file documents its checks and known behaviours in detail.

## Development

Requires [Foundry](https://book.getfoundry.sh/). CI pins forge `v1.8.6`.

```bash
forge install          # dependencies (git submodules)
forge build
forge fmt --check
forge lint --deny warnings
```

### Tests

```bash
# Everything except the fork tests, as CI runs it
forge test --no-match-path "test/fork/**"

# Fork tests against live chains: need RPC endpoints, see test/fork/README.md
```

The unit tests deploy their own Uniswap V3 (`test/Mocks/uniswapV3/`) and V4 PoolManager
(`test/Mocks/uniswapV4/`) from bytecode, so they need no network.
