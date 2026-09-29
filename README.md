# armature-vault

An OU-gated vault for **warehouse receipts** on EVE Frontier, with a dynamic,
multi-principal access-control list keyed on [armature](https://github.com/loash-industries/armature)
OU identity.

It is a descendant of the warehouse-receipts `tribe_vault`, but the access-control
source is **armature OU membership** instead of a raw in-game `tribe_id`, and the
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

- `armature` (framework) pinned to `ff22e5f` (Cycle 7, armature `main`) — OU identity
  (`armature::ou::OU`) / `is_governance_member`.
- `world` pinned to `32300a2` — same rev warehouse-receipts uses, so `StorageUnit`
  / `Character` types match.
- `multicoin` pinned to `e384bbc` (`override = true`) — same rev as warehouse-receipts,
  so `multicoin::Balance` receipts are the same on-chain type across the deposit
  boundary. armature itself no longer depends on multicoin.
- `warehouse_receipts` pinned to `e872aac`.

**Target env:** `testnet_stillness`.

```
sui move build --build-env testnet_stillness
sui move test  --build-env testnet_stillness
```

**Known issue:** `sui move test` also compiles warehouse_receipts' own tests, and at
`e872aac` those don't compile (`receipt::batch_redeem_receipt` gained a
`to_ssu_owner` parameter the tests don't pass). Vault tests pass once that upstream
test file is fixed.
