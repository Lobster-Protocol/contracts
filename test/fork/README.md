# Fork tests for `UniswapProxy`

These suites run against **real Uniswap deployments** — live V3 pools and the V4 PoolManager
singleton — rather than mocks. That is deliberate: the proxy's correctness depends on how canonical
pools actually behave (who they call back, what they measure), so mocking them would assume away
the thing under test.

Everything in `test/` outside this directory is mock-based and runs offline with plain `forge test`.

## Layout

| Path | What it covers |
| --- | --- |
| `helpers/ForkBase.sol` | Shared fixture: per-chain addresses, actors, funding, unlimited approvals |
| `helpers/Callers.sol` | Non-cooperative callers: direct-callback caller, re-entrant token, ETH force-feeder |
| `helpers/Tokens.sol` | Throwaway ERC20s for building purpose-made pools (plain + fee-on-transfer) |
| `security/Authorisation.t.sol` | Standing approvals are only spendable by the account that granted them |
| `security/AmountCasts.t.sol` | Behaviour at the `uint256` -> `int256` conversion boundary |
| `integration/HappyPath.t.sol` | V3 mint / exactInput / exactOutput work as documented |
| `integration/V4Swap.t.sol` | V4 swaps, native ETH handling, hook rejection, the refund sweep |
| `integration/SwapSemantics.t.sol` | Edge behaviour: short fills, non-standard tokens, mint slippage |

`security/Authorisation.t.sol` is the one to read first — it states the invariant the whole design
rests on: `payer` is always `msg.sender`, at any call depth.

## Running them

Two environment variables drive the fixture:

- **`FORK_RPC`** — which chain to fork. Defaults to `http://127.0.0.1:8545`.
- **`PROXY`** — attach to an already-deployed instance instead of deploying a fresh one. This is
  the difference between testing `src/` and testing what actually shipped.

Supported chains are mainnet (chain id 1, or a fork of it at 31337) and Sepolia. Addresses and
trade sizes resolve per chain in `ForkBase._loadNetwork`.

### Against a local mainnet fork

```bash
anvil --fork-url "$RPC" --fork-block-number 25795000 --compute-units-per-second 90

forge script script/DeployUniswapProxy.s.sol:DeployUniswapProxy \
  --rpc-url http://127.0.0.1:8545 \
  --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 \
  --broadcast

FOUNDRY_PROFILE=fork PROXY=<deployed address> forge test --match-path "test/fork/**/*.t.sol"
```

### Against Sepolia

```bash
FOUNDRY_PROFILE=fork FORK_RPC=$SEPOLIA_RPC_URL forge test --match-path "test/fork/**/*.t.sol"
```

## Rate limits

A single deep swap costs one RPC storage read per tick crossed, so these suites are read-heavy. On
a rate-limited endpoint that surfaces as:

```
EVM error; database error: failed to get storage for 0x…: HTTP error 429
```

That is the node giving up, not a contract failure. Three things keep it under control:

1. **Throttle the node that talks upstream.** When forking from a local Anvil, Anvil is the one
   making upstream calls — `anvil --compute-units-per-second 90`. Passing
   `--compute-units-per-second` to `forge` only limits forge→Anvil, which is the wrong hop.
   When forking an endpoint directly, pass it to `forge` instead.
2. **`FOUNDRY_PROFILE=fork`** drops fuzz runs to 64 and raises the RPC timeout.
3. Runs warm the on-disk cache, so a repeat run is far cheaper than the first.

## Two fork-testing traps

Both produce *green tests that prove nothing*, and both bit this suite during development:

- **`makeAddr` can land on a real contract.** Some labels hash to addresses that already hold code
  on mainnet, including contracts whose fallback forwards their balance elsewhere — which silently
  invalidates any test measuring that account. Use `ForkBase._actor`, which salts the label until
  the address has no code.
- **Absolute balance assertions are unsafe on a fork.** Deterministic `CREATE` addresses inherit
  whatever the real account already holds. Assert on deltas.
