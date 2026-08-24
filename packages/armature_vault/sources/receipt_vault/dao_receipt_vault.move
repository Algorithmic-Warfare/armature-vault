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
module armature_vault::dao_receipt_vault {
    use armature::dao::DAO;
    use armature_vault::acl::{Self as acl, Principal};
    use armature_vault::acl_v2::{Self as acl_v2, PrincipalV2};
    use armature_vault::principal_acl;
    use multicoin::multicoin::Balance;
    use sui::{dynamic_object_field as dof, event, table::{Self, Table}, vec_map::{Self, VecMap}};
    use warehouse_receipts::vault::VaultConfig;
    use world::{access::{Self, OwnerCap}, storage_unit::StorageUnit};

    // === Roles ===

    public enum Role has copy, drop, store {
        Deposit,
        Withdraw,
        Edit,
    }

    public fun role_deposit(): Role { Role::Deposit }

    public fun role_withdraw(): Role { Role::Withdraw }

    public fun role_edit(): Role { Role::Edit }

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
    const EEditMustBeOu: vector<u8> = b"Edit role only accepts Ou principals — use grant_edit_ou";
    #[error(code = 8)]
    const EEditorWouldLockSelf: vector<u8> =
        b"Revocation would leave the caller unable to administer the vault";
    #[error(code = 9)]
    const EVaultNonEmpty: vector<u8> =
        b"Vault holds at least one non-empty asset balance — drain before deinit";
    #[error(code = 10)]
    const EVaultRegistryMismatch: vector<u8> = b"Registry slot does not point at this vault";
    #[error(code = 11)]
    const EStorageUnitMismatch: vector<u8> = b"VaultConfig does not bind the passed StorageUnit";
    #[error(code = 12)]
    const EUnauthorizedForStorageUnit: vector<u8> =
        b"Caller's OwnerCap does not authorize this StorageUnit";
    #[error(code = 13)]
    const EEmptyEditPrincipals: vector<u8> =
        b"edit_principals must be non-empty — vault would have no administrator";

    // === Structs ===

    /// Composite key used in the registry table. Keyed by the *registrant* DAO,
    /// which scopes a vault to the OU it was registered for on a given SSU.
    public struct VaultKey has copy, drop, store {
        storage_unit_id: ID,
        registrant_dao_id: ID,
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
        /// M2: which registrant DAO the registry currently keys this vault under.
        /// Set at init from `registrant_dao.id()`; updated by `update_registry_key`.
        /// `deinitialize_dao_vault` uses this to find the right slot to remove,
        /// so the caller doesn't need to track migration history out-of-band.
        registrant_dao_id: ID,
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
        registrant_dao_id: ID,
        storage_unit_id: ID,
        collection_id: ID,
    }

    /// M2: emitted when a vault is deinitialized — its registry slot is freed and
    /// its ACL is wiped. The vault object itself remains as an orphan (Sui shared
    /// objects cannot be deleted), but is no longer discoverable via `lookup` and
    /// no caller can satisfy any role on it.
    public struct VaultDeinitializedEvent has copy, drop {
        vault_id: ID,
        /// The `registrant_dao_id` component of the `VaultKey` that was freed —
        /// equivalently `vault.registrant_dao_id` at the moment of deinit. After
        /// a prior `update_registry_key` migration this is the *current* registrant
        /// DAO id, not the original initializer's. Indexers should treat it as the
        /// registry-key half, not the caller's identity.
        registrant_dao_id: ID,
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

    /// v2 twins of the ACL events.  These carry the whole `PrincipalV2`, so one
    /// event type serves every present and future kind — indexers read the kind
    /// from `acl_v2::kind` rather than the event name.
    public struct AclGrantedEventV2 has copy, drop {
        vault_id: ID,
        role: Role,
        principal: PrincipalV2,
        by: address,
    }

    public struct AclRevokedEventV2 has copy, drop {
        vault_id: ID,
        role: Role,
        principal: PrincipalV2,
        by: address,
    }

    /// Emitted once per role by `migrate_acl_to_v2`.  Access is unchanged —
    /// indexers should *replace* that vault/role's v1 rows with these v2 rows
    /// rather than reading it as a revoke followed by a grant.
    public struct AclMigratedV2 has copy, drop {
        vault_id: ID,
        role: Role,
        principals: vector<PrincipalV2>,
        by: address,
    }

    // === Authorization (internal) ===

    /// True if `sender` satisfies *some* principal listed for `role`, using `dao` as
    /// the OU context. False if the role is absent or no principal matches.
    fun satisfies_role(vault: &DaoReceiptVault, role: Role, dao: &DAO, sender: address): bool {
        if (vault.acl.contains(&role)) {
            let principals = vault.acl.get(&role);
            let n = principals.length();
            let mut i = 0;
            while (i < n) {
                if (acl::satisfies(&principals[i], dao, sender)) {
                    return true
                };
                i = i + 1;
            };
        };
        // v2 store (machines and any later kind) — see the ACL v2 section.
        principal_acl::satisfies(&vault.id, role, dao, sender)
    }

    /// Total principals holding `role` across both ACL stores.  The brick
    /// guards are defined over this, not over the v1 list alone, so a role can
    /// migrate to v2 without tripping them.
    public fun role_count(vault: &DaoReceiptVault, role: Role): u64 {
        let v1 = if (vault.acl.contains(&role)) {
            vault.acl.get(&role).length()
        } else { 0 };
        v1 + principal_acl::count(&vault.id, role)
    }

    /// Aborts with `ENotAuthorized` unless `satisfies_role` holds.
    fun assert_role(vault: &DaoReceiptVault, role: Role, dao: &DAO, sender: address) {
        assert!(satisfies_role(vault, role, dao, sender), ENotAuthorized);
    }

    // === Public: lifecycle ===

    /// Initialize a vault on a given StorageUnit.
    ///
    /// The caller must be a board member of `registrant_dao`. `registrant_dao` is
    /// used only as the registry key and for caller authorization — it is NOT
    /// automatically seeded into the Edit role. Pass the desired Edit principals
    /// explicitly via `edit_principals`; at least one must be supplied
    /// (`EEmptyEditPrincipals`).
    ///
    /// `deposit_principals`, `withdraw_principals`, and `edit_principals` are the
    /// caller-supplied initial ACL entries for those roles — pass empty vectors for
    /// Deposit/Withdraw to leave those roles unpopulated at init and populate later
    /// via `grant`/`grant_edit_ou`.
    ///
    /// This separation lets deployers express "officers have Edit, members have
    /// Deposit/Withdraw" in a single init call: pass the officer DAO's Ou principal
    /// in `edit_principals` and the member DAO's Ou principal in
    /// `deposit_principals`/`withdraw_principals`, with the member DAO as
    /// `registrant_dao` so the vault is directly discoverable under the member
    /// DAO's registry key.
    ///
    /// Reverts if a vault for this (SSU, registrant_dao) pair already exists.
    ///
    /// F1 (#3): `vault_config` is the `warehouse_receipts::vault::VaultConfig` for
    /// this SSU. It is the on-chain authoritative record that a specific
    /// `Collection` was created for a specific `StorageUnit`. We assert the SSU
    /// binding (`EStorageUnitMismatch`) and derive `collection_id` from the
    /// config, closing the prior gap where a caller could supply a raw
    /// `collection_id: ID` that didn't match the SSU and permanently misconfigure
    /// the vault.
    ///
    /// M1 (#4): `owner_cap` is the `OwnerCap<StorageUnit>` for `storage_unit`.
    /// `world::access::is_authorized(owner_cap, ssu_id)` verifies on-chain that the
    /// caller has the SSU's authority surface, closing the SSU-squatting hole
    /// where any DAO board member could register a vault against any
    /// `&StorageUnit` they could obtain a reference to. The composition F1+M1
    /// ensures both halves of the binding (Collection<->SSU and caller<->SSU)
    /// are verified by witness, not trusted from input.
    ///
    /// Trust assumption (not verified on-chain): the caller — a governance member
    /// of `registrant_dao` who possesses `OwnerCap<StorageUnit>` — is acting on
    /// behalf of the DAO. M1 verifies (caller passes board-membership check) AND
    /// (caller can produce the OwnerCap), but does NOT verify the DAO *collectively*
    /// controls the cap. A board member personally holding the cap can unilaterally
    /// bind that SSU to their DAO's vault. If you need cap-custody under DAO
    /// governance, custody the cap in the DAO's treasury and borrow it via the
    /// DAO's standard proposal flow.
    public fun initialize_dao_vault(
        registry: &mut DaoReceiptVaultRegistry,
        storage_unit: &StorageUnit,
        owner_cap: &OwnerCap<StorageUnit>,
        registrant_dao: &DAO,
        vault_config: &VaultConfig,
        deposit_principals: vector<Principal>,
        withdraw_principals: vector<Principal>,
        edit_principals: vector<Principal>,
        ctx: &mut TxContext,
    ) {
        assert!(registrant_dao.is_governance_member(ctx.sender()), ENotAuthorized);
        assert!(!edit_principals.is_empty(), EEmptyEditPrincipals);

        let storage_unit_id = object::id(storage_unit);
        // M1: caller's OwnerCap must authorize this SSU.
        assert!(access::is_authorized(owner_cap, storage_unit_id), EUnauthorizedForStorageUnit);
        // F1: the VaultConfig's bound SSU must match the passed StorageUnit. This
        // is the verifier that closes the "wrong collection for this SSU" hole.
        assert!(vault_config.storage_unit_id() == storage_unit_id, EStorageUnitMismatch);
        let collection_id = vault_config.collection_id();

        let registrant_dao_id = registrant_dao.id();
        let key = VaultKey { storage_unit_id, registrant_dao_id };
        assert!(!table::contains(&registry.vaults, key), EVaultAlreadyExists);

        let mut vault_acl = vec_map::empty<Role, vector<Principal>>();
        if (!deposit_principals.is_empty()) {
            vault_acl.insert(Role::Deposit, deposit_principals);
        };
        if (!withdraw_principals.is_empty()) {
            vault_acl.insert(Role::Withdraw, withdraw_principals);
        };
        vault_acl.insert(Role::Edit, edit_principals);

        let vault = DaoReceiptVault {
            id: object::new(ctx),
            storage_unit_id,
            collection_id,
            acl: vault_acl,
            non_empty_assets: 0,
            registrant_dao_id,
        };
        let vault_id = object::id(&vault);

        event::emit(VaultInitializedEvent {
            vault_id,
            registrant_dao_id,
            storage_unit_id,
            collection_id,
        });

        // I1: emit AclGrantedEvent for each seeded principal so event-sourced
        // ACL reconstructions don't need to hardcode the seeding rule. We borrow
        // from the vault before sharing so we can iterate the stored vectors.
        let sender = ctx.sender();
        let mut role_idx = 0;
        while (role_idx < vault.acl.length()) {
            let (role, principals) = vault.acl.get_entry_by_idx(role_idx);
            let n = principals.length();
            let mut i = 0;
            while (i < n) {
                event::emit(AclGrantedEvent {
                    vault_id,
                    role: *role,
                    principal: principals[i],
                    by: sender,
                });
                i = i + 1;
            };
            role_idx = role_idx + 1;
        };

        table::add(&mut registry.vaults, key, vault_id);
        transfer::share_object(vault);
    }

    /// Governance-member-only variant of `initialize_dao_vault` that does not
    /// require an `OwnerCap<StorageUnit>`. Any board member of `registrant_dao`
    /// may call this — the SSU-owner gate is intentionally absent. Prefer this
    /// when the SSU owner and the DAO board member are different accounts.
    public fun initialize_dao_vault_v2(
        registry: &mut DaoReceiptVaultRegistry,
        storage_unit: &StorageUnit,
        registrant_dao: &DAO,
        vault_config: &VaultConfig,
        deposit_principals: vector<Principal>,
        withdraw_principals: vector<Principal>,
        edit_principals: vector<Principal>,
        ctx: &mut TxContext,
    ) {
        assert!(registrant_dao.is_governance_member(ctx.sender()), ENotAuthorized);
        assert!(!edit_principals.is_empty(), EEmptyEditPrincipals);

        let storage_unit_id = object::id(storage_unit);
        // F1: the VaultConfig's bound SSU must match the passed StorageUnit.
        assert!(vault_config.storage_unit_id() == storage_unit_id, EStorageUnitMismatch);
        let collection_id = vault_config.collection_id();

        let registrant_dao_id = registrant_dao.id();
        let key = VaultKey { storage_unit_id, registrant_dao_id };
        assert!(!table::contains(&registry.vaults, key), EVaultAlreadyExists);

        let mut vault_acl = vec_map::empty<Role, vector<Principal>>();
        if (!deposit_principals.is_empty()) {
            vault_acl.insert(Role::Deposit, deposit_principals);
        };
        if (!withdraw_principals.is_empty()) {
            vault_acl.insert(Role::Withdraw, withdraw_principals);
        };
        vault_acl.insert(Role::Edit, edit_principals);

        let vault = DaoReceiptVault {
            id: object::new(ctx),
            storage_unit_id,
            collection_id,
            acl: vault_acl,
            non_empty_assets: 0,
            registrant_dao_id,
        };
        let vault_id = object::id(&vault);

        event::emit(VaultInitializedEvent {
            vault_id,
            registrant_dao_id,
            storage_unit_id,
            collection_id,
        });

        let sender = ctx.sender();
        let mut role_idx = 0;
        while (role_idx < vault.acl.length()) {
            let (role, principals) = vault.acl.get_entry_by_idx(role_idx);
            let n = principals.length();
            let mut i = 0;
            while (i < n) {
                event::emit(AclGrantedEvent {
                    vault_id,
                    role: *role,
                    principal: principals[i],
                    by: sender,
                });
                i = i + 1;
            };
            role_idx = role_idx + 1;
        };

        table::add(&mut registry.vaults, key, vault_id);
        transfer::share_object(vault);
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
            // Keep one identity in one store. If the v2 store already admits this
            // sender for the role, a second grant here adds no access and makes a
            // later single-store revoke ambiguous. Matched across kinds, so a v1
            // `Player { x }` is skipped when v2 holds `machine(x)`.
            let held_in_v2 = principal_acl::contains(
                &vault.id,
                role,
                &acl_v2::from_v1(&principal),
            );
            // L1: only emit on real state change.
            let changed = !held_in_v2 && add_principal(vault, role, principal);
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
        let principal = acl::ou(target_dao.id());
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

        // L1: track what each (role, principal) pair actually cleared, per store.
        // Defer all event emission until after the brick-guards (F2) and only emit
        // for real changes (L1). Revocation is identity-wide, so a v1 revoke can
        // clear a v2 twin — both are reported, so indexers stay in step.
        let mut cleared_v1: vector<Option<Principal>> = vector[];
        let mut cleared_v2: vector<vector<PrincipalV2>> = vector[];
        let mut i = 0;
        while (i < n) {
            let (v1, v2) = remove_principal_everywhere(vault, roles[i], principals[i]);
            cleared_v1.push_back(v1);
            cleared_v2.push_back(v2);
            i = i + 1;
        };

        // Brick-guard 1: Edit must remain non-empty, counting both ACL stores
        // so a migrated Edit principal still satisfies it.
        assert!(role_count(vault, Role::Edit) > 0, ELastEditor);
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
            emit_revocations(vault_id, roles[j], cleared_v1[j], cleared_v2[j], sender);
            j = j + 1;
        };
    }

    // === Public: ACL v2 (upgradeable principals, incl. machines) ===
    //
    // `acl::Principal` is frozen at Player/Ou, and `DaoReceiptVault.acl`'s field
    // type is frozen with it, so machine principals live in the shared
    // `principal_acl` store hung off this vault's UID.  Both stores are read
    // together by `satisfies_role`, and the brick guards count both.
    //
    // `Edit` stays v1/OU-only.  `grant_edit_ou` exists so every Edit principal
    // references a live `&DAO` witness — an unsatisfiable Edit principal bricks
    // the vault.  A machine key is exactly the kind of principal that rule
    // exists to keep out (lose the key, lose the vault), so `grant_v2` refuses
    // `Edit` for every kind, mirroring `grant`.

    /// Batch-grant v2 principals (machines included) to `Deposit` / `Withdraw`.
    /// Caller must satisfy `Edit` using `editor_dao`.  Aborts `EEditMustBeOu`
    /// for `Role::Edit` — see the section note.
    public fun grant_v2(
        vault: &mut DaoReceiptVault,
        editor_dao: &DAO,
        roles: vector<Role>,
        principals: vector<PrincipalV2>,
        ctx: &mut TxContext,
    ) {
        let sender = ctx.sender();
        assert_role(vault, Role::Edit, editor_dao, sender);
        assert!(roles.length() == principals.length(), EInvalidArguments);

        let vault_id = object::id(vault);
        let n = roles.length();
        let mut i = 0;
        while (i < n) {
            let role = roles[i];
            let principal = principals[i];
            assert!(role != Role::Edit, EEditMustBeOu);
            // Mirror of the v1 path: skip when the frozen store already admits
            // this identity for the role.
            let dup = held_in_v1(vault, role, &principal);
            if (!dup && principal_acl::add(&mut vault.id, role, principal, ctx)) {
                event::emit(AclGrantedEventV2 { vault_id, role, principal, by: sender });
            };
            i = i + 1;
        };
    }

    /// Batch-revoke v2 principals.  Caller must satisfy `Edit`.  Applies the
    /// same two brick guards as `revoke`, computed across both ACL stores.
    public fun revoke_v2(
        vault: &mut DaoReceiptVault,
        editor_dao: &DAO,
        roles: vector<Role>,
        principals: vector<PrincipalV2>,
        ctx: &TxContext,
    ) {
        let sender = ctx.sender();
        assert_role(vault, Role::Edit, editor_dao, sender);
        assert!(roles.length() == principals.length(), EInvalidArguments);

        let vault_id = object::id(vault);
        let n = roles.length();

        let mut cleared_v1: vector<Option<Principal>> = vector[];
        let mut cleared_v2: vector<vector<PrincipalV2>> = vector[];
        let mut i = 0;
        while (i < n) {
            let (v1, v2) = remove_v2_everywhere(vault, roles[i], principals[i]);
            cleared_v1.push_back(v1);
            cleared_v2.push_back(v2);
            i = i + 1;
        };

        assert!(role_count(vault, Role::Edit) > 0, ELastEditor);
        assert!(satisfies_role(vault, Role::Edit, editor_dao, sender), EEditorWouldLockSelf);

        let mut j = 0;
        while (j < n) {
            emit_revocations(vault_id, roles[j], cleared_v1[j], cleared_v2[j], sender);
            j = j + 1;
        };
    }

    /// v2 principals holding `role` (empty when the store is absent or its
    /// version is newer than this code understands — fail closed).
    public fun principals_v2(vault: &DaoReceiptVault, role: Role): vector<PrincipalV2> {
        principal_acl::principals(&vault.id, role)
    }

    /// Lift every v1 principal into the v2 store, one role at a time.  Caller
    /// must satisfy `Edit`.
    ///
    /// Access-neutral — `acl_v2::from_v1` preserves exactly which senders each
    /// principal admits — and idempotent: a second call finds the v1 lists
    /// empty and does nothing.  Gated on `Edit` rather than permissionless
    /// because an SDK older than the v2 release reads principals from the
    /// object's `acl` field and would see an emptied list.
    public fun migrate_acl_to_v2(
        vault: &mut DaoReceiptVault,
        editor_dao: &DAO,
        ctx: &mut TxContext,
    ) {
        assert_role(vault, Role::Edit, editor_dao, ctx.sender());
        migrate_role_to_v2(vault, Role::Deposit, ctx);
        migrate_role_to_v2(vault, Role::Withdraw, ctx);
        migrate_role_to_v2(vault, Role::Edit, ctx);
    }

    fun migrate_role_to_v2(vault: &mut DaoReceiptVault, role: Role, ctx: &mut TxContext) {
        let legacy = if (vault.acl.contains(&role)) {
            *vault.acl.get(&role)
        } else { vector[] };
        if (legacy.is_empty()) { return };

        // The v1 field's type is frozen; its contents are ours to clear.
        {
            let list = vault.acl.get_mut(&role);
            *list = vector[];
        };

        let vault_id = object::id(vault);
        let sender = ctx.sender();
        let mut lifted = vector[];
        let n = legacy.length();
        let mut i = 0;
        while (i < n) {
            let principal = acl_v2::from_v1(&legacy[i]);
            if (principal_acl::add(&mut vault.id, role, principal, ctx)) {
                lifted.push_back(principal);
            };
            i = i + 1;
        };
        if (!lifted.is_empty()) {
            event::emit(AclMigratedV2 { vault_id, role, principals: lifted, by: sender });
        };
    }

    // === Registry maintenance ===

    /// F4: re-key the registry entry for this vault after a registrant DAO migration.
    ///
    /// The caller must satisfy the current `Edit` role using `editor_dao` AND be a
    /// governance member of `new_registrant_dao` — a registry slot keyed by a DAO
    /// can only be claimed by that DAO's board, the same rule
    /// `initialize_dao_vault` applies when a slot is first created. A migration
    /// therefore has to be signed by someone on the successor DAO's board, which
    /// whoever just created that DAO will be.
    ///
    /// The old key is derived from `vault.registrant_dao_id`; the new key uses
    /// `new_registrant_dao.id()`. Aborts if no entry exists for the old key or if
    /// an entry already exists for the new key.
    ///
    /// This does NOT alter the ACL. This function only keeps `lookup(...)` discoverable
    /// under the new registrant DAO's identity.
    public fun update_registry_key(
        registry: &mut DaoReceiptVaultRegistry,
        vault: &mut DaoReceiptVault,
        editor_dao: &DAO,
        new_registrant_dao: &DAO,
        ctx: &TxContext,
    ) {
        let sender = ctx.sender();
        assert_role(vault, Role::Edit, editor_dao, sender);
        // Claiming a registry slot keyed by a DAO requires membership of that
        // DAO — the same rule `initialize_dao_vault` applies when a slot is
        // first created, now applied when one is moved.
        //
        // Without it, Edit on *any* vault was enough to move that vault into
        // *any* DAO's slot. `initialize_dao_vault_v2` needs no `OwnerCap`, so an
        // attacker could register a vault against someone else's SSU under a DAO
        // they control, then re-key it to the victim's DAO. The victim could
        // then neither register their own vault for that SSU
        // (`EVaultAlreadyExists`) nor free the slot (they hold no Edit on the
        // squatter), and `lookup` — the intended discovery path — resolved their
        // key to the attacker's vault. Granting the victim's OU `Deposit` but
        // not `Withdraw` turned that into a funnel.
        assert!(new_registrant_dao.is_governance_member(sender), ENotAuthorized);

        let old_key = VaultKey {
            storage_unit_id: vault.storage_unit_id,
            registrant_dao_id: vault.registrant_dao_id,
        };
        let new_key = VaultKey {
            storage_unit_id: vault.storage_unit_id,
            registrant_dao_id: new_registrant_dao.id(),
        };
        assert!(table::contains(&registry.vaults, old_key), EInvalidArguments);
        // Cross-vault safety: a caller with Edit on this vault who also has the
        // editor_dao listed as an Ou principal on *another* vault's ACL could
        // otherwise remap the other vault's registry entry. Assert the stored id
        // at old_key really refers to *this* vault before swapping.
        assert!(*table::borrow(&registry.vaults, old_key) == object::id(vault), EInvalidArguments);
        assert!(!table::contains(&registry.vaults, new_key), EVaultAlreadyExists);

        let vault_id = table::remove(&mut registry.vaults, old_key);
        table::add(&mut registry.vaults, new_key, vault_id);
        // M2: keep the vault's self-reported registrant dao in sync so
        // `deinitialize_dao_vault` can later find the right slot to free.
        vault.registrant_dao_id = new_registrant_dao.id();
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
            registrant_dao_id: vault.registrant_dao_id,
        };
        // The registry slot must exist and point at *this* vault. Mirrors the
        // cross-vault safety check in `update_registry_key`.
        assert!(table::contains(&registry.vaults, key), EInvalidArguments);
        assert!(*table::borrow(&registry.vaults, key) == object::id(vault), EVaultRegistryMismatch);
        let vault_id = table::remove(&mut registry.vaults, key);
        let freed_registrant_dao_id = vault.registrant_dao_id;

        // Brick the ACL. Any subsequent assert_role aborts ENotAuthorized.
        //
        // BOTH stores must go: `satisfies_role` reads their union, so clearing
        // only the v1 map would leave every v2 principal holding its role on a
        // vault the registry has already released. On a migrated vault that is
        // all three roles — the orphan would still accept deposits and honor
        // withdrawals, while a fresh vault occupies its freed registry slot.
        while (!vault.acl.is_empty()) {
            vault.acl.pop();
        };
        principal_acl::destroy<Role>(&mut vault.id);
        // Nothing can satisfy any role now — the invariant this function's doc
        // promises, asserted rather than assumed.
        assert!(role_count(vault, Role::Deposit) == 0, ELastEditor);
        assert!(role_count(vault, Role::Withdraw) == 0, ELastEditor);
        assert!(role_count(vault, Role::Edit) == 0, ELastEditor);

        event::emit(VaultDeinitializedEvent {
            vault_id,
            registrant_dao_id: freed_registrant_dao_id,
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

    /// Remove a legacy principal from `role` in BOTH stores, returning true if
    /// either held it.
    ///
    /// `satisfies_role` reads the union, and `grant`/`grant_v2` each write only
    /// their own store without consulting the other, so one identity can sit in
    /// both. Clearing a single store would report success (`revoke` emits per
    /// changed pair and never aborts on a no-op) while leaving the principal
    /// authorized — the failure mode is silent, which is what makes it dangerous
    /// for a vault holding assets. Revocation is therefore identity-wide.
    fun remove_principal_everywhere(
        vault: &mut DaoReceiptVault,
        role: Role,
        principal: Principal,
    ): (Option<Principal>, vector<PrincipalV2>) {
        let from_v1 = if (remove_principal(vault, role, principal)) {
            option::some(principal)
        } else {
            option::none()
        };
        let from_v2 = principal_acl::remove(
            &mut vault.id,
            role,
            acl_v2::from_v1(&principal),
        );
        (from_v1, from_v2)
    }

    /// The `PrincipalV2` counterpart of `remove_principal_everywhere`. Kinds with
    /// no v1 equivalent live only in the v2 store.
    ///
    /// Pairs with `to_v1_equivalent`, not `to_v1`: revoking `machine(x)` must
    /// clear a v1 `Player { x }` as well, since the two admit the same sender.
    fun remove_v2_everywhere(
        vault: &mut DaoReceiptVault,
        role: Role,
        principal: PrincipalV2,
    ): (Option<Principal>, vector<PrincipalV2>) {
        let from_v2 = principal_acl::remove(&mut vault.id, role, principal);
        let legacy = acl_v2::to_v1_equivalent(&principal);
        let from_v1 = if (legacy.is_some()) {
            let twin = *legacy.borrow();
            if (remove_principal(vault, role, twin)) {
                option::some(twin)
            } else {
                option::none()
            }
        } else {
            option::none()
        };
        (from_v1, from_v2)
    }

    /// True when the frozen v1 list for `role` already holds a principal
    /// admitting the same senders as `principal`.
    fun held_in_v1(vault: &DaoReceiptVault, role: Role, principal: &PrincipalV2): bool {
        let legacy = acl_v2::to_v1_equivalent(principal);
        if (legacy.is_none()) { return false };
        vault.acl.contains(&role) && vault.acl.get(&role).contains(legacy.borrow())
    }

    /// Emit one event per store entry a revocation actually cleared.
    ///
    /// Revocation is identity-wide, so a v1 revoke can clear a v2 twin and the
    /// reverse. Emitting only the event matching the kind the *caller* named
    /// would leave an indexer showing a grant the chain no longer holds.
    fun emit_revocations(
        vault_id: ID,
        role: Role,
        cleared_v1: Option<Principal>,
        cleared_v2: vector<PrincipalV2>,
        by: address,
    ) {
        if (cleared_v1.is_some()) {
            event::emit(AclRevokedEvent {
                vault_id,
                role,
                principal: *cleared_v1.borrow(),
                by,
            });
        };
        let n = cleared_v2.length();
        let mut i = 0;
        while (i < n) {
            event::emit(AclRevokedEventV2 { vault_id, role, principal: cleared_v2[i], by });
            i = i + 1;
        };
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

    /// Look up the vault id for a (storage_unit_id, registrant_dao_id) pair.
    public fun lookup(
        registry: &DaoReceiptVaultRegistry,
        storage_unit_id: ID,
        registrant_dao_id: ID,
    ): Option<ID> {
        let key = VaultKey { storage_unit_id, registrant_dao_id };
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
        acl_map: VecMap<Role, vector<Principal>>,
        ctx: &mut TxContext,
    ): DaoReceiptVault {
        // `registrant_dao_id` is set to a sentinel zero-id by default. Tests
        // that *only* exercise ACL paths (most of the suite) can leave it alone.
        // Tests that touch the registry (lookup / update_registry_key /
        // deinitialize) MUST call `set_registrant_dao_id_for_testing` after
        // construction to match the key they register — otherwise
        // `deinitialize_dao_vault` will look up the sentinel slot and abort
        // `EInvalidArguments`. We intentionally don't assert non-zero in deinit
        // because the sentinel is a legitimate `ID` value in production, just
        // unlikely; the doc + helper make the test-side contract explicit.
        DaoReceiptVault {
            id: object::new(ctx),
            storage_unit_id,
            collection_id,
            acl: acl_map,
            non_empty_assets: 0,
            registrant_dao_id: object::id_from_address(@0x0),
        }
    }

    #[test_only]
    public fun set_registrant_dao_id_for_testing(
        vault: &mut DaoReceiptVault,
        registrant_dao_id: ID,
    ) {
        vault.registrant_dao_id = registrant_dao_id;
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
        registrant_dao_id: ID,
        vault_id: ID,
    ) {
        table::add(&mut registry.vaults, VaultKey { storage_unit_id, registrant_dao_id }, vault_id);
    }
}
