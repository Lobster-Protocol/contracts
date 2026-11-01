# Fork tests for `LobsterProxy`

These suites run against **real Uniswap deployments** — live V3 pools and the V4 PoolManager
singleton — rather than mocks. That is deliberate: the proxy's correctness depends on how canonical
pools actually behave (who they call back, what they measure), so mocking them would assume away
the thing under test.

The actors (`approver`, `outsider`, and the purpose-built ones in individual suites) are vaults in
their own right: `ForkBase` registers the live pools each one trades on for itself, and each swap pays
out to its own caller, as `LobsterProxy` requires. The registry is therefore never what stops a
call here, except in the tests that are about it; its rules are covered by the offline suites.

## The entry point under test

Every swap goes through one entry point, `swap(bytes data)` (payable), whose `data` packs a deadline,
a token table and one or more legs (`src/libraries/SwapFlags.sol`). A single swap is a one-leg call;
the call returns one amount per leg (received for exact input, paid for exact output). A leg names its
tokens and fee (plus tick spacing on V4) and nothing else:

- **no recipient**: its output goes to the caller, or with `PARK` stays for a later `HELD` leg of the
  same call, which spends exactly what was parked;
- **no hooks**: a V4 leg always targets the hookless pool of its currencies, fee and tick spacing.

A call with any V4 leg runs entirely inside one PoolManager unlock, V3 legs included; a V3-only call
opens none. `ForkBase` builds legs against the live pools (`_v3In`, `_v3Out`, `_v4In`, `_v4Out`,
`_parked`, `_held`) and encodes them with `test/helpers/SwapCalldata.sol`.

Everything in `test/` outside this directory is mock-based and runs offline with plain `forge test`.

## Layout

| Path | What it covers |
| --- | --- |
| `helpers/ForkBase.sol` | Shared fixture: per-chain addresses, actors, funding, unlimited approvals, leg builders |
| `helpers/Callers.sol` | Non-cooperative callers: direct-callback caller, re-entrant token, settlement-thief token |
| `helpers/Tokens.sol` | Throwaway ERC20s for building purpose-made pools (plain + fee-on-transfer) |
| `security/Authorisation.t.sol` | Standing approvals are only spendable by the account that granted them: forged callbacks, payer and recipient are always the caller, re-entrant tokens, no plain ETH transfers |
| `security/AmountCasts.t.sol` | The amount-encoding boundary: amounts are 16-byte (`uint128`) fields, so nothing can wrap; wider data is `MalformedSwap` |
| `integration/HappyPath.t.sol` | V3 mint and a one-leg `swap` work as documented; deadline and price band |
| `integration/V4Swap.t.sol` | V4 legs, native ETH (payable `swap`, refunds, the force-fed ETH sweep), hooks that cannot be encoded, the unlock callback |
| `integration/SwapSemantics.t.sol` | Edge behaviour: non-standard tokens (USDT, fee-on-transfer), mint slippage, exact-output fills |
| `integration/BatchSwap.t.sol` | Multi-leg `swap`: V3 + V4 legs in one unlock, routes through every hand-off (PARK/HELD, native ETH in the middle); equivalence, atomicity, nothing runs unless every leg passes, payer |

`security/Authorisation.t.sol` is the one to read first — it states the invariant the whole design
rests on: `payer` is always the entry point's `msg.sender`, at any call depth (the pool callbacks read
it from the proxy's reentrancy lock, never from calldata).

## Running them

Two environment variables drive the fixture:

- **`FORK_RPC`** — which chain to fork. Defaults to `http://127.0.0.1:8545`.
- **`PROXY`** — attach to an already-deployed `LobsterProxy` instead of deploying a fresh one.
  This is the difference between testing `src/` and testing what actually shipped. The actors'
  registrations are written on the fork, so an attached deployment needs no setup of its own.

Supported chains are mainnet (chain id 1, or a fork of it at 31337) and Sepolia. Addresses and
trade sizes resolve per chain in `ForkBase._loadNetwork`.

### Against a local mainnet fork

```bash
anvil --fork-url "$RPC" --fork-block-number 25795000 --compute-units-per-second 90

# Deploys a fresh LobsterProxy on the fork
FOUNDRY_PROFILE=fork forge test --match-path "test/fork/**/*.t.sol"

# Or, against an instance already deployed there
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
