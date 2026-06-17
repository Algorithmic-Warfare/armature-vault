/// ACL-based encryption access control — ported from loash-industries/keyspace.
///
/// Flow:
///   1. Creator calls `create_allowlist` → shared AllowList + owned AdminCap.
///   2. Admin calls `add` / `remove` to manage the grantee set.  Both bump the
///      version so existing EncryptedEntry objects are flagged stale and must be
///      re-encrypted by `update_entry`.
///   3. Client generates an AES-GCM key (or obtains one from Walrus Seal) and
///      encrypts plaintext off-chain.  Walrus Seal gates key release via
///      `seal_approve`.
///   4. Client uploads the ciphertext blob and calls `publish_entry` with the
///      resulting location (`ipfs://…` or `https://…`).
///   5. Authorised readers fetch the blob from the location and decrypt locally.
module armature_vault::acl_encrypt {
    use std::string::String;
    use sui::{event, vec_set::{Self, VecSet}};

    // ── Error codes ──────────────────────────────────────────────────────────
    const EWrongCap: u64 = 0;
    const ENotAllowed: u64 = 1;
    const EAlreadyInList: u64 = 2;
    const ENotInList: u64 = 3;
    const EAlreadyCurrentEpoch: u64 = 4;

    // ── Objects ──────────────────────────────────────────────────────────────

    /// Shared object — the on-chain access-control registry.
    public struct AllowList has key {
        id: UID,
        owner: address,
        list: VecSet<address>,
        name: String,
        version: u64,
        entries: vector<ID>,
    }

    /// Transferable capability granting admin rights over one AllowList.
    public struct AdminCap has key, store {
        id: UID,
        allowlist_id: ID,
    }

    /// A pointer to an AES-GCM–encrypted content blob.  The ciphertext lives
    /// off-chain; only the location (IPFS CID or object-store URL) is stored
    /// here.  Shared after `publish_entry` so any allowlist member can rotate
    /// the key via `update_entry`.
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
        owner: address,
        name: String,
    }
    public struct AccessGranted has copy, drop {
        allowlist_id: ID,
        grantee: address,
    }
    public struct AccessRevoked has copy, drop {
        allowlist_id: ID,
        grantee: address,
    }
    public struct EntryPublished has copy, drop {
        entry_id: ID,
        allowlist_id: ID,
        location: String,
        created_by: address,
    }

    // ── Entry functions ──────────────────────────────────────────────────────

    /// Create a new AllowList (shared).  Caller receives the AdminCap.
    #[allow(lint(self_transfer))]
    public fun create_allowlist(name: vector<u8>, ctx: &mut TxContext) {
        let uid = object::new(ctx);
        let allowlist_id = uid.to_inner();
        let owner = ctx.sender();

        event::emit(AllowListCreated {
            id: allowlist_id,
            owner,
            name: name.to_string(),
        });

        transfer::share_object(AllowList {
            id: uid,
            owner,
            list: vec_set::empty(),
            name: name.to_string(),
            version: 0,
            entries: vector::empty(),
        });
        transfer::public_transfer(
            AdminCap { id: object::new(ctx), allowlist_id },
            owner,
        );
    }

    /// Grant access to `grantee`.  Requires the matching AdminCap.  Bumps
    /// version so existing entries are flagged stale and must be re-encrypted
    /// to share the key with the new member.
    public fun add(allowlist: &mut AllowList, cap: &AdminCap, grantee: address, _ctx: &TxContext) {
        assert!(cap.allowlist_id == allowlist.id.to_inner(), EWrongCap);
        assert!(!allowlist.list.contains(&grantee), EAlreadyInList);
        allowlist.list.insert(grantee);
        allowlist.version = allowlist.version + 1;
        event::emit(AccessGranted { allowlist_id: allowlist.id.to_inner(), grantee });
    }

    /// Revoke access from `grantee`.  Requires the matching AdminCap.  Bumps
    /// version so existing entries must be re-encrypted to exclude the removed
    /// member.
    public fun remove(
        allowlist: &mut AllowList,
        cap: &AdminCap,
        grantee: address,
        _ctx: &TxContext,
    ) {
        assert!(cap.allowlist_id == allowlist.id.to_inner(), EWrongCap);
        assert!(allowlist.list.contains(&grantee), ENotInList);
        allowlist.list.remove(&grantee);
        allowlist.version = allowlist.version + 1;
        event::emit(AccessRevoked { allowlist_id: allowlist.id.to_inner(), grantee });
    }

    /// Called by the Seal key-server inside a PTB to gate decryption-key release.
    /// The `id` bytes are the AllowList UID (32 bytes) + a random nonce.  We
    /// verify the first 32 bytes match and that the caller is authorised.
    entry fun seal_approve(id: vector<u8>, allowlist: &AllowList, ctx: &TxContext) {
        let allowlist_bytes = object::uid_to_bytes(&allowlist.id);
        let mut i = 0;
        while (i < 32) {
            assert!(allowlist_bytes[i] == id[i], ENotAllowed);
            i = i + 1;
        };
        let caller = ctx.sender();
        assert!(caller == allowlist.owner || allowlist.list.contains(&caller), ENotAllowed);
    }

    /// Publish a location pointing to an AES-GCM–encrypted blob.  The entry is
    /// shared so any allowlist member can rotate the key via `update_entry`.
    public fun publish_entry(
        allowlist: &mut AllowList,
        location: vector<u8>,
        description: vector<u8>,
        ctx: &mut TxContext,
    ) {
        let creator = ctx.sender();
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

    /// Re-encrypt an entry with a new location when the AllowList version has
    /// changed (key rotation).  Any current member may call this.
    public fun update_entry(
        allowlist: &AllowList,
        entry: &mut EncryptedEntry,
        new_location: vector<u8>,
        ctx: &TxContext,
    ) {
        let caller = ctx.sender();
        assert!(caller == allowlist.owner || allowlist.list.contains(&caller), ENotAllowed);
        assert!(entry.allowlist_id == allowlist.id.to_inner(), EWrongCap);
        assert!(entry.epoch != allowlist.version, EAlreadyCurrentEpoch);
        entry.location = new_location.to_string();
        entry.epoch = allowlist.version;
    }

    /// Update an entry's location with new encrypted content (same epoch, no
    /// key rotation required).  Any current member may call this.
    public fun edit_entry(
        allowlist: &AllowList,
        entry: &mut EncryptedEntry,
        new_location: vector<u8>,
        ctx: &TxContext,
    ) {
        let caller = ctx.sender();
        assert!(caller == allowlist.owner || allowlist.list.contains(&caller), ENotAllowed);
        assert!(entry.allowlist_id == allowlist.id.to_inner(), EWrongCap);
        entry.location = new_location.to_string();
    }

    // ── Pure accessors ───────────────────────────────────────────────────────

    public fun owner(allowlist: &AllowList): address { allowlist.owner }

    public fun name(allowlist: &AllowList): &String { &allowlist.name }

    public fun version(allowlist: &AllowList): u64 { allowlist.version }

    public fun is_allowed(allowlist: &AllowList, addr: address): bool {
        addr == allowlist.owner || allowlist.list.contains(&addr)
    }

    public fun cap_allowlist_id(cap: &AdminCap): ID { cap.allowlist_id }

    public fun entry_location(entry: &EncryptedEntry): &String { &entry.location }

    public fun entry_epoch(entry: &EncryptedEntry): u64 { entry.epoch }

    // ── Test-only helpers ────────────────────────────────────────────────────

    #[test_only]
    public fun test_create(name: vector<u8>, ctx: &mut TxContext): (AllowList, AdminCap) {
        let uid = object::new(ctx);
        let allowlist_id = uid.to_inner();
        let owner = ctx.sender();
        (
            AllowList {
                id: uid,
                owner,
                list: vec_set::empty(),
                name: name.to_string(),
                version: 0,
                entries: vector::empty(),
            },
            AdminCap { id: object::new(ctx), allowlist_id },
        )
    }

    #[test_only]
    public fun test_destroy(allowlist: AllowList) {
        let AllowList { id, owner: _, list: _, name: _, version: _, entries: _ } = allowlist;
        object::delete(id);
    }

    #[test_only]
    public fun test_destroy_cap(cap: AdminCap) {
        let AdminCap { id, allowlist_id: _ } = cap;
        object::delete(id);
    }

    /// Create an EncryptedEntry for testing (does not share it).
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
