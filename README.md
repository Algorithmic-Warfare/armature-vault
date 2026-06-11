# armature-vault

A DAO/OU-gated vault for **warehouse receipts** on EVE Frontier, with a dynamic,
multi-principal access-control list keyed on [armature](https://github.com/loash-industries/armature)
DAO identity.

It is a descendant of the warehouse-receipts `tribe_vault`, but the access-control
source is **armature DAO membership** instead of a raw in-game `tribe_id`, and the
ACL is dynamic and role-based rather than a single fixed tribe. It lives in its own
package (not inside `armature_world_bridge`) because that bridge is transitional and
the vault outlives it.

## What it does

Players mint standard `multicoin::Balance` receipts via the `warehouse_receipts`
package (which "digitalizes" EVE `StorageUnit` items into fungible bearer tokens),
then deposit those receipts here. The vault:

- accepts only receipts from the SSU's bound `collection_id`,
- accumulates balances per `asset_id` in dynamic object fields,
- gates every operation behind a **role** whose **principals** are checked at call time.

## Access model

Three roles — `Deposit`, `Withdraw`, `Edit` — each mapping to a list of **principals**.
A principal is either:

- `player::${address}` — satisfied when `ctx.sender()` equals the address, or
- `ou::${dao_id}` — satisfied when the caller passes the matching `&DAO` and is one
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
`&awar_officers_dao`) to drop `player(protodroid)` from `deposit` and `withdraw`.

## Why the OU indirection (migration)

A migrated DAO gets a **new object id**. The OU principal expresses "the current
board" by id, so the guaranteed migration path is:

1. create the new DAO,
2. grant `ou(new_dao_id)` the `Edit` role on the vault (old + new editors coexist),
3. migrate caps/coins to the new DAO object,
4. revoke the old `Edit` principal.

Invariant: `Edit` can never be emptied (`ELastEditor`) — an empty `Edit` list would
permanently brick the ACL.

## Dependencies & environments

- `armature` (framework) — DAO identity / `is_governance_member`.
- `world` pinned to `8e2e97b` — same rev warehouse-receipts uses, so `StorageUnit`
  / `Character` types match.
- `multicoin` pinned to `c7a97f2` (`override = true`) — same rev as warehouse-receipts
  / armature-trading / triexbook, so `multicoin::Balance` receipts are the same
  on-chain type across the deposit boundary.

**Target env:** `testnet_stillness`. **Blocker:** `armature_framework` on `main`
declares only `testnet_wip`, not `testnet_stillness`; Move's automated address
management requires every transitive dep to declare the build env, so
`sui move build -e testnet_stillness` will not resolve until the framework adds that
environment. Until then, build/test with the shared implicit env:

```
sui move build --build-env testnet
sui move test  --build-env testnet
```

## Status

Source + tests complete and green (6 tests). Publishing on `testnet_stillness` is
blocked on the framework environment declaration above.
