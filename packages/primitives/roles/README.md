# roles

The caller-identity primitive for role-gated packages in this repo. It depends only on [armature](https://github.com/loash-industries/armature).

- [agreement_roles](../../extensions/agreement_roles) uses it for its claim gate.
- [armature_vault](../../composites/armature_vault) uses it for every role check (since Cycle 8; it shipped its own copy, `armature_vault::acl`, before that).

## `roles::acl`

A `Principal` is one of:

| Constructor | Satisfied when |
|---|---|
| `player(addr)` | the sender is `addr` |
| `machine(addr)` | the sender is `addr`. For a service or bot key that isn't an on-chain Player |
| `ou(ou_id)` | the caller passes the `&OU` with that ID and the sender is one of its current board members |

This package defines no roles. Each consuming package defines its own `Role` type, maps each role to a list of principals, and grants a role to a caller who satisfies **any** principal in its list.

### Checking a caller

- **`satisfies(principal, org, sender)`**: for a caller acting as `org`. A `player` or `machine` principal ignores `org`; an `ou` principal needs `org` to be that OU.
- **`satisfies_directly(principal, sender)`**: for a caller with no OU to pass. It only matches `player` and `machine` principals and is always false for `ou`.

An `ou` principal is read at call time, so a board change applies at once to every list that names the OU. To move a role to a new OU (a migrated OU has a new object ID), list the new OU alongside the old one, then remove the old one.

### Reading principals from BCS

`peel_principal(bcs)` reads one `Principal` written by `bcs::to_bytes`, for packages that store principals inside a BCS-encoded config such as a requirement. It aborts with `EUnknownPrincipal` on an unknown variant tag. It sits beside the enum so the variant tags stay in step with it: **add new variants only at the end**, or encoded principals will decode as the wrong variant.

## Differences from the old `armature_vault::acl`

The `Principal` enum, its variants and their order are identical to the copy the vault shipped through Cycle 7. This package adds:

- `satisfies` is `public` (it was `public(package)` in the vault),
- `satisfies_directly`,
- `peel_principal`.

## Dependency pin

`armature` is pinned to `cf027e9` (Cycle 8, armature `cycle-8`), the same revision armature_vault and agreement_roles use, so `armature::ou::OU` is one type across the repo.

## Build & test

```bash
cd packages/primitives/roles
sui move build --build-env testnet_stillness
sui move test  --build-env testnet_stillness
```
