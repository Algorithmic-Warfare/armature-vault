/// Branch-coverage tests for `keyspace` and `ou_receipt_vault`: each test hits
/// one arm the other suites leave untaken. Kept separate so the existing test
/// files stay untouched.
#[test_only]
module armature_vault::coverage_tests {
    use armature::{ou::{Self, OU}, governance};
    // @todo(roles): import `acl` from `roles::acl` (packages/primitives/roles) once acl.move moves there.
    use armature_vault::{
        acl::{Self as acl, Principal},
        keyspace::{Self, Keyspace},
        ou_receipt_vault::{Self as vault, OuReceiptVault, OuReceiptVaultRegistry, Role}
    };
    use multicoin::multicoin::{Self, Collection, CollectionCap, Balance};
    use std::string;
    use sui::{test_scenario as ts, vec_map};

    const ADMIN: address = @0xA;
    const USER1: address = @0xB;
    const USER2: address = @0xC;

    const MEMBER: address = @0xA1;
    const OFFICER: address = @0xD1;

    const ASSET: u64 = 7;

    // === Helpers ===

    fun make_ou(scenario: &mut ts::Scenario, creator: address, members: vector<address>): ID {
        ts::next_tx(scenario, creator);
        let init = governance::init_board(members);
        ou::create(
            &init,
            string::utf8(b"OU"),
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

    /// Deposit + Withdraw: [ou(members)]; Edit: [ou(officers)].
    fun member_acl(members: ID, officers: ID): vec_map::VecMap<Role, vector<Principal>> {
        let mut acl_map = vec_map::empty<Role, vector<Principal>>();
        acl_map.insert(vault::role_deposit(), vector[acl::ou(members)]);
        acl_map.insert(vault::role_withdraw(), vector[acl::ou(members)]);
        acl_map.insert(vault::role_edit(), vector[acl::ou(officers)]);
        acl_map
    }

    /// Share a vault on `ssu_id` for `collection_id` with `member_acl`; returns its id.
    fun share_vault(
        scenario: &mut ts::Scenario,
        ssu_id: ID,
        collection_id: ID,
        members: ID,
        officers: ID,
    ): ID {
        ts::next_tx(scenario, MEMBER);
        let v = vault::new_for_testing(
            ssu_id,
            collection_id,
            member_acl(members, officers),
            scenario.ctx(),
        );
        let v_id = object::id(&v);
        vault::share_for_testing(v);
        v_id
    }

    // === keyspace ===

    /// keyspace.move:353 — create_keyspace_for_ou with an empty Read list skips the Read insert.
    #[test]
    fun keyspace_create_for_ou_empty_read_leaves_read_unset() {
        let mut sc = ts::begin(ADMIN);
        let ou_id = make_ou(&mut sc, ADMIN, vector[ADMIN]);

        ts::next_tx(&mut sc, ADMIN);
        let org = ts::take_shared_by_id<OU>(&sc, ou_id);
        keyspace::create_keyspace_for_ou(
            b"Org Vault",
            &org,
            vector[acl::ou(ou_id)],
            vector[],
            vector[acl::player(USER1)],
            sc.ctx(),
        );
        ts::return_shared(org);

        ts::next_tx(&mut sc, ADMIN);
        let ks = ts::take_shared<Keyspace>(&sc);
        let org = ts::take_shared_by_id<OU>(&sc, ou_id);
        assert!(keyspace::principals(&ks, keyspace::role_read()) == vector[], 0);
        assert!(!keyspace::has_role(&ks, keyspace::role_read(), &org, ADMIN), 1);
        assert!(keyspace::principals(&ks, keyspace::role_write()) == vector[acl::player(USER1)], 2);
        ts::return_shared(org);
        ts::return_shared(ks);
        sc.end();
    }

    /// keyspace.move:453 — revoke by a caller without Grant aborts ENotAllowed.
    #[test]
    #[expected_failure(abort_code = keyspace::ENotAllowed)]
    fun keyspace_revoke_unauthorized_aborts() {
        let mut sc = ts::begin(ADMIN);
        let ou_id = make_ou(&mut sc, ADMIN, vector[ADMIN]);

        ts::next_tx(&mut sc, USER2);
        let org = ts::take_shared_by_id<OU>(&sc, ou_id);
        let mut ks = keyspace::test_create_for_ou(
            b"Vault",
            vector[acl::player(ADMIN)],
            vector[acl::player(USER1)],
            vector[],
            sc.ctx(),
        );
        keyspace::revoke(&mut ks, keyspace::role_read(), acl::player(USER1), &org, sc.ctx());
        abort 99
    }

    /// keyspace.move:458 — revoking one of two Grant principals passes the last-grantor guard.
    #[test]
    fun keyspace_revoke_grantor_with_another_remaining() {
        let mut sc = ts::begin(ADMIN);
        let ou_id = make_ou(&mut sc, ADMIN, vector[ADMIN]);

        ts::next_tx(&mut sc, ADMIN);
        let org = ts::take_shared_by_id<OU>(&sc, ou_id);
        let mut ks = keyspace::test_create(b"Vault", sc.ctx());
        keyspace::grant(&mut ks, keyspace::role_grant(), acl::player(USER1), &org, sc.ctx());
        keyspace::revoke(&mut ks, keyspace::role_grant(), acl::player(ADMIN), &org, sc.ctx());
        assert!(keyspace::principals(&ks, keyspace::role_grant()) == vector[acl::player(USER1)], 0);
        assert!(!keyspace::has_role(&ks, keyspace::role_grant(), &org, ADMIN), 1);
        // A Grant change does not bump the Read epoch.
        assert!(keyspace::version(&ks) == 0, 2);

        keyspace::test_destroy(ks);
        ts::return_shared(org);
        sc.end();
    }

    // === ou_receipt_vault: deposit / withdraw ===

    /// ou_receipt_vault.move:346 — a receipt from another collection aborts EWrongCollection.
    #[test]
    #[expected_failure(abort_code = vault::EWrongCollection)]
    fun vault_deposit_wrong_collection_aborts() {
        let mut scenario = ts::begin(MEMBER);
        let members = make_ou(&mut scenario, MEMBER, vector[MEMBER]);
        let officers = make_ou(&mut scenario, OFFICER, vector[OFFICER]);
        let collection_id = make_collection(&mut scenario, MEMBER);
        // A second collection, owned by OFFICER so its cap is unambiguous.
        let other_collection_id = make_collection(&mut scenario, OFFICER);
        let v_id = share_vault(
            &mut scenario,
            object::id_from_address(@0x5501),
            collection_id,
            members,
            officers,
        );

        let r = mint(&mut scenario, OFFICER, other_collection_id, ASSET, 10);
        ts::next_tx(&mut scenario, MEMBER);
        let mut v = ts::take_shared_by_id<OuReceiptVault>(&scenario, v_id);
        let members_ou = ts::take_shared_by_id<OU>(&scenario, members);
        vault::deposit_receipt(&mut v, &members_ou, r, scenario.ctx());

        abort
    }

    /// ou_receipt_vault.move:386 — withdrawing an asset_id the vault never held aborts.
    #[test]
    #[expected_failure(abort_code = vault::EInsufficientVaultBalance)]
    fun vault_withdraw_unknown_asset_aborts() {
        let mut scenario = ts::begin(MEMBER);
        let members = make_ou(&mut scenario, MEMBER, vector[MEMBER]);
        let officers = make_ou(&mut scenario, OFFICER, vector[OFFICER]);
        let collection_id = make_collection(&mut scenario, MEMBER);
        let v_id = share_vault(
            &mut scenario,
            object::id_from_address(@0x5501),
            collection_id,
            members,
            officers,
        );

        ts::next_tx(&mut scenario, MEMBER);
        let mut v = ts::take_shared_by_id<OuReceiptVault>(&scenario, v_id);
        let members_ou = ts::take_shared_by_id<OU>(&scenario, members);
        let _out = vault::withdraw_receipt(&mut v, &members_ou, ASSET, 1, scenario.ctx());

        abort
    }

    /// ou_receipt_vault.move:388 — withdrawing more than the stored balance aborts.
    #[test]
    #[expected_failure(abort_code = vault::EInsufficientVaultBalance)]
    fun vault_withdraw_more_than_balance_aborts() {
        let mut scenario = ts::begin(MEMBER);
        let members = make_ou(&mut scenario, MEMBER, vector[MEMBER]);
        let officers = make_ou(&mut scenario, OFFICER, vector[OFFICER]);
        let collection_id = make_collection(&mut scenario, MEMBER);
        let v_id = share_vault(
            &mut scenario,
            object::id_from_address(@0x5501),
            collection_id,
            members,
            officers,
        );

        let r = mint(&mut scenario, MEMBER, collection_id, ASSET, 10);
        ts::next_tx(&mut scenario, MEMBER);
        {
            let mut v = ts::take_shared_by_id<OuReceiptVault>(&scenario, v_id);
            let members_ou = ts::take_shared_by_id<OU>(&scenario, members);
            vault::deposit_receipt(&mut v, &members_ou, r, scenario.ctx());
            ts::return_shared(members_ou);
            ts::return_shared(v);
        };

        ts::next_tx(&mut scenario, MEMBER);
        let mut v = ts::take_shared_by_id<OuReceiptVault>(&scenario, v_id);
        let members_ou = ts::take_shared_by_id<OU>(&scenario, members);
        let _out = vault::withdraw_receipt(&mut v, &members_ou, ASSET, 11, scenario.ctx());

        abort
    }

    // === ou_receipt_vault: ACL administration ===

    /// ou_receipt_vault.move:457 — grant_edit_ou for an OU already in Edit is a no-op.
    #[test]
    fun vault_grant_edit_ou_already_present_is_noop() {
        let mut scenario = ts::begin(MEMBER);
        let members = make_ou(&mut scenario, MEMBER, vector[MEMBER]);
        let officers = make_ou(&mut scenario, OFFICER, vector[OFFICER]);
        let collection_id = make_collection(&mut scenario, MEMBER);
        let v_id = share_vault(
            &mut scenario,
            object::id_from_address(@0x5501),
            collection_id,
            members,
            officers,
        );

        ts::next_tx(&mut scenario, OFFICER);
        {
            let mut v = ts::take_shared_by_id<OuReceiptVault>(&scenario, v_id);
            let officers_ou = ts::take_shared_by_id<OU>(&scenario, officers);
            vault::grant_edit_ou(&mut v, &officers_ou, &officers_ou, scenario.ctx());
            assert!(vault::principals(&v, vault::role_edit()) == vector[acl::ou(officers)], 0);
            ts::return_shared(officers_ou);
            ts::return_shared(v);
        };
        let effects = ts::next_tx(&mut scenario, OFFICER);
        assert!(effects.num_user_events() == 0, 1);

        ts::end(scenario);
    }

    /// ou_receipt_vault.move:480 — revoke with roles/principals of different lengths aborts.
    #[test]
    #[expected_failure(abort_code = vault::EInvalidArguments)]
    fun vault_revoke_length_mismatch_aborts() {
        let mut scenario = ts::begin(MEMBER);
        let members = make_ou(&mut scenario, MEMBER, vector[MEMBER]);
        let officers = make_ou(&mut scenario, OFFICER, vector[OFFICER]);
        let collection_id = make_collection(&mut scenario, MEMBER);
        let v_id = share_vault(
            &mut scenario,
            object::id_from_address(@0x5501),
            collection_id,
            members,
            officers,
        );

        ts::next_tx(&mut scenario, OFFICER);
        let mut v = ts::take_shared_by_id<OuReceiptVault>(&scenario, v_id);
        let officers_ou = ts::take_shared_by_id<OU>(&scenario, officers);
        vault::revoke(
            &mut v,
            &officers_ou,
            vector[vault::role_deposit(), vault::role_withdraw()],
            vector[acl::ou(members)],
            scenario.ctx(),
        );

        abort
    }

    // === ou_receipt_vault: registry maintenance ===

    /// ou_receipt_vault.move:560 — update_registry_key aborts when the old slot holds another vault's id.
    #[test]
    #[expected_failure(abort_code = vault::EInvalidArguments)]
    fun vault_update_registry_key_slot_points_elsewhere_aborts() {
        let mut scenario = ts::begin(MEMBER);
        let members = make_ou(&mut scenario, MEMBER, vector[MEMBER]);
        let officers = make_ou(&mut scenario, OFFICER, vector[OFFICER]);
        let new_officers = make_ou(&mut scenario, OFFICER, vector[OFFICER]);
        let collection_id = make_collection(&mut scenario, MEMBER);
        let ssu_id = object::id_from_address(@0x5501);

        ts::next_tx(&mut scenario, MEMBER);
        vault::init_for_testing(scenario.ctx());
        let v_id = share_vault(&mut scenario, ssu_id, collection_id, members, officers);

        // The vault claims (ssu_id, officers), but that slot holds a different id.
        ts::next_tx(&mut scenario, MEMBER);
        {
            let mut reg = ts::take_shared<OuReceiptVaultRegistry>(&scenario);
            let mut v = ts::take_shared_by_id<OuReceiptVault>(&scenario, v_id);
            vault::register_for_testing(&mut reg, ssu_id, officers, object::id_from_address(@0xDEAD));
            vault::set_registrant_ou_id_for_testing(&mut v, officers);
            ts::return_shared(v);
            ts::return_shared(reg);
        };

        ts::next_tx(&mut scenario, OFFICER);
        let mut reg = ts::take_shared<OuReceiptVaultRegistry>(&scenario);
        let mut v = ts::take_shared_by_id<OuReceiptVault>(&scenario, v_id);
        let officers_ou = ts::take_shared_by_id<OU>(&scenario, officers);
        let new_officers_ou = ts::take_shared_by_id<OU>(&scenario, new_officers);
        vault::update_registry_key(&mut reg, &mut v, &officers_ou, &new_officers_ou, scenario.ctx());

        abort
    }

    /// ou_receipt_vault.move:561 — update_registry_key aborts when the new slot is already taken.
    #[test]
    #[expected_failure(abort_code = vault::EVaultAlreadyExists)]
    fun vault_update_registry_key_new_slot_taken_aborts() {
        let mut scenario = ts::begin(MEMBER);
        let members = make_ou(&mut scenario, MEMBER, vector[MEMBER]);
        let officers = make_ou(&mut scenario, OFFICER, vector[OFFICER]);
        let new_officers = make_ou(&mut scenario, OFFICER, vector[OFFICER]);
        let collection_id = make_collection(&mut scenario, MEMBER);
        let ssu_id = object::id_from_address(@0x5501);

        ts::next_tx(&mut scenario, MEMBER);
        vault::init_for_testing(scenario.ctx());
        let v_id = share_vault(&mut scenario, ssu_id, collection_id, members, officers);

        // The vault owns (ssu_id, officers); another vault already holds (ssu_id, new_officers).
        ts::next_tx(&mut scenario, MEMBER);
        {
            let mut reg = ts::take_shared<OuReceiptVaultRegistry>(&scenario);
            let mut v = ts::take_shared_by_id<OuReceiptVault>(&scenario, v_id);
            vault::register_for_testing(&mut reg, ssu_id, officers, v_id);
            vault::set_registrant_ou_id_for_testing(&mut v, officers);
            vault::register_for_testing(
                &mut reg,
                ssu_id,
                new_officers,
                object::id_from_address(@0xBEEF),
            );
            ts::return_shared(v);
            ts::return_shared(reg);
        };

        ts::next_tx(&mut scenario, OFFICER);
        let mut reg = ts::take_shared<OuReceiptVaultRegistry>(&scenario);
        let mut v = ts::take_shared_by_id<OuReceiptVault>(&scenario, v_id);
        let officers_ou = ts::take_shared_by_id<OU>(&scenario, officers);
        let new_officers_ou = ts::take_shared_by_id<OU>(&scenario, new_officers);
        vault::update_registry_key(&mut reg, &mut v, &officers_ou, &new_officers_ou, scenario.ctx());

        abort
    }

    /// ou_receipt_vault.move:607 — deinit aborts when the vault's registry slot does not exist.
    #[test]
    #[expected_failure(abort_code = vault::EInvalidArguments)]
    fun vault_deinit_missing_registry_slot_aborts() {
        let mut scenario = ts::begin(MEMBER);
        let members = make_ou(&mut scenario, MEMBER, vector[MEMBER]);
        let officers = make_ou(&mut scenario, OFFICER, vector[OFFICER]);
        let collection_id = make_collection(&mut scenario, MEMBER);
        let ssu_id = object::id_from_address(@0x5501);

        ts::next_tx(&mut scenario, MEMBER);
        vault::init_for_testing(scenario.ctx());
        let v_id = share_vault(&mut scenario, ssu_id, collection_id, members, officers);

        // The vault claims (ssu_id, officers) but was never registered.
        ts::next_tx(&mut scenario, MEMBER);
        {
            let mut v = ts::take_shared_by_id<OuReceiptVault>(&scenario, v_id);
            vault::set_registrant_ou_id_for_testing(&mut v, officers);
            ts::return_shared(v);
        };

        ts::next_tx(&mut scenario, OFFICER);
        let mut reg = ts::take_shared<OuReceiptVaultRegistry>(&scenario);
        let mut v = ts::take_shared_by_id<OuReceiptVault>(&scenario, v_id);
        let officers_ou = ts::take_shared_by_id<OU>(&scenario, officers);
        vault::deinitialize_ou_vault(&mut reg, &mut v, &officers_ou, scenario.ctx());

        abort
    }

    /// ou_receipt_vault.move:608 — deinit aborts when the registry slot holds another vault's id.
    #[test]
    #[expected_failure(abort_code = vault::EVaultRegistryMismatch)]
    fun vault_deinit_slot_points_elsewhere_aborts() {
        let mut scenario = ts::begin(MEMBER);
        let members = make_ou(&mut scenario, MEMBER, vector[MEMBER]);
        let officers = make_ou(&mut scenario, OFFICER, vector[OFFICER]);
        let collection_id = make_collection(&mut scenario, MEMBER);
        let ssu_id = object::id_from_address(@0x5501);

        ts::next_tx(&mut scenario, MEMBER);
        vault::init_for_testing(scenario.ctx());
        let v_id = share_vault(&mut scenario, ssu_id, collection_id, members, officers);

        ts::next_tx(&mut scenario, MEMBER);
        {
            let mut reg = ts::take_shared<OuReceiptVaultRegistry>(&scenario);
            let mut v = ts::take_shared_by_id<OuReceiptVault>(&scenario, v_id);
            vault::register_for_testing(&mut reg, ssu_id, officers, object::id_from_address(@0xDEAD));
            vault::set_registrant_ou_id_for_testing(&mut v, officers);
            ts::return_shared(v);
            ts::return_shared(reg);
        };

        ts::next_tx(&mut scenario, OFFICER);
        let mut reg = ts::take_shared<OuReceiptVaultRegistry>(&scenario);
        let mut v = ts::take_shared_by_id<OuReceiptVault>(&scenario, v_id);
        let officers_ou = ts::take_shared_by_id<OU>(&scenario, officers);
        vault::deinitialize_ou_vault(&mut reg, &mut v, &officers_ou, scenario.ctx());

        abort
    }
}
