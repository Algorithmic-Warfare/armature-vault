/// DAO Receipt Vault — a DAO/OU-gated accumulator for warehouse receipts with a
/// dynamic, multi-principal access-control list.
///
/// Players mint standard `multicoin::Balance` receipts via the warehouse_receipts
/// package, then deposit them here. The vault accepts only receipts from the SSU's
/// specific collection (locked at initialization) and accumulates balances per
/// `asset_id` in dynamic object fields.
///
/// Access control:
///   - Each operation is gated by a *role*: `Deposit`, `Withdraw`, or `Edit`.
///   - Each role maps to a list of *principals*. A principal is either:
///       * `Player { addr }` — satisfied when `ctx.sender() == addr`, or
///       * `Ou { dao_id }`   — satisfied when the caller passes the matching `&DAO`
///         (`dao.id() == dao_id`) and is one of its board members.
///     A caller passes a role check if they satisfy *any* principal listed for it.
///   - `Edit` is ACL administration: holders may batch grant/revoke principals on
///     `Deposit`/`Withdraw` roles via `grant`/`revoke`. The people who can
///     *administer* the vault need not be the people who can *use* it — e.g. AWAR
///     officers hold `Edit` while AWAR/WOLF members hold `Deposit`/`Withdraw`.
///   - `Edit` itself can only be granted via `grant_edit_ou`, which takes a
///     live `&DAO` witness. `grant` aborts `EEditMustBeOu` on `Role::Edit`. This
///     forces every `Edit` principal to reference a real on-chain DAO and closes
///     brick-by-unsatisfiable-principal attacks (bogus dao ids, `Player{@0x0}`)
///     plus bare-`Player` Edit backdoors that would defeat OU migration.
///   - Invariants on `revoke`: (1) `Edit` can never be emptied (`ELastEditor`),
///     and (2) the caller must still satisfy `Edit` via `editor_dao` after the
///     batch (`EEditorWouldLockSelf`). Together they prevent both empty-Edit
///     bricks and grant-bogus-then-revoke-self brick paths.
///
/// Why the OU indirection (and not a flat address list): it makes board-membership
/// changes and DAO *migration* work without re-listing addresses. A migrated DAO
/// gets a new object id; the guaranteed migration path is — create the new DAO,
/// grant `Ou { new_dao_id }` the `Edit` role on this vault (old + new editors
/// coexist during cutover), migrate caps/coins to the new DAO, then revoke the old
/// `Edit` principal. Only the OU principal can express "the new board" by id.
///
/// The `multicoin` and `world` types used here MUST resolve to the same on-chain
/// packages as the warehouse_receipts package the receipts are minted from
/// (multicoin `c7a97f2`, world `8e2e97b`) — otherwise the `Balance` / `StorageUnit`
/// types diverge and receipts cannot be deposited.
module armature_vault::dao_receipt_vault;

use armature::dao::DAO;
use multicoin::multicoin::Balance;
use sui::{dynamic_object_field as dof, event, table::{Self, Table}, vec_map::{Self, VecMap}};
use world::storage_unit::StorageUnit;

// === Errors ===

#[error(code = 0)]
const ENotAuthorized: vector<u8> =
    b"Sender does not satisfy any principal for the required role";
#[error(code = 1)]
const EInsufficientVaultBalance: vector<u8> = b"Insufficient balance in the receipt vault";
#[error(code = 2)]
const EWrongCollection: vector<u8> =
    b"Receipt collection_id does not match this vault's collection";
#[error(code = 3)]
const EVaultAlreadyExists: vector<u8> =
    b"A receipt vault already exists for this DAO at this storage unit";
#[error(code = 4)]
const ELastEditor: vector<u8> =
    b"Cannot remove the last Edit principal — the vault would be unadministrable";
#[error(code = 5)]
const EInvalidArguments: vector<u8> =
    b"Invalid arguments (e.g. parallel vectors of different lengths)";
#[error(code = 6)]
const EZeroAmount: vector<u8> = b"Amount must be greater than zero";
#[error(code = 7)]
const EEditMustBeOu: vector<u8> =
    b"Edit role only accepts Ou principals — use grant_edit_ou";
#[error(code = 8)]
const EEditorWouldLockSelf: vector<u8> =
    b"Revocation would leave the caller unable to administer the vault";
#[error(code = 9)]
const EVaultNonEmpty: vector<u8> =
    b"Vault holds at least one non-empty asset balance — drain before deinit";
#[error(code = 10)]
const EVaultRegistryMismatch: vector<u8> =
    b"Registry slot does not point at this vault";

// === Roles ===

public enum Role has copy, drop, store {
    Deposit,
    Withdraw,
    Edit,
}

public fun role_deposit(): Role { Role::Deposit }

public fun role_withdraw(): Role { Role::Withdraw }

public fun role_edit(): Role { Role::Edit }

// === Principals ===

public enum Principal has copy, drop, store {
    Player { addr: address },
    Ou { dao_id: ID },
}

/// A principal satisfied by a single wallet address.
public fun player(addr: address): Principal {
    Principal::Player { addr }
}

/// A principal satisfied by any board member of the DAO/OU with this id.
public fun ou(dao_id: ID): Principal {
    Principal::Ou { dao_id }
}

// === Structs ===

/// Composite key used in the registry table. Keyed by the *initial editor* DAO,
/// which scopes a vault to the OU that bootstrapped it on a given SSU.
public struct VaultKey has copy, drop, store {
    storage_unit_id: ID,
    editor_dao_id: ID,
}

/// Shared singleton registry mapping (storage_unit_id, editor_dao_id) → vault id.
public struct DaoReceiptVaultRegistry has key {
    id: UID,
    vaults: Table<VaultKey, ID>,
}

/// Shared per-(StorageUnit, ...) vault.
/// Accepts only receipts from `collection_id`. Per-asset balances are stored as
/// dynamic object fields keyed by asset_id (u64). The ACL maps each role to its
/// list of principals.
public struct DaoReceiptVault has key {
    id: UID,
    storage_unit_id: ID,
    collection_id: ID,
    acl: VecMap<Role, vector<Principal>>,
    /// M2: number of asset_ids with a live dynamic-object-field entry. Bumped
    /// by `deposit_receipt` when a new asset_id is added; decremented by
    /// `withdraw_receipt` when the last balance for an asset_id is drained.
    /// `deinitialize_dao_vault` asserts this is zero before freeing the
    /// registry slot.
    non_empty_assets: u64,
    /// M2: which `editor_dao_id` the registry currently keys this vault under.
    /// Set at init from `editor_dao.id()`; updated by `update_registry_key`.
    /// `deinitialize_dao_vault` uses this to find the right slot to remove,
    /// so the caller doesn't need to track migration history out-of-band.
    registry_key_dao_id: ID,
}

// === Module initializer ===

fun init(ctx: &mut TxContext) {
    transfer::share_object(DaoReceiptVaultRegistry {
        id: object::new(ctx),
        vaults: table::new(ctx),
    });
}

// === Events ===

public struct VaultInitializedEvent has copy, drop {
    vault_id: ID,
    editor_dao_id: ID,
    storage_unit_id: ID,
    collection_id: ID,
}

/// M2: emitted when a vault is deinitialized — its registry slot is freed and
/// its ACL is wiped. The vault object itself remains as an orphan (Sui shared
/// objects cannot be deleted), but is no longer discoverable via `lookup` and
/// no caller can satisfy any role on it.
public struct VaultDeinitializedEvent has copy, drop {
    vault_id: ID,
    editor_dao_id: ID,
    by: address,
}

public struct DepositEvent has copy, drop {
    vault_id: ID,
    collection_id: ID,
    asset_id: u64,
    amount: u64,
    depositor: address,
}

public struct WithdrawEvent has copy, drop {
    vault_id: ID,
    collection_id: ID,
    asset_id: u64,
    amount: u64,
    withdrawer: address,
}

public struct AclGrantedEvent has copy, drop {
    vault_id: ID,
    role: Role,
    principal: Principal,
    by: address,
}

public struct AclRevokedEvent has copy, drop {
    vault_id: ID,
    role: Role,
    principal: Principal,
    by: address,
}

// === Authorization (internal) ===

/// True if `sender` satisfies `principal` given the `&DAO` the caller is acting
/// as. For a `Player` principal the DAO is irrelevant; for an `Ou` principal the
/// passed DAO must be that OU and `sender` must be on its board.
fun satisfies(principal: &Principal, dao: &DAO, sender: address): bool {
    match (principal) {
        Principal::Player { addr } => *addr == sender,
        Principal::Ou { dao_id } => dao.id() == *dao_id && dao.is_governance_member(sender),
    }
}

/// True if `sender` satisfies *some* principal listed for `role`, using `dao` as
/// the OU context. False if the role is absent or no principal matches.
fun satisfies_role(vault: &DaoReceiptVault, role: Role, dao: &DAO, sender: address): bool {
    if (!vault.acl.contains(&role)) { return false };
    let principals = vault.acl.get(&role);
    let n = principals.length();
    let mut i = 0;
    while (i < n) {
        if (satisfies(&principals[i], dao, sender)) {
            return true
        };
        i = i + 1;
    };
    false
}

/// Aborts with `ENotAuthorized` unless `satisfies_role` holds.
fun assert_role(vault: &DaoReceiptVault, role: Role, dao: &DAO, sender: address) {
    assert!(satisfies_role(vault, role, dao, sender), ENotAuthorized);
}

// === Public: lifecycle ===

/// Initialize a vault on a given StorageUnit. The caller must be a board member
/// of `editor_dao`, which is seeded as the sole initial `Edit` principal; the
/// ACL is otherwise empty (grant deposit/withdraw principals via `grant`).
/// Reverts if a vault for this (SSU, editor_dao) pair already exists.
/// `collection_id` must be the ID of the SSU's warehouse receipt Collection.
public fun initialize_dao_vault(
    registry: &mut DaoReceiptVaultRegistry,
    storage_unit: &StorageUnit,
    editor_dao: &DAO,
    collection_id: ID,
    ctx: &mut TxContext,
) {
    assert!(editor_dao.is_governance_member(ctx.sender()), ENotAuthorized);

    let storage_unit_id = object::id(storage_unit);
    let editor_dao_id = editor_dao.id();
    let key = VaultKey { storage_unit_id, editor_dao_id };
    assert!(!table::contains(&registry.vaults, key), EVaultAlreadyExists);

    let seed_principal = Principal::Ou { dao_id: editor_dao_id };
    let mut acl = vec_map::empty<Role, vector<Principal>>();
    acl.insert(Role::Edit, vector[seed_principal]);

    let vault = DaoReceiptVault {
        id: object::new(ctx),
        storage_unit_id,
        collection_id,
        acl,
        non_empty_assets: 0,
        registry_key_dao_id: editor_dao_id,
    };
    let vault_id = object::id(&vault);

    table::add(&mut registry.vaults, key, vault_id);
    transfer::share_object(vault);

    event::emit(VaultInitializedEvent {
        vault_id,
        editor_dao_id,
        storage_unit_id,
        collection_id,
    });
    // I1: also emit AclGrantedEvent for the seeded Edit principal so event-sourced
    // ACL reconstructions don't need to hardcode the seeding rule.
    event::emit(AclGrantedEvent {
        vault_id,
        role: Role::Edit,
        principal: seed_principal,
        by: ctx.sender(),
    });
}

// === Public: deposit / withdraw ===

/// Deposit a warehouse receipt. The caller must satisfy the `Deposit` role using
/// `dao` as their OU context (or be a bare `Player` deposit principal, in which
/// case any `&DAO` may be passed). Receipt must belong to the vault's collection.
public fun deposit_receipt(
    vault: &mut DaoReceiptVault,
    dao: &DAO,
    receipt: Balance,
    ctx: &mut TxContext,
) {
    let sender = ctx.sender();
    assert_role(vault, Role::Deposit, dao, sender);
    assert!(receipt.collection_id() == vault.collection_id, EWrongCollection);
    // M4/L2: reject zero-value deposits so a Deposit-only principal cannot
    // unilaterally grow the vault's DOF set with phantom entries.
    assert!(receipt.value() > 0, EZeroAmount);

    let asset_id = receipt.asset_id();
    let amount = receipt.value();

    if (dof::exists_(&vault.id, asset_id)) {
        let stored: &mut Balance = dof::borrow_mut(&mut vault.id, asset_id);
        stored.join(receipt, ctx);
    } else {
        dof::add(&mut vault.id, asset_id, receipt);
        // M2: new asset_id slot — bump the live-asset counter.
        vault.non_empty_assets = vault.non_empty_assets + 1;
    };

    event::emit(DepositEvent {
        vault_id: object::id(vault),
        collection_id: vault.collection_id,
        asset_id,
        amount,
        depositor: sender,
    });
}

/// Withdraw a specific amount for a given asset_id. The caller must satisfy the
/// `Withdraw` role using `dao` as their OU context. Returns the split Balance.
public fun withdraw_receipt(
    vault: &mut DaoReceiptVault,
    dao: &DAO,
    asset_id: u64,
    amount: u64,
    ctx: &mut TxContext,
): Balance {
    let sender = ctx.sender();
    assert_role(vault, Role::Withdraw, dao, sender);
    // F3: reject zero-amount withdrawals so indexers don't see spurious WithdrawEvents.
    assert!(amount > 0, EZeroAmount);

    assert!(dof::exists_(&vault.id, asset_id), EInsufficientVaultBalance);
    let stored: &mut Balance = dof::borrow_mut(&mut vault.id, asset_id);
    assert!(stored.value() >= amount, EInsufficientVaultBalance);

    let withdrawn = stored.split(amount, ctx);

    if (stored.value() == 0) {
        let zero: Balance = dof::remove(&mut vault.id, asset_id);
        zero.destroy_zero();
        // M2: asset_id slot drained — decrement the live-asset counter.
        vault.non_empty_assets = vault.non_empty_assets - 1;
    };

    event::emit(WithdrawEvent {
        vault_id: object::id(vault),
        collection_id: vault.collection_id,
        asset_id,
        amount,
        withdrawer: sender,
    });

    withdrawn
}

// === Public: ACL administration (Edit role) ===

/// Batch-grant principals to roles. The caller must satisfy the `Edit` role using
/// `editor_dao` as their OU context. `roles` and `principals` are parallel vectors
/// (same length); each (role, principal) pair is added if not already present.
public fun grant(
    vault: &mut DaoReceiptVault,
    editor_dao: &DAO,
    roles: vector<Role>,
    principals: vector<Principal>,
    ctx: &TxContext,
) {
    let sender = ctx.sender();
    assert_role(vault, Role::Edit, editor_dao, sender);
    // F5: distinct error code so callers can tell bad-input from auth failure.
    assert!(roles.length() == principals.length(), EInvalidArguments);

    let vault_id = object::id(vault);
    let n = roles.length();
    let mut i = 0;
    while (i < n) {
        let role = roles[i];
        let principal = principals[i];
        // H1/M3: Edit principals must come through grant_edit_ou, which validates
        // the &DAO witness and refuses bare-Player and unverifiable-Ou principals.
        assert!(role != Role::Edit, EEditMustBeOu);
        // L1: only emit on real state change.
        let changed = add_principal(vault, role, principal);
        if (changed) {
            event::emit(AclGrantedEvent { vault_id, role, principal, by: sender });
        };
        i = i + 1;
    };
}

/// H1: grant the Edit role to an OU, validated by a live `&DAO` witness. This
/// is the only path that can add an Edit principal — it forces every Edit grant
/// to reference a real DAO with at least one governance member, closing the
/// brick-by-unsatisfiable-principal attack and the bare-Player Edit backdoor.
public fun grant_edit_ou(
    vault: &mut DaoReceiptVault,
    editor_dao: &DAO,
    target_dao: &DAO,
    ctx: &TxContext,
) {
    let sender = ctx.sender();
    assert_role(vault, Role::Edit, editor_dao, sender);

    let vault_id = object::id(vault);
    let principal = Principal::Ou { dao_id: target_dao.id() };
    let changed = add_principal(vault, Role::Edit, principal);
    if (changed) {
        event::emit(AclGrantedEvent {
            vault_id,
            role: Role::Edit,
            principal,
            by: sender,
        });
    };
}

/// Batch-revoke principals from roles. The caller must satisfy the `Edit` role
/// using `editor_dao`. Each (role, principal) pair is removed if present.
/// Aborts (`ELastEditor`) if a revocation would leave `Edit` with no principals.
public fun revoke(
    vault: &mut DaoReceiptVault,
    editor_dao: &DAO,
    roles: vector<Role>,
    principals: vector<Principal>,
    ctx: &TxContext,
) {
    let sender = ctx.sender();
    assert_role(vault, Role::Edit, editor_dao, sender);
    // F5: distinct error code for bad input vs. auth failure.
    assert!(roles.length() == principals.length(), EInvalidArguments);

    let vault_id = object::id(vault);
    let n = roles.length();

    // L1: track which (role, principal) pairs actually changed state. Defer all
    // event emission until after the brick-guards (F2) and only emit for real
    // changes (L1).
    let mut changed_mask: vector<bool> = vector[];
    let mut i = 0;
    while (i < n) {
        let role = roles[i];
        let principal = principals[i];
        let changed = remove_principal(vault, role, principal);
        changed_mask.push_back(changed);
        i = i + 1;
    };

    // Brick-guard 1: Edit list must remain non-empty.
    assert!(
        vault.acl.contains(&Role::Edit) && vault.acl.get(&Role::Edit).length() > 0,
        ELastEditor,
    );
    // H1: brick-guard 2 — the caller must still satisfy Edit using editor_dao.
    // Prevents grant-bogus-then-revoke-self bricking attacks: a rogue can only
    // remove themselves from Edit if some other satisfiable principal remains
    // for *them* (which they can verify by passing the same editor_dao). This
    // is the post-state version of assert_role(Edit, ...) — it would have
    // succeeded entering revoke; the assertion forces it to still hold on exit.
    assert!(satisfies_role(vault, Role::Edit, editor_dao, sender), EEditorWouldLockSelf);

    // F2 + L1: emit events only now (after guards), and only for state-changing pairs.
    let mut j = 0;
    while (j < n) {
        if (changed_mask[j]) {
            event::emit(AclRevokedEvent {
                vault_id,
                role: roles[j],
                principal: principals[j],
                by: sender,
            });
        };
        j = j + 1;
    };
}

// === Registry maintenance ===

/// F4: re-key the registry entry for this vault after a DAO migration. The caller
/// must satisfy the *current* `Edit` role using `editor_dao`. The new key uses
/// `new_editor_dao.id()` for the `editor_dao_id` component. Aborts if no entry
/// exists for the old key or if an entry already exists for the new key.
///
/// Note: this does NOT alter the ACL — granting `Ou { new_editor_dao.id() }` the
/// `Edit` role is a separate `grant_edit_ou` call. This function only keeps
/// `lookup(...)` discoverable under the new DAO's identity.
public fun update_registry_key(
    registry: &mut DaoReceiptVaultRegistry,
    vault: &mut DaoReceiptVault,
    editor_dao: &DAO,
    new_editor_dao: &DAO,
    ctx: &TxContext,
) {
    let sender = ctx.sender();
    assert_role(vault, Role::Edit, editor_dao, sender);

    let old_key = VaultKey {
        storage_unit_id: vault.storage_unit_id,
        editor_dao_id: editor_dao.id(),
    };
    let new_key = VaultKey {
        storage_unit_id: vault.storage_unit_id,
        editor_dao_id: new_editor_dao.id(),
    };
    assert!(table::contains(&registry.vaults, old_key), EInvalidArguments);
    // Cross-vault safety: a caller with Edit on this vault who also has the
    // editor_dao listed as an Ou principal on *another* vault's ACL could
    // otherwise remap the other vault's registry entry. Assert the stored id
    // at old_key really refers to *this* vault before swapping.
    assert!(
        *table::borrow(&registry.vaults, old_key) == object::id(vault),
        EInvalidArguments,
    );
    assert!(!table::contains(&registry.vaults, new_key), EVaultAlreadyExists);

    let vault_id = table::remove(&mut registry.vaults, old_key);
    table::add(&mut registry.vaults, new_key, vault_id);
    // M2: keep the vault's self-reported registry key in sync so
    // `deinitialize_dao_vault` can later find the right slot to free.
    vault.registry_key_dao_id = new_editor_dao.id();
}

/// M2: free the registry slot for this vault's (SSU, current editor_dao) key
/// and effectively brick the vault by clearing its ACL. The caller must satisfy
/// `Edit` using `editor_dao`, and the vault must be empty
/// (`non_empty_assets == 0`).
///
/// Sui shared objects cannot be deleted once shared (see
/// `sui::transfer::share_object` doc: "once an object is shared, it will stay
/// shared forever"). So this function does not destroy the vault object — it
/// orphans it. Subsequent `deposit_receipt` / `withdraw_receipt` / `grant` /
/// `revoke` / `grant_edit_ou` / `update_registry_key` calls all go through
/// `assert_role(...)` which now aborts `ENotAuthorized` because the ACL is
/// empty. The orphan is harmless: no DOFs, no admin path, not discoverable
/// via the registry.
///
/// `editor_dao` may differ from the original initializer — after
/// `update_registry_key` the vault's current registry slot is keyed by the
/// migrated DAO id. The vault tracks `registry_key_dao_id` internally and
/// uses it to locate the slot, so the caller only needs a DAO that satisfies
/// the current `Edit` role.
public fun deinitialize_dao_vault(
    registry: &mut DaoReceiptVaultRegistry,
    vault: &mut DaoReceiptVault,
    editor_dao: &DAO,
    ctx: &TxContext,
) {
    let sender = ctx.sender();
    assert_role(vault, Role::Edit, editor_dao, sender);
    assert!(vault.non_empty_assets == 0, EVaultNonEmpty);

    let key = VaultKey {
        storage_unit_id: vault.storage_unit_id,
        editor_dao_id: vault.registry_key_dao_id,
    };
    // The registry slot must exist and point at *this* vault. Mirrors the
    // cross-vault safety check in `update_registry_key`.
    assert!(table::contains(&registry.vaults, key), EInvalidArguments);
    assert!(
        *table::borrow(&registry.vaults, key) == object::id(vault),
        EVaultRegistryMismatch,
    );
    let vault_id = table::remove(&mut registry.vaults, key);
    let editor_dao_id = vault.registry_key_dao_id;

    // Brick the ACL. Any subsequent assert_role aborts ENotAuthorized.
    while (!vault.acl.is_empty()) {
        vault.acl.pop();
    };

    event::emit(VaultDeinitializedEvent {
        vault_id,
        editor_dao_id,
        by: sender,
    });
}

// === ACL mutation (internal) ===

/// Returns true iff the principal was actually added (i.e. state changed).
fun add_principal(vault: &mut DaoReceiptVault, role: Role, principal: Principal): bool {
    if (!vault.acl.contains(&role)) {
        vault.acl.insert(role, vector[principal]);
        return true
    };
    let list = vault.acl.get_mut(&role);
    if (list.contains(&principal)) {
        return false
    };
    list.push_back(principal);
    true
}

/// Returns true iff the principal was actually removed (i.e. state changed).
fun remove_principal(vault: &mut DaoReceiptVault, role: Role, principal: Principal): bool {
    if (!vault.acl.contains(&role)) {
        return false
    };
    let list = vault.acl.get_mut(&role);
    let (found, idx) = list.index_of(&principal);
    if (!found) {
        return false
    };
    list.remove(idx);
    true
}

// === View Functions ===

/// Look up the vault id for a (storage_unit_id, editor_dao_id) pair.
public fun lookup(
    registry: &DaoReceiptVaultRegistry,
    storage_unit_id: ID,
    editor_dao_id: ID,
): Option<ID> {
    let key = VaultKey { storage_unit_id, editor_dao_id };
    if (table::contains(&registry.vaults, key)) {
        option::some(*table::borrow(&registry.vaults, key))
    } else {
        option::none()
    }
}

public fun storage_unit_id(vault: &DaoReceiptVault): ID {
    vault.storage_unit_id
}

public fun collection_id(vault: &DaoReceiptVault): ID {
    vault.collection_id
}

/// Returns the list of principals for a role (empty if the role is unset).
public fun principals(vault: &DaoReceiptVault, role: Role): vector<Principal> {
    if (vault.acl.contains(&role)) {
        *vault.acl.get(&role)
    } else {
        vector[]
    }
}

/// Returns the vault's accumulated balance for a given asset_id.
public fun vault_balance(vault: &DaoReceiptVault, asset_id: u64): u64 {
    if (dof::exists_(&vault.id, asset_id)) {
        let stored: &Balance = dof::borrow(&vault.id, asset_id);
        stored.value()
    } else {
        0
    }
}

// === Test Functions ===

/// Construct + share a vault directly, seeding the full ACL, bypassing the
/// SSU/registry setup (anchoring a real StorageUnit needs the full world
/// bootstrap; the ACL paths under test never touch the StorageUnit).
#[test_only]
public fun new_for_testing(
    storage_unit_id: ID,
    collection_id: ID,
    acl: VecMap<Role, vector<Principal>>,
    ctx: &mut TxContext,
): DaoReceiptVault {
    // `registry_key_dao_id` is set to a sentinel zero-id by default; tests that
    // exercise the registry (lookup / update_registry_key / deinitialize)
    // should call `set_registry_key_dao_id_for_testing` after construction to
    // match whatever key they register.
    DaoReceiptVault {
        id: object::new(ctx),
        storage_unit_id,
        collection_id,
        acl,
        non_empty_assets: 0,
        registry_key_dao_id: object::id_from_address(@0x0),
    }
}

#[test_only]
public fun set_registry_key_dao_id_for_testing(
    vault: &mut DaoReceiptVault,
    editor_dao_id: ID,
) {
    vault.registry_key_dao_id = editor_dao_id;
}

#[test_only]
public fun share_for_testing(vault: DaoReceiptVault) {
    transfer::share_object(vault)
}

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx)
}

#[test_only]
public fun register_for_testing(
    registry: &mut DaoReceiptVaultRegistry,
    storage_unit_id: ID,
    editor_dao_id: ID,
    vault_id: ID,
) {
    table::add(&mut registry.vaults, VaultKey { storage_unit_id, editor_dao_id }, vault_id);
}
