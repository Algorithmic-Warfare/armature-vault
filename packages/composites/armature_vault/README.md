# armature_vault

Shared resources whose access is a role-based list of principals keyed on [armature](https://github.com/loash-industries/armature) OU identity. Two modules use it:

- [`ou_receipt_vault`](#armature_vaultou_receipt_vault): a vault for [warehouse receipts](https://github.com/loash-industries/warehouse-receipts) on one Storage Unit.
- [`keyspace`](#armature_vaultkeyspace): an access list for Seal-encrypted content stored off-chain.

Both depend on [`acl`](#armature_vaultacl) for the caller identity.

- [docs/keyspace-indexing.md](../../../docs/keyspace-indexing.md): rebuilding keyspace state from events.
- [docs/registrant-ou-edit-decoupling.md](../../../docs/registrant-ou-edit-decoupling.md): why the vault's registry key and its `Edit` role are separate.

## `armature_vault::acl`

A `Principal` is one of:

- `player(addr)`: satisfied when the sender is `addr`.
- `machine(addr)`: the same check, for a service or bot key that isn't an on-chain Player.
- `ou(ou_id)`: satisfied when the caller passes that `&OU` and is one of its current board members.

Each module defines its own `Role` enum and maps each role to a list of principals. A caller holds a role if they satisfy **any** principal listed for it.

**Every role check takes an `&OU`,** including checks a `player` or `machine` principal passes. Those principals match whatever OU is passed, so a caller listed directly may pass any OU.

This module is copied as `roles::acl` in [`primitives/roles`](../../primitives/roles). The vault switches to it at its next fresh publish; the change points are marked `@todo(roles)`.

## `armature_vault::ou_receipt_vault`

Players mint `multicoin::Balance` receipts with the warehouse_receipts package, which turns items in an EVE `StorageUnit` into fungible bearer tokens, then deposit them here.

### Lifecycle

1. **`initialize_ou_vault`**: a board member of `registrant_org` creates a vault for one Storage Unit. They pass the SSU's warehouse_receipts `VaultConfig`, and the vault accepts only receipts from the collection that config binds to the SSU. They also pass the starting principals for each role. `Edit` must have at least one; `Deposit` and `Withdraw` may start empty. The SSU owner doesn't need to sign.
2. **`deposit_receipt`**: a `Deposit` holder adds a receipt from the vault's collection. Balances are kept per `asset_id` in dynamic object fields. Zero-value receipts are rejected.
3. **`withdraw_receipt`**: a `Withdraw` holder takes an amount of one `asset_id` and receives it as a `Balance`.
4. **`deinitialize_ou_vault`**: once every balance is drained, an `Edit` holder frees the registry slot and clears the ACL. Shared objects can't be deleted, so the vault stays on-chain, but no one can satisfy any role on it and `lookup` no longer finds it.

### Roles

| Role | Allows |
|---|---|
| `Deposit` | `deposit_receipt` |
| `Withdraw` | `withdraw_receipt` |
| `Edit` | `grant`, `revoke`, `grant_edit_ou`, `update_registry_key`, `deinitialize_ou_vault` |

- **`grant` and `revoke`** take parallel vectors of roles and principals, so one call can change several roles. Pairs that are already present (or absent) are skipped without an event.
- **`grant_edit_ou`** gives `Edit` to an OU passed as `&OU`, so the granted ID is known to be a real OU. `grant` accepts any ID.
- **`revoke` can't lock the vault.** It aborts if `Edit` would be left empty (`ELastEditor`), or if the caller would no longer satisfy `Edit` through the OU they passed (`EEditorWouldLockSelf`).

The people who administer a vault need not be the people who use it. For a store shared by two OUs and one player, run by one OU's officers:

```
deposit  => [ ou(awar_members), ou(wolf_members), player(protodroid) ]
withdraw => [ ou(awar_members), ou(wolf_members), player(protodroid) ]
edit     => [ ou(awar_officers) ]
```

### Registry

A shared `OuReceiptVaultRegistry`, created at publish, maps `(storage_unit_id, registrant_ou_id)` to a vault ID. `lookup` reads it. Each OU can have one vault per Storage Unit.

`registrant_org` sets only the registry key and who may initialize. It doesn't get `Edit` unless it is listed in `edit_principals`. So a vault can be found under the members' OU while only the officers' OU administers it.

### Moving to a new OU

A migrated OU gets a new object ID. Because a principal names an OU by ID, the board can move without re-listing addresses:

1. Create the new OU.
2. `grant_edit_ou` the new OU, so old and new editors coexist.
3. Move caps and coins to the new OU.
4. `update_registry_key` if the vault was registered under the old OU.
5. `revoke` the old OU's `Edit` principal.

### Events

| Event | Emitted by |
|---|---|
| `VaultInitializedEvent` | `initialize_ou_vault` |
| `AclGrantedEvent` | `initialize_ou_vault` (once per starting principal), `grant`, `grant_edit_ou` |
| `AclRevokedEvent` | `revoke` |
| `DepositEvent` | `deposit_receipt` |
| `WithdrawEvent` | `withdraw_receipt` |
| `VaultDeinitializedEvent` | `deinitialize_ou_vault` |

ACL events are emitted only for real changes, so an indexer can rebuild the current ACL from them, with two caveats:

- **Count, don't deduplicate.** `initialize_ou_vault` stores its starting lists as given, duplicates included, and emits one `AclGrantedEvent` per element. `revoke` removes one copy and emits one `AclRevokedEvent`. A principal holds a role while its `AclGrantedEvent`s for that role outnumber its `AclRevokedEvent`s.
- **`VaultDeinitializedEvent` revokes everything.** `deinitialize_ou_vault` empties the whole ACL without emitting any `AclRevokedEvent`.

`update_registry_key` emits no event.

## `armature_vault::keyspace`

Ported from loash-industries/keyspace. A `Keyspace` is a shared access list for content encrypted with [Seal](https://github.com/MystenLabs/seal) and stored off-chain, for example on Walrus. Each `EncryptedEntry` is a shared pointer to one blob.

### Roles

| Role | Allows |
|---|---|
| `Grant` | `grant`, `multi_grant`, `revoke`, `multi_revoke` |
| `Read` | `seal_approve`: the Seal key server releases decryption keys |
| `Write` | `publish_entry`, `update_entry`, `edit_entry`, `edit_description` |

- **Creating.** `create_keyspace` makes a personal keyspace with the sender in all three roles. `create_keyspace_for_ou` is called by a board member of an OU, takes a separate principal list per role (`Grant` must not be empty) and records the OU as `registrant_ou_id` in `KeyspaceCreated`.
- **Changing access.** Unlike the vault, `grant` aborts on a principal that is already listed and `revoke` aborts on one that isn't. `revoke` can't empty `Grant`, `Read` or `Write`.
- **Seal key IDs** must start with the keyspace's object ID. `seal_approve` checks those 32 bytes, then the `Read` role.

### Re-encryption

Seal can't take back a key a reader already has. So each `Read` grant or revoke bumps the keyspace's `version`, and each entry records the `epoch` it was encrypted under. An entry whose epoch is behind `version` should be re-encrypted:

- **`update_entry`** replaces the URI with a re-encrypted blob and sets the epoch to the current version. It aborts if the entry is already current.
- **`edit_entry`** replaces the URI without changing the epoch, for a content change under the same key.

### Events

Every state change emits an event, so an indexer can rebuild keyspaces, ACLs, versions and entries without reading objects. See [docs/keyspace-indexing.md](../../../docs/keyspace-indexing.md).

## Dependency pins

| Dependency | Rev | Why |
|---|---|---|
| armature | `ae60685` | Cycle 7, armature `main`. Provides `armature::ou::OU`. |
| world | `d33ff23` | The rev warehouse-receipts uses, so `StorageUnit` is the same type. |
| multicoin | `2772c26` | The rev warehouse-receipts uses, so a deposited `Balance` is the same on-chain type. `override = true`. |
| warehouse_receipts | `212be7c` | warehouse-receipts `main`. Provides `VaultConfig`. |

When you bump a pin, bump the matching `*_REV` in [.github/workflows/move-test.yml](../../../.github/workflows/move-test.yml) too.

Published to `testnet_stillness` at `0xf447556abd7a92cc8690d626e1dd85dd40510c4a4dd75dcb5671f88ddfaec87e` (version 1). Moving to `roles` changes the `Principal` type, so it ships as a fresh publish at a cycle rollover rather than an upgrade.

## Build & test

```bash
cd packages/composites/armature_vault
sui move build --build-env testnet_stillness
sui move test  --build-env testnet_stillness
```

- `tests/ou_receipt_vault_tests.move`: ACL, deposit, withdraw, registry and deinit paths, on vaults built with `new_for_testing`.
- `tests/ou_receipt_vault_init_tests.move`: `initialize_ou_vault` against a real `StorageUnit` and `VaultConfig`.
- `tests/keyspace_tests.move`: keyspace roles, versions and entries.
