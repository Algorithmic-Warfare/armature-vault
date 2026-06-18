/// ACL-based encryption access control — ported from loash-industries/keyspace.
///
/// Flow:
///   1. Creator calls `create_keyspace` → shared Keyspace.  Creator is seeded
///      into all three roles.
///   2. A `Grant` holder calls `grant` / `revoke` to manage role membership.
///   3. Walrus Seal gates decryption-key release via `seal_approve`, which
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
module armature_vault::keyspace {
    use armature::dao::DAO;
    use armature_vault::acl::{Self as acl, Principal};
    use std::string::String;
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
        location: String,
        description: String,
        created_by: address,
        epoch: u64, // Keyspace version at time of encryption
    }

    // ── Events ───────────────────────────────────────────────────────────────

    public struct KeyspaceCreated has copy, drop {
        id: ID,
        creator: Principal,
        name: String,
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
        location: String,
        created_by: address,
    }
    public struct EntryUpdated has copy, drop {
        entry_id: ID,
        keyspace_id: ID,
        new_location: String,
        new_epoch: u64,
        by: address,
    }
    public struct EntryEdited has copy, drop {
        entry_id: ID,
        keyspace_id: ID,
        new_location: String,
        by: address,
    }
    public struct EntryDescriptionEdited has copy, drop {
        entry_id: ID,
        keyspace_id: ID,
        new_description: String,
        by: address,
    }

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

        event::emit(KeyspaceCreated { id: keyspace_id, creator, name: name.to_string() });
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
        location: vector<u8>,
        description: vector<u8>,
        dao: &DAO,
        ctx: &mut TxContext,
    ) {
        let creator = ctx.sender();
        assert!(satisfies_role(keyspace, Role::Write, dao, creator), ENotAllowed);
        let uid = object::new(ctx);
        let entry_id = uid.to_inner();
        let location_str = location.to_string();
        keyspace.entries.push_back(entry_id);
        event::emit(EntryPublished {
            entry_id,
            keyspace_id: keyspace.id.to_inner(),
            location: location_str,
            created_by: creator,
        });
        transfer::share_object(EncryptedEntry {
            id: uid,
            keyspace_id: keyspace.id.to_inner(),
            location: location_str,
            description: description.to_string(),
            created_by: creator,
            epoch: keyspace.version,
        });
    }

    /// Re-encrypt an entry with a new location (key rotation).  Requires `Write`.
    /// Entry epoch must be stale (not equal to current version).
    public fun update_entry(
        keyspace: &Keyspace,
        entry: &mut EncryptedEntry,
        new_location: vector<u8>,
        dao: &DAO,
        ctx: &TxContext,
    ) {
        assert!(satisfies_role(keyspace, Role::Write, dao, ctx.sender()), ENotAllowed);
        assert!(entry.keyspace_id == keyspace.id.to_inner(), EWrongKeyspace);
        assert!(entry.epoch != keyspace.version, EAlreadyCurrentEpoch);
        entry.location = new_location.to_string();
        entry.epoch = keyspace.version;
        event::emit(EntryUpdated {
            entry_id: entry.id.to_inner(),
            keyspace_id: keyspace.id.to_inner(),
            new_location: entry.location,
            new_epoch: entry.epoch,
            by: ctx.sender(),
        });
    }

    /// Update an entry's location without key rotation (same epoch).  Requires `Write`.
    public fun edit_entry(
        keyspace: &Keyspace,
        entry: &mut EncryptedEntry,
        new_location: vector<u8>,
        dao: &DAO,
        ctx: &TxContext,
    ) {
        assert!(satisfies_role(keyspace, Role::Write, dao, ctx.sender()), ENotAllowed);
        assert!(entry.keyspace_id == keyspace.id.to_inner(), EWrongKeyspace);
        entry.location = new_location.to_string();
        event::emit(EntryEdited {
            entry_id: entry.id.to_inner(),
            keyspace_id: keyspace.id.to_inner(),
            new_location: entry.location,
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

    fun satisfies_role(keyspace: &Keyspace, role: Role, dao: &DAO, sender: address): bool {
        if (!keyspace.acl.contains(&role)) { return false };
        let principals = keyspace.acl.get(&role);
        let n = principals.length();
        let mut i = 0;
        while (i < n) {
            if (acl::satisfies(&principals[i], dao, sender)) { return true };
            i = i + 1;
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

    public fun entry_location(entry: &EncryptedEntry): &String { &entry.location }

    public fun entry_description(entry: &EncryptedEntry): &String { &entry.description }

    public fun entry_epoch(entry: &EncryptedEntry): u64 { entry.epoch }

    // ── Test-only helpers ─────────────────────────────────────────────────────

    /// Create an Keyspace for testing.  Creator is seeded into all three roles.
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

    #[test_only]
    public fun test_destroy(keyspace: Keyspace) {
        let Keyspace { id, acl: _, name: _, version: _, entries: _ } = keyspace;
        object::delete(id);
    }

    /// Create an EncryptedEntry for testing without checking roles or sharing it.
    #[test_only]
    public fun test_publish_entry(
        keyspace: &mut Keyspace,
        location: vector<u8>,
        description: vector<u8>,
        ctx: &mut TxContext,
    ): EncryptedEntry {
        let creator = ctx.sender();
        let uid = object::new(ctx);
        let entry_id = uid.to_inner();
        let location_str = location.to_string();
        keyspace.entries.push_back(entry_id);
        EncryptedEntry {
            id: uid,
            keyspace_id: keyspace.id.to_inner(),
            location: location_str,
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
            location: _,
            description: _,
            created_by: _,
            epoch: _,
        } = entry;
        object::delete(id);
    }
}
