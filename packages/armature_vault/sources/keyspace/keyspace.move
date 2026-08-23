/// ACL-based encryption access control — ported from loash-industries/keyspace.
///
/// Flow:
///   1. Creator calls `create_keyspace` (personal) or `create_keyspace_for_dao`
///      (org-linked) → shared Keyspace.  Creator is seeded into all three roles
///      for personal keyspaces; org keyspaces accept explicit role principal lists.
///   2. A `Grant` holder calls `grant` / `revoke` to manage role membership.
///   3. Seal gates decryption-key release via `seal_approve`, which
///      requires the `Read` role.
///   4. A `Write` holder calls `publish_entry` to upload a new encrypted blob
///      pointer, and `update_entry` / `edit_entry` to mutate it.
///
/// Role semantics:
///   - `Grant` — can call `grant` / `revoke`.  Last grantor cannot be removed.
///   - `Read`  — can call `seal_approve` (decryption gate).  Membership changes
///               bump `version`, signalling that existing entries should be
///               re-encrypted.
///   - `Write` — can call `publish_entry`, `update_entry`, `edit_entry`.
///
/// Access control uses the shared `Principal` model from `armature_vault::acl`:
/// each list member is either a bare `Player { addr }` (single wallet) or an
/// `Ou { dao_id }` (any board member of that DAO), checked via `acl::satisfies`.
///
/// DAO-linked keyspaces (`create_keyspace_for_dao`) emit `registrant_dao_id` in
/// `KeyspaceCreated` so an indexer can answer "all keyspaces for DAO X" without
/// scanning every Grant-role membership list.  The `&DAO` witness + governance-
/// member check makes that association unspoofable.
module armature_vault::keyspace {
    use armature::dao::DAO;
    use armature_vault::acl::{Self as acl, Principal, PrincipalV2};
    use std::{option::{Self, Option}, string::String};
    use sui::{
        dynamic_field as df,
        event,
        vec_map::{Self, VecMap},
        versioned::{Self, Versioned},
    };

    // ── Roles ─────────────────────────────────────────────────────────────────

    public enum Role has copy, drop, store {
        Grant,
        Read,
        Write,
    }

    public fun role_grant(): Role { Role::Grant }

    public fun role_read(): Role { Role::Read }

    public fun role_write(): Role { Role::Write }

    // ── Error codes ──────────────────────────────────────────────────────────
    const ENotAllowed: u64 = 0;
    const EAlreadyGranted: u64 = 1;
    const ENotGranted: u64 = 2;
    const EAlreadyCurrentEpoch: u64 = 3;
    const EWrongKeyspace: u64 = 4;
    const ELastGrantor: u64 = 5;
    const ELastWriter: u64 = 6;
    const ELastReader: u64 = 7;
    const EEmptyGrantPrincipals: u64 = 8;
    const EUnknownPrincipalAclVersion: u64 = 9;

    // ── Objects ──────────────────────────────────────────────────────────────

    /// Shared object — the on-chain access-control registry.
    public struct Keyspace has key {
        id: UID,
        acl: VecMap<Role, vector<Principal>>,
        name: String,
        /// Incremented whenever the `Read` membership set changes.  Clients use
        /// this to detect when existing entries need re-encryption.
        version: u64,
        entries: vector<ID>,
    }

    /// A pointer to an AES-GCM–encrypted content blob stored off-chain.
    /// Shared after `publish_entry`.
    public struct EncryptedEntry has key, store {
        id: UID,
        keyspace_id: ID,
        uri: String,
        description: String,
        created_by: address,
        epoch: u64, // Keyspace version at time of encryption
    }

    // ── Events ───────────────────────────────────────────────────────────────

    public struct KeyspaceCreated has copy, drop {
        id: ID,
        creator: Principal,
        name: String,
        /// None for personal keyspaces; Some(dao_id) for org-linked keyspaces
        /// created via `create_keyspace_for_dao`.  The DAO ID is derived from
        /// the on-chain `&DAO` witness — not supplied by the caller — so it
        /// cannot be spoofed.
        registrant_dao_id: Option<ID>,
    }
    public struct AccessGranted has copy, drop {
        keyspace_id: ID,
        role: Role,
        principal: Principal,
        by: address,
    }
    public struct AccessRevoked has copy, drop {
        keyspace_id: ID,
        role: Role,
        principal: Principal,
        by: address,
    }
    public struct EntryPublished has copy, drop {
        entry_id: ID,
        keyspace_id: ID,
        uri: String,
        created_by: address,
    }
    public struct EntryUpdated has copy, drop {
        entry_id: ID,
        keyspace_id: ID,
        new_uri: String,
        new_epoch: u64,
        by: address,
    }
    public struct EntryEdited has copy, drop {
        entry_id: ID,
        keyspace_id: ID,
        new_uri: String,
        by: address,
    }
    public struct EntryDescriptionEdited has copy, drop {
        entry_id: ID,
        keyspace_id: ID,
        new_description: String,
        by: address,
    }

    // ── Indexing reference ───────────────────────────────────────────────────
    //
    // All state changes in this module are fully expressed through events.
    // An indexer can reconstruct complete live state by replaying the event log
    // in checkpoint order.  No object reads are required.
    //
    // ── Events ───────────────────────────────────────────────────────────────
    //
    // KeyspaceCreated
    //   Emitted by: create_keyspace, create_keyspace_for_dao
    //   Fields:
    //     id                — Keyspace object ID (primary key)
    //     creator           — Principal who created it (Player or Ou)
    //     name              — human-readable label
    //     registrant_dao_id — Option<ID>:
    //                           None → personal keyspace (create_keyspace)
    //                           Some → DAO-linked (create_keyspace_for_dao);
    //                                  derived from on-chain &DAO witness,
    //                                  cannot be spoofed by the caller
    //   Primary index queries:
    //     • All keyspaces for DAO X:  WHERE registrant_dao_id = Some(X)
    //     • Keyspace by ID:           WHERE id = Y
    //
    // AccessGranted
    //   Emitted by: create_keyspace (×3 for Grant/Read/Write),
    //               create_keyspace_for_dao (once per seeded principal × role),
    //               grant, multi_grant
    //   Fields:
    //     keyspace_id — parent Keyspace
    //     role        — Grant | Read | Write
    //     principal   — Player { addr } or Ou { dao_id }
    //     by          — address of the caller who performed the grant
    //   Primary index queries:
    //     • Current role-R members of keyspace K:
    //         AccessGranted(keyspace_id=K, role=R) − AccessRevoked(keyspace_id=K, role=R)
    //     • All keyspaces where address A holds Read:
    //         WHERE role=Read AND principal=Player{addr=A}
    //     • All keyspaces where DAO D holds any role:
    //         WHERE principal=Ou{dao_id=D}
    //   Note: only emitted on real state changes — add_principal is a no-op
    //   (returns false) for duplicates, so no spurious events are produced.
    //
    // AccessRevoked
    //   Emitted by: revoke, multi_revoke
    //   Fields:
    //     keyspace_id — parent Keyspace
    //     role        — Grant | Read | Write
    //     principal   — the principal being removed
    //     by          — caller address
    //   Note: only emitted on real state changes.  A Read revocation always
    //   accompanies a version increment (see version reconstruction below).
    //
    // EntryPublished
    //   Emitted by: publish_entry
    //   Fields:
    //     entry_id    — EncryptedEntry object ID (primary key)
    //     keyspace_id — parent Keyspace
    //     uri         — initial off-chain blob URI (e.g. Walrus/IPFS CID)
    //     created_by  — address of the Write-role caller
    //   Primary index queries:
    //     • All entries for keyspace K:  WHERE keyspace_id = K
    //     • Current URI for entry E:     latest EntryUpdated or EntryEdited
    //                                    for that entry_id, falling back to
    //                                    this event's uri if neither exists
    //
    // EntryUpdated
    //   Emitted by: update_entry (key rotation — blob re-encrypted after
    //               Read membership change)
    //   Fields:
    //     entry_id    — EncryptedEntry being updated
    //     keyspace_id — parent Keyspace
    //     new_uri     — URI of the re-encrypted blob
    //     new_epoch   — keyspace version at time of re-encryption
    //     by          — caller address
    //   Note: only emitted when entry.epoch != keyspace.version.  new_epoch
    //   equals keyspace.version after the call.  Cross-check new_epoch against
    //   the reconstructed version counter to detect out-of-order indexing.
    //
    // EntryEdited
    //   Emitted by: edit_entry (same-epoch URI change, no key rotation)
    //   Fields:
    //     entry_id    — EncryptedEntry being edited
    //     keyspace_id — parent Keyspace
    //     new_uri     — updated URI (content changed, encryption key unchanged)
    //     by          — caller address
    //   Note: epoch is NOT incremented.  Distinct from EntryUpdated so the
    //   indexer can tell content changes from key-rotation changes.
    //
    // EntryDescriptionEdited
    //   Emitted by: edit_description
    //   Fields:
    //     entry_id        — EncryptedEntry being edited
    //     keyspace_id     — parent Keyspace
    //     new_description — updated label
    //     by              — caller address
    //
    // ── State reconstruction ─────────────────────────────────────────────────
    //
    // Keyspace row
    //   KeyspaceCreated → INSERT (id, name, registrant_dao_id, version=0)
    //
    // ACL (per keyspace, per role)
    //   AccessGranted  → UPSERT principal into role membership set
    //   AccessRevoked  → REMOVE principal from role membership set
    //
    // Version counter (re-encryption epoch — not emitted standalone)
    //   AccessGranted(role=Read) → version += 1
    //   AccessRevoked(role=Read) → version += 1
    //   EntryUpdated.new_epoch reflects the keyspace version at rotation time
    //   and can be used to cross-check the reconstructed counter.
    //
    // Entry row (per EncryptedEntry)
    //   EntryPublished         → INSERT (entry_id, keyspace_id, uri, created_by,
    //                                    epoch=version_at_publish)
    //   EntryUpdated           → UPDATE uri=new_uri, epoch=new_epoch
    //   EntryEdited            → UPDATE uri=new_uri          (epoch unchanged)
    //   EntryDescriptionEdited → UPDATE description=new_description
    //
    // ── Suggested indexer endpoints ──────────────────────────────────────────
    //
    //   GET /v1/dao/:dao_id/keyspaces
    //     → KeyspaceCreated WHERE registrant_dao_id = dao_id
    //
    //   GET /v1/keyspace/:keyspace_id/acl
    //     → current principals per role
    //       (AccessGranted minus AccessRevoked, grouped by role)
    //
    //   GET /v1/keyspace/:keyspace_id/entries
    //     → EntryPublished + latest EntryUpdated / EntryEdited /
    //       EntryDescriptionEdited per entry_id
    //
    //   GET /v1/address/:addr/keyspaces?role=Read
    //     → AccessGranted WHERE role=Read AND principal=Player{addr}
    //       minus AccessRevoked for the same (addr, keyspace_id, role) tuples

    // ── v2 principal ACL events ──────────────────────────────────────────────
    //
    //   AccessGrantedV2 { keyspace_id, role, principal: PrincipalV2, by }
    //     → INSERT principal_kind = kind_name(principal.kind),
    //              principal_value = principal.id
    //   AccessRevokedV2 { keyspace_id, role, principal, by }
    //     → mark the matching grant inactive
    //
    //   kind_name: 0 → 'player', 1 → 'ou', 2 → 'machine'.  Later upgrades add
    //   kinds without new event types, so indexers should map unknown kinds to
    //   a stable fallback (e.g. 'kind_<n>') and keep ingesting rather than
    //   dropping the row.  `principal.data` is empty for all current kinds.
    //
    //   v2 principals live in a versioned dynamic field on the Keyspace UID,
    //   not in the object's `acl` field — the object JSON never shows them, so
    //   these events (plus the DF read) are the only sources.  Both ACLs are
    //   live simultaneously; a keyspace's effective principal set for a role is
    //   the union of the v1 and v2 sets:
    //
    //   GET /v1/address/:addr/keyspaces?role=Read additionally matches
    //     → AccessGrantedV2 WHERE role=Read AND principal.id=addr
    //       minus AccessRevokedV2 for the same (principal, keyspace_id, role)

    // ── Entry functions ──────────────────────────────────────────────────────

    /// Create a new Keyspace (shared).  Creator is seeded into all three roles.
    public fun create_keyspace(name: vector<u8>, ctx: &mut TxContext) {
        let uid = object::new(ctx);
        let keyspace_id = uid.to_inner();
        let creator = acl::player(ctx.sender());

        let mut acl_map = vec_map::empty<Role, vector<Principal>>();
        acl_map.insert(Role::Grant, vector[creator]);
        acl_map.insert(Role::Read, vector[creator]);
        acl_map.insert(Role::Write, vector[creator]);

        event::emit(KeyspaceCreated {
            id: keyspace_id,
            creator,
            name: name.to_string(),
            registrant_dao_id: option::none(),
        });
        let sender = ctx.sender();
        event::emit(AccessGranted {
            keyspace_id,
            role: Role::Grant,
            principal: creator,
            by: sender,
        });
        event::emit(AccessGranted {
            keyspace_id,
            role: Role::Read,
            principal: creator,
            by: sender,
        });
        event::emit(AccessGranted {
            keyspace_id,
            role: Role::Write,
            principal: creator,
            by: sender,
        });

        transfer::share_object(Keyspace {
            id: uid,
            acl: acl_map,
            name: name.to_string(),
            version: 0,
            entries: vector::empty(),
        });
    }

    /// Create a new Keyspace on behalf of a DAO (shared).
    ///
    /// The caller must be a governance member of `dao`; the DAO's on-chain ID
    /// is recorded in `KeyspaceCreated.registrant_dao_id` so an indexer can
    /// answer "all keyspaces for DAO X" without replaying full Grant-role lists.
    /// Because `registrant_dao_id` is derived from the `&DAO` witness (not from
    /// caller input), it cannot be spoofed.
    ///
    /// `grant_principals` must be non-empty — it becomes the Grant role, which
    /// is the only admin path into the keyspace.  `read_principals` and
    /// `write_principals` may be empty and populated later via `grant`.
    ///
    /// This mirrors the `initialize_dao_vault` pattern in `dao_receipt_vault`:
    /// callers can express "officers hold Grant, members hold Read/Write" in a
    /// single call by passing different principal lists per role.
    public fun create_keyspace_for_dao(
        name: vector<u8>,
        dao: &DAO,
        grant_principals: vector<Principal>,
        read_principals: vector<Principal>,
        write_principals: vector<Principal>,
        ctx: &mut TxContext,
    ) {
        assert!(dao.is_governance_member(ctx.sender()), ENotAllowed);
        assert!(!grant_principals.is_empty(), EEmptyGrantPrincipals);

        let uid = object::new(ctx);
        let keyspace_id = uid.to_inner();
        let registrant_dao_id = dao.id();
        let creator = acl::ou(registrant_dao_id);
        let sender = ctx.sender();

        let mut acl_map = vec_map::empty<Role, vector<Principal>>();
        acl_map.insert(Role::Grant, grant_principals);
        if (!read_principals.is_empty()) {
            acl_map.insert(Role::Read, read_principals);
        };
        if (!write_principals.is_empty()) {
            acl_map.insert(Role::Write, write_principals);
        };

        event::emit(KeyspaceCreated {
            id: keyspace_id,
            creator,
            name: name.to_string(),
            registrant_dao_id: option::some(registrant_dao_id),
        });

        // Emit AccessGranted for every seeded principal so event-sourced ACL
        // reconstructions don't need to special-case the init path.
        let mut role_idx = 0;
        while (role_idx < acl_map.length()) {
            let (role, principals) = acl_map.get_entry_by_idx(role_idx);
            let n = principals.length();
            let mut i = 0;
            while (i < n) {
                event::emit(AccessGranted {
                    keyspace_id,
                    role: *role,
                    principal: principals[i],
                    by: sender,
                });
                i = i + 1;
            };
            role_idx = role_idx + 1;
        };

        transfer::share_object(Keyspace {
            id: uid,
            acl: acl_map,
            name: name.to_string(),
            version: 0,
            entries: vector::empty(),
        });
    }

    /// Grant `principal` the `role`.  Caller must satisfy `Grant`.
    /// Bumps `version` when the `Read` set changes.
    public fun grant(
        keyspace: &mut Keyspace,
        role: Role,
        principal: Principal,
        dao: &DAO,
        ctx: &TxContext,
    ) {
        assert!(satisfies_role(keyspace, Role::Grant, dao, ctx.sender()), ENotAllowed);
        let changed = add_principal(keyspace, role, principal);
        assert!(changed, EAlreadyGranted);
        if (role == Role::Read) { keyspace.version = keyspace.version + 1 };
        event::emit(AccessGranted {
            keyspace_id: keyspace.id.to_inner(),
            role,
            principal,
            by: ctx.sender(),
        });
    }

    /// Grant `principal` every role in `roles` in one call.  Caller must satisfy `Grant`.
    /// Bumps `version` once per `Read` role added.  Aborts if any role is already held.
    public fun multi_grant(
        keyspace: &mut Keyspace,
        roles: vector<Role>,
        principal: Principal,
        dao: &DAO,
        ctx: &TxContext,
    ) {
        assert!(satisfies_role(keyspace, Role::Grant, dao, ctx.sender()), ENotAllowed);
        let n = roles.length();
        let mut i = 0;
        while (i < n) {
            let role = roles[i];
            let changed = add_principal(keyspace, role, principal);
            assert!(changed, EAlreadyGranted);
            if (role == Role::Read) { keyspace.version = keyspace.version + 1 };
            event::emit(AccessGranted {
                keyspace_id: keyspace.id.to_inner(),
                role,
                principal,
                by: ctx.sender(),
            });
            i = i + 1;
        };
    }

    /// Revoke `principal` from `role`.  Caller must satisfy `Grant`.
    /// Bumps `version` when the `Read` set changes.  Cannot remove the last
    /// `Grant` principal (would brick the keyspace).
    public fun revoke(
        keyspace: &mut Keyspace,
        role: Role,
        principal: Principal,
        dao: &DAO,
        ctx: &TxContext,
    ) {
        assert!(satisfies_role(keyspace, Role::Grant, dao, ctx.sender()), ENotAllowed);
        let changed = remove_principal(keyspace, role, principal);
        assert!(changed, ENotGranted);
        // Guards count both stores (see `role_count`): a v2 grant can cover a
        // removed v1 one, which is what makes migrating a role off the frozen
        // v1 store possible at all.
        if (role == Role::Grant) {
            assert!(role_count(keyspace, Role::Grant) > 0, ELastGrantor);
        };
        if (role == Role::Write) {
            assert!(role_count(keyspace, Role::Write) > 0, ELastWriter);
        };
        if (role == Role::Read) {
            assert!(role_count(keyspace, Role::Read) > 0, ELastReader);
            keyspace.version = keyspace.version + 1;
        };
        event::emit(AccessRevoked {
            keyspace_id: keyspace.id.to_inner(),
            role,
            principal,
            by: ctx.sender(),
        });
    }

    /// Revoke `principal` from every role in `roles` in one call.  Caller must satisfy `Grant`.
    /// Applies last-principal guards and bumps `version` per `Read` removal.  Aborts if any
    /// role is not currently held.
    public fun multi_revoke(
        keyspace: &mut Keyspace,
        roles: vector<Role>,
        principal: Principal,
        dao: &DAO,
        ctx: &TxContext,
    ) {
        assert!(satisfies_role(keyspace, Role::Grant, dao, ctx.sender()), ENotAllowed);
        let n = roles.length();
        let mut i = 0;
        while (i < n) {
            let role = roles[i];
            let changed = remove_principal(keyspace, role, principal);
            assert!(changed, ENotGranted);
            if (role == Role::Grant) {
                assert!(role_count(keyspace, Role::Grant) > 0, ELastGrantor);
            };
            if (role == Role::Write) {
                assert!(role_count(keyspace, Role::Write) > 0, ELastWriter);
            };
            if (role == Role::Read) {
                assert!(role_count(keyspace, Role::Read) > 0, ELastReader);
                keyspace.version = keyspace.version + 1;
            };
            event::emit(AccessRevoked {
                keyspace_id: keyspace.id.to_inner(),
                role,
                principal,
                by: ctx.sender(),
            });
            i = i + 1;
        };
    }

    // ── Upgradeable principal ACL (v2) ───────────────────────────────────────
    //
    // Same ACL model as `Keyspace.acl` — principals grouped by role, evaluated
    // by `acl::satisfies*` — but holding `acl::PrincipalV2`, whose kind is data
    // rather than an enum variant.  That is what makes new principal kinds
    // (starting with `machine`) possible: adding one is a constant plus a
    // `satisfies_v2` arm, never a layout change.
    //
    // It lives in a dynamic field rather than a new `Keyspace` field only
    // because struct layouts are frozen by Sui's upgrade compatibility, exactly
    // as enum variants are.  Semantically this is the keyspace's ACL, v2: the
    // two stores are read together everywhere (`satisfies_role`), role
    // invariants span both, and `Read` changes bump `version` identically.
    //
    // Upgrade-in-place recipe (the template for future extensions): the DF
    // value is a `sui::versioned::Versioned` wrapping the payload.  To evolve:
    //   1. add `PrincipalAclV2 { .. } has store`, bump PRINCIPAL_ACL_VERSION,
    //   2. migrate lazily on first mutation inside `principal_acl_mut`:
    //      `versioned::remove_value_for_upgrade` → build V2 → `versioned::upgrade`,
    //   3. teach the read path (`principals_v2`) to answer for both versions
    //      until migration saturates.
    // Read paths tolerate every historical version; only mutations migrate.
    // Versions newer than this code answer "no access" — fail closed.

    const PRINCIPAL_ACL_VERSION: u64 = 1;

    /// Dynamic-field key under `Keyspace.id` for the v2 principal ACL.
    public struct PrincipalAclKey has copy, drop, store {}

    /// Version 1 payload: the same role → principals shape as `Keyspace.acl`,
    /// over the upgradeable `PrincipalV2`.
    public struct PrincipalAclV1 has store {
        acl: VecMap<Role, vector<PrincipalV2>>,
    }

    /// v2 twin of `AccessGranted`.  Carries the whole principal, so one event
    /// type serves every present and future kind — indexers derive
    /// `principal_kind` from `acl::v2_kind` rather than the event name.
    public struct AccessGrantedV2 has copy, drop {
        keyspace_id: ID,
        role: Role,
        principal: PrincipalV2,
        by: address,
    }

    /// v2 twin of `AccessRevoked`.
    public struct AccessRevokedV2 has copy, drop {
        keyspace_id: ID,
        role: Role,
        principal: PrincipalV2,
        by: address,
    }

    /// Grant `principal` the `role`, in the v2 store.  Caller must satisfy
    /// `Grant`.  Accepts every principal kind — `player_v2`, `ou_v2`,
    /// `machine_v2`, and whatever kinds later upgrades add.  Bumps `version`
    /// when the `Read` set changes, exactly like `grant`.
    public fun grant_v2(
        keyspace: &mut Keyspace,
        role: Role,
        principal: PrincipalV2,
        dao: &DAO,
        ctx: &mut TxContext,
    ) {
        assert!(satisfies_role(keyspace, Role::Grant, dao, ctx.sender()), ENotAllowed);
        if (!df::exists_(&keyspace.id, PrincipalAclKey {})) {
            df::add(
                &mut keyspace.id,
                PrincipalAclKey {},
                versioned::create(
                    PRINCIPAL_ACL_VERSION,
                    PrincipalAclV1 { acl: vec_map::empty() },
                    ctx,
                ),
            );
        };
        {
            let store = principal_acl_mut(keyspace);
            if (!store.acl.contains(&role)) {
                store.acl.insert(role, vector[principal]);
            } else {
                let list = store.acl.get_mut(&role);
                assert!(!list.contains(&principal), EAlreadyGranted);
                list.push_back(principal);
            };
        };
        if (role == Role::Read) { keyspace.version = keyspace.version + 1 };
        event::emit(AccessGrantedV2 {
            keyspace_id: keyspace.id.to_inner(),
            role,
            principal,
            by: ctx.sender(),
        });
    }

    /// Revoke `principal` from `role` in the v2 store.  Caller must satisfy
    /// `Grant`.  Last-principal guards count both stores, so the v1 grant of a
    /// role can cover for a removed v2 one and vice versa.
    public fun revoke_v2(
        keyspace: &mut Keyspace,
        role: Role,
        principal: PrincipalV2,
        dao: &DAO,
        ctx: &TxContext,
    ) {
        assert!(satisfies_role(keyspace, Role::Grant, dao, ctx.sender()), ENotAllowed);
        assert!(df::exists_(&keyspace.id, PrincipalAclKey {}), ENotGranted);
        {
            let store = principal_acl_mut(keyspace);
            assert!(store.acl.contains(&role), ENotGranted);
            let list = store.acl.get_mut(&role);
            let (found, idx) = list.index_of(&principal);
            assert!(found, ENotGranted);
            list.remove(idx);
        };
        if (role == Role::Grant) {
            assert!(role_count(keyspace, Role::Grant) > 0, ELastGrantor);
        };
        if (role == Role::Write) {
            assert!(role_count(keyspace, Role::Write) > 0, ELastWriter);
        };
        if (role == Role::Read) {
            assert!(role_count(keyspace, Role::Read) > 0, ELastReader);
            keyspace.version = keyspace.version + 1;
        };
        event::emit(AccessRevokedV2 {
            keyspace_id: keyspace.id.to_inner(),
            role,
            principal,
            by: ctx.sender(),
        });
    }

    /// v2 principals holding `role` (empty when the store is absent, or its
    /// stored version is newer than this code understands — fail closed).
    public fun principals_v2(keyspace: &Keyspace, role: Role): vector<PrincipalV2> {
        if (!df::exists_(&keyspace.id, PrincipalAclKey {})) { return vector[] };
        let v: &Versioned = df::borrow(&keyspace.id, PrincipalAclKey {});
        if (v.version() != PRINCIPAL_ACL_VERSION) { return vector[] };
        let store: &PrincipalAclV1 = v.load_value();
        if (store.acl.contains(&role)) { *store.acl.get(&role) } else { vector[] }
    }

    /// Total principals holding `role` across both stores.  Role invariants
    /// (last grantor / writer / reader) are defined over this, not one store.
    public fun role_count(keyspace: &Keyspace, role: Role): u64 {
        let v1 = if (keyspace.acl.contains(&role)) {
            keyspace.acl.get(&role).length()
        } else { 0 };
        v1 + principals_v2(keyspace, role).length()
    }

    /// Mutable access to the current-version v2 payload.  The single place
    /// future schema migrations happen (see the recipe above).
    fun principal_acl_mut(keyspace: &mut Keyspace): &mut PrincipalAclV1 {
        let v: &mut Versioned = df::borrow_mut(&mut keyspace.id, PrincipalAclKey {});
        assert!(v.version() == PRINCIPAL_ACL_VERSION, EUnknownPrincipalAclVersion);
        v.load_value_mut()
    }

    /// Called by the Seal key-server inside a PTB to gate decryption-key release.
    /// Requires the `Read` role.
    entry fun seal_approve(id: vector<u8>, keyspace: &Keyspace, dao: &DAO, ctx: &TxContext) {
        let keyspace_bytes = object::uid_to_bytes(&keyspace.id);
        let mut i = 0;
        while (i < 32) {
            assert!(keyspace_bytes[i] == id[i], ENotAllowed);
            i = i + 1;
        };
        assert!(satisfies_role(keyspace, Role::Read, dao, ctx.sender()), ENotAllowed);
    }

    /// Publish a new encrypted entry.  Requires the `Write` role.
    public fun publish_entry(
        keyspace: &mut Keyspace,
        uri: vector<u8>,
        description: vector<u8>,
        dao: &DAO,
        ctx: &mut TxContext,
    ) {
        let creator = ctx.sender();
        assert!(satisfies_role(keyspace, Role::Write, dao, creator), ENotAllowed);
        let uid = object::new(ctx);
        let entry_id = uid.to_inner();
        let uri_str = uri.to_string();
        keyspace.entries.push_back(entry_id);
        event::emit(EntryPublished {
            entry_id,
            keyspace_id: keyspace.id.to_inner(),
            uri: uri_str,
            created_by: creator,
        });
        transfer::share_object(EncryptedEntry {
            id: uid,
            keyspace_id: keyspace.id.to_inner(),
            uri: uri_str,
            description: description.to_string(),
            created_by: creator,
            epoch: keyspace.version,
        });
    }

    /// Re-encrypt an entry with a new URI (key rotation).  Requires `Write`.
    /// Entry epoch must be stale (not equal to current version).
    public fun update_entry(
        keyspace: &Keyspace,
        entry: &mut EncryptedEntry,
        new_uri: vector<u8>,
        dao: &DAO,
        ctx: &TxContext,
    ) {
        assert!(satisfies_role(keyspace, Role::Write, dao, ctx.sender()), ENotAllowed);
        assert!(entry.keyspace_id == keyspace.id.to_inner(), EWrongKeyspace);
        assert!(entry.epoch != keyspace.version, EAlreadyCurrentEpoch);
        entry.uri = new_uri.to_string();
        entry.epoch = keyspace.version;
        event::emit(EntryUpdated {
            entry_id: entry.id.to_inner(),
            keyspace_id: keyspace.id.to_inner(),
            new_uri: entry.uri,
            new_epoch: entry.epoch,
            by: ctx.sender(),
        });
    }

    /// Update an entry's URI without key rotation (same epoch).  Requires `Write`.
    public fun edit_entry(
        keyspace: &Keyspace,
        entry: &mut EncryptedEntry,
        new_uri: vector<u8>,
        dao: &DAO,
        ctx: &TxContext,
    ) {
        assert!(satisfies_role(keyspace, Role::Write, dao, ctx.sender()), ENotAllowed);
        assert!(entry.keyspace_id == keyspace.id.to_inner(), EWrongKeyspace);
        entry.uri = new_uri.to_string();
        event::emit(EntryEdited {
            entry_id: entry.id.to_inner(),
            keyspace_id: keyspace.id.to_inner(),
            new_uri: entry.uri,
            by: ctx.sender(),
        });
    }

    /// Update an entry's description.  Requires `Write`.
    public fun edit_description(
        keyspace: &Keyspace,
        entry: &mut EncryptedEntry,
        new_description: vector<u8>,
        dao: &DAO,
        ctx: &TxContext,
    ) {
        assert!(satisfies_role(keyspace, Role::Write, dao, ctx.sender()), ENotAllowed);
        assert!(entry.keyspace_id == keyspace.id.to_inner(), EWrongKeyspace);
        entry.description = new_description.to_string();
        event::emit(EntryDescriptionEdited {
            entry_id: entry.id.to_inner(),
            keyspace_id: keyspace.id.to_inner(),
            new_description: entry.description,
            by: ctx.sender(),
        });
    }

    // ── Internal ─────────────────────────────────────────────────────────────

    /// Both principal stores are consulted here, so every consumer of this
    /// check — grant/revoke authorization, `has_role`, publish/edit gating and
    /// `seal_approve` — honors v2 principals (including `machine`) with no
    /// signature changes anywhere.
    fun satisfies_role(keyspace: &Keyspace, role: Role, dao: &DAO, sender: address): bool {
        if (keyspace.acl.contains(&role)) {
            let principals = keyspace.acl.get(&role);
            let n = principals.length();
            let mut i = 0;
            while (i < n) {
                if (acl::satisfies(&principals[i], dao, sender)) { return true };
                i = i + 1;
            };
        };
        let v2 = principals_v2(keyspace, role);
        let n2 = v2.length();
        let mut j = 0;
        while (j < n2) {
            if (acl::satisfies_v2(&v2[j], dao, sender)) { return true };
            j = j + 1;
        };
        false
    }

    fun add_principal(keyspace: &mut Keyspace, role: Role, principal: Principal): bool {
        if (!keyspace.acl.contains(&role)) {
            keyspace.acl.insert(role, vector[principal]);
            return true
        };
        let list = keyspace.acl.get_mut(&role);
        if (list.contains(&principal)) { return false };
        list.push_back(principal);
        true
    }

    fun remove_principal(keyspace: &mut Keyspace, role: Role, principal: Principal): bool {
        if (!keyspace.acl.contains(&role)) { return false };
        let list = keyspace.acl.get_mut(&role);
        let (found, idx) = list.index_of(&principal);
        if (!found) { return false };
        list.remove(idx);
        true
    }

    // ── Accessors ─────────────────────────────────────────────────────────────

    public fun name(keyspace: &Keyspace): &String { &keyspace.name }

    public fun version(keyspace: &Keyspace): u64 { keyspace.version }

    /// Returns all principals for `role` (empty vector if the role is unset).
    public fun principals(keyspace: &Keyspace, role: Role): vector<Principal> {
        if (keyspace.acl.contains(&role)) { *keyspace.acl.get(&role) } else { vector[] }
    }

    /// True if `sender` satisfies `role` on this keyspace.
    public fun has_role(keyspace: &Keyspace, role: Role, dao: &DAO, sender: address): bool {
        satisfies_role(keyspace, role, dao, sender)
    }

    public fun entry_uri(entry: &EncryptedEntry): &String { &entry.uri }

    public fun entry_description(entry: &EncryptedEntry): &String { &entry.description }

    public fun entry_epoch(entry: &EncryptedEntry): u64 { entry.epoch }

    // ── Test-only helpers ─────────────────────────────────────────────────────

    /// Create a Keyspace for testing.  Creator is seeded into all three roles.
    #[test_only]
    public fun test_create(name: vector<u8>, ctx: &mut TxContext): Keyspace {
        let uid = object::new(ctx);
        let creator = acl::player(ctx.sender());
        let mut acl_map = vec_map::empty<Role, vector<Principal>>();
        acl_map.insert(Role::Grant, vector[creator]);
        acl_map.insert(Role::Read, vector[creator]);
        acl_map.insert(Role::Write, vector[creator]);
        Keyspace {
            id: uid,
            acl: acl_map,
            name: name.to_string(),
            version: 0,
            entries: vector::empty(),
        }
    }

    /// Create a DAO-linked Keyspace for testing, bypassing the `&DAO` witness.
    /// `dao_id` is the sentinel DAO ID to embed in the ACL maps.
    #[test_only]
    public fun test_create_for_dao(
        name: vector<u8>,
        grant_principals: vector<Principal>,
        read_principals: vector<Principal>,
        write_principals: vector<Principal>,
        ctx: &mut TxContext,
    ): Keyspace {
        let mut acl_map = vec_map::empty<Role, vector<Principal>>();
        acl_map.insert(Role::Grant, grant_principals);
        if (!read_principals.is_empty()) {
            acl_map.insert(Role::Read, read_principals);
        };
        if (!write_principals.is_empty()) {
            acl_map.insert(Role::Write, write_principals);
        };
        Keyspace {
            id: object::new(ctx),
            acl: acl_map,
            name: name.to_string(),
            version: 0,
            entries: vector::empty(),
        }
    }

    #[test_only]
    public fun test_destroy(keyspace: Keyspace) {
        let Keyspace { id, acl: _, name: _, version: _, entries: _ } = keyspace;
        object::delete(id);
    }

    /// Create an EncryptedEntry for testing without checking roles or sharing it.
    #[test_only]
    public fun test_publish_entry(
        keyspace: &mut Keyspace,
        uri: vector<u8>,
        description: vector<u8>,
        ctx: &mut TxContext,
    ): EncryptedEntry {
        let creator = ctx.sender();
        let uid = object::new(ctx);
        let entry_id = uid.to_inner();
        let uri_str = uri.to_string();
        keyspace.entries.push_back(entry_id);
        EncryptedEntry {
            id: uid,
            keyspace_id: keyspace.id.to_inner(),
            uri: uri_str,
            description: description.to_string(),
            created_by: creator,
            epoch: keyspace.version,
        }
    }

    #[test_only]
    public fun test_destroy_entry(entry: EncryptedEntry) {
        let EncryptedEntry {
            id,
            keyspace_id: _,
            uri: _,
            description: _,
            created_by: _,
            epoch: _,
        } = entry;
        object::delete(id);
    }
}
