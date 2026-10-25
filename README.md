# armature-vault

An OU-gated vault for **warehouse receipts** on EVE Frontier, with a dynamic,
multi-principal access-control list keyed on [armature](https://github.com/loash-industries/armature)
OU identity.

It is a descendant of the warehouse-receipts `tribe_vault`, but the access-control
source is **armature OU membership** instead of a raw in-game `tribe_id`, and the
ACL is dynamic and role-based rather than a single fixed tribe. It lives in its own
package (not inside `armature_world_bridge`) because that bridge is transitional and
the vault outlives it.

## Packages

Packages are grouped into three tiers under `packages/`, plus unpublished
integration tests:

- **`primitives/`**: shared building blocks with no lifecycle of their own. They
  depend only on external pins, never on another package in this repo.
- **`composites/`**: packages that own shared objects and state and have an
  end-to-end lifecycle (a vault, an agreement type). They depend on primitives
  and external pins, never on each other or on extensions.
- **`extensions/`**: opt-in packages that attach to a composite's extension
  points (rules, observers and so on), authorized through
  `Permit<T>`. They depend on primitives, plus the one composite they extend
  if they only work with that one, and never on each other. Anything that
  needs armature, world-contracts or another outside system lives here rather
  than in a composite's core.
- **`integration/`**: test-only packages that exercise packages from different
  tiers together. Sui's package manager has no dev-dependencies, so a
  test-only link from an extension to a composite would otherwise become a
  published dependency. They have no sources, are never published, and
  nothing depends on them.

| Package | Depends on | What it is |
|---|---|---|
| [`primitives/roles`](packages/primitives/roles) | armature | The shared `Principal` (player, machine or OU board member) for role-gated packages. `agreement_roles` uses it now; `armature_vault` moves to it at its next fresh publish |
| [`primitives/agreements`](packages/primitives/agreements) | multicoin | What every agreement type shares: requests and requirements (how extensions gate an action), `Spec` (an exact multicoin amount) and `payout` (sending a balance, or splitting it by bps) |
| [`composites/armature_vault`](packages/composites/armature_vault) | armature, world, multicoin, warehouse_receipts | The OU-gated receipt vault and keyspace described below |
| [`composites/hauling_agreements`](packages/composites/hauling_agreements) | agreements, multicoin | Collateralized hauling agreements with optional accept rules and observers ([design](docs/agreements/design.md), [user paths](docs/agreements/user-paths.md)) |
| [`extensions/agreement_roles`](packages/extensions/agreement_roles) | agreements, roles, armature | A claim gate that limits an agreement action to a list of principals: one player (a reservation), machine keys, or an OU's board |
| [`integration/hauling_claim_tests`](packages/integration/hauling_claim_tests) | agreements, roles, hauling_agreements, agreement_roles, armature, multicoin | Unpublished. End-to-end tests of the claim gate on hauling agreements |

`agreement_roles`' gate takes any `agreements` request, so it gates every
agreement type without depending on one. The lister of a hauling agreement
attaches it with `draft.require_to_accept(claim::requirement(principals))`.

CI checks each package's direct dependencies against the `deps` list in its
`.github/workflows/move-test.yml` matrix entry, so `hauling_agreements` can
never gain anything beyond multicoin and `agreements`, and `agreement_roles`
never an agreement type. Keep that matrix and this table in sync.

## What it does

Players mint standard `multicoin::Balance` receipts via the `warehouse_receipts`
package (which "digitalizes" EVE `StorageUnit` items into fungible bearer tokens),
then deposit those receipts here. The vault:

- accepts only receipts from the SSU's bound `collection_id`,
- accumulates balances per `asset_id` in dynamic object fields,
- gates every operation behind a **role** whose **principals** are checked at call time.

## Access model

Three roles — `Deposit`, `Withdraw`, `Edit` — each mapping to a list of **principals**.
A principal is one of:

- `player::${address}` — satisfied when `ctx.sender()` equals the address,
- `machine::${address}` — the same check as `player`, for a service or bot key
  that is not an on-chain Player, or
- `ou::${ou_id}` — satisfied when the caller passes the matching `&OU` and is one
  of its board members.

A caller passes a role check if they satisfy **any** principal listed for that role.

`Edit` is **ACL administration**: holders may batch grant/revoke principals on any
role (including `Edit`). The administrators need not be users — e.g. AWAR officers
hold `Edit` while AWAR/WOLF members hold `Deposit`/`Withdraw`.

### Example

A shared store where AWAR and WOLF members plus Protodroid can deposit/withdraw,
administered by AWAR officers:

```
deposit  => [ ou(awar_members), ou(wolf_members), player(protodroid) ]
withdraw => [ ou(awar_members), ou(wolf_members), player(protodroid) ]
edit     => [ ou(awar_officers) ]
```

If Protodroid goes rogue, an AWAR officer calls `revoke` (invoking as
`&awar_officers_ou`) to drop `player(protodroid)` from `deposit` and `withdraw`.

## Why the OU indirection (migration)

A migrated OU gets a **new object id**. The OU principal expresses "the current
board" by id, so the guaranteed migration path is:

1. create the new OU,
2. grant `ou(new_ou_id)` the `Edit` role on the vault (old + new editors coexist),
3. migrate caps/coins to the new OU object,
4. revoke the old `Edit` principal.

Invariant: `Edit` can never be emptied (`ELastEditor`) — an empty `Edit` list would
permanently brick the ACL.

## Dependencies & environments

- **Pending: `roles`** (local, `packages/primitives/roles`). The vault still ships
  its own `armature_vault::acl`, which `roles::acl` copies. Switching the vault to
  `roles` changes its types, so it waits for the next fresh publish (every cycle
  rollover is one) rather than an upgrade of v1. The change points are marked
  `@todo(roles)` in the package.
- `armature` (framework) pinned to `ae60685` (Cycle 7, armature `main`) — OU identity
  (`armature::ou::OU`) / `is_governance_member`.
- `world` pinned to `d33ff23` — same rev warehouse-receipts uses, so `StorageUnit`
  / `Character` types match.
- `multicoin` pinned to `2772c26` (`override = true`) — same rev as warehouse-receipts,
  so `multicoin::Balance` receipts are the same on-chain type across the deposit
  boundary. armature itself no longer depends on multicoin.
- `warehouse_receipts` pinned to `212be7c` (warehouse-receipts `main`).

**Target env:** `testnet_stillness`.

```
cd packages/<package>
sui move build --build-env testnet_stillness
sui move test  --build-env testnet_stillness
```

### Test coverage

```
python3 scripts/move_coverage.py [--uncovered] [--min 80]
```

Prints line, function, branch and bytecode coverage for each source file and writes
LCOV, CSV and JSON reports to `coverage/`. It needs a Sui CLI built with the `tracing`
feature: the release binaries that `suiup` installs have it, a `cargo install` build
does not. Set `SUI=/path/to/sui` to choose which binary it uses.
