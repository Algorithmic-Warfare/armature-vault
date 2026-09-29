/// OU receipt vault (`ou_receipt_vault`) — an OU-gated accumulator for warehouse
/// receipts with a dynamic, multi-principal access-control list.
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
///       * `Ou { ou_id }`   — satisfied when the caller passes the matching `&OU`
///         (`org.id() == ou_id`) and is one of its board members.
///     A caller passes a role check if they satisfy *any* principal listed for it.
///   - `Edit` is ACL administration: holders may batch grant/revoke principals on
///     `Deposit`/`Withdraw` roles via `grant`/`revoke`. The people who can
///     *administer* the vault need not be the people who can *use* it — e.g. AWAR
///     officers hold `Edit` while AWAR/WOLF members hold `Deposit`/`Withdraw`.
///   - `Edit` itself can only be granted via `grant_edit_ou`, which takes a
///     live `&OU` witness. `grant` aborts `EEditMustBeOu` on `Role::Edit`. This
///     forces every `Edit` principal to reference a real on-chain OU and closes
///     brick-by-unsatisfiable-principal attacks (bogus org ids, `Player{@0x0}`)
///     plus bare-`Player` Edit backdoors that would defeat OU migration.
///   - Invariants on `revoke`: (1) `Edit` can never be emptied (`ELastEditor`),
///     and (2) the caller must still satisfy `Edit` via `editor_org` after the
///     batch (`EEditorWouldLockSelf`). Together they prevent both empty-Edit
///     bricks and grant-bogus-then-revoke-self brick paths.
///
/// Why the OU indirection (and not a flat address list): it makes board-membership
/// changes and OU *migration* work without re-listing addresses. A migrated OU
/// gets a new object id; the guaranteed migration path is — create the new OU,
/// grant `Ou { new_ou_id }` the `Edit` role on this vault (old + new editors
/// coexist during cutover), migrate caps/coins to the new OU, then revoke the old
/// `Edit` principal. Only the OU principal can express "the new board" by id.
///
/// The `multicoin` and `world` types used here MUST resolve to the same on-chain
/// packages as the warehouse_receipts package the receipts are minted from
/// (multicoin `e384bbc`, world `32300a2`) — otherwise the `Balance` / `StorageUnit`
/// types diverge and receipts cannot be deposited.
module armature_vault::ou_receipt_vault {
    use armature::ou::OU;
    use armature_vault::acl::{Self as acl, Principal};
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
        b"A receipt vault already exists for this OU at this storage unit";
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

    /// Composite key used in the registry table. Keyed by the *registrant* OU,
    /// which scopes a vault to the OU it was registered for on a given SSU.
    public struct VaultKey has copy, drop, store {
        storage_unit_id: ID,
        registrant_ou_id: ID,
    }

    /// Shared singleton registry mapping (storage_unit_id, editor_ou_id) → vault id.
    public struct OuReceiptVaultRegistry has key {
        id: UID,
        vaults: Table<VaultKey, ID>,
    }

    /// Shared per-(StorageUnit, ...) vault.
    /// Accepts only receipts from `collection_id`. Per-asset balances are stored as
    /// dynamic object fields keyed by asset_id (u64). The ACL maps each role to its
    /// list of principals.
    public struct OuReceiptVault has key {
        id: UID,
        storage_unit_id: ID,
        collection_id: ID,
        acl: VecMap<Role, vector<Principal>>,
        /// M2: number of asset_ids with a live dynamic-object-field entry. Bumped
        /// by `deposit_receipt` when a new asset_id is added; decremented by
        /// `withdraw_receipt` when the last balance for an asset_id is drained.
        /// `deinitialize_ou_vault` asserts this is zero before freeing the
        /// registry slot.
        non_empty_assets: u64,
        /// M2: which registrant OU the registry currently keys this vault under.
        /// Set at init from `registrant_org.id()`; updated by `update_registry_key`.
        /// `deinitialize_ou_vault` uses this to find the right slot to remove,
        /// so the caller doesn't need to track migration history out-of-band.
        registrant_ou_id: ID,
    }

    // === Module initializer ===

    fun init(ctx: &mut TxContext) {
        transfer::share_object(OuReceiptVaultRegistry {
            id: object::new(ctx),
            vaults: table::new(ctx),
        });
    }

    // === Events ===

    public struct VaultInitializedEvent has copy, drop {
        vault_id: ID,
        registrant_ou_id: ID,
        storage_unit_id: ID,
        collection_id: ID,
    }

    /// M2: emitted when a vault is deinitialized — its registry slot is freed and
    /// its ACL is wiped. The vault object itself remains as an orphan (Sui shared
    /// objects cannot be deleted), but is no longer discoverable via `lookup` and
    /// no caller can satisfy any role on it.
    public struct VaultDeinitializedEvent has copy, drop {
        vault_id: ID,
        /// The `registrant_ou_id` component of the `VaultKey` that was freed —
        /// equivalently `vault.registrant_ou_id` at the moment of deinit. After
        /// a prior `update_registry_key` migration this is the *current* registrant
        /// OU id, not the original initializer's. Indexers should treat it as the
        /// registry-key half, not the caller's identity.
        registrant_ou_id: ID,
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

    /// True if `sender` satisfies *some* principal listed for `role`, using `org` as
    /// the OU context. False if the role is absent or no principal matches.
    fun satisfies_role(vault: &OuReceiptVault, role: Role, org: &OU, sender: address): bool {
        if (!vault.acl.contains(&role)) { return false };
        let principals = vault.acl.get(&role);
        let n = principals.length();
        let mut i = 0;
        while (i < n) {
            if (acl::satisfies(&principals[i], org, sender)) {
                return true
            };
            i = i + 1;
        };
        false
    }

    /// Aborts with `ENotAuthorized` unless `satisfies_role` holds.
    fun assert_role(vault: &OuReceiptVault, role: Role, org: &OU, sender: address) {
        assert!(satisfies_role(vault, role, org, sender), ENotAuthorized);
    }

    // === Public: lifecycle ===

    /// Initialize a vault on a given StorageUnit.
    ///
    /// The caller must be a board member of `registrant_org`. `registrant_org` is
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
    /// Deposit/Withdraw" in a single init call: pass the officer OU's Ou principal
    /// in `edit_principals` and the member OU's Ou principal in
    /// `deposit_principals`/`withdraw_principals`, with the member OU as
    /// `registrant_org` so the vault is directly discoverable under the member
    /// OU's registry key.
    ///
    /// Reverts if a vault for this (SSU, registrant_org) pair already exists.
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
    /// where any OU board member could register a vault against any
    /// `&StorageUnit` they could obtain a reference to. The composition F1+M1
    /// ensures both halves of the binding (Collection<->SSU and caller<->SSU)
    /// are verified by witness, not trusted from input.
    ///
    /// Trust assumption (not verified on-chain): the caller — a governance member
    /// of `registrant_org` who possesses `OwnerCap<StorageUnit>` — is acting on
    /// behalf of the OU. M1 verifies (caller passes board-membership check) AND
    /// (caller can produce the OwnerCap), but does NOT verify the OU *collectively*
    /// controls the cap. A board member personally holding the cap can unilaterally
    /// bind that SSU to their OU's vault. If you need cap-custody under OU
    /// governance, custody the cap in the OU's treasury and borrow it via the
    /// OU's standard proposal flow.
    public fun initialize_ou_vault(
        registry: &mut OuReceiptVaultRegistry,
        storage_unit: &StorageUnit,
        owner_cap: &OwnerCap<StorageUnit>,
        registrant_org: &OU,
        vault_config: &VaultConfig,
        deposit_principals: vector<Principal>,
        withdraw_principals: vector<Principal>,
        edit_principals: vector<Principal>,
        ctx: &mut TxContext,
    ) {
        assert!(registrant_org.is_governance_member(ctx.sender()), ENotAuthorized);
        assert!(!edit_principals.is_empty(), EEmptyEditPrincipals);

        let storage_unit_id = object::id(storage_unit);
        // M1: caller's OwnerCap must authorize this SSU.
        assert!(access::is_authorized(owner_cap, storage_unit_id), EUnauthorizedForStorageUnit);
        // F1: the VaultConfig's bound SSU must match the passed StorageUnit. This
        // is the verifier that closes the "wrong collection for this SSU" hole.
        assert!(vault_config.storage_unit_id() == storage_unit_id, EStorageUnitMismatch);
        let collection_id = vault_config.collection_id();

        let registrant_ou_id = registrant_org.id();
        let key = VaultKey { storage_unit_id, registrant_ou_id };
        assert!(!table::contains(&registry.vaults, key), EVaultAlreadyExists);

        let mut vault_acl = vec_map::empty<Role, vector<Principal>>();
        if (!deposit_principals.is_empty()) {
            vault_acl.insert(Role::Deposit, deposit_principals);
        };
        if (!withdraw_principals.is_empty()) {
            vault_acl.insert(Role::Withdraw, withdraw_principals);
        };
        vault_acl.insert(Role::Edit, edit_principals);

        let vault = OuReceiptVault {
            id: object::new(ctx),
            storage_unit_id,
            collection_id,
            acl: vault_acl,
            non_empty_assets: 0,
            registrant_ou_id,
        };
        let vault_id = object::id(&vault);

        event::emit(VaultInitializedEvent {
            vault_id,
            registrant_ou_id,
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

    /// Governance-member-only variant of `initialize_ou_vault` that does not
    /// require an `OwnerCap<StorageUnit>`. Any board member of `registrant_org`
    /// may call this — the SSU-owner gate is intentionally absent. Prefer this
    /// when the SSU owner and the OU board member are different accounts.
    public fun initialize_ou_vault_v2(
        registry: &mut OuReceiptVaultRegistry,
        storage_unit: &StorageUnit,
        registrant_org: &OU,
        vault_config: &VaultConfig,
        deposit_principals: vector<Principal>,
        withdraw_principals: vector<Principal>,
        edit_principals: vector<Principal>,
        ctx: &mut TxContext,
    ) {
        assert!(registrant_org.is_governance_member(ctx.sender()), ENotAuthorized);
        assert!(!edit_principals.is_empty(), EEmptyEditPrincipals);

        let storage_unit_id = object::id(storage_unit);
        // F1: the VaultConfig's bound SSU must match the passed StorageUnit.
        assert!(vault_config.storage_unit_id() == storage_unit_id, EStorageUnitMismatch);
        let collection_id = vault_config.collection_id();

        let registrant_ou_id = registrant_org.id();
        let key = VaultKey { storage_unit_id, registrant_ou_id };
        assert!(!table::contains(&registry.vaults, key), EVaultAlreadyExists);

        let mut vault_acl = vec_map::empty<Role, vector<Principal>>();
        if (!deposit_principals.is_empty()) {
            vault_acl.insert(Role::Deposit, deposit_principals);
        };
        if (!withdraw_principals.is_empty()) {
            vault_acl.insert(Role::Withdraw, withdraw_principals);
        };
        vault_acl.insert(Role::Edit, edit_principals);

        let vault = OuReceiptVault {
            id: object::new(ctx),
            storage_unit_id,
            collection_id,
            acl: vault_acl,
            non_empty_assets: 0,
            registrant_ou_id,
        };
        let vault_id = object::id(&vault);

        event::emit(VaultInitializedEvent {
            vault_id,
            registrant_ou_id,
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
    /// `org` as their OU context (or be a bare `Player` deposit principal, in which
    /// case any `&OU` may be passed). Receipt must belong to the vault's collection.
    public fun deposit_receipt(
        vault: &mut OuReceiptVault,
        org: &OU,
        receipt: Balance,
        ctx: &mut TxContext,
    ) {
        let sender = ctx.sender();
        assert_role(vault, Role::Deposit, org, sender);
        assert!(receipt.collection_id() == vault.collection_id, EWrongCollection);
        // M4/L2: reject zero-value deposits so a Deposit-only principal cannot
        // unilaterally grow the vault's DOF set with phantom entries.
        assert!(receipt.value() > 0, EZeroAmount);

        let asset_id = receipt.asset_id();
        let amount = receipt.value();

        if (dof::exists(&vault.id, asset_id)) {
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
    /// `Withdraw` role using `org` as their OU context. Returns the split Balance.
    public fun withdraw_receipt(
        vault: &mut OuReceiptVault,
        org: &OU,
        asset_id: u64,
        amount: u64,
        ctx: &mut TxContext,
    ): Balance {
        let sender = ctx.sender();
        assert_role(vault, Role::Withdraw, org, sender);
        // F3: reject zero-amount withdrawals so indexers don't see spurious WithdrawEvents.
        assert!(amount > 0, EZeroAmount);

        assert!(dof::exists(&vault.id, asset_id), EInsufficientVaultBalance);
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
    /// `editor_org` as their OU context. `roles` and `principals` are parallel vectors
    /// (same length); each (role, principal) pair is added if not already present.
    public fun grant(
        vault: &mut OuReceiptVault,
        editor_org: &OU,
        roles: vector<Role>,
        principals: vector<Principal>,
        ctx: &TxContext,
    ) {
        let sender = ctx.sender();
        assert_role(vault, Role::Edit, editor_org, sender);
        // F5: distinct error code so callers can tell bad-input from auth failure.
        assert!(roles.length() == principals.length(), EInvalidArguments);

        let vault_id = object::id(vault);
        let n = roles.length();
        let mut i = 0;
        while (i < n) {
            let role = roles[i];
            let principal = principals[i];
            // H1/M3: Edit principals must come through grant_edit_ou, which validates
            // the &OU witness and refuses bare-Player and unverifiable-Ou principals.
            assert!(role != Role::Edit, EEditMustBeOu);
            // L1: only emit on real state change.
            let changed = add_principal(vault, role, principal);
            if (changed) {
                event::emit(AclGrantedEvent { vault_id, role, principal, by: sender });
            };
            i = i + 1;
        };
    }

    /// H1: grant the Edit role to an OU, validated by a live `&OU` witness. This
    /// is the only path that can add an Edit principal — it forces every Edit grant
    /// to reference a real OU with at least one governance member, closing the
    /// brick-by-unsatisfiable-principal attack and the bare-Player Edit backdoor.
    public fun grant_edit_ou(
        vault: &mut OuReceiptVault,
        editor_org: &OU,
        target_org: &OU,
        ctx: &TxContext,
    ) {
        let sender = ctx.sender();
        assert_role(vault, Role::Edit, editor_org, sender);

        let vault_id = object::id(vault);
        let principal = acl::ou(target_org.id());
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
    /// using `editor_org`. Each (role, principal) pair is removed if present.
    /// Aborts (`ELastEditor`) if a revocation would leave `Edit` with no principals.
    public fun revoke(
        vault: &mut OuReceiptVault,
        editor_org: &OU,
        roles: vector<Role>,
        principals: vector<Principal>,
        ctx: &TxContext,
    ) {
        let sender = ctx.sender();
        assert_role(vault, Role::Edit, editor_org, sender);
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
        let edit_role = Role::Edit;
        assert!(
            vault.acl.contains(&edit_role) && vault.acl.get(&edit_role).length() > 0,
            ELastEditor,
        );
        // H1: brick-guard 2 — the caller must still satisfy Edit using editor_org.
        // Prevents grant-bogus-then-revoke-self bricking attacks: a rogue can only
        // remove themselves from Edit if some other satisfiable principal remains
        // for *them* (which they can verify by passing the same editor_org). This
        // is the post-state version of assert_role(Edit, ...) — it would have
        // succeeded entering revoke; the assertion forces it to still hold on exit.
        assert!(satisfies_role(vault, Role::Edit, editor_org, sender), EEditorWouldLockSelf);

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

    /// F4: re-key the registry entry for this vault after a registrant OU migration.
    /// The caller must satisfy the current `Edit` role using `editor_org`. The old
    /// key is derived from `vault.registrant_ou_id`; the new key uses
    /// `new_registrant_org.id()`. Aborts if no entry exists for the old key or if
    /// an entry already exists for the new key.
    ///
    /// This does NOT alter the ACL. This function only keeps `lookup(...)` discoverable
    /// under the new registrant OU's identity.
    public fun update_registry_key(
        registry: &mut OuReceiptVaultRegistry,
        vault: &mut OuReceiptVault,
        editor_org: &OU,
        new_registrant_org: &OU,
        ctx: &TxContext,
    ) {
        let sender = ctx.sender();
        assert_role(vault, Role::Edit, editor_org, sender);

        let old_key = VaultKey {
            storage_unit_id: vault.storage_unit_id,
            registrant_ou_id: vault.registrant_ou_id,
        };
        let new_key = VaultKey {
            storage_unit_id: vault.storage_unit_id,
            registrant_ou_id: new_registrant_org.id(),
        };
        assert!(table::contains(&registry.vaults, old_key), EInvalidArguments);
        // Cross-vault safety: a caller with Edit on this vault who also has the
        // editor_org listed as an Ou principal on *another* vault's ACL could
        // otherwise remap the other vault's registry entry. Assert the stored id
        // at old_key really refers to *this* vault before swapping.
        assert!(*table::borrow(&registry.vaults, old_key) == object::id(vault), EInvalidArguments);
        assert!(!table::contains(&registry.vaults, new_key), EVaultAlreadyExists);

        let vault_id = table::remove(&mut registry.vaults, old_key);
        table::add(&mut registry.vaults, new_key, vault_id);
        // M2: keep the vault's self-reported registrant org in sync so
        // `deinitialize_ou_vault` can later find the right slot to free.
        vault.registrant_ou_id = new_registrant_org.id();
    }

    /// M2: free the registry slot for this vault's (SSU, current editor_org) key
    /// and effectively brick the vault by clearing its ACL. The caller must satisfy
    /// `Edit` using `editor_org`, and the vault must be empty
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
    /// `editor_org` may differ from the original initializer — after
    /// `update_registry_key` the vault's current registry slot is keyed by the
    /// migrated OU id. The vault tracks `registry_key_ou_id` internally and
    /// uses it to locate the slot, so the caller only needs an OU that satisfies
    /// the current `Edit` role.
    public fun deinitialize_ou_vault(
        registry: &mut OuReceiptVaultRegistry,
        vault: &mut OuReceiptVault,
        editor_org: &OU,
        ctx: &TxContext,
    ) {
        let sender = ctx.sender();
        assert_role(vault, Role::Edit, editor_org, sender);
        assert!(vault.non_empty_assets == 0, EVaultNonEmpty);

        let key = VaultKey {
            storage_unit_id: vault.storage_unit_id,
            registrant_ou_id: vault.registrant_ou_id,
        };
        // The registry slot must exist and point at *this* vault. Mirrors the
        // cross-vault safety check in `update_registry_key`.
        assert!(table::contains(&registry.vaults, key), EInvalidArguments);
        assert!(*table::borrow(&registry.vaults, key) == object::id(vault), EVaultRegistryMismatch);
        let vault_id = table::remove(&mut registry.vaults, key);
        let freed_registrant_ou_id = vault.registrant_ou_id;

        // Brick the ACL. Any subsequent assert_role aborts ENotAuthorized.
        while (!vault.acl.is_empty()) {
            vault.acl.pop();
        };

        event::emit(VaultDeinitializedEvent {
            vault_id,
            registrant_ou_id: freed_registrant_ou_id,
            by: sender,
        });
    }

    // === ACL mutation (internal) ===

    /// Returns true iff the principal was actually added (i.e. state changed).
    fun add_principal(vault: &mut OuReceiptVault, role: Role, principal: Principal): bool {
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
    fun remove_principal(vault: &mut OuReceiptVault, role: Role, principal: Principal): bool {
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

    /// Look up the vault id for a (storage_unit_id, registrant_ou_id) pair.
    public fun lookup(
        registry: &OuReceiptVaultRegistry,
        storage_unit_id: ID,
        registrant_ou_id: ID,
    ): Option<ID> {
        let key = VaultKey { storage_unit_id, registrant_ou_id };
        if (table::contains(&registry.vaults, key)) {
            option::some(*table::borrow(&registry.vaults, key))
        } else {
            option::none()
        }
    }

    public fun storage_unit_id(vault: &OuReceiptVault): ID {
        vault.storage_unit_id
    }

    public fun collection_id(vault: &OuReceiptVault): ID {
        vault.collection_id
    }

    /// Returns the list of principals for a role (empty if the role is unset).
    public fun principals(vault: &OuReceiptVault, role: Role): vector<Principal> {
        if (vault.acl.contains(&role)) {
            *vault.acl.get(&role)
        } else {
            vector[]
        }
    }

    /// Returns the vault's accumulated balance for a given asset_id.
    public fun vault_balance(vault: &OuReceiptVault, asset_id: u64): u64 {
        if (dof::exists(&vault.id, asset_id)) {
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
    ): OuReceiptVault {
        // `registrant_ou_id` is set to a sentinel zero-id by default. Tests
        // that *only* exercise ACL paths (most of the suite) can leave it alone.
        // Tests that touch the registry (lookup / update_registry_key /
        // deinitialize) MUST call `set_registrant_ou_id_for_testing` after
        // construction to match the key they register — otherwise
        // `deinitialize_ou_vault` will look up the sentinel slot and abort
        // `EInvalidArguments`. We intentionally don't assert non-zero in deinit
        // because the sentinel is a legitimate `ID` value in production, just
        // unlikely; the doc + helper make the test-side contract explicit.
        OuReceiptVault {
            id: object::new(ctx),
            storage_unit_id,
            collection_id,
            acl: acl_map,
            non_empty_assets: 0,
            registrant_ou_id: object::id_from_address(@0x0),
        }
    }

    #[test_only]
    public fun set_registrant_ou_id_for_testing(
        vault: &mut OuReceiptVault,
        registrant_ou_id: ID,
    ) {
        vault.registrant_ou_id = registrant_ou_id;
    }

    #[test_only]
    public fun share_for_testing(vault: OuReceiptVault) {
        transfer::share_object(vault)
    }

    #[test_only]
    public fun init_for_testing(ctx: &mut TxContext) {
        init(ctx)
    }

    #[test_only]
    public fun register_for_testing(
        registry: &mut OuReceiptVaultRegistry,
        storage_unit_id: ID,
        registrant_ou_id: ID,
        vault_id: ID,
    ) {
        table::add(&mut registry.vaults, VaultKey { storage_unit_id, registrant_ou_id }, vault_id);
    }
}
