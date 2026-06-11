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
///     any role (including `Edit` itself). The people who can *administer* the vault
///     need not be the people who can *use* it — e.g. AWAR officers hold `Edit`
///     while AWAR/WOLF members hold `Deposit`/`Withdraw`.
///   - Invariant: `Edit` can never be emptied (`ELastEditor`). An empty `Edit` list
///     would permanently brick the ACL.
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

/// Assert `sender` satisfies *some* principal listed for `role`, using `dao` as
/// the OU context. Aborts with `ENotAuthorized` if the role is absent or no
/// principal matches.
fun assert_role(vault: &DaoReceiptVault, role: Role, dao: &DAO, sender: address) {
    assert!(vault.acl.contains(&role), ENotAuthorized);
    let principals = vault.acl.get(&role);
    let n = principals.length();
    let mut i = 0;
    let mut ok = false;
    while (i < n) {
        if (satisfies(&principals[i], dao, sender)) {
            ok = true;
            break
        };
        i = i + 1;
    };
    assert!(ok, ENotAuthorized);
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

    let mut acl = vec_map::empty<Role, vector<Principal>>();
    acl.insert(Role::Edit, vector[Principal::Ou { dao_id: editor_dao_id }]);

    let vault = DaoReceiptVault {
        id: object::new(ctx),
        storage_unit_id,
        collection_id,
        acl,
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

    let asset_id = receipt.asset_id();
    let amount = receipt.value();

    if (dof::exists_(&vault.id, asset_id)) {
        let stored: &mut Balance = dof::borrow_mut(&mut vault.id, asset_id);
        stored.join(receipt, ctx);
    } else {
        dof::add(&mut vault.id, asset_id, receipt);
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

    assert!(dof::exists_(&vault.id, asset_id), EInsufficientVaultBalance);
    let stored: &mut Balance = dof::borrow_mut(&mut vault.id, asset_id);
    assert!(stored.value() >= amount, EInsufficientVaultBalance);

    let withdrawn = stored.split(amount, ctx);

    if (stored.value() == 0) {
        let zero: Balance = dof::remove(&mut vault.id, asset_id);
        zero.destroy_zero();
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
    assert!(roles.length() == principals.length(), ENotAuthorized);

    let vault_id = object::id(vault);
    let n = roles.length();
    let mut i = 0;
    while (i < n) {
        let role = roles[i];
        let principal = principals[i];
        add_principal(vault, role, principal);
        event::emit(AclGrantedEvent { vault_id, role, principal, by: sender });
        i = i + 1;
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
    assert!(roles.length() == principals.length(), ENotAuthorized);

    let vault_id = object::id(vault);
    let n = roles.length();
    let mut i = 0;
    while (i < n) {
        let role = roles[i];
        let principal = principals[i];
        remove_principal(vault, role, principal);
        event::emit(AclRevokedEvent { vault_id, role, principal, by: sender });
        i = i + 1;
    };

    // Enforce the brick-guard once, after all removals in this batch.
    assert!(
        vault.acl.contains(&Role::Edit) && vault.acl.get(&Role::Edit).length() > 0,
        ELastEditor,
    );
}

// === ACL mutation (internal) ===

fun add_principal(vault: &mut DaoReceiptVault, role: Role, principal: Principal) {
    if (!vault.acl.contains(&role)) {
        vault.acl.insert(role, vector[principal]);
        return
    };
    let list = vault.acl.get_mut(&role);
    if (!list.contains(&principal)) {
        list.push_back(principal);
    };
}

fun remove_principal(vault: &mut DaoReceiptVault, role: Role, principal: Principal) {
    if (!vault.acl.contains(&role)) {
        return
    };
    let list = vault.acl.get_mut(&role);
    let (found, idx) = list.index_of(&principal);
    if (found) {
        list.remove(idx);
    };
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
    DaoReceiptVault {
        id: object::new(ctx),
        storage_unit_id,
        collection_id,
        acl,
    }
}

#[test_only]
public fun share_for_testing(vault: DaoReceiptVault) {
    transfer::share_object(vault)
}

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx)
}
