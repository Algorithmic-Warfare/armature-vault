/// Tests for `dao_receipt_vault` — the dynamic multi-principal DAO/OU-gated
/// receipt vault.
///
/// Scenarios mirror the motivating example: a shared storage where AWAR members
/// and WOLF members (two OUs) plus Protodroid (a bare player) can deposit and
/// withdraw, while AWAR officers (a higher OU) hold the Edit role and can remove
/// a principal who goes rogue. Plus the DAO-migration path and the last-editor
/// brick guard.
///
/// Vaults are built via `new_for_testing` to skip the heavy world StorageUnit
/// anchor — the ACL paths under test never reference the StorageUnit.
#[test_only]
module armature_vault::dao_receipt_vault_tests {
    use armature::{dao::{Self, DAO}, governance};
    use armature_vault::dao_receipt_vault::{Self as vault, DaoReceiptVault, Role, Principal};
    use multicoin::multicoin::{Self, Collection, CollectionCap, Balance};
    use std::string;
    use sui::{test_scenario as ts, vec_map};

    // AWAR members
    const AWAR_M1: address = @0xA1;
    // WOLF members
    const WOLF_M1: address = @0xB1;
    // Protodroid — bare player principal
    const PROTO: address = @0xC1;
    // AWAR officer — holds Edit
    const AWAR_OFFICER: address = @0xD1;
    // Nobody
    const OUTSIDER: address = @0x0E;

    const ASSET: u64 = 7;

    // === Helpers ===

    fun make_dao(scenario: &mut ts::Scenario, creator: address, members: vector<address>): ID {
        ts::next_tx(scenario, creator);
        let init = governance::init_board(members);
        dao::create(
            &init,
            string::utf8(b"OU"),
            string::utf8(b"ou"),
            string::utf8(b"https://example.com/i.png"),
            scenario.ctx(),
        )
    }

    fun make_collection(scenario: &mut ts::Scenario, owner: address): ID {
        ts::next_tx(scenario, owner);
        let (collection, cap) = multicoin::new_collection(scenario.ctx());
        let cid = object::id(&collection);
        transfer::public_share_object(collection);
        transfer::public_transfer(cap, owner);
        cid
    }

    fun mint(
        scenario: &mut ts::Scenario,
        owner: address,
        collection_id: ID,
        asset_id: u64,
        amount: u64,
    ): Balance {
        ts::next_tx(scenario, owner);
        let mut collection = ts::take_shared_by_id<Collection>(scenario, collection_id);
        let cap = ts::take_from_sender<CollectionCap>(scenario);
        let bal = multicoin::mint_balance(&cap, &mut collection, asset_id, amount, scenario.ctx());
        ts::return_to_sender(scenario, cap);
        ts::return_shared(collection);
        bal
    }

    /// Build the example ACL:
    ///   deposit/withdraw: [ou(awar_members), ou(wolf_members), player(proto)]
    ///   edit:             [ou(awar_officers)]
    fun example_acl(
        awar_members: ID,
        wolf_members: ID,
        awar_officers: ID,
    ): vec_map::VecMap<Role, vector<Principal>> {
        let use_perms = vector[
            vault::ou(awar_members),
            vault::ou(wolf_members),
            vault::player(PROTO),
        ];
        let mut acl = vec_map::empty<Role, vector<Principal>>();
        acl.insert(vault::role_deposit(), use_perms);
        acl.insert(vault::role_withdraw(), use_perms);
        acl.insert(vault::role_edit(), vector[vault::ou(awar_officers)]);
        acl
    }

    // === Tests ===

    /// AWAR member deposits; WOLF member deposits; Protodroid (player) withdraws.
    #[test]
    fun multi_principal_deposit_withdraw() {
        let mut scenario = ts::begin(AWAR_M1);

        let awar = make_dao(&mut scenario, AWAR_M1, vector[AWAR_M1]);
        let wolf = make_dao(&mut scenario, WOLF_M1, vector[WOLF_M1]);
        let officers = make_dao(&mut scenario, AWAR_OFFICER, vector[AWAR_OFFICER]);
        let collection_id = make_collection(&mut scenario, AWAR_M1);

        ts::next_tx(&mut scenario, AWAR_M1);
        let v = vault::new_for_testing(
            object::id_from_address(@0x5501),
            collection_id,
            example_acl(awar, wolf, officers),
            scenario.ctx(),
        );
        vault::share_for_testing(v);

        // AWAR member deposits 100 (acting as the AWAR OU).
        let r1 = mint(&mut scenario, AWAR_M1, collection_id, ASSET, 100);
        ts::next_tx(&mut scenario, AWAR_M1);
        {
            let mut v = ts::take_shared<DaoReceiptVault>(&scenario);
            let awar_dao = ts::take_shared_by_id<DAO>(&scenario, awar);
            vault::deposit_receipt(&mut v, &awar_dao, r1, scenario.ctx());
            ts::return_shared(awar_dao);
            ts::return_shared(v);
        };

        // WOLF member deposits 50 (acting as the WOLF OU). The receipt is minted by
        // the collection owner (AWAR_M1 holds the CollectionCap) and handed to WOLF.
        let r2 = mint(&mut scenario, AWAR_M1, collection_id, ASSET, 50);
        ts::next_tx(&mut scenario, WOLF_M1);
        {
            let mut v = ts::take_shared<DaoReceiptVault>(&scenario);
            let wolf_dao = ts::take_shared_by_id<DAO>(&scenario, wolf);
            vault::deposit_receipt(&mut v, &wolf_dao, r2, scenario.ctx());
            assert!(vault::vault_balance(&v, ASSET) == 150, 0);
            ts::return_shared(wolf_dao);
            ts::return_shared(v);
        };

        // Protodroid (bare player) withdraws 60 — passes any DAO ref (uses AWAR's).
        ts::next_tx(&mut scenario, PROTO);
        {
            let mut v = ts::take_shared<DaoReceiptVault>(&scenario);
            let any_dao = ts::take_shared_by_id<DAO>(&scenario, awar);
            let out = vault::withdraw_receipt(&mut v, &any_dao, ASSET, 60, scenario.ctx());
            assert!(out.value() == 60, 1);
            assert!(vault::vault_balance(&v, ASSET) == 90, 2);
            transfer::public_transfer(out, PROTO);
            ts::return_shared(any_dao);
            ts::return_shared(v);
        };

        ts::end(scenario);
    }

    /// An outsider (no principal) cannot deposit.
    #[test]
    #[expected_failure(abort_code = vault::ENotAuthorized)]
    fun deposit_rejected_for_outsider() {
        let mut scenario = ts::begin(AWAR_M1);
        let awar = make_dao(&mut scenario, AWAR_M1, vector[AWAR_M1]);
        let wolf = make_dao(&mut scenario, WOLF_M1, vector[WOLF_M1]);
        let officers = make_dao(&mut scenario, AWAR_OFFICER, vector[AWAR_OFFICER]);
        let collection_id = make_collection(&mut scenario, AWAR_M1);

        ts::next_tx(&mut scenario, AWAR_M1);
        let v = vault::new_for_testing(
            object::id_from_address(@0x5501),
            collection_id,
            example_acl(awar, wolf, officers),
            scenario.ctx(),
        );
        vault::share_for_testing(v);

        let r = mint(&mut scenario, AWAR_M1, collection_id, ASSET, 10);
        // OUTSIDER tries to deposit, passing AWAR's DAO (they aren't a member).
        ts::next_tx(&mut scenario, OUTSIDER);
        let mut v = ts::take_shared<DaoReceiptVault>(&scenario);
        let awar_dao = ts::take_shared_by_id<DAO>(&scenario, awar);
        vault::deposit_receipt(&mut v, &awar_dao, r, scenario.ctx());

        abort
    }

    /// AWAR officers (Edit) revoke Protodroid's withdraw perm; he can no longer withdraw.
    #[test]
    #[expected_failure(abort_code = vault::ENotAuthorized)]
    fun officers_revoke_rogue_player() {
        let mut scenario = ts::begin(AWAR_M1);
        let awar = make_dao(&mut scenario, AWAR_M1, vector[AWAR_M1]);
        let wolf = make_dao(&mut scenario, WOLF_M1, vector[WOLF_M1]);
        let officers = make_dao(&mut scenario, AWAR_OFFICER, vector[AWAR_OFFICER]);
        let collection_id = make_collection(&mut scenario, AWAR_M1);

        ts::next_tx(&mut scenario, AWAR_M1);
        let v = vault::new_for_testing(
            object::id_from_address(@0x5501),
            collection_id,
            example_acl(awar, wolf, officers),
            scenario.ctx(),
        );
        vault::share_for_testing(v);

        // Seed some balance via AWAR member.
        let r = mint(&mut scenario, AWAR_M1, collection_id, ASSET, 100);
        ts::next_tx(&mut scenario, AWAR_M1);
        {
            let mut v = ts::take_shared<DaoReceiptVault>(&scenario);
            let awar_dao = ts::take_shared_by_id<DAO>(&scenario, awar);
            vault::deposit_receipt(&mut v, &awar_dao, r, scenario.ctx());
            ts::return_shared(awar_dao);
            ts::return_shared(v);
        };

        // Officer revokes Protodroid from both deposit and withdraw (batch).
        ts::next_tx(&mut scenario, AWAR_OFFICER);
        {
            let mut v = ts::take_shared<DaoReceiptVault>(&scenario);
            let officers_dao = ts::take_shared_by_id<DAO>(&scenario, officers);
            vault::revoke(
                &mut v,
                &officers_dao,
                vector[vault::role_deposit(), vault::role_withdraw()],
                vector[vault::player(PROTO), vault::player(PROTO)],
                scenario.ctx(),
            );
            ts::return_shared(officers_dao);
            ts::return_shared(v);
        };

        // Protodroid now tries to withdraw — must abort ENotAuthorized.
        ts::next_tx(&mut scenario, PROTO);
        let mut v = ts::take_shared<DaoReceiptVault>(&scenario);
        let awar_dao = ts::take_shared_by_id<DAO>(&scenario, awar);
        let out = vault::withdraw_receipt(&mut v, &awar_dao, ASSET, 10, scenario.ctx());
        transfer::public_transfer(out, PROTO);

        abort
    }

    /// A non-editor cannot administer the ACL.
    #[test]
    #[expected_failure(abort_code = vault::ENotAuthorized)]
    fun non_editor_cannot_grant() {
        let mut scenario = ts::begin(AWAR_M1);
        let awar = make_dao(&mut scenario, AWAR_M1, vector[AWAR_M1]);
        let wolf = make_dao(&mut scenario, WOLF_M1, vector[WOLF_M1]);
        let officers = make_dao(&mut scenario, AWAR_OFFICER, vector[AWAR_OFFICER]);
        let collection_id = make_collection(&mut scenario, AWAR_M1);

        ts::next_tx(&mut scenario, AWAR_M1);
        let v = vault::new_for_testing(
            object::id_from_address(@0x5501),
            collection_id,
            example_acl(awar, wolf, officers),
            scenario.ctx(),
        );
        vault::share_for_testing(v);

        // AWAR member (deposit/withdraw, NOT edit) tries to grant — must abort.
        ts::next_tx(&mut scenario, AWAR_M1);
        let mut v = ts::take_shared<DaoReceiptVault>(&scenario);
        let awar_dao = ts::take_shared_by_id<DAO>(&scenario, awar);
        vault::grant(
            &mut v,
            &awar_dao,
            vector[vault::role_deposit()],
            vector[vault::player(OUTSIDER)],
            scenario.ctx(),
        );

        abort
    }

    /// Migration path: a new DAO is granted Edit (coexisting with the old editor),
    /// then the old editor is revoked. The new DAO can administer; the property we
    /// assert is that the new OU's Edit grant takes effect and the old one is gone.
    #[test]
    fun migration_grant_new_editor_then_revoke_old() {
        let mut scenario = ts::begin(AWAR_M1);
        let awar = make_dao(&mut scenario, AWAR_M1, vector[AWAR_M1]);
        let wolf = make_dao(&mut scenario, WOLF_M1, vector[WOLF_M1]);
        let officers = make_dao(&mut scenario, AWAR_OFFICER, vector[AWAR_OFFICER]);
        let collection_id = make_collection(&mut scenario, AWAR_M1);

        ts::next_tx(&mut scenario, AWAR_M1);
        let v = vault::new_for_testing(
            object::id_from_address(@0x5501),
            collection_id,
            example_acl(awar, wolf, officers),
            scenario.ctx(),
        );
        vault::share_for_testing(v);

        // The "migrated" officers DAO (new id, same officer on board for the test).
        let new_officers = make_dao(&mut scenario, AWAR_OFFICER, vector[AWAR_OFFICER]);

        // Old officers grant Edit to the new officers OU (both editors coexist).
        // Edit grants must go through grant_edit_ou, which validates the &DAO witness.
        ts::next_tx(&mut scenario, AWAR_OFFICER);
        {
            let mut v = ts::take_shared<DaoReceiptVault>(&scenario);
            let officers_dao = ts::take_shared_by_id<DAO>(&scenario, officers);
            let new_officers_dao = ts::take_shared_by_id<DAO>(&scenario, new_officers);
            vault::grant_edit_ou(&mut v, &officers_dao, &new_officers_dao, scenario.ctx());
            assert!(vault::principals(&v, vault::role_edit()).length() == 2, 0);
            ts::return_shared(new_officers_dao);
            ts::return_shared(officers_dao);
            ts::return_shared(v);
        };

        // New officers DAO now revokes the old Edit principal (valid editor itself).
        ts::next_tx(&mut scenario, AWAR_OFFICER);
        {
            let mut v = ts::take_shared<DaoReceiptVault>(&scenario);
            let new_officers_dao = ts::take_shared_by_id<DAO>(&scenario, new_officers);
            vault::revoke(
                &mut v,
                &new_officers_dao,
                vector[vault::role_edit()],
                vector[vault::ou(officers)],
                scenario.ctx(),
            );
            assert!(vault::principals(&v, vault::role_edit()).length() == 1, 1);
            ts::return_shared(new_officers_dao);
            ts::return_shared(v);
        };

        ts::end(scenario);
    }

    /// The last Edit principal cannot be revoked (brick guard).
    #[test]
    #[expected_failure(abort_code = vault::ELastEditor)]
    fun cannot_revoke_last_editor() {
        let mut scenario = ts::begin(AWAR_M1);
        let awar = make_dao(&mut scenario, AWAR_M1, vector[AWAR_M1]);
        let wolf = make_dao(&mut scenario, WOLF_M1, vector[WOLF_M1]);
        let officers = make_dao(&mut scenario, AWAR_OFFICER, vector[AWAR_OFFICER]);
        let collection_id = make_collection(&mut scenario, AWAR_M1);

        ts::next_tx(&mut scenario, AWAR_M1);
        let v = vault::new_for_testing(
            object::id_from_address(@0x5501),
            collection_id,
            example_acl(awar, wolf, officers),
            scenario.ctx(),
        );
        vault::share_for_testing(v);

        // Officers try to revoke themselves — the only Edit principal — must abort.
        ts::next_tx(&mut scenario, AWAR_OFFICER);
        let mut v = ts::take_shared<DaoReceiptVault>(&scenario);
        let officers_dao = ts::take_shared_by_id<DAO>(&scenario, officers);
        vault::revoke(
            &mut v,
            &officers_dao,
            vector[vault::role_edit()],
            vector[vault::ou(officers)],
            scenario.ctx(),
        );

        abort
    }

    // =============================================================================
    // === Regression tests for issue #1 fixes (F2/F3/F4/F5 + H1/M3/M4/L1/L2/I1)
    // === Each test was originally written against unfixed code as part of the
    // === adversarial review in
    // === https://github.com/Algorithmic-Warfare/armature-vault/issues/1#issuecomment-4690910572
    // === then flipped here to verify the fix shipped in PR #2.
    // =============================================================================

    // --- H1/M3: Edit role must be granted via grant_edit_ou (rejects Player + bogus Ou)

    /// Original H1 (Player variant): bypass attempted via Player{@0x0}. Post-fix the
    /// grant() call rejects the Edit role itself with EEditMustBeOu, before the
    /// Principal value is ever inspected.
    #[test]
    #[expected_failure(abort_code = vault::EEditMustBeOu)]
    fun grant_rejects_player_for_edit_role() {
        let mut scenario = ts::begin(AWAR_M1);
        let awar = make_dao(&mut scenario, AWAR_M1, vector[AWAR_M1]);
        let wolf = make_dao(&mut scenario, WOLF_M1, vector[WOLF_M1]);
        let officers = make_dao(&mut scenario, AWAR_OFFICER, vector[AWAR_OFFICER]);
        let collection_id = make_collection(&mut scenario, AWAR_M1);

        ts::next_tx(&mut scenario, AWAR_M1);
        let v = vault::new_for_testing(
            object::id_from_address(@0x5501),
            collection_id,
            example_acl(awar, wolf, officers),
            scenario.ctx(),
        );
        vault::share_for_testing(v);

        ts::next_tx(&mut scenario, AWAR_OFFICER);
        let mut v = ts::take_shared<DaoReceiptVault>(&scenario);
        let officers_dao = ts::take_shared_by_id<DAO>(&scenario, officers);
        vault::grant(
            &mut v,
            &officers_dao,
            vector[vault::role_edit()],
            vector[vault::player(@0x0)],
            scenario.ctx(),
        );

        abort
    }

    /// Original H1 (Ou variant): bypass attempted via Ou{bogus_dao_id}. Post-fix the
    /// grant() call rejects the Edit role itself — bogus Ou ids are no longer reachable.
    #[test]
    #[expected_failure(abort_code = vault::EEditMustBeOu)]
    fun grant_rejects_bogus_ou_for_edit_role() {
        let mut scenario = ts::begin(AWAR_M1);
        let awar = make_dao(&mut scenario, AWAR_M1, vector[AWAR_M1]);
        let wolf = make_dao(&mut scenario, WOLF_M1, vector[WOLF_M1]);
        let officers = make_dao(&mut scenario, AWAR_OFFICER, vector[AWAR_OFFICER]);
        let collection_id = make_collection(&mut scenario, AWAR_M1);

        ts::next_tx(&mut scenario, AWAR_M1);
        let v = vault::new_for_testing(
            object::id_from_address(@0x5501),
            collection_id,
            example_acl(awar, wolf, officers),
            scenario.ctx(),
        );
        vault::share_for_testing(v);

        let bogus = object::id_from_address(@0xDEADBEEF);
        ts::next_tx(&mut scenario, AWAR_OFFICER);
        let mut v = ts::take_shared<DaoReceiptVault>(&scenario);
        let officers_dao = ts::take_shared_by_id<DAO>(&scenario, officers);
        vault::grant(
            &mut v,
            &officers_dao,
            vector[vault::role_edit()],
            vector[vault::ou(bogus)],
            scenario.ctx(),
        );

        abort
    }

    /// Original M3: rogue self-grants Player Edit then revokes the OU. Post-fix the
    /// initial grant aborts EEditMustBeOu — the bare-Player Edit backdoor is closed.
    #[test]
    #[expected_failure(abort_code = vault::EEditMustBeOu)]
    fun grant_rejects_player_self_grant_for_edit() {
        let mut scenario = ts::begin(AWAR_M1);
        let awar = make_dao(&mut scenario, AWAR_M1, vector[AWAR_M1]);
        let wolf = make_dao(&mut scenario, WOLF_M1, vector[WOLF_M1]);
        let officers = make_dao(&mut scenario, AWAR_OFFICER, vector[AWAR_OFFICER]);
        let collection_id = make_collection(&mut scenario, AWAR_M1);

        ts::next_tx(&mut scenario, AWAR_M1);
        let v = vault::new_for_testing(
            object::id_from_address(@0x5501),
            collection_id,
            example_acl(awar, wolf, officers),
            scenario.ctx(),
        );
        vault::share_for_testing(v);

        ts::next_tx(&mut scenario, AWAR_OFFICER);
        let mut v = ts::take_shared<DaoReceiptVault>(&scenario);
        let officers_dao = ts::take_shared_by_id<DAO>(&scenario, officers);
        vault::grant(
            &mut v,
            &officers_dao,
            vector[vault::role_edit()],
            vector[vault::player(AWAR_OFFICER)],
            scenario.ctx(),
        );

        abort
    }

    /// H1 positive: grant_edit_ou succeeds with a real &DAO witness and emits an event.
    #[test]
    fun grant_edit_ou_happy_path() {
        let mut scenario = ts::begin(AWAR_M1);
        let awar = make_dao(&mut scenario, AWAR_M1, vector[AWAR_M1]);
        let wolf = make_dao(&mut scenario, WOLF_M1, vector[WOLF_M1]);
        let officers = make_dao(&mut scenario, AWAR_OFFICER, vector[AWAR_OFFICER]);
        let collection_id = make_collection(&mut scenario, AWAR_M1);
        let new_officers = make_dao(&mut scenario, AWAR_OFFICER, vector[AWAR_OFFICER]);

        ts::next_tx(&mut scenario, AWAR_M1);
        let v = vault::new_for_testing(
            object::id_from_address(@0x5501),
            collection_id,
            example_acl(awar, wolf, officers),
            scenario.ctx(),
        );
        vault::share_for_testing(v);

        ts::next_tx(&mut scenario, AWAR_OFFICER);
        {
            let mut v = ts::take_shared<DaoReceiptVault>(&scenario);
            let officers_dao = ts::take_shared_by_id<DAO>(&scenario, officers);
            let new_officers_dao = ts::take_shared_by_id<DAO>(&scenario, new_officers);
            vault::grant_edit_ou(&mut v, &officers_dao, &new_officers_dao, scenario.ctx());
            let edits = vault::principals(&v, vault::role_edit());
            assert!(edits.length() == 2, 0);
            assert!(edits.contains(&vault::ou(new_officers)), 1);
            ts::return_shared(new_officers_dao);
            ts::return_shared(officers_dao);
            ts::return_shared(v);
        };
        ts::end(scenario);
    }

    // --- H1 brick-guard 2: caller must remain satisfied post-revoke

    /// Revoke aborts EEditorWouldLockSelf if the caller wouldn't pass assert_role(Edit)
    /// after the batch. Defends against the "grant unsatisfiable then revoke self"
    /// brick path even if a future change re-opened the Edit grant to non-Ou.
    #[test]
    #[expected_failure(abort_code = vault::EEditorWouldLockSelf)]
    fun revoke_aborts_if_caller_would_lock_themselves() {
        let mut scenario = ts::begin(AWAR_M1);
        let awar = make_dao(&mut scenario, AWAR_M1, vector[AWAR_M1]);
        let wolf = make_dao(&mut scenario, WOLF_M1, vector[WOLF_M1]);
        let officers = make_dao(&mut scenario, AWAR_OFFICER, vector[AWAR_OFFICER]);
        let collection_id = make_collection(&mut scenario, AWAR_M1);
        // A second editor who is NOT a member of `officers`.
        let other = make_dao(&mut scenario, OUTSIDER, vector[OUTSIDER]);

        ts::next_tx(&mut scenario, AWAR_M1);
        let v = vault::new_for_testing(
            object::id_from_address(@0x5501),
            collection_id,
            example_acl(awar, wolf, officers),
            scenario.ctx(),
        );
        vault::share_for_testing(v);

        // First, validly add `other` as a second Edit principal (Edit list non-empty).
        ts::next_tx(&mut scenario, AWAR_OFFICER);
        {
            let mut v = ts::take_shared<DaoReceiptVault>(&scenario);
            let officers_dao = ts::take_shared_by_id<DAO>(&scenario, officers);
            let other_dao = ts::take_shared_by_id<DAO>(&scenario, other);
            vault::grant_edit_ou(&mut v, &officers_dao, &other_dao, scenario.ctx());
            ts::return_shared(other_dao);
            ts::return_shared(officers_dao);
            ts::return_shared(v);
        };

        // Now AWAR_OFFICER tries to revoke `officers` (their own OU). The brick-guard 1
        // (length > 0) passes since `other` remains. But AWAR_OFFICER is NOT a member
        // of `other` — so the post-revoke caller-satisfies check fires.
        ts::next_tx(&mut scenario, AWAR_OFFICER);
        let mut v = ts::take_shared<DaoReceiptVault>(&scenario);
        let officers_dao = ts::take_shared_by_id<DAO>(&scenario, officers);
        vault::revoke(
            &mut v,
            &officers_dao,
            vector[vault::role_edit()],
            vector[vault::ou(officers)],
            scenario.ctx(),
        );

        abort
    }

    // --- F2 + L1: events emitted only after brick-guards, and only on real changes

    /// Original L1: phantom events on no-op grant/revoke. Post-fix: zero events
    /// when the operation is a no-op, and the state is unchanged.
    #[test]
    fun no_op_grant_and_revoke_emit_no_events() {
        let mut scenario = ts::begin(AWAR_M1);
        let awar = make_dao(&mut scenario, AWAR_M1, vector[AWAR_M1]);
        let wolf = make_dao(&mut scenario, WOLF_M1, vector[WOLF_M1]);
        let officers = make_dao(&mut scenario, AWAR_OFFICER, vector[AWAR_OFFICER]);
        let collection_id = make_collection(&mut scenario, AWAR_M1);

        ts::next_tx(&mut scenario, AWAR_M1);
        let v = vault::new_for_testing(
            object::id_from_address(@0x5501),
            collection_id,
            example_acl(awar, wolf, officers),
            scenario.ctx(),
        );
        vault::share_for_testing(v);

        ts::next_tx(&mut scenario, AWAR_OFFICER);
        let deposit_len_before = {
            let v = ts::take_shared<DaoReceiptVault>(&scenario);
            let n = vault::principals(&v, vault::role_deposit()).length();
            ts::return_shared(v);
            n
        };

        // (1) Duplicate grant: PROTO already has deposit.
        ts::next_tx(&mut scenario, AWAR_OFFICER);
        {
            let mut v = ts::take_shared<DaoReceiptVault>(&scenario);
            let officers_dao = ts::take_shared_by_id<DAO>(&scenario, officers);
            vault::grant(
                &mut v,
                &officers_dao,
                vector[vault::role_deposit()],
                vector[vault::player(PROTO)],
                scenario.ctx(),
            );
            ts::return_shared(officers_dao);
            ts::return_shared(v);
        };
        let regrant_effects = ts::next_tx(&mut scenario, AWAR_OFFICER);
        assert!(ts::num_user_events(&regrant_effects) == 0, 100);
        {
            let v = ts::take_shared<DaoReceiptVault>(&scenario);
            assert!(
                vault::principals(&v, vault::role_deposit()).length() == deposit_len_before,
                101,
            );
            ts::return_shared(v);
        };

        // (2) Revoke of non-member: OUTSIDER never had deposit.
        ts::next_tx(&mut scenario, AWAR_OFFICER);
        {
            let mut v = ts::take_shared<DaoReceiptVault>(&scenario);
            let officers_dao = ts::take_shared_by_id<DAO>(&scenario, officers);
            vault::revoke(
                &mut v,
                &officers_dao,
                vector[vault::role_deposit()],
                vector[vault::player(OUTSIDER)],
                scenario.ctx(),
            );
            ts::return_shared(officers_dao);
            ts::return_shared(v);
        };
        let rerevoke_effects = ts::next_tx(&mut scenario, AWAR_OFFICER);
        assert!(ts::num_user_events(&rerevoke_effects) == 0, 200);

        ts::end(scenario);
    }

    // --- M4 + L2: zero-value deposit is rejected

    #[test]
    #[expected_failure(abort_code = vault::EZeroAmount)]
    fun zero_value_deposit_rejected() {
        let mut scenario = ts::begin(AWAR_M1);
        let awar = make_dao(&mut scenario, AWAR_M1, vector[AWAR_M1]);
        let wolf = make_dao(&mut scenario, WOLF_M1, vector[WOLF_M1]);
        let officers = make_dao(&mut scenario, AWAR_OFFICER, vector[AWAR_OFFICER]);
        let collection_id = make_collection(&mut scenario, AWAR_M1);

        ts::next_tx(&mut scenario, AWAR_M1);
        let v = vault::new_for_testing(
            object::id_from_address(@0x5501),
            collection_id,
            example_acl(awar, wolf, officers),
            scenario.ctx(),
        );
        vault::share_for_testing(v);

        ts::next_tx(&mut scenario, AWAR_M1);
        let zero_receipt = multicoin::zero(collection_id, ASSET, scenario.ctx());

        ts::next_tx(&mut scenario, AWAR_M1);
        let mut v = ts::take_shared<DaoReceiptVault>(&scenario);
        let awar_dao = ts::take_shared_by_id<DAO>(&scenario, awar);
        vault::deposit_receipt(&mut v, &awar_dao, zero_receipt, scenario.ctx());

        abort
    }

    // --- F3: zero-amount withdraw is rejected

    #[test]
    #[expected_failure(abort_code = vault::EZeroAmount)]
    fun zero_amount_withdraw_rejected() {
        let mut scenario = ts::begin(AWAR_M1);
        let awar = make_dao(&mut scenario, AWAR_M1, vector[AWAR_M1]);
        let wolf = make_dao(&mut scenario, WOLF_M1, vector[WOLF_M1]);
        let officers = make_dao(&mut scenario, AWAR_OFFICER, vector[AWAR_OFFICER]);
        let collection_id = make_collection(&mut scenario, AWAR_M1);

        ts::next_tx(&mut scenario, AWAR_M1);
        let v = vault::new_for_testing(
            object::id_from_address(@0x5501),
            collection_id,
            example_acl(awar, wolf, officers),
            scenario.ctx(),
        );
        vault::share_for_testing(v);

        let r = mint(&mut scenario, AWAR_M1, collection_id, ASSET, 10);
        ts::next_tx(&mut scenario, AWAR_M1);
        {
            let mut v = ts::take_shared<DaoReceiptVault>(&scenario);
            let awar_dao = ts::take_shared_by_id<DAO>(&scenario, awar);
            vault::deposit_receipt(&mut v, &awar_dao, r, scenario.ctx());
            ts::return_shared(awar_dao);
            ts::return_shared(v);
        };

        ts::next_tx(&mut scenario, PROTO);
        let mut v = ts::take_shared<DaoReceiptVault>(&scenario);
        let any_dao = ts::take_shared_by_id<DAO>(&scenario, awar);
        let out = vault::withdraw_receipt(&mut v, &any_dao, ASSET, 0, scenario.ctx());
        transfer::public_transfer(out, PROTO);

        abort
    }

    // --- F5: length mismatch returns EInvalidArguments, not ENotAuthorized

    #[test]
    #[expected_failure(abort_code = vault::EInvalidArguments)]
    fun grant_length_mismatch_returns_invalid_arguments() {
        let mut scenario = ts::begin(AWAR_M1);
        let awar = make_dao(&mut scenario, AWAR_M1, vector[AWAR_M1]);
        let wolf = make_dao(&mut scenario, WOLF_M1, vector[WOLF_M1]);
        let officers = make_dao(&mut scenario, AWAR_OFFICER, vector[AWAR_OFFICER]);
        let collection_id = make_collection(&mut scenario, AWAR_M1);

        ts::next_tx(&mut scenario, AWAR_M1);
        let v = vault::new_for_testing(
            object::id_from_address(@0x5501),
            collection_id,
            example_acl(awar, wolf, officers),
            scenario.ctx(),
        );
        vault::share_for_testing(v);

        ts::next_tx(&mut scenario, AWAR_OFFICER);
        let mut v = ts::take_shared<DaoReceiptVault>(&scenario);
        let officers_dao = ts::take_shared_by_id<DAO>(&scenario, officers);
        vault::grant(
            &mut v,
            &officers_dao,
            vector[vault::role_deposit(), vault::role_withdraw()],
            vector[vault::player(OUTSIDER)],
            scenario.ctx(),
        );

        abort
    }

    // --- F4: registry key is updatable after DAO migration

    #[test]
    fun update_registry_key_remaps_vault_after_migration() {
        let mut scenario = ts::begin(AWAR_M1);
        let awar = make_dao(&mut scenario, AWAR_M1, vector[AWAR_M1]);
        let wolf = make_dao(&mut scenario, WOLF_M1, vector[WOLF_M1]);
        let officers = make_dao(&mut scenario, AWAR_OFFICER, vector[AWAR_OFFICER]);
        let new_officers = make_dao(&mut scenario, AWAR_OFFICER, vector[AWAR_OFFICER]);
        let collection_id = make_collection(&mut scenario, AWAR_M1);
        let ssu_id = object::id_from_address(@0x5501);

        // Stand up the registry so update_registry_key has a real entry to remap.
        ts::next_tx(&mut scenario, AWAR_M1);
        vault::init_for_testing(scenario.ctx());

        // Construct a vault by hand and register its key under the OLD editor DAO.
        ts::next_tx(&mut scenario, AWAR_M1);
        let v = vault::new_for_testing(
            ssu_id,
            collection_id,
            example_acl(awar, wolf, officers),
            scenario.ctx(),
        );
        let v_id = object::id(&v);
        vault::share_for_testing(v);

        ts::next_tx(&mut scenario, AWAR_M1);
        {
            let mut reg = ts::take_shared<vault::DaoReceiptVaultRegistry>(&scenario);
            let mut v = ts::take_shared<DaoReceiptVault>(&scenario);
            vault::register_for_testing(&mut reg, ssu_id, officers, v_id);
            // M2: tell the vault which registry slot it lives under.
            vault::set_registry_key_dao_id_for_testing(&mut v, officers);
            // Lookup under the old key works.
            assert!(vault::lookup(&reg, ssu_id, officers).is_some(), 0);
            assert!(vault::lookup(&reg, ssu_id, new_officers).is_none(), 1);
            ts::return_shared(v);
            ts::return_shared(reg);
        };

        // Editor re-keys the registry entry to point at the migrated DAO.
        ts::next_tx(&mut scenario, AWAR_OFFICER);
        {
            let mut reg = ts::take_shared<vault::DaoReceiptVaultRegistry>(&scenario);
            let mut v = ts::take_shared<DaoReceiptVault>(&scenario);
            let officers_dao = ts::take_shared_by_id<DAO>(&scenario, officers);
            let new_officers_dao = ts::take_shared_by_id<DAO>(&scenario, new_officers);
            vault::update_registry_key(
                &mut reg,
                &mut v,
                &officers_dao,
                &new_officers_dao,
                scenario.ctx(),
            );
            // New key resolves; old key no longer.
            assert!(vault::lookup(&reg, ssu_id, new_officers).is_some(), 2);
            assert!(vault::lookup(&reg, ssu_id, officers).is_none(), 3);
            ts::return_shared(new_officers_dao);
            ts::return_shared(officers_dao);
            ts::return_shared(v);
            ts::return_shared(reg);
        };

        ts::end(scenario);
    }

    /// F4 cross-vault safety (per PR #2 review): update_registry_key aborts if the
    /// registry entry at old_key points at a *different* vault than the one passed.
    /// Prevents a caller with Edit on vault B (and editor_dao listed on vault B's
    /// ACL) from silently remapping vault A's registry entry.
    #[test]
    #[expected_failure(abort_code = vault::EInvalidArguments)]
    fun update_registry_key_rejects_cross_vault_remap() {
        let mut scenario = ts::begin(AWAR_M1);
        let awar = make_dao(&mut scenario, AWAR_M1, vector[AWAR_M1]);
        let wolf = make_dao(&mut scenario, WOLF_M1, vector[WOLF_M1]);
        let officers = make_dao(&mut scenario, AWAR_OFFICER, vector[AWAR_OFFICER]);
        let new_officers = make_dao(&mut scenario, AWAR_OFFICER, vector[AWAR_OFFICER]);
        let collection_id = make_collection(&mut scenario, AWAR_M1);
        let ssu_id = object::id_from_address(@0x5501);

        ts::next_tx(&mut scenario, AWAR_M1);
        vault::init_for_testing(scenario.ctx());

        // Vault A is the real registry occupant of (ssu_id, officers).
        ts::next_tx(&mut scenario, AWAR_M1);
        let v_a = vault::new_for_testing(
            ssu_id,
            collection_id,
            example_acl(awar, wolf, officers),
            scenario.ctx(),
        );
        let v_a_id = object::id(&v_a);
        vault::share_for_testing(v_a);

        // Vault B is a separate vault on which the officer also holds Edit.
        ts::next_tx(&mut scenario, AWAR_M1);
        let v_b = vault::new_for_testing(
            object::id_from_address(@0x5502),
            collection_id,
            example_acl(awar, wolf, officers),
            scenario.ctx(),
        );
        vault::share_for_testing(v_b);

        ts::next_tx(&mut scenario, AWAR_M1);
        {
            let mut reg = ts::take_shared<vault::DaoReceiptVaultRegistry>(&scenario);
            // Only register vault A under (ssu_id, officers). Vault B is unrelated to
            // this slot but the attacker tries to remap it.
            vault::register_for_testing(&mut reg, ssu_id, officers, v_a_id);
            ts::return_shared(reg);
        };

        // Attacker holds Edit on vault B and passes vault B (not vault A) to
        // update_registry_key — pre-fix this would silently remap vault A's slot.
        ts::next_tx(&mut scenario, AWAR_OFFICER);
        let mut reg = ts::take_shared<vault::DaoReceiptVaultRegistry>(&scenario);
        // Both vaults are shared; disambiguate by taking vault B by id.
        // We don't actually need the v_b id earlier — take_shared returns the second
        // one if we already took the first; instead just take by id here.
        let mut v_b = ts::take_shared<DaoReceiptVault>(&scenario);
        let officers_dao = ts::take_shared_by_id<DAO>(&scenario, officers);
        let new_officers_dao = ts::take_shared_by_id<DAO>(&scenario, new_officers);
        vault::update_registry_key(
            &mut reg,
            &mut v_b,
            &officers_dao,
            &new_officers_dao,
            scenario.ctx(),
        );

        abort
    }

    // --- I1: initialize_dao_vault emits AclGrantedEvent for the seeded Edit principal

    // I1 is verified by inspection of the source — initialize_dao_vault now emits
    // AclGrantedEvent { role: Edit, principal: Ou{editor_dao_id} } alongside
    // VaultInitializedEvent. The initialize path requires a real world::StorageUnit
    // which the existing test harness intentionally bypasses (see new_for_testing's
    // doc-comment), so this fix is not exercisable as a Move #[test] here. The
    // follow-up issue tracking M1/M2/F1 should add an SSU-bootstrap helper.

    // =============================================================================
    // === M2: vault teardown + DOF-emptiness tracking (#5)
    // =============================================================================

    /// M2 happy path: deinitialize an empty vault frees the registry slot and
    /// bricks the ACL so subsequent admin calls fail.
    #[test]
    fun deinitialize_empty_vault_frees_registry_slot_and_bricks_acl() {
        let mut scenario = ts::begin(AWAR_M1);
        let awar = make_dao(&mut scenario, AWAR_M1, vector[AWAR_M1]);
        let wolf = make_dao(&mut scenario, WOLF_M1, vector[WOLF_M1]);
        let officers = make_dao(&mut scenario, AWAR_OFFICER, vector[AWAR_OFFICER]);
        let collection_id = make_collection(&mut scenario, AWAR_M1);
        let ssu_id = object::id_from_address(@0x5501);

        ts::next_tx(&mut scenario, AWAR_M1);
        vault::init_for_testing(scenario.ctx());

        ts::next_tx(&mut scenario, AWAR_M1);
        let v = vault::new_for_testing(
            ssu_id,
            collection_id,
            example_acl(awar, wolf, officers),
            scenario.ctx(),
        );
        let v_id = object::id(&v);
        vault::share_for_testing(v);

        ts::next_tx(&mut scenario, AWAR_M1);
        {
            let mut reg = ts::take_shared<vault::DaoReceiptVaultRegistry>(&scenario);
            let mut v = ts::take_shared<DaoReceiptVault>(&scenario);
            vault::register_for_testing(&mut reg, ssu_id, officers, v_id);
            vault::set_registry_key_dao_id_for_testing(&mut v, officers);
            ts::return_shared(v);
            ts::return_shared(reg);
        };

        // Editor deinitializes the empty vault.
        ts::next_tx(&mut scenario, AWAR_OFFICER);
        {
            let mut reg = ts::take_shared<vault::DaoReceiptVaultRegistry>(&scenario);
            let mut v = ts::take_shared<DaoReceiptVault>(&scenario);
            let officers_dao = ts::take_shared_by_id<DAO>(&scenario, officers);
            vault::deinitialize_dao_vault(&mut reg, &mut v, &officers_dao, scenario.ctx());

            // Registry slot freed: lookup returns none.
            assert!(vault::lookup(&reg, ssu_id, officers).is_none(), 0);
            // ACL fully wiped — every role is now absent.
            assert!(vault::principals(&v, vault::role_edit()).is_empty(), 1);
            assert!(vault::principals(&v, vault::role_deposit()).is_empty(), 2);
            assert!(vault::principals(&v, vault::role_withdraw()).is_empty(), 3);

            ts::return_shared(officers_dao);
            ts::return_shared(v);
            ts::return_shared(reg);
        };

        ts::end(scenario);
    }

    /// M2: after deinit, no caller can satisfy any role — including the original
    /// editor. Demonstrates the brick is total.
    #[test]
    #[expected_failure(abort_code = vault::ENotAuthorized)]
    fun deinitialized_vault_rejects_grant() {
        let mut scenario = ts::begin(AWAR_M1);
        let awar = make_dao(&mut scenario, AWAR_M1, vector[AWAR_M1]);
        let wolf = make_dao(&mut scenario, WOLF_M1, vector[WOLF_M1]);
        let officers = make_dao(&mut scenario, AWAR_OFFICER, vector[AWAR_OFFICER]);
        let collection_id = make_collection(&mut scenario, AWAR_M1);
        let ssu_id = object::id_from_address(@0x5501);

        ts::next_tx(&mut scenario, AWAR_M1);
        vault::init_for_testing(scenario.ctx());

        ts::next_tx(&mut scenario, AWAR_M1);
        let v = vault::new_for_testing(
            ssu_id,
            collection_id,
            example_acl(awar, wolf, officers),
            scenario.ctx(),
        );
        let v_id = object::id(&v);
        vault::share_for_testing(v);

        ts::next_tx(&mut scenario, AWAR_M1);
        {
            let mut reg = ts::take_shared<vault::DaoReceiptVaultRegistry>(&scenario);
            let mut v = ts::take_shared<DaoReceiptVault>(&scenario);
            vault::register_for_testing(&mut reg, ssu_id, officers, v_id);
            vault::set_registry_key_dao_id_for_testing(&mut v, officers);
            ts::return_shared(v);
            ts::return_shared(reg);
        };

        ts::next_tx(&mut scenario, AWAR_OFFICER);
        {
            let mut reg = ts::take_shared<vault::DaoReceiptVaultRegistry>(&scenario);
            let mut v = ts::take_shared<DaoReceiptVault>(&scenario);
            let officers_dao = ts::take_shared_by_id<DAO>(&scenario, officers);
            vault::deinitialize_dao_vault(&mut reg, &mut v, &officers_dao, scenario.ctx());
            ts::return_shared(officers_dao);
            ts::return_shared(v);
            ts::return_shared(reg);
        };

        // Even the original editor can no longer administer the orphan vault.
        ts::next_tx(&mut scenario, AWAR_OFFICER);
        let mut v = ts::take_shared<DaoReceiptVault>(&scenario);
        let officers_dao = ts::take_shared_by_id<DAO>(&scenario, officers);
        vault::grant(
            &mut v,
            &officers_dao,
            vector[vault::role_deposit()],
            vector[vault::player(OUTSIDER)],
            scenario.ctx(),
        );

        abort
    }

    /// M2: registry slot is reusable after deinit — a fresh registration under the
    /// same (ssu_id, editor_dao_id) key succeeds.
    #[test]
    fun registry_slot_reusable_after_deinit() {
        let mut scenario = ts::begin(AWAR_M1);
        let awar = make_dao(&mut scenario, AWAR_M1, vector[AWAR_M1]);
        let wolf = make_dao(&mut scenario, WOLF_M1, vector[WOLF_M1]);
        let officers = make_dao(&mut scenario, AWAR_OFFICER, vector[AWAR_OFFICER]);
        let collection_id = make_collection(&mut scenario, AWAR_M1);
        let ssu_id = object::id_from_address(@0x5501);

        ts::next_tx(&mut scenario, AWAR_M1);
        vault::init_for_testing(scenario.ctx());

        // Stand up + register vault A.
        ts::next_tx(&mut scenario, AWAR_M1);
        let v_a = vault::new_for_testing(
            ssu_id,
            collection_id,
            example_acl(awar, wolf, officers),
            scenario.ctx(),
        );
        let v_a_id = object::id(&v_a);
        vault::share_for_testing(v_a);

        ts::next_tx(&mut scenario, AWAR_M1);
        {
            let mut reg = ts::take_shared<vault::DaoReceiptVaultRegistry>(&scenario);
            let mut v = ts::take_shared<DaoReceiptVault>(&scenario);
            vault::register_for_testing(&mut reg, ssu_id, officers, v_a_id);
            vault::set_registry_key_dao_id_for_testing(&mut v, officers);
            ts::return_shared(v);
            ts::return_shared(reg);
        };

        // Deinit vault A.
        ts::next_tx(&mut scenario, AWAR_OFFICER);
        {
            let mut reg = ts::take_shared<vault::DaoReceiptVaultRegistry>(&scenario);
            let mut v = ts::take_shared<DaoReceiptVault>(&scenario);
            let officers_dao = ts::take_shared_by_id<DAO>(&scenario, officers);
            vault::deinitialize_dao_vault(&mut reg, &mut v, &officers_dao, scenario.ctx());
            ts::return_shared(officers_dao);
            ts::return_shared(v);
            ts::return_shared(reg);
        };

        // Re-register a fresh vault B under the same key — must succeed.
        ts::next_tx(&mut scenario, AWAR_M1);
        let v_b = vault::new_for_testing(
            ssu_id,
            collection_id,
            example_acl(awar, wolf, officers),
            scenario.ctx(),
        );
        let v_b_id = object::id(&v_b);
        vault::share_for_testing(v_b);

        ts::next_tx(&mut scenario, AWAR_M1);
        {
            let mut reg = ts::take_shared<vault::DaoReceiptVaultRegistry>(&scenario);
            vault::register_for_testing(&mut reg, ssu_id, officers, v_b_id);
            let looked_up = vault::lookup(&reg, ssu_id, officers);
            assert!(looked_up.is_some(), 0);
            assert!(*looked_up.borrow() == v_b_id, 1);
            ts::return_shared(reg);
        };

        ts::end(scenario);
    }

    /// M2: deinit aborts EVaultNonEmpty if any asset_id has a live balance.
    #[test]
    #[expected_failure(abort_code = vault::EVaultNonEmpty)]
    fun deinit_rejected_on_non_empty_vault() {
        let mut scenario = ts::begin(AWAR_M1);
        let awar = make_dao(&mut scenario, AWAR_M1, vector[AWAR_M1]);
        let wolf = make_dao(&mut scenario, WOLF_M1, vector[WOLF_M1]);
        let officers = make_dao(&mut scenario, AWAR_OFFICER, vector[AWAR_OFFICER]);
        let collection_id = make_collection(&mut scenario, AWAR_M1);
        let ssu_id = object::id_from_address(@0x5501);

        ts::next_tx(&mut scenario, AWAR_M1);
        vault::init_for_testing(scenario.ctx());

        ts::next_tx(&mut scenario, AWAR_M1);
        let v = vault::new_for_testing(
            ssu_id,
            collection_id,
            example_acl(awar, wolf, officers),
            scenario.ctx(),
        );
        let v_id = object::id(&v);
        vault::share_for_testing(v);

        ts::next_tx(&mut scenario, AWAR_M1);
        {
            let mut reg = ts::take_shared<vault::DaoReceiptVaultRegistry>(&scenario);
            let mut v = ts::take_shared<DaoReceiptVault>(&scenario);
            vault::register_for_testing(&mut reg, ssu_id, officers, v_id);
            vault::set_registry_key_dao_id_for_testing(&mut v, officers);
            ts::return_shared(v);
            ts::return_shared(reg);
        };

        // Deposit a real balance so the vault is non-empty.
        let r = mint(&mut scenario, AWAR_M1, collection_id, ASSET, 100);
        ts::next_tx(&mut scenario, AWAR_M1);
        {
            let mut v = ts::take_shared<DaoReceiptVault>(&scenario);
            let awar_dao = ts::take_shared_by_id<DAO>(&scenario, awar);
            vault::deposit_receipt(&mut v, &awar_dao, r, scenario.ctx());
            assert!(vault::vault_balance(&v, ASSET) == 100, 0);
            ts::return_shared(awar_dao);
            ts::return_shared(v);
        };

        // Try to deinit — must abort EVaultNonEmpty.
        ts::next_tx(&mut scenario, AWAR_OFFICER);
        let mut reg = ts::take_shared<vault::DaoReceiptVaultRegistry>(&scenario);
        let mut v = ts::take_shared<DaoReceiptVault>(&scenario);
        let officers_dao = ts::take_shared_by_id<DAO>(&scenario, officers);
        vault::deinitialize_dao_vault(&mut reg, &mut v, &officers_dao, scenario.ctx());

        abort
    }

    /// M2: deinit is Edit-gated — a non-editor cannot deinit even an empty vault.
    #[test]
    #[expected_failure(abort_code = vault::ENotAuthorized)]
    fun deinit_rejected_for_non_editor() {
        let mut scenario = ts::begin(AWAR_M1);
        let awar = make_dao(&mut scenario, AWAR_M1, vector[AWAR_M1]);
        let wolf = make_dao(&mut scenario, WOLF_M1, vector[WOLF_M1]);
        let officers = make_dao(&mut scenario, AWAR_OFFICER, vector[AWAR_OFFICER]);
        let collection_id = make_collection(&mut scenario, AWAR_M1);
        let ssu_id = object::id_from_address(@0x5501);

        ts::next_tx(&mut scenario, AWAR_M1);
        vault::init_for_testing(scenario.ctx());

        ts::next_tx(&mut scenario, AWAR_M1);
        let v = vault::new_for_testing(
            ssu_id,
            collection_id,
            example_acl(awar, wolf, officers),
            scenario.ctx(),
        );
        let v_id = object::id(&v);
        vault::share_for_testing(v);

        ts::next_tx(&mut scenario, AWAR_M1);
        {
            let mut reg = ts::take_shared<vault::DaoReceiptVaultRegistry>(&scenario);
            let mut v = ts::take_shared<DaoReceiptVault>(&scenario);
            vault::register_for_testing(&mut reg, ssu_id, officers, v_id);
            vault::set_registry_key_dao_id_for_testing(&mut v, officers);
            ts::return_shared(v);
            ts::return_shared(reg);
        };

        // AWAR_M1 holds Deposit/Withdraw, NOT Edit. Try to deinit with AWAR DAO.
        ts::next_tx(&mut scenario, AWAR_M1);
        let mut reg = ts::take_shared<vault::DaoReceiptVaultRegistry>(&scenario);
        let mut v = ts::take_shared<DaoReceiptVault>(&scenario);
        let awar_dao = ts::take_shared_by_id<DAO>(&scenario, awar);
        vault::deinitialize_dao_vault(&mut reg, &mut v, &awar_dao, scenario.ctx());

        abort
    }

    /// M2 counter: deposit + full-drain returns non_empty_assets to zero, enabling
    /// deinit after a complete drawdown.
    #[test]
    fun deinit_succeeds_after_full_drawdown() {
        let mut scenario = ts::begin(AWAR_M1);
        let awar = make_dao(&mut scenario, AWAR_M1, vector[AWAR_M1]);
        let wolf = make_dao(&mut scenario, WOLF_M1, vector[WOLF_M1]);
        let officers = make_dao(&mut scenario, AWAR_OFFICER, vector[AWAR_OFFICER]);
        let collection_id = make_collection(&mut scenario, AWAR_M1);
        let ssu_id = object::id_from_address(@0x5501);

        ts::next_tx(&mut scenario, AWAR_M1);
        vault::init_for_testing(scenario.ctx());

        ts::next_tx(&mut scenario, AWAR_M1);
        let v = vault::new_for_testing(
            ssu_id,
            collection_id,
            example_acl(awar, wolf, officers),
            scenario.ctx(),
        );
        let v_id = object::id(&v);
        vault::share_for_testing(v);

        ts::next_tx(&mut scenario, AWAR_M1);
        {
            let mut reg = ts::take_shared<vault::DaoReceiptVaultRegistry>(&scenario);
            let mut v = ts::take_shared<DaoReceiptVault>(&scenario);
            vault::register_for_testing(&mut reg, ssu_id, officers, v_id);
            vault::set_registry_key_dao_id_for_testing(&mut v, officers);
            ts::return_shared(v);
            ts::return_shared(reg);
        };

        // Deposit 100 of ASSET.
        let r = mint(&mut scenario, AWAR_M1, collection_id, ASSET, 100);
        ts::next_tx(&mut scenario, AWAR_M1);
        {
            let mut v = ts::take_shared<DaoReceiptVault>(&scenario);
            let awar_dao = ts::take_shared_by_id<DAO>(&scenario, awar);
            vault::deposit_receipt(&mut v, &awar_dao, r, scenario.ctx());
            ts::return_shared(awar_dao);
            ts::return_shared(v);
        };

        // Withdraw all 100 — drives the cleanup branch + counter decrement.
        ts::next_tx(&mut scenario, PROTO);
        {
            let mut v = ts::take_shared<DaoReceiptVault>(&scenario);
            let any_dao = ts::take_shared_by_id<DAO>(&scenario, awar);
            let out = vault::withdraw_receipt(&mut v, &any_dao, ASSET, 100, scenario.ctx());
            assert!(out.value() == 100, 0);
            assert!(vault::vault_balance(&v, ASSET) == 0, 1);
            transfer::public_transfer(out, PROTO);
            ts::return_shared(any_dao);
            ts::return_shared(v);
        };

        // Now empty: deinit succeeds.
        ts::next_tx(&mut scenario, AWAR_OFFICER);
        {
            let mut reg = ts::take_shared<vault::DaoReceiptVaultRegistry>(&scenario);
            let mut v = ts::take_shared<DaoReceiptVault>(&scenario);
            let officers_dao = ts::take_shared_by_id<DAO>(&scenario, officers);
            vault::deinitialize_dao_vault(&mut reg, &mut v, &officers_dao, scenario.ctx());
            assert!(vault::lookup(&reg, ssu_id, officers).is_none(), 0);
            ts::return_shared(officers_dao);
            ts::return_shared(v);
            ts::return_shared(reg);
        };

        ts::end(scenario);
    }

    /// M2: after `update_registry_key`, deinit uses the *new* registry slot (the
    /// vault's `registry_key_dao_id` tracks the migration).
    #[test]
    fun deinit_uses_current_registry_key_after_migration() {
        let mut scenario = ts::begin(AWAR_M1);
        let awar = make_dao(&mut scenario, AWAR_M1, vector[AWAR_M1]);
        let wolf = make_dao(&mut scenario, WOLF_M1, vector[WOLF_M1]);
        let officers = make_dao(&mut scenario, AWAR_OFFICER, vector[AWAR_OFFICER]);
        let new_officers = make_dao(&mut scenario, AWAR_OFFICER, vector[AWAR_OFFICER]);
        let collection_id = make_collection(&mut scenario, AWAR_M1);
        let ssu_id = object::id_from_address(@0x5501);

        ts::next_tx(&mut scenario, AWAR_M1);
        vault::init_for_testing(scenario.ctx());

        ts::next_tx(&mut scenario, AWAR_M1);
        let v = vault::new_for_testing(
            ssu_id,
            collection_id,
            example_acl(awar, wolf, officers),
            scenario.ctx(),
        );
        let v_id = object::id(&v);
        vault::share_for_testing(v);

        ts::next_tx(&mut scenario, AWAR_M1);
        {
            let mut reg = ts::take_shared<vault::DaoReceiptVaultRegistry>(&scenario);
            let mut v = ts::take_shared<DaoReceiptVault>(&scenario);
            vault::register_for_testing(&mut reg, ssu_id, officers, v_id);
            vault::set_registry_key_dao_id_for_testing(&mut v, officers);
            ts::return_shared(v);
            ts::return_shared(reg);
        };

        // First: grant new_officers Edit, then migrate the registry key to new_officers.
        ts::next_tx(&mut scenario, AWAR_OFFICER);
        {
            let mut reg = ts::take_shared<vault::DaoReceiptVaultRegistry>(&scenario);
            let mut v = ts::take_shared<DaoReceiptVault>(&scenario);
            let officers_dao = ts::take_shared_by_id<DAO>(&scenario, officers);
            let new_officers_dao = ts::take_shared_by_id<DAO>(&scenario, new_officers);
            vault::grant_edit_ou(&mut v, &officers_dao, &new_officers_dao, scenario.ctx());
            vault::update_registry_key(
                &mut reg,
                &mut v,
                &officers_dao,
                &new_officers_dao,
                scenario.ctx(),
            );
            assert!(vault::lookup(&reg, ssu_id, new_officers).is_some(), 0);
            assert!(vault::lookup(&reg, ssu_id, officers).is_none(), 1);
            ts::return_shared(new_officers_dao);
            ts::return_shared(officers_dao);
            ts::return_shared(v);
            ts::return_shared(reg);
        };

        // Now deinit with new_officers (the *current* editor) — must locate the
        // new key and free it.
        ts::next_tx(&mut scenario, AWAR_OFFICER);
        {
            let mut reg = ts::take_shared<vault::DaoReceiptVaultRegistry>(&scenario);
            let mut v = ts::take_shared<DaoReceiptVault>(&scenario);
            let new_officers_dao = ts::take_shared_by_id<DAO>(&scenario, new_officers);
            vault::deinitialize_dao_vault(&mut reg, &mut v, &new_officers_dao, scenario.ctx());
            assert!(vault::lookup(&reg, ssu_id, new_officers).is_none(), 2);
            // ACL is fully wiped — every role becomes empty/absent.
            assert!(vault::principals(&v, vault::role_edit()).is_empty(), 3);
            assert!(vault::principals(&v, vault::role_deposit()).is_empty(), 4);
            assert!(vault::principals(&v, vault::role_withdraw()).is_empty(), 5);
            ts::return_shared(new_officers_dao);
            ts::return_shared(v);
            ts::return_shared(reg);
        };

        ts::end(scenario);
    }
}
