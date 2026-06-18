/// ACL-based encryption access control — ported from loash-industries/keyspace.
///
/// Flow:
///   1. Creator calls `create_allowlist` → shared AllowList.  Creator is seeded
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
module armature_vault::acl_encrypt {
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
    const EWrongAllowList: u64 = 4;
    const ELastGrantor: u64 = 5;

    // ── Objects ──────────────────────────────────────────────────────────────

    /// Shared object — the on-chain access-control registry.
    public struct AllowList has key {
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
        allowlist_id: ID,
        location: String,
        description: String,
        created_by: address,
        epoch: u64, // AllowList version at time of encryption
    }

    // ── Events ───────────────────────────────────────────────────────────────

    public struct AllowListCreated has copy, drop {
        id: ID,
        creator: Principal,
        name: String,
    }
    public struct AccessGranted has copy, drop {
        allowlist_id: ID,
        role: Role,
        principal: Principal,
        by: address,
    }
    public struct AccessRevoked has copy, drop {
        allowlist_id: ID,
        role: Role,
        principal: Principal,
        by: address,
    }
    public struct EntryPublished has copy, drop {
        entry_id: ID,
        allowlist_id: ID,
        location: String,
        created_by: address,
    }

    // ── Entry functions ──────────────────────────────────────────────────────

    /// Create a new AllowList (shared).  Creator is seeded into all three roles.
    public fun create_allowlist(name: vector<u8>, ctx: &mut TxContext) {
        let uid = object::new(ctx);
        let allowlist_id = uid.to_inner();
        let creator = acl::player(ctx.sender());

        let mut acl_map = vec_map::empty<Role, vector<Principal>>();
        acl_map.insert(Role::Grant, vector[creator]);
        acl_map.insert(Role::Read, vector[creator]);
        acl_map.insert(Role::Write, vector[creator]);

        event::emit(AllowListCreated { id: allowlist_id, creator, name: name.to_string() });

        transfer::share_object(AllowList {
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
        allowlist: &mut AllowList,
        role: Role,
        principal: Principal,
        dao: &DAO,
        ctx: &TxContext,
    ) {
        assert!(satisfies_role(allowlist, Role::Grant, dao, ctx.sender()), ENotAllowed);
        let changed = add_principal(allowlist, role, principal);
        assert!(changed, EAlreadyGranted);
        if (role == Role::Read) { allowlist.version = allowlist.version + 1 };
        event::emit(AccessGranted {
            allowlist_id: allowlist.id.to_inner(),
            role,
            principal,
            by: ctx.sender(),
        });
    }

    /// Revoke `principal` from `role`.  Caller must satisfy `Grant`.
    /// Bumps `version` when the `Read` set changes.  Cannot remove the last
    /// `Grant` principal (would brick the allowlist).
    public fun revoke(
        allowlist: &mut AllowList,
        role: Role,
        principal: Principal,
        dao: &DAO,
        ctx: &TxContext,
    ) {
        assert!(satisfies_role(allowlist, Role::Grant, dao, ctx.sender()), ENotAllowed);
        let changed = remove_principal(allowlist, role, principal);
        assert!(changed, ENotGranted);
        if (role == Role::Grant) {
            let grant_list = allowlist.acl.get(&Role::Grant);
            assert!(grant_list.length() > 0, ELastGrantor);
        };
        if (role == Role::Read) { allowlist.version = allowlist.version + 1 };
        event::emit(AccessRevoked {
            allowlist_id: allowlist.id.to_inner(),
            role,
            principal,
            by: ctx.sender(),
        });
    }

    /// Called by the Seal key-server inside a PTB to gate decryption-key release.
    /// Requires the `Read` role.
    entry fun seal_approve(id: vector<u8>, allowlist: &AllowList, dao: &DAO, ctx: &TxContext) {
        let allowlist_bytes = object::uid_to_bytes(&allowlist.id);
        let mut i = 0;
        while (i < 32) {
            assert!(allowlist_bytes[i] == id[i], ENotAllowed);
            i = i + 1;
        };
        assert!(satisfies_role(allowlist, Role::Read, dao, ctx.sender()), ENotAllowed);
    }

    /// Publish a new encrypted entry.  Requires the `Write` role.
    public fun publish_entry(
        allowlist: &mut AllowList,
        location: vector<u8>,
        description: vector<u8>,
        dao: &DAO,
        ctx: &mut TxContext,
    ) {
        let creator = ctx.sender();
        assert!(satisfies_role(allowlist, Role::Write, dao, creator), ENotAllowed);
        let uid = object::new(ctx);
        let entry_id = uid.to_inner();
        let location_str = location.to_string();
        allowlist.entries.push_back(entry_id);
        event::emit(EntryPublished {
            entry_id,
            allowlist_id: allowlist.id.to_inner(),
            location: location_str,
            created_by: creator,
        });
        transfer::share_object(EncryptedEntry {
            id: uid,
            allowlist_id: allowlist.id.to_inner(),
            location: location_str,
            description: description.to_string(),
            created_by: creator,
            epoch: allowlist.version,
        });
    }

    /// Re-encrypt an entry with a new location (key rotation).  Requires `Write`.
    /// Entry epoch must be stale (not equal to current version).
    public fun update_entry(
        allowlist: &AllowList,
        entry: &mut EncryptedEntry,
        new_location: vector<u8>,
        dao: &DAO,
        ctx: &TxContext,
    ) {
        assert!(satisfies_role(allowlist, Role::Write, dao, ctx.sender()), ENotAllowed);
        assert!(entry.allowlist_id == allowlist.id.to_inner(), EWrongAllowList);
        assert!(entry.epoch != allowlist.version, EAlreadyCurrentEpoch);
        entry.location = new_location.to_string();
        entry.epoch = allowlist.version;
    }

    /// Update an entry's location without key rotation (same epoch).  Requires `Write`.
    public fun edit_entry(
        allowlist: &AllowList,
        entry: &mut EncryptedEntry,
        new_location: vector<u8>,
        dao: &DAO,
        ctx: &TxContext,
    ) {
        assert!(satisfies_role(allowlist, Role::Write, dao, ctx.sender()), ENotAllowed);
        assert!(entry.allowlist_id == allowlist.id.to_inner(), EWrongAllowList);
        entry.location = new_location.to_string();
    }

    // ── Internal ─────────────────────────────────────────────────────────────

    fun satisfies_role(allowlist: &AllowList, role: Role, dao: &DAO, sender: address): bool {
        if (!allowlist.acl.contains(&role)) { return false };
        let principals = allowlist.acl.get(&role);
        let n = principals.length();
        let mut i = 0;
        while (i < n) {
            if (acl::satisfies(&principals[i], dao, sender)) { return true };
            i = i + 1;
        };
        false
    }

    fun add_principal(allowlist: &mut AllowList, role: Role, principal: Principal): bool {
        if (!allowlist.acl.contains(&role)) {
            allowlist.acl.insert(role, vector[principal]);
            return true
        };
        let list = allowlist.acl.get_mut(&role);
        if (list.contains(&principal)) { return false };
        list.push_back(principal);
        true
    }

    fun remove_principal(allowlist: &mut AllowList, role: Role, principal: Principal): bool {
        if (!allowlist.acl.contains(&role)) { return false };
        let list = allowlist.acl.get_mut(&role);
        let (found, idx) = list.index_of(&principal);
        if (!found) { return false };
        list.remove(idx);
        true
    }

    // ── Accessors ─────────────────────────────────────────────────────────────

    public fun name(allowlist: &AllowList): &String { &allowlist.name }

    public fun version(allowlist: &AllowList): u64 { allowlist.version }

    /// Returns all principals for `role` (empty vector if the role is unset).
    public fun principals(allowlist: &AllowList, role: Role): vector<Principal> {
        if (allowlist.acl.contains(&role)) { *allowlist.acl.get(&role) } else { vector[] }
    }

    /// True if `sender` satisfies `role` on this allowlist.
    public fun has_role(allowlist: &AllowList, role: Role, dao: &DAO, sender: address): bool {
        satisfies_role(allowlist, role, dao, sender)
    }

    public fun entry_location(entry: &EncryptedEntry): &String { &entry.location }

    public fun entry_epoch(entry: &EncryptedEntry): u64 { entry.epoch }

    // ── Test-only helpers ─────────────────────────────────────────────────────

    /// Create an AllowList for testing.  Creator is seeded into all three roles.
    #[test_only]
    public fun test_create(name: vector<u8>, ctx: &mut TxContext): AllowList {
        let uid = object::new(ctx);
        let creator = acl::player(ctx.sender());
        let mut acl_map = vec_map::empty<Role, vector<Principal>>();
        acl_map.insert(Role::Grant, vector[creator]);
        acl_map.insert(Role::Read, vector[creator]);
        acl_map.insert(Role::Write, vector[creator]);
        AllowList {
            id: uid,
            acl: acl_map,
            name: name.to_string(),
            version: 0,
            entries: vector::empty(),
        }
    }

    #[test_only]
    public fun test_destroy(allowlist: AllowList) {
        let AllowList { id, acl: _, name: _, version: _, entries: _ } = allowlist;
        object::delete(id);
    }

    /// Create an EncryptedEntry for testing without checking roles or sharing it.
    #[test_only]
    public fun test_publish_entry(
        allowlist: &mut AllowList,
        location: vector<u8>,
        description: vector<u8>,
        ctx: &mut TxContext,
    ): EncryptedEntry {
        let creator = ctx.sender();
        let uid = object::new(ctx);
        let entry_id = uid.to_inner();
        let location_str = location.to_string();
        allowlist.entries.push_back(entry_id);
        EncryptedEntry {
            id: uid,
            allowlist_id: allowlist.id.to_inner(),
            location: location_str,
            description: description.to_string(),
            created_by: creator,
            epoch: allowlist.version,
        }
    }

    #[test_only]
    public fun test_destroy_entry(entry: EncryptedEntry) {
        let EncryptedEntry {
            id,
            allowlist_id: _,
            location: _,
            description: _,
            created_by: _,
            epoch: _,
        } = entry;
        object::delete(id);
    }
}
