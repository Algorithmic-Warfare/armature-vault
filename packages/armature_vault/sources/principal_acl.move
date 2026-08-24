/// Shared storage for `acl_v2::PrincipalV2` sets, hung off any object's `UID`
/// as a versioned dynamic field.
///
/// Both `keyspace::Keyspace` and `dao_receipt_vault::DaoReceiptVault` hold their
/// original ACL in a `VecMap<Role, vector<Principal>>` struct field.  Those
/// layouts are frozen by Sui's upgrade compatibility, so neither can hold the
/// upgradeable `PrincipalV2`.  Rather than each module growing its own parallel
/// store, both hang *this* one off their `UID` — same shape, one implementation,
/// generic over each module's own `Role` type.
///
/// The stored value is a `sui::versioned::Versioned` wrapping the payload, so
/// the store's own schema can be upgraded in place later: add `PrincipalAclV2`,
/// bump `STORE_VERSION`, migrate lazily in `borrow_mut`, and teach the read path
/// to answer for both versions until migration saturates.  Reads tolerate every
/// historical version and fail closed (empty, no access) on versions newer than
/// this code; only mutations migrate.
module armature_vault::principal_acl {
    use armature::dao::DAO;
    use armature_vault::acl_v2::{Self as acl_v2, PrincipalV2};
    use sui::{
        dynamic_field as df,
        vec_map::{Self, VecMap},
        versioned::{Self, Versioned},
    };

    /// Payload schema version of the store itself (not of any principal).
    const STORE_VERSION: u64 = 1;

    /// The stored payload is a version this code does not understand.  Only
    /// mutation paths abort; reads fail closed instead.
    const EUnknownStoreVersion: u64 = 0;

    /// Dynamic-field key.  The same key type on different parent objects, since
    /// each parent's `UID` is its own namespace.
    public struct PrincipalAclKey has copy, drop, store {}

    /// Version 1 payload: the same role → principals shape the frozen v1 ACL
    /// fields use, over `PrincipalV2`.
    public struct PrincipalAclV1<R: copy + drop + store> has store {
        acl: VecMap<R, vector<PrincipalV2>>,
    }

    // === Reads ===

    /// Principals holding `role`.  Empty when the store is absent, or when its
    /// stored version is newer than this code understands — fail closed.
    ///
    /// Versions at or below `STORE_VERSION` are read normally; only version 1
    /// exists today, so `load_value` below is unambiguous.  When `STORE_VERSION`
    /// grows, add a branch per historical version here — the read path must keep
    /// answering for every version still in the wild until migration saturates.
    public(package) fun principals<R: copy + drop + store>(
        uid: &UID,
        role: R,
    ): vector<PrincipalV2> {
        if (!df::exists_(uid, PrincipalAclKey {})) { return vector[] };
        let wrapper: &Versioned = df::borrow(uid, PrincipalAclKey {});
        if (wrapper.version() > STORE_VERSION) { return vector[] };
        let store: &PrincipalAclV1<R> = wrapper.load_value();
        if (store.acl.contains(&role)) { *store.acl.get(&role) } else { vector[] }
    }

    /// True when the v2 store holds any principal admitting the same senders as
    /// `principal` for `role`.
    ///
    /// Compares by identity, not bytes: `player(x)` and `machine(x)` are one
    /// authority under `acl_v2::satisfies`, so counting them as separate grants
    /// would let either hide behind the other.  Used to keep one identity from
    /// being granted in both stores at once, or twice in this one.
    public(package) fun contains<R: copy + drop + store>(
        uid: &UID,
        role: R,
        principal: &PrincipalV2,
    ): bool {
        let list = principals<R>(uid, role);
        let n = list.length();
        let mut i = 0;
        while (i < n) {
            if (acl_v2::same_identity(&list[i], principal)) { return true };
            i = i + 1;
        };
        false
    }

    /// Number of principals holding `role`.
    public(package) fun count<R: copy + drop + store>(uid: &UID, role: R): u64 {
        principals<R>(uid, role).length()
    }

    /// True if `sender` satisfies any principal holding `role`.
    public(package) fun satisfies<R: copy + drop + store>(
        uid: &UID,
        role: R,
        dao: &DAO,
        sender: address,
    ): bool {
        let list = principals<R>(uid, role);
        let n = list.length();
        let mut i = 0;
        while (i < n) {
            if (acl_v2::satisfies(&list[i], dao, sender)) { return true };
            i = i + 1;
        };
        false
    }

    // === Mutations ===

    /// Add `principal` to `role`, creating the store on first use.
    ///
    /// Returns false (no-op) when an *identity-equivalent* principal already
    /// holds the role: `player(x)` blocks `machine(x)` and the reverse, because
    /// both admit exactly the same sender and a later revoke must be able to
    /// clear "x" without knowing which label it was filed under.
    public(package) fun add<R: copy + drop + store>(
        uid: &mut UID,
        role: R,
        principal: PrincipalV2,
        ctx: &mut TxContext,
    ): bool {
        if (!df::exists_(uid, PrincipalAclKey {})) {
            let empty = PrincipalAclV1<R> { acl: vec_map::empty() };
            df::add(uid, PrincipalAclKey {}, versioned::create(STORE_VERSION, empty, ctx));
        };
        let store = borrow_mut<R>(uid);
        if (!store.acl.contains(&role)) {
            store.acl.insert(role, vector[principal]);
            return true
        };
        let list = store.acl.get_mut(&role);
        let n = list.length();
        let mut i = 0;
        while (i < n) {
            if (acl_v2::same_identity(&list[i], &principal)) { return false };
            i = i + 1;
        };
        list.push_back(principal);
        true
    }

    /// Remove every principal admitting the same senders as `principal` from
    /// `role`, returning the ones actually removed.
    ///
    /// Identity-wide rather than byte-exact: revoking `player(x)` has to clear
    /// `machine(x)` too, or the revoke succeeds, emits its event, and leaves x
    /// still holding the role — a silent failure on an ACL guarding assets and
    /// decryption keys.  `add` refuses to create such a pair in the first place,
    /// so in practice this returns at most one principal; it returns a vector so
    /// the guarantee does not rest on that, and so callers can emit one event
    /// per entry they really cleared rather than assuming which kind it was.
    ///
    /// Iterates high-to-low so a removal does not skip the following element.
    public(package) fun remove<R: copy + drop + store>(
        uid: &mut UID,
        role: R,
        principal: PrincipalV2,
    ): vector<PrincipalV2> {
        let mut removed = vector[];
        if (!df::exists_(uid, PrincipalAclKey {})) { return removed };
        let store = borrow_mut<R>(uid);
        if (!store.acl.contains(&role)) { return removed };
        let list = store.acl.get_mut(&role);
        let mut i = list.length();
        while (i > 0) {
            i = i - 1;
            if (acl_v2::same_identity(&list[i], &principal)) {
                removed.push_back(list.remove(i));
            };
        };
        removed
    }

    /// Mutable access to the current-version payload.  The single place a future
    /// schema migration happens (see the module doc): when `STORE_VERSION` grows,
    /// upgrade an older payload in place here — via
    /// `versioned::remove_value_for_upgrade` / `versioned::upgrade` — before
    /// returning, so writers always see the current shape.  A version NEWER than
    /// this code understands aborts rather than silently writing a shape the
    /// owner cannot read back.
    fun borrow_mut<R: copy + drop + store>(uid: &mut UID): &mut PrincipalAclV1<R> {
        let wrapper: &mut Versioned = df::borrow_mut(uid, PrincipalAclKey {});
        assert!(wrapper.version() <= STORE_VERSION, EUnknownStoreVersion);
        wrapper.load_value_mut()
    }

    // === Teardown ===

    /// Delete the whole v2 store from `uid`, dropping every principal it holds.
    ///
    /// Exists so an owner that tears down its parent object can revoke v2
    /// principals as well as v1 ones.  Draining only the caller's own v1 field
    /// would leave this store authorizing every role it held, since
    /// `satisfies_role` reads both — see `dao_receipt_vault::deinitialize_dao_vault`.
    ///
    /// No-op when the store is absent.  Aborts on a payload version this code
    /// cannot destructure, rather than orphaning it.
    public(package) fun destroy<R: copy + drop + store>(uid: &mut UID) {
        if (!df::exists_(uid, PrincipalAclKey {})) { return };
        let wrapper: Versioned = df::remove(uid, PrincipalAclKey {});
        assert!(wrapper.version() <= STORE_VERSION, EUnknownStoreVersion);
        let store: PrincipalAclV1<R> = wrapper.destroy();
        let PrincipalAclV1 { acl: _ } = store;
    }
}
