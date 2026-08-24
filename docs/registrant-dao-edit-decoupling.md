# Decoupling Registry Key from Edit Authority in `initialize_dao_vault`

## Problem

`initialize_dao_vault` currently uses `editor_dao` for two distinct purposes:

1. **Registry key** — `VaultKey { storage_unit_id, editor_dao_id }` determines how the vault is discovered in `DaoReceiptVaultRegistry`.
2. **Edit ACL seed** — `Ou { editor_dao.id() }` is automatically inserted as the sole Edit principal.

These two concerns are fused, which creates a permission escalation when creating tier-specific vaults. To make a vault discoverable under a member DAO (i.e. `VaultKey { ssu_id, member_dao_id }`), you must pass the member DAO as `editor_dao` — which grants every governance member of that DAO the ability to modify the vault's ACL. Members should only have operational access (Deposit/Withdraw), not administrative access (Edit).

The intended access model is:

| Role | Actor |
|------|-------|
| Deposit / Withdraw | Member DAO |
| Edit (ACL admin) | Officer or Owner DAO |

The current constructor cannot express this without losing registry discoverability.

## Proposed Change

Introduce an explicit `edit_principals` parameter (mirroring the existing `deposit_principals` / `withdraw_principals`) and rename `editor_dao` to `registrant_dao` to reflect its narrowed responsibility.

### New constructor signature

```move
public fun initialize_dao_vault(
    registry: &mut DaoReceiptVaultRegistry,
    storage_unit: &StorageUnit,
    owner_cap: &OwnerCap<StorageUnit>,
    registrant_dao: &DAO,               // registry key only; no longer auto-seeded into Edit
    vault_config: &VaultConfig,
    deposit_principals: vector<Principal>,
    withdraw_principals: vector<Principal>,
    edit_principals: vector<Principal>,  // explicit; must be non-empty
    ctx: &mut TxContext,
)
```

### Body changes

- Remove the auto-seed of `Ou { registrant_dao.id() }` into the Edit role.
- Seed Edit from caller-supplied `edit_principals` using the same loop that seeds Deposit/Withdraw.
- Assert `edit_principals.length() > 0` at the top of the function — without this guard, a vault could be created with no Edit principal, permanently freezing its ACL.
- Registry key `VaultKey { storage_unit_id, registrant_dao_id }` and the `registry_key_dao_id` field on `DaoReceiptVault` are renamed for clarity but otherwise unchanged.
- `update_registry_key` and `grant_edit_ou` migration helpers should be renamed to reflect that re-keying the registry no longer implies any change to Edit rights.

### Call site (OrgVaultPanel.tsx)

When initializing a member-tier vault, the caller explicitly passes the higher-tier DAO as the Edit principal:

```typescript
tx.moveCall({
    target: `${armatureVaultPackageId}::dao_receipt_vault::initialize_dao_vault`,
    arguments: [
        tx.object(registryId),
        tx.object(storageUnitId),
        cap,
        tx.object(memberDaoId),             // registrant_dao: registry key
        tx.object(vaultConfigId),
        makeOuPrincipalVec(memberDaoId),    // deposit
        makeOuPrincipalVec(memberDaoId),    // withdraw
        makeOuPrincipalVec(officerDaoId),   // edit ← explicitly the higher tier
    ],
})
```

### Discovery improvement

Because the registry key now faithfully means "whose vault is this," vault discovery can use a direct registry lookup `(ssu_id, member_dao_id) → vault_id` rather than the current client-side ACL scan over all vaults for a given SSU.

## Spoofability Analysis

### Can a caller register a vault under a DAO they don't belong to?

No. `registrant_dao: &DAO` is a live Sui object reference. Move's object system prevents forging or constructing a `DAO` value — the caller must pass the actual on-chain object. The body asserts `registrant_dao.is_governance_member(ctx.sender())`, so the caller must be a governance member of the DAO they claim as registrant. This guard is unchanged from the current design.

### Can a caller register a vault for an SSU they don't own?

No. The existing M1 check — `OwnerCap<StorageUnit>` must authorize the passed `storage_unit` — is unchanged.

### Can a caller register a vault with a mismatched collection?

No. The existing F1 check — `vault_config.storage_unit_id() == storage_unit.id()` — is unchanged.

### Can a caller pass a malicious `edit_principals` (e.g., grant Edit to an arbitrary DAO)?

Yes, intentionally. The vault creator can delegate Edit authority to any DAO — including one they are not a member of. This matches the existing trust model for Deposit/Withdraw principals. The invariant that matters is that only an *existing* Edit principal can subsequently grant Edit to others; the initial assignment at construction time is the creator's prerogative.

### Can a caller register a duplicate vault for the same (SSU, registrant DAO) pair?

No. The registry uniqueness assertion is unchanged.

## New Invariant

The only guard this design adds that does not exist today:

```move
assert!(edit_principals.length() > 0, EEmptyEditPrincipals);
```

Currently, Edit is guaranteed non-empty by auto-seeding. With explicit passing, an empty `edit_principals` vector would create a permanently un-administrable vault.
