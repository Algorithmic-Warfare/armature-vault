# Keyspace Indexing Reference

All state changes in `armature_vault::keyspace` are fully expressed through
events. An indexer can reconstruct complete live state by replaying the event
log in checkpoint order — no object reads are required.

---

## Events

### `KeyspaceCreated`

Emitted by `create_keyspace` and `create_keyspace_for_ou`.

| Field | Type | Description |
|---|---|---|
| `id` | `ID` | Keyspace object ID (primary key) |
| `creator` | `Principal` | `Player { addr }` or `Ou { ou_id }` |
| `name` | `String` | Human-readable label |
| `registrant_ou_id` | `Option<ID>` | `None` → personal keyspace; `Some(ou_id)` → OU-linked |

`registrant_ou_id` is derived from the on-chain `&OU` witness in
`create_keyspace_for_ou` — it is never a raw caller-supplied value and
**cannot be spoofed**. The caller is also required to be a governance member
of the OU at creation time.

---

### `AccessGranted`

Emitted by `create_keyspace` (×3 for Grant/Read/Write), `create_keyspace_for_ou`
(once per seeded principal per role), `grant`, and `multi_grant`.

| Field | Type | Description |
|---|---|---|
| `keyspace_id` | `ID` | Parent Keyspace |
| `role` | `Role` | `Grant`, `Read`, or `Write` |
| `principal` | `Principal` | `Player { addr }` or `Ou { ou_id }` |
| `by` | `address` | Caller who performed the grant |

Only emitted on real state changes — `add_principal` is a no-op (and produces
no event) for duplicate entries.

---

### `AccessRevoked`

Emitted by `revoke` and `multi_revoke`.

| Field | Type | Description |
|---|---|---|
| `keyspace_id` | `ID` | Parent Keyspace |
| `role` | `Role` | `Grant`, `Read`, or `Write` |
| `principal` | `Principal` | The principal being removed |
| `by` | `address` | Caller address |

Only emitted on real state changes. A `Read` revocation always accompanies
a version increment (see [version reconstruction](#version-counter) below).

---

### `EntryPublished`

Emitted by `publish_entry`.

| Field | Type | Description |
|---|---|---|
| `entry_id` | `ID` | `EncryptedEntry` object ID (primary key) |
| `keyspace_id` | `ID` | Parent Keyspace |
| `uri` | `String` | Initial off-chain blob URI (e.g. Walrus/IPFS CID) |
| `created_by` | `address` | Write-role caller |

---

### `EntryUpdated`

Emitted by `update_entry` — key rotation path. The blob was re-encrypted
because the Read membership set changed (keyspace version advanced).

| Field | Type | Description |
|---|---|---|
| `entry_id` | `ID` | `EncryptedEntry` being updated |
| `keyspace_id` | `ID` | Parent Keyspace |
| `new_uri` | `String` | URI of the re-encrypted blob |
| `new_epoch` | `u64` | Keyspace version at time of re-encryption |
| `by` | `address` | Caller address |

Only emitted when `entry.epoch != keyspace.version` (i.e. the entry was
encrypted under a stale Read set). After the call, `new_epoch == keyspace.version`.
Cross-check `new_epoch` against the reconstructed version counter to detect
out-of-order indexing.

---

### `EntryEdited`

Emitted by `edit_entry` — same-epoch URI change, no key rotation.

| Field | Type | Description |
|---|---|---|
| `entry_id` | `ID` | `EncryptedEntry` being edited |
| `keyspace_id` | `ID` | Parent Keyspace |
| `new_uri` | `String` | Updated URI (content changed, encryption key unchanged) |
| `by` | `address` | Caller address |

Epoch is **not** incremented. Distinct from `EntryUpdated` so the indexer
can distinguish content edits from key-rotation updates.

---

### `EntryDescriptionEdited`

Emitted by `edit_description`.

| Field | Type | Description |
|---|---|---|
| `entry_id` | `ID` | `EncryptedEntry` being edited |
| `keyspace_id` | `ID` | Parent Keyspace |
| `new_description` | `String` | Updated label |
| `by` | `address` | Caller address |

---

## State Reconstruction

Replay events in checkpoint order to build the following tables.

### Keyspace row

```
KeyspaceCreated → INSERT (id, name, registrant_ou_id, version = 0)
```

### ACL (per keyspace, per role)

```
AccessGranted  → UPSERT principal into (keyspace_id, role) membership set
AccessRevoked  → REMOVE principal from (keyspace_id, role) membership set
```

### Version counter

The keyspace version is not emitted as a standalone event. Reconstruct it as:

```
AccessGranted(role = Read) → version += 1
AccessRevoked(role = Read) → version += 1
```

`EntryUpdated.new_epoch` reflects the keyspace version at rotation time and
can be used to cross-check the reconstructed counter.

### Entry row (per `EncryptedEntry`)

```
EntryPublished         → INSERT (entry_id, keyspace_id, uri, created_by,
                                 epoch = version at time of publish)
EntryUpdated           → UPDATE uri = new_uri, epoch = new_epoch
EntryEdited            → UPDATE uri = new_uri          (epoch unchanged)
EntryDescriptionEdited → UPDATE description = new_description
```

---

## Suggested Indexer Endpoints

| Endpoint | Source events |
|---|---|
| `GET /v1/ou/:ou_id/keyspaces` | `KeyspaceCreated WHERE registrant_ou_id = ou_id` |
| `GET /v1/keyspace/:keyspace_id/acl` | `AccessGranted − AccessRevoked`, grouped by role |
| `GET /v1/keyspace/:keyspace_id/entries` | `EntryPublished` + latest `EntryUpdated` / `EntryEdited` / `EntryDescriptionEdited` per `entry_id` |
| `GET /v1/address/:addr/keyspaces?role=Read` | `AccessGranted(role=Read, principal=Player{addr})` minus matching `AccessRevoked` |
| `GET /v1/ou/:ou_id/keyspaces?role=Grant` | `AccessGranted(role=Grant, principal=Ou{ou_id})` minus matching `AccessRevoked` |

---

## Notes on Event Ordering

- `AccessGranted` events for seeded principals are always emitted **after**
  `KeyspaceCreated` in the same transaction, so a keyspace row is guaranteed
  to exist before any ACL rows for it are inserted.
- `EntryPublished` is emitted before the `EncryptedEntry` object is shared,
  so `entry_id` is stable and can be used as a foreign key immediately.
- `update_entry` enforces `entry.epoch != keyspace.version` on-chain, so
  `EntryUpdated.new_epoch` is monotonically increasing per entry.
