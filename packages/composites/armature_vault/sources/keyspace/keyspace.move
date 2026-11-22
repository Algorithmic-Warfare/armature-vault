/// ACL-based encryption access control — ported from loash-industries/keyspace.
///
/// Flow:
///   1. Creator calls `create_keyspace` (personal) or `create_keyspace_for_ou`
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
///     On an OU keyspace the anchor OU (below) is always a grantor.
///   - `Read`  — can call `seal_approve` (decryption gate).  Membership changes
///               bump `version`, signalling that existing entries should be
///               re-encrypted.
///   - `Write` — can call `publish_entry`, `update_entry`, `edit_entry`.
///
/// Access control uses the shared `Principal` model from `roles::acl`:
/// each list member is a bare `Player { addr }` (single wallet), a
/// `Machine { addr }` (single service/bot key), or an `Ou { ou_id }` (any board
/// member of that OU), checked via `acl::satisfies`.
///
/// OU-linked keyspaces (`create_keyspace_for_ou`) emit `registrant_ou_id` in
/// `KeyspaceCreated` so an indexer can answer "all keyspaces for OU X" without
/// scanning every Grant-role membership list.  The `&OU` witness + governance-
/// member check makes that association unspoofable.  It does not say who
/// controls the keyspace: any one board member of X can create a keyspace for X
/// anchored to an OU of their choosing.  Clients listing X's keyspaces must also
/// check the anchor (`AnchorSet` / `anchor_ou_id`) against the OU they trust.
///
/// Anchor (ARMATURE-46): an OU keyspace has one anchor OU, always on `Grant`,
/// that nobody can revoke (`EAnchorNotRevocable`).  An `Ou` principal is
/// satisfied by any one board member, so without it a single member could list
/// a principal they alone control (their own `Player`, or an OU they created
/// with themselves as its only member), revoke the board's OU, and keep reading
/// and granting after the board removes them.  With it, the board can always
/// revoke what a removed member granted.  The anchor moves only through
/// `rotate_anchor_to_successor`, to the successor the anchor OU recorded by vote
/// when it began migrating.  Personal keyspaces have no anchor.  A `Grant`
/// holder is still trusted while it holds `Grant`: it can read everything
/// published before the board acts.
module armature_vault::keyspace {
    use armature::ou::OU;
    use roles::acl::{Self as acl, Principal};
    use std::{option::{Self, Option}, string::String};
    use sui::{event, vec_map::{Self, VecMap}};

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
    // 8 (EEmptyGrantPrincipals) is retired: an OU keyspace always has its anchor on Grant.
    const EAnchorNotRevocable: u64 = 9;
    const EAnchorMismatch: u64 = 10;
    const EAnchorNotMigrating: u64 = 11;
    const ENotSuccessor: u64 = 12;

    // ── Objects ──────────────────────────────────────────────────────────────

    /// Shared object — the on-chain access-control registry.
    public struct Keyspace has key {
        id: UID,
        acl: VecMap<Role, vector<Principal>>,
        name: String,
        /// Incremented whenever the `Read` membership set changes.  Clients use
        /// this to detect when existing entries need re-encryption.
        version: u64,
        /// The OU always on `Grant` (see the module doc).  None for personal
        /// keyspaces.  Changed only by `rotate_anchor_to_successor`.
        anchor_ou_id: Option<ID>,
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
        /// None for personal keyspaces; Some(ou_id) for org-linked keyspaces
        /// created via `create_keyspace_for_ou`.  The OU ID is derived from
        /// the on-chain `&OU` witness — not supplied by the caller — so it
        /// cannot be spoofed.
        registrant_ou_id: Option<ID>,
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
    /// Emitted when an OU keyspace's anchor is set: at creation
    /// (`previous_anchor_ou_id` none) and by `rotate_anchor_to_successor`.
    public struct AnchorSet has copy, drop {
        keyspace_id: ID,
        anchor_ou_id: ID,
        previous_anchor_ou_id: Option<ID>,
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
    //   Emitted by: create_keyspace, create_keyspace_for_ou
    //   Fields:
    //     id                — Keyspace object ID (primary key)
    //     creator           — Principal who created it (Player or Ou; never Machine)
    //     name              — human-readable label
    //     registrant_ou_id — Option<ID>:
    //                           None → personal keyspace (create_keyspace)
    //                           Some → OU-linked (create_keyspace_for_ou);
    //                                  derived from on-chain &OU witness,
    //                                  cannot be spoofed by the caller
    //   Primary index queries:
    //     • All keyspaces for OU X:  WHERE registrant_ou_id = Some(X)
    //                                AND current anchor (AnchorSet) is trusted
    //     • Keyspace by ID:           WHERE id = Y
    //
    // AccessGranted
    //   Emitted by: create_keyspace (×3 for Grant/Read/Write),
    //               create_keyspace_for_ou (once per seeded principal × role,
    //               the anchor included), grant, multi_grant,
    //               rotate_anchor_to_successor (if the successor wasn't on Grant)
    //   Fields:
    //     keyspace_id — parent Keyspace
    //     role        — Grant | Read | Write
    //     principal   — Player { addr }, Machine { addr } or Ou { ou_id }
    //     by          — address of the caller who performed the grant
    //   Primary index queries:
    //     • Current role-R members of keyspace K:
    //         AccessGranted(keyspace_id=K, role=R) − AccessRevoked(keyspace_id=K, role=R)
    //     • All keyspaces where address A holds Read:
    //         WHERE role=Read AND principal=Player{addr=A}
    //     • All keyspaces where OU D holds any role:
    //         WHERE principal=Ou{ou_id=D}
    //   Note: only emitted on real state changes — add_principal is a no-op
    //   (returns false) for duplicates, so no spurious events are produced.
    //
    // AnchorSet
    //   Emitted by: create_keyspace_for_ou, rotate_anchor_to_successor
    //   Fields: keyspace_id, anchor_ou_id, previous_anchor_ou_id (None at
    //   creation), by.  The anchor is always also on Grant: creation emits its
    //   AccessGranted, and rotation emits one if the successor wasn't listed.
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
    //   KeyspaceCreated → INSERT (id, name, registrant_ou_id, version=0)
    //
    // ACL (per keyspace, per role)
    //   AccessGranted  → UPSERT principal into role membership set
    //   AccessRevoked  → REMOVE principal from role membership set
    //
    // Version counter (re-encryption epoch — not emitted standalone)
    //   AccessGranted(role=Read) → version += 1, except the grants emitted in
    //                              the KeyspaceCreated transaction (version
    //                              starts at 0 whatever the seeded readers)
    //   AccessRevoked(role=Read) → version += 1
    //   Or read the on-chain `version` directly.
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
    //   GET /v1/org/:ou_id/keyspaces
    //     → KeyspaceCreated WHERE registrant_ou_id = ou_id, with the current
    //       anchor so clients can drop keyspaces anchored to an untrusted OU
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
            registrant_ou_id: option::none(),
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
            anchor_ou_id: option::none(),
        });
    }

    /// Create a new Keyspace on behalf of an OU (shared).
    ///
    /// The caller must be a governance member of `org`; the OU's on-chain ID
    /// is recorded in `KeyspaceCreated.registrant_ou_id` so an indexer can
    /// answer "all keyspaces for OU X" without replaying full Grant-role lists.
    /// Because `registrant_ou_id` is derived from the `&OU` witness (not from
    /// caller input), it cannot be spoofed.  The anchor, which controls the
    /// keyspace, is the caller's choice: clients must check it too.
    ///
    /// `anchor_org` becomes the anchor: listed first on Grant and never
    /// revocable (see the module doc).  `grant_principals` are extra grantors;
    /// duplicates in any list are dropped.  `read_principals` and
    /// `write_principals` may be empty and populated later via `grant`.  Any of
    /// the three lists may be empty.
    ///
    /// This mirrors the `initialize_ou_vault` pattern in `ou_receipt_vault`:
    /// callers can express "officers hold Grant, members hold Read/Write" in a
    /// single call by passing the officers as `anchor_org` and the members in
    /// the Read/Write lists.
    public fun create_keyspace_for_ou(
        name: vector<u8>,
        org: &OU,
        anchor_org: &OU,
        grant_principals: vector<Principal>,
        read_principals: vector<Principal>,
        write_principals: vector<Principal>,
        ctx: &mut TxContext,
    ) {
        assert!(org.is_governance_member(ctx.sender()), ENotAllowed);

        let uid = object::new(ctx);
        let keyspace_id = uid.to_inner();
        let registrant_ou_id = org.id();
        let creator = acl::ou(registrant_ou_id);
        let sender = ctx.sender();

        let anchor_ou_id = anchor_org.id();
        let mut acl_map = vec_map::empty<Role, vector<Principal>>();
        // Each role's list is a set: `remove_principal` removes one copy, so a
        // duplicate seeded here would survive a revoke.
        acl_map.insert(Role::Grant, with_anchor_first(anchor_ou_id, grant_principals));
        if (!read_principals.is_empty()) {
            acl_map.insert(Role::Read, dedup(read_principals));
        };
        if (!write_principals.is_empty()) {
            acl_map.insert(Role::Write, dedup(write_principals));
        };

        event::emit(KeyspaceCreated {
            id: keyspace_id,
            creator,
            name: name.to_string(),
            registrant_ou_id: option::some(registrant_ou_id),
        });
        event::emit(AnchorSet {
            keyspace_id,
            anchor_ou_id,
            previous_anchor_ou_id: option::none(),
            by: sender,
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
            anchor_ou_id: option::some(anchor_ou_id),
        });
    }

    /// Grant `principal` the `role`.  Caller must satisfy `Grant`.
    /// Bumps `version` when the `Read` set changes.
    public fun grant(
        keyspace: &mut Keyspace,
        role: Role,
        principal: Principal,
        org: &OU,
        ctx: &TxContext,
    ) {
        assert!(satisfies_role(keyspace, Role::Grant, org, ctx.sender()), ENotAllowed);
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
        org: &OU,
        ctx: &TxContext,
    ) {
        assert!(satisfies_role(keyspace, Role::Grant, org, ctx.sender()), ENotAllowed);
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
    /// `Grant` principal (would brick the keyspace), nor the anchor from `Grant`
    /// (`EAnchorNotRevocable`).
    public fun revoke(
        keyspace: &mut Keyspace,
        role: Role,
        principal: Principal,
        org: &OU,
        ctx: &TxContext,
    ) {
        assert!(satisfies_role(keyspace, Role::Grant, org, ctx.sender()), ENotAllowed);
        assert_not_anchor(keyspace, role, &principal);
        let changed = remove_principal(keyspace, role, principal);
        assert!(changed, ENotGranted);
        if (role == Role::Grant) {
            let grant_list = keyspace.acl.get(&Role::Grant);
            assert!(grant_list.length() > 0, ELastGrantor);
        };
        if (role == Role::Write) {
            let write_list = keyspace.acl.get(&Role::Write);
            assert!(write_list.length() > 0, ELastWriter);
        };
        if (role == Role::Read) {
            let read_list = keyspace.acl.get(&Role::Read);
            assert!(read_list.length() > 0, ELastReader);
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
    /// Applies last-principal and anchor guards and bumps `version` per `Read` removal.
    /// Aborts if any role is not currently held.
    public fun multi_revoke(
        keyspace: &mut Keyspace,
        roles: vector<Role>,
        principal: Principal,
        org: &OU,
        ctx: &TxContext,
    ) {
        assert!(satisfies_role(keyspace, Role::Grant, org, ctx.sender()), ENotAllowed);
        let n = roles.length();
        let mut i = 0;
        while (i < n) {
            let role = roles[i];
            assert_not_anchor(keyspace, role, &principal);
            let changed = remove_principal(keyspace, role, principal);
            assert!(changed, ENotGranted);
            if (role == Role::Grant) {
                let grant_list = keyspace.acl.get(&Role::Grant);
                assert!(grant_list.length() > 0, ELastGrantor);
            };
            if (role == Role::Write) {
                let write_list = keyspace.acl.get(&Role::Write);
                assert!(write_list.length() > 0, ELastWriter);
            };
            if (role == Role::Read) {
                let read_list = keyspace.acl.get(&Role::Read);
                assert!(read_list.length() > 0, ELastReader);
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

    /// Move an OU keyspace's anchor to the successor the anchor OU recorded when
    /// it began migrating, and list the successor on `Grant`.  Permissionless:
    /// the authority is the anchor OU's own vote, which set
    /// `OUStatus::Migrating { successor_ou_id }`.  The old OU stays on `Grant` as
    /// an ordinary principal; the successor's board revokes it when ready.
    ///
    /// Call it before the old OU's last `TransferAssets`: once its treasury and
    /// capability vault are empty, anyone may destroy it, and a destroyed anchor
    /// can't be passed here.
    ///
    /// Aborts `EAnchorMismatch` unless `anchor_org` is the anchor (a personal
    /// keyspace has none), `EAnchorNotMigrating` unless it is migrating, and
    /// `ENotSuccessor` unless `successor_org` is its recorded successor.
    public fun rotate_anchor_to_successor(
        keyspace: &mut Keyspace,
        anchor_org: &OU,
        successor_org: &OU,
        ctx: &TxContext,
    ) {
        let previous = anchor_org.id();
        assert!(keyspace.anchor_ou_id == option::some(previous), EAnchorMismatch);
        let status = anchor_org.status();
        assert!(status.is_migrating(), EAnchorNotMigrating);
        let successor_ou_id = successor_org.id();
        assert!(status.successor_ou_id() == successor_ou_id, ENotSuccessor);

        let keyspace_id = keyspace.id.to_inner();
        let sender = ctx.sender();
        keyspace.anchor_ou_id = option::some(successor_ou_id);
        let principal = acl::ou(successor_ou_id);
        if (add_principal(keyspace, Role::Grant, principal)) {
            event::emit(AccessGranted { keyspace_id, role: Role::Grant, principal, by: sender });
        };
        event::emit(AnchorSet {
            keyspace_id,
            anchor_ou_id: successor_ou_id,
            previous_anchor_ou_id: option::some(previous),
            by: sender,
        });
    }

    /// Called by the Seal key-server inside a PTB to gate decryption-key release.
    /// Requires the `Read` role.
    entry fun seal_approve(id: vector<u8>, keyspace: &Keyspace, org: &OU, ctx: &TxContext) {
        let keyspace_bytes = object::uid_to_bytes(&keyspace.id);
        let mut i = 0;
        while (i < 32) {
            assert!(keyspace_bytes[i] == id[i], ENotAllowed);
            i = i + 1;
        };
        assert!(satisfies_role(keyspace, Role::Read, org, ctx.sender()), ENotAllowed);
    }

    /// Publish a new encrypted entry.  Requires the `Write` role.
    public fun publish_entry(
        keyspace: &Keyspace,
        uri: vector<u8>,
        description: vector<u8>,
        org: &OU,
        ctx: &mut TxContext,
    ) {
        let creator = ctx.sender();
        assert!(satisfies_role(keyspace, Role::Write, org, creator), ENotAllowed);
        let uid = object::new(ctx);
        let entry_id = uid.to_inner();
        let uri_str = uri.to_string();
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
        org: &OU,
        ctx: &TxContext,
    ) {
        assert!(satisfies_role(keyspace, Role::Write, org, ctx.sender()), ENotAllowed);
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
        org: &OU,
        ctx: &TxContext,
    ) {
        assert!(satisfies_role(keyspace, Role::Write, org, ctx.sender()), ENotAllowed);
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
        org: &OU,
        ctx: &TxContext,
    ) {
        assert!(satisfies_role(keyspace, Role::Write, org, ctx.sender()), ENotAllowed);
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

    fun satisfies_role(keyspace: &Keyspace, role: Role, org: &OU, sender: address): bool {
        if (!keyspace.acl.contains(&role)) { return false };
        let principals = keyspace.acl.get(&role);
        let n = principals.length();
        let mut i = 0;
        while (i < n) {
            if (acl::satisfies(&principals[i], org, sender)) { return true };
            i = i + 1;
        };
        false
    }

    /// Abort if `(role, principal)` is the anchor's place on `Grant`.
    fun assert_not_anchor(keyspace: &Keyspace, role: Role, principal: &Principal) {
        if (role != Role::Grant || keyspace.anchor_ou_id.is_none()) return;
        assert!(*principal != acl::ou(*keyspace.anchor_ou_id.borrow()), EAnchorNotRevocable);
    }

    /// `Ou { anchor_ou_id }` followed by `principals`, without duplicates.
    fun with_anchor_first(anchor_ou_id: ID, principals: vector<Principal>): vector<Principal> {
        let mut out = vector[acl::ou(anchor_ou_id)];
        principals.do!(|p| if (!out.contains(&p)) out.push_back(p));
        out
    }

    /// `principals` in order, without duplicates.
    fun dedup(principals: vector<Principal>): vector<Principal> {
        let mut out = vector[];
        principals.do!(|p| if (!out.contains(&p)) out.push_back(p));
        out
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

    /// The anchor OU of an OU keyspace; none for a personal keyspace.
    public fun anchor_ou_id(keyspace: &Keyspace): Option<ID> { keyspace.anchor_ou_id }

    /// Returns all principals for `role` (empty vector if the role is unset).
    public fun principals(keyspace: &Keyspace, role: Role): vector<Principal> {
        if (keyspace.acl.contains(&role)) { *keyspace.acl.get(&role) } else { vector[] }
    }

    /// True if `sender` satisfies `role` on this keyspace.
    public fun has_role(keyspace: &Keyspace, role: Role, org: &OU, sender: address): bool {
        satisfies_role(keyspace, role, org, sender)
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
            anchor_ou_id: option::none(),
        }
    }

    /// Create an OU-linked Keyspace for testing, bypassing the `&OU` witness.
    /// The anchor is the first `Ou` principal in `grant_principals`, as
    /// `create_keyspace_for_ou` lists it first; none if there is no `Ou`.
    #[test_only]
    public fun test_create_for_ou(
        name: vector<u8>,
        grant_principals: vector<Principal>,
        read_principals: vector<Principal>,
        write_principals: vector<Principal>,
        ctx: &mut TxContext,
    ): Keyspace {
        let found = grant_principals.find_index!(|p| acl::ou_id(p).is_some());
        let anchor_ou_id = if (found.is_some()) {
            acl::ou_id(&grant_principals[found.destroy_some()])
        } else option::none();
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
            anchor_ou_id,
        }
    }

    #[test_only]
    public fun test_destroy(keyspace: Keyspace) {
        let Keyspace { id, acl: _, name: _, version: _, anchor_ou_id: _ } = keyspace;
        object::delete(id);
    }

    /// Create an EncryptedEntry for testing without checking roles or sharing it.
    #[test_only]
    public fun test_publish_entry(
        keyspace: &Keyspace,
        uri: vector<u8>,
        description: vector<u8>,
        ctx: &mut TxContext,
    ): EncryptedEntry {
        let creator = ctx.sender();
        let uid = object::new(ctx);
        let uri_str = uri.to_string();
        EncryptedEntry {
            id: uid,
            keyspace_id: keyspace.id.to_inner(),
            uri: uri_str,
            description: description.to_string(),
            created_by: creator,
            epoch: keyspace.version,
        }
    }

    /// `seal_approve` is a private `entry fun`, so tests reach it through this wrapper.
    #[test_only]
    public fun test_seal_approve(id: vector<u8>, keyspace: &Keyspace, org: &OU, ctx: &TxContext) {
        seal_approve(id, keyspace, org, ctx)
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
