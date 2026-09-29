#[test_only]
module armature_vault::keyspace_tests {
    use armature::{ou::{Self, OU}, governance, proposal, remove_member::RemoveMember};
    use armature_vault::{acl as acl, keyspace::{Self, Keyspace, EncryptedEntry}};
    use std::string;
    use sui::test_scenario as ts;

    const ADMIN: address = @0xA;
    const USER1: address = @0xB;
    const USER2: address = @0xC;

    // ── Helpers ──────────────────────────────────────────────────────────────

    fun make_ou(sc: &mut ts::Scenario, creator: address, members: vector<address>): ID {
        ts::next_tx(sc, creator);
        let init = governance::init_board(members);
        ou::create(
            &init,
            string::utf8(b"OU"),
            string::utf8(b"https://example.com/i.png"),
            sc.ctx(),
        )
    }

    /// Share a personal keyspace created by `creator` via the public entry point.
    fun share_personal(sc: &mut ts::Scenario, creator: address): ID {
        ts::next_tx(sc, creator);
        keyspace::create_keyspace(b"Shared", sc.ctx());
        ts::next_tx(sc, creator);
        let ks = ts::take_shared<Keyspace>(sc);
        let id = object::id(&ks);
        ts::return_shared(ks);
        id
    }

    /// Publish an entry into keyspace `ks_id` as `writer` and return its ID.
    fun publish(sc: &mut ts::Scenario, ks_id: ID, ou_id: ID, writer: address): ID {
        ts::next_tx(sc, writer);
        let mut ks = ts::take_shared_by_id<Keyspace>(sc, ks_id);
        let org = ts::take_shared_by_id<OU>(sc, ou_id);
        keyspace::publish_entry(&mut ks, b"QmPublished", b"first", &org, sc.ctx());
        ts::return_shared(org);
        ts::return_shared(ks);
        ts::next_tx(sc, writer);
        let entry = ts::take_shared<EncryptedEntry>(sc);
        let id = object::id(&entry);
        ts::return_shared(entry);
        id
    }

    // ── Tests ─────────────────────────────────────────────────────────────────

    // Creator is seeded into all three roles; non-creators have none.
    #[test]
    fun test_create_seeds_all_roles() {
        let mut sc = ts::begin(ADMIN);
        let ou_id = make_ou(&mut sc, ADMIN, vector[ADMIN]);

        ts::next_tx(&mut sc, ADMIN);
        let org = ts::take_shared_by_id<OU>(&sc, ou_id);
        let allowlist = keyspace::test_create(b"My Vault", sc.ctx());

        assert!(keyspace::has_role(&allowlist, keyspace::role_grant(), &org, ADMIN), 0);
        assert!(keyspace::has_role(&allowlist, keyspace::role_read(), &org, ADMIN), 1);
        assert!(keyspace::has_role(&allowlist, keyspace::role_write(), &org, ADMIN), 2);
        assert!(!keyspace::has_role(&allowlist, keyspace::role_read(), &org, USER1), 3);

        keyspace::test_destroy(allowlist);
        ts::return_shared(org);
        sc.end();
    }

    // Grant a Read principal → has_role; revoke → no longer has_role.
    #[test]
    fun test_grant_and_revoke_read() {
        let mut sc = ts::begin(ADMIN);
        let ou_id = make_ou(&mut sc, ADMIN, vector[ADMIN]);

        ts::next_tx(&mut sc, ADMIN);
        let org = ts::take_shared_by_id<OU>(&sc, ou_id);
        let mut allowlist = keyspace::test_create(b"Vault", sc.ctx());

        keyspace::grant(
            &mut allowlist,
            keyspace::role_read(),
            acl::player(USER1),
            &org,
            sc.ctx(),
        );
        assert!(keyspace::has_role(&allowlist, keyspace::role_read(), &org, USER1), 0);
        assert!(!keyspace::has_role(&allowlist, keyspace::role_read(), &org, USER2), 1);

        keyspace::revoke(
            &mut allowlist,
            keyspace::role_read(),
            acl::player(USER1),
            &org,
            sc.ctx(),
        );
        assert!(!keyspace::has_role(&allowlist, keyspace::role_read(), &org, USER1), 2);

        keyspace::test_destroy(allowlist);
        ts::return_shared(org);
        sc.end();
    }

    // A Machine principal is satisfied by its address, like Player, but is a
    // distinct principal: revoking Player(addr) leaves Machine(addr) in place.
    #[test]
    fun test_machine_principal() {
        let mut sc = ts::begin(ADMIN);
        let ou_id = make_ou(&mut sc, ADMIN, vector[ADMIN]);

        ts::next_tx(&mut sc, ADMIN);
        let org = ts::take_shared_by_id<OU>(&sc, ou_id);
        let mut allowlist = keyspace::test_create(b"Vault", sc.ctx());

        keyspace::grant(
            &mut allowlist,
            keyspace::role_write(),
            acl::machine(USER1),
            &org,
            sc.ctx(),
        );
        assert!(keyspace::has_role(&allowlist, keyspace::role_write(), &org, USER1), 0);
        assert!(!keyspace::has_role(&allowlist, keyspace::role_write(), &org, USER2), 1);

        keyspace::grant(
            &mut allowlist,
            keyspace::role_write(),
            acl::player(USER1),
            &org,
            sc.ctx(),
        );
        keyspace::revoke(
            &mut allowlist,
            keyspace::role_write(),
            acl::player(USER1),
            &org,
            sc.ctx(),
        );
        assert!(keyspace::has_role(&allowlist, keyspace::role_write(), &org, USER1), 2);

        keyspace::revoke(
            &mut allowlist,
            keyspace::role_write(),
            acl::machine(USER1),
            &org,
            sc.ctx(),
        );
        assert!(!keyspace::has_role(&allowlist, keyspace::role_write(), &org, USER1), 3);

        keyspace::test_destroy(allowlist);
        ts::return_shared(org);
        sc.end();
    }

    // A Machine principal can hold Grant (administer the keyspace) and Write
    // (edit entries) on its own, with no board membership.
    #[test]
    fun test_machine_grantor_and_writer() {
        let mut sc = ts::begin(ADMIN);
        let ou_id = make_ou(&mut sc, ADMIN, vector[ADMIN]);

        ts::next_tx(&mut sc, USER1);
        let org = ts::take_shared_by_id<OU>(&sc, ou_id);
        let mut allowlist = keyspace::test_create_for_ou(
            b"Vault",
            vector[acl::machine(USER1)],
            vector[],
            vector[acl::machine(USER1)],
            sc.ctx(),
        );
        let mut entry = keyspace::test_publish_entry(
            &mut allowlist,
            b"QmOriginal",
            b"desc",
            sc.ctx(),
        );

        keyspace::grant(
            &mut allowlist,
            keyspace::role_read(),
            acl::player(USER2),
            &org,
            sc.ctx(),
        );
        assert!(keyspace::has_role(&allowlist, keyspace::role_read(), &org, USER2), 0);

        keyspace::edit_entry(&allowlist, &mut entry, b"QmByMachine", &org, sc.ctx());
        assert!(*keyspace::entry_uri(&entry) == b"QmByMachine".to_string(), 1);

        keyspace::test_destroy_entry(entry);
        keyspace::test_destroy(allowlist);
        ts::return_shared(org);
        sc.end();
    }

    // Granting the same principal to the same role twice must abort (EAlreadyGranted).
    #[test]
    #[expected_failure]
    fun test_duplicate_grant_aborts() {
        let mut sc = ts::begin(ADMIN);
        let ou_id = make_ou(&mut sc, ADMIN, vector[ADMIN]);

        ts::next_tx(&mut sc, ADMIN);
        let org = ts::take_shared_by_id<OU>(&sc, ou_id);
        let mut allowlist = keyspace::test_create(b"Vault", sc.ctx());

        keyspace::grant(
            &mut allowlist,
            keyspace::role_read(),
            acl::player(USER1),
            &org,
            sc.ctx(),
        );
        keyspace::grant(
            &mut allowlist,
            keyspace::role_read(),
            acl::player(USER1),
            &org,
            sc.ctx(),
        ); // abort

        keyspace::test_destroy(allowlist);
        ts::return_shared(org);
        sc.end();
    }

    // Revoking a principal that was never granted must abort (ENotGranted).
    #[test]
    #[expected_failure]
    fun test_revoke_absent_aborts() {
        let mut sc = ts::begin(ADMIN);
        let ou_id = make_ou(&mut sc, ADMIN, vector[ADMIN]);

        ts::next_tx(&mut sc, ADMIN);
        let org = ts::take_shared_by_id<OU>(&sc, ou_id);
        let mut allowlist = keyspace::test_create(b"Vault", sc.ctx());

        keyspace::revoke(
            &mut allowlist,
            keyspace::role_read(),
            acl::player(USER1),
            &org,
            sc.ctx(),
        ); // abort

        keyspace::test_destroy(allowlist);
        ts::return_shared(org);
        sc.end();
    }

    // Caller without Grant role cannot call grant (ENotAllowed).
    #[test]
    #[expected_failure]
    fun test_unauthorized_grant_aborts() {
        let mut sc = ts::begin(ADMIN);
        let ou_id = make_ou(&mut sc, ADMIN, vector[ADMIN]);

        ts::next_tx(&mut sc, ADMIN);
        let org = ts::take_shared_by_id<OU>(&sc, ou_id);
        let mut allowlist = keyspace::test_create(b"Vault", sc.ctx());
        ts::return_shared(org);
        sc.end();

        // USER2 has no Grant role — should abort
        let mut sc = ts::begin(USER2);
        let org = ts::take_shared_by_id<OU>(&sc, ou_id);
        keyspace::grant(
            &mut allowlist,
            keyspace::role_read(),
            acl::player(USER2),
            &org,
            sc.ctx(),
        ); // abort

        keyspace::test_destroy(allowlist);
        ts::return_shared(org);
        sc.end();
    }

    // Cannot revoke the last Grant principal (ELastGrantor).
    #[test]
    #[expected_failure]
    fun test_revoke_last_grantor_aborts() {
        let mut sc = ts::begin(ADMIN);
        let ou_id = make_ou(&mut sc, ADMIN, vector[ADMIN]);

        ts::next_tx(&mut sc, ADMIN);
        let org = ts::take_shared_by_id<OU>(&sc, ou_id);
        let mut allowlist = keyspace::test_create(b"Vault", sc.ctx());

        // ADMIN is the only Grant principal — revoking them must abort
        keyspace::revoke(
            &mut allowlist,
            keyspace::role_grant(),
            acl::player(ADMIN),
            &org,
            sc.ctx(),
        ); // abort

        keyspace::test_destroy(allowlist);
        ts::return_shared(org);
        sc.end();
    }

    // Multiple roles across multiple principals; verify correct membership after revoke.
    #[test]
    fun test_multi_member_lifecycle() {
        let mut sc = ts::begin(ADMIN);
        let ou_id = make_ou(&mut sc, ADMIN, vector[ADMIN]);

        ts::next_tx(&mut sc, ADMIN);
        let org = ts::take_shared_by_id<OU>(&sc, ou_id);
        let mut allowlist = keyspace::test_create(b"Team Vault", sc.ctx());

        keyspace::grant(
            &mut allowlist,
            keyspace::role_read(),
            acl::player(USER1),
            &org,
            sc.ctx(),
        );
        keyspace::grant(
            &mut allowlist,
            keyspace::role_read(),
            acl::player(USER2),
            &org,
            sc.ctx(),
        );
        assert!(keyspace::has_role(&allowlist, keyspace::role_read(), &org, USER1), 0);
        assert!(keyspace::has_role(&allowlist, keyspace::role_read(), &org, USER2), 1);

        keyspace::revoke(
            &mut allowlist,
            keyspace::role_read(),
            acl::player(USER1),
            &org,
            sc.ctx(),
        );
        assert!(!keyspace::has_role(&allowlist, keyspace::role_read(), &org, USER1), 2);
        assert!(keyspace::has_role(&allowlist, keyspace::role_read(), &org, USER2), 3);
        assert!(keyspace::has_role(&allowlist, keyspace::role_grant(), &org, ADMIN), 4);

        keyspace::test_destroy(allowlist);
        ts::return_shared(org);
        sc.end();
    }

    // Granting Read bumps version; other roles do not.
    #[test]
    fun test_version_bumps_only_on_read_changes() {
        let mut sc = ts::begin(ADMIN);
        let ou_id = make_ou(&mut sc, ADMIN, vector[ADMIN]);

        ts::next_tx(&mut sc, ADMIN);
        let org = ts::take_shared_by_id<OU>(&sc, ou_id);
        let mut allowlist = keyspace::test_create(b"Vault", sc.ctx());

        // Grant/Write changes do not bump version
        keyspace::grant(
            &mut allowlist,
            keyspace::role_write(),
            acl::player(USER1),
            &org,
            sc.ctx(),
        );
        keyspace::grant(
            &mut allowlist,
            keyspace::role_grant(),
            acl::player(USER1),
            &org,
            sc.ctx(),
        );
        assert!(keyspace::version(&allowlist) == 0, 0);

        // Read grant bumps version
        keyspace::grant(
            &mut allowlist,
            keyspace::role_read(),
            acl::player(USER1),
            &org,
            sc.ctx(),
        );
        assert!(keyspace::version(&allowlist) == 1, 1);

        // Read revoke bumps version again
        keyspace::revoke(
            &mut allowlist,
            keyspace::role_read(),
            acl::player(USER1),
            &org,
            sc.ctx(),
        );
        assert!(keyspace::version(&allowlist) == 2, 2);

        keyspace::test_destroy(allowlist);
        ts::return_shared(org);
        sc.end();
    }

    // Publishing an entry stores its ID in the entries vector.
    // Uses test_publish_entry to bypass the Write role check.
    #[test]
    fun test_publish_entry_tracks_in_allowlist() {
        let mut sc = ts::begin(ADMIN);
        let mut allowlist = keyspace::test_create(b"Vault", sc.ctx());

        let entry = keyspace::test_publish_entry(
            &mut allowlist,
            b"QmFakeCid1",
            b"first entry",
            sc.ctx(),
        );
        assert!(keyspace::entry_epoch(&entry) == 0, 0);
        assert!(keyspace::version(&allowlist) == 0, 1);

        keyspace::test_destroy_entry(entry);
        keyspace::test_destroy(allowlist);
        sc.end();
    }

    // A Write holder can edit an entry; a non-Write caller cannot.
    #[test]
    fun test_writer_can_edit_entry() {
        let mut sc = ts::begin(ADMIN);
        let ou_id = make_ou(&mut sc, ADMIN, vector[ADMIN]);

        ts::next_tx(&mut sc, ADMIN);
        let org = ts::take_shared_by_id<OU>(&sc, ou_id);
        let mut allowlist = keyspace::test_create(b"Vault", sc.ctx());
        let mut entry = keyspace::test_publish_entry(
            &mut allowlist,
            b"QmOriginal",
            b"desc",
            sc.ctx(),
        );
        keyspace::grant(
            &mut allowlist,
            keyspace::role_write(),
            acl::player(USER1),
            &org,
            sc.ctx(),
        );
        ts::return_shared(org);
        sc.end();

        let mut sc = ts::begin(USER1);
        let org = ts::take_shared_by_id<OU>(&sc, ou_id);
        keyspace::edit_entry(&allowlist, &mut entry, b"QmUpdatedByWriter", &org, sc.ctx());
        assert!(*keyspace::entry_uri(&entry) == b"QmUpdatedByWriter".to_string(), 0);

        keyspace::test_destroy_entry(entry);
        keyspace::test_destroy(allowlist);
        ts::return_shared(org);
        sc.end();
    }

    // Caller without Write role cannot edit an entry (ENotAllowed).
    #[test]
    #[expected_failure]
    fun test_non_writer_cannot_edit_entry() {
        let mut sc = ts::begin(ADMIN);
        let ou_id = make_ou(&mut sc, ADMIN, vector[ADMIN]);

        ts::next_tx(&mut sc, ADMIN);
        let org = ts::take_shared_by_id<OU>(&sc, ou_id);
        let mut allowlist = keyspace::test_create(b"Vault", sc.ctx());
        let mut entry = keyspace::test_publish_entry(
            &mut allowlist,
            b"QmCid",
            b"desc",
            sc.ctx(),
        );
        ts::return_shared(org);
        sc.end();

        // USER2 has no Write role — should abort
        let mut sc = ts::begin(USER2);
        let org = ts::take_shared_by_id<OU>(&sc, ou_id);
        keyspace::edit_entry(&allowlist, &mut entry, b"QmHacked", &org, sc.ctx()); // abort

        keyspace::test_destroy_entry(entry);
        keyspace::test_destroy(allowlist);
        ts::return_shared(org);
        sc.end();
    }

    // Granting Read bumps version; update_entry succeeds on epoch mismatch.
    #[test]
    fun test_update_entry_after_read_grant() {
        let mut sc = ts::begin(ADMIN);
        let ou_id = make_ou(&mut sc, ADMIN, vector[ADMIN]);

        ts::next_tx(&mut sc, ADMIN);
        let org = ts::take_shared_by_id<OU>(&sc, ou_id);
        let mut allowlist = keyspace::test_create(b"Vault", sc.ctx());
        let mut entry = keyspace::test_publish_entry(
            &mut allowlist,
            b"QmOld",
            b"desc",
            sc.ctx(),
        );
        assert!(keyspace::entry_epoch(&entry) == 0, 0);

        // Grant Read to USER1 → version bumps to 1
        keyspace::grant(
            &mut allowlist,
            keyspace::role_read(),
            acl::player(USER1),
            &org,
            sc.ctx(),
        );
        assert!(keyspace::version(&allowlist) == 1, 1);

        // ADMIN has Write — update_entry now succeeds (epoch 0 ≠ version 1)
        keyspace::update_entry(&allowlist, &mut entry, b"QmRotated", &org, sc.ctx());
        assert!(*keyspace::entry_uri(&entry) == b"QmRotated".to_string(), 2);
        assert!(keyspace::entry_epoch(&entry) == 1, 3);

        keyspace::test_destroy_entry(entry);
        keyspace::test_destroy(allowlist);
        ts::return_shared(org);
        sc.end();
    }

    // update_entry aborts when epoch already matches version (EAlreadyCurrentEpoch).
    #[test]
    #[expected_failure]
    fun test_update_entry_same_epoch_aborts() {
        let mut sc = ts::begin(ADMIN);
        let ou_id = make_ou(&mut sc, ADMIN, vector[ADMIN]);

        ts::next_tx(&mut sc, ADMIN);
        let org = ts::take_shared_by_id<OU>(&sc, ou_id);
        let mut allowlist = keyspace::test_create(b"Vault", sc.ctx());
        let mut entry = keyspace::test_publish_entry(
            &mut allowlist,
            b"QmCid",
            b"desc",
            sc.ctx(),
        );

        // epoch == version == 0 → abort
        keyspace::update_entry(&allowlist, &mut entry, b"QmNew", &org, sc.ctx());

        keyspace::test_destroy_entry(entry);
        keyspace::test_destroy(allowlist);
        ts::return_shared(org);
        sc.end();
    }

    // A member removed from an OU's board loses the roles held via that OU's
    // principal; remaining members keep them.
    #[test]
    fun test_removed_board_member_loses_ou_role() {
        let mut sc = ts::begin(ADMIN);
        let ou_id = make_ou(&mut sc, ADMIN, vector[ADMIN, USER1]);

        ts::next_tx(&mut sc, ADMIN);
        let mut org = ts::take_shared_by_id<OU>(&sc, ou_id);
        let keyspace = keyspace::test_create_for_ou(
            b"Org",
            vector[acl::player(ADMIN)],
            vector[acl::ou(ou_id)],
            vector[],
            sc.ctx(),
        );
        assert!(keyspace::has_role(&keyspace, keyspace::role_read(), &org, USER1), 0);

        let req = proposal::new_execution_request_for_testing<RemoveMember>(
            ou_id,
            object::id_from_address(@0x9999),
        );
        org.remove_board_member_governance(USER1, &req);
        proposal::consume_execution_request_for_testing(req);

        assert!(!keyspace::has_role(&keyspace, keyspace::role_read(), &org, USER1), 1);
        assert!(keyspace::has_role(&keyspace, keyspace::role_read(), &org, ADMIN), 2);

        keyspace::test_destroy(keyspace);
        ts::return_shared(org);
        sc.end();
    }

    // ── Public constructors ──────────────────────────────────────────────────

    // create_keyspace shares a keyspace with the sender seeded into every role.
    #[test]
    fun test_create_keyspace_shared() {
        let mut sc = ts::begin(ADMIN);
        let ou_id = make_ou(&mut sc, ADMIN, vector[ADMIN]);
        let ks_id = share_personal(&mut sc, ADMIN);

        ts::next_tx(&mut sc, ADMIN);
        let ks = ts::take_shared_by_id<Keyspace>(&sc, ks_id);
        let org = ts::take_shared_by_id<OU>(&sc, ou_id);
        assert!(*keyspace::name(&ks) == b"Shared".to_string(), 0);
        assert!(keyspace::version(&ks) == 0, 1);
        assert!(keyspace::principals(&ks, keyspace::role_grant()) == vector[acl::player(ADMIN)], 2);
        assert!(keyspace::principals(&ks, keyspace::role_read()) == vector[acl::player(ADMIN)], 3);
        assert!(keyspace::principals(&ks, keyspace::role_write()) == vector[acl::player(ADMIN)], 4);
        assert!(keyspace::has_role(&ks, keyspace::role_write(), &org, ADMIN), 5);
        assert!(!keyspace::has_role(&ks, keyspace::role_write(), &org, USER1), 6);
        ts::return_shared(org);
        ts::return_shared(ks);
        sc.end();
    }

    // create_keyspace_for_ou seeds each role from its own list; empty lists
    // leave the role unset.
    #[test]
    fun test_create_keyspace_for_ou() {
        let mut sc = ts::begin(ADMIN);
        let ou_id = make_ou(&mut sc, ADMIN, vector[ADMIN]);

        ts::next_tx(&mut sc, ADMIN);
        let org = ts::take_shared_by_id<OU>(&sc, ou_id);
        keyspace::create_keyspace_for_ou(
            b"Org Vault",
            &org,
            vector[acl::ou(ou_id)],
            vector[acl::player(USER1), acl::machine(USER2)],
            vector[],
            sc.ctx(),
        );
        ts::return_shared(org);

        ts::next_tx(&mut sc, ADMIN);
        let ks = ts::take_shared<Keyspace>(&sc);
        let org = ts::take_shared_by_id<OU>(&sc, ou_id);
        assert!(*keyspace::name(&ks) == b"Org Vault".to_string(), 0);
        assert!(keyspace::principals(&ks, keyspace::role_grant()) == vector[acl::ou(ou_id)], 1);
        assert!(
            keyspace::principals(&ks, keyspace::role_read())
                == vector[acl::player(USER1), acl::machine(USER2)],
            2,
        );
        assert!(keyspace::principals(&ks, keyspace::role_write()) == vector[], 3);
        assert!(keyspace::has_role(&ks, keyspace::role_grant(), &org, ADMIN), 4);
        assert!(keyspace::has_role(&ks, keyspace::role_read(), &org, USER2), 5);
        // Write is unset, so nobody holds it.
        assert!(!keyspace::has_role(&ks, keyspace::role_write(), &org, ADMIN), 6);
        ts::return_shared(org);
        ts::return_shared(ks);
        sc.end();
    }

    // Read and Write lists may both be non-empty at creation.
    #[test]
    fun test_create_keyspace_for_ou_all_roles() {
        let mut sc = ts::begin(ADMIN);
        let ou_id = make_ou(&mut sc, ADMIN, vector[ADMIN]);

        ts::next_tx(&mut sc, ADMIN);
        let org = ts::take_shared_by_id<OU>(&sc, ou_id);
        keyspace::create_keyspace_for_ou(
            b"Org Vault",
            &org,
            vector[acl::ou(ou_id)],
            vector[acl::ou(ou_id)],
            vector[acl::player(USER1)],
            sc.ctx(),
        );
        ts::return_shared(org);

        ts::next_tx(&mut sc, ADMIN);
        let ks = ts::take_shared<Keyspace>(&sc);
        assert!(keyspace::principals(&ks, keyspace::role_write()) == vector[acl::player(USER1)], 0);
        ts::return_shared(ks);
        sc.end();
    }

    // Only a board member of the OU may create a keyspace for it.
    #[test]
    #[expected_failure(abort_code = keyspace::ENotAllowed)]
    fun test_create_keyspace_for_ou_non_member_aborts() {
        let mut sc = ts::begin(ADMIN);
        let ou_id = make_ou(&mut sc, ADMIN, vector[ADMIN]);

        ts::next_tx(&mut sc, USER1);
        let org = ts::take_shared_by_id<OU>(&sc, ou_id);
        keyspace::create_keyspace_for_ou(
            b"Org Vault",
            &org,
            vector[acl::player(USER1)],
            vector[],
            vector[],
            sc.ctx(),
        );
        abort 99
    }

    // An empty Grant list would leave the keyspace unadministrable.
    #[test]
    #[expected_failure(abort_code = keyspace::EEmptyGrantPrincipals)]
    fun test_create_keyspace_for_ou_empty_grant_aborts() {
        let mut sc = ts::begin(ADMIN);
        let ou_id = make_ou(&mut sc, ADMIN, vector[ADMIN]);

        ts::next_tx(&mut sc, ADMIN);
        let org = ts::take_shared_by_id<OU>(&sc, ou_id);
        keyspace::create_keyspace_for_ou(
            b"Org Vault",
            &org,
            vector[],
            vector[acl::player(USER1)],
            vector[],
            sc.ctx(),
        );
        abort 99
    }

    // ── Unset roles ──────────────────────────────────────────────────────────

    // Granting into an unset role creates it.
    #[test]
    fun test_grant_into_unset_role() {
        let mut sc = ts::begin(ADMIN);
        let ou_id = make_ou(&mut sc, ADMIN, vector[ADMIN]);

        ts::next_tx(&mut sc, ADMIN);
        let org = ts::take_shared_by_id<OU>(&sc, ou_id);
        let mut ks = keyspace::test_create_for_ou(
            b"Vault",
            vector[acl::player(ADMIN)],
            vector[],
            vector[],
            sc.ctx(),
        );
        assert!(!keyspace::has_role(&ks, keyspace::role_write(), &org, USER1), 0);
        keyspace::grant(&mut ks, keyspace::role_write(), acl::player(USER1), &org, sc.ctx());
        assert!(keyspace::has_role(&ks, keyspace::role_write(), &org, USER1), 1);

        keyspace::test_destroy(ks);
        ts::return_shared(org);
        sc.end();
    }

    // Revoking from an unset role aborts ENotGranted.
    #[test]
    #[expected_failure(abort_code = keyspace::ENotGranted)]
    fun test_revoke_from_unset_role_aborts() {
        let mut sc = ts::begin(ADMIN);
        let ou_id = make_ou(&mut sc, ADMIN, vector[ADMIN]);

        ts::next_tx(&mut sc, ADMIN);
        let org = ts::take_shared_by_id<OU>(&sc, ou_id);
        let mut ks = keyspace::test_create_for_ou(
            b"Vault",
            vector[acl::player(ADMIN)],
            vector[],
            vector[],
            sc.ctx(),
        );
        keyspace::revoke(&mut ks, keyspace::role_read(), acl::player(ADMIN), &org, sc.ctx());
        abort 99
    }

    // Revoking the only Write principal aborts ELastWriter.
    #[test]
    #[expected_failure(abort_code = keyspace::ELastWriter)]
    fun test_revoke_last_writer_aborts() {
        let mut sc = ts::begin(ADMIN);
        let ou_id = make_ou(&mut sc, ADMIN, vector[ADMIN]);

        ts::next_tx(&mut sc, ADMIN);
        let org = ts::take_shared_by_id<OU>(&sc, ou_id);
        let mut ks = keyspace::test_create(b"Vault", sc.ctx());
        keyspace::revoke(&mut ks, keyspace::role_write(), acl::player(ADMIN), &org, sc.ctx());
        abort 99
    }

    // Revoking the only Read principal aborts ELastReader.
    #[test]
    #[expected_failure(abort_code = keyspace::ELastReader)]
    fun test_revoke_last_reader_aborts() {
        let mut sc = ts::begin(ADMIN);
        let ou_id = make_ou(&mut sc, ADMIN, vector[ADMIN]);

        ts::next_tx(&mut sc, ADMIN);
        let org = ts::take_shared_by_id<OU>(&sc, ou_id);
        let mut ks = keyspace::test_create(b"Vault", sc.ctx());
        keyspace::revoke(&mut ks, keyspace::role_read(), acl::player(ADMIN), &org, sc.ctx());
        abort 99
    }

    // ── multi_grant / multi_revoke ───────────────────────────────────────────

    // multi_grant adds every role and bumps version once per Read; multi_revoke
    // removes them again and bumps version for the Read removal.
    #[test]
    fun test_multi_grant_and_multi_revoke() {
        let mut sc = ts::begin(ADMIN);
        let ou_id = make_ou(&mut sc, ADMIN, vector[ADMIN]);

        ts::next_tx(&mut sc, ADMIN);
        let org = ts::take_shared_by_id<OU>(&sc, ou_id);
        let mut ks = keyspace::test_create(b"Vault", sc.ctx());
        let all = vector[keyspace::role_grant(), keyspace::role_read(), keyspace::role_write()];

        keyspace::multi_grant(&mut ks, all, acl::player(USER1), &org, sc.ctx());
        assert!(keyspace::version(&ks) == 1, 0);
        assert!(keyspace::has_role(&ks, keyspace::role_grant(), &org, USER1), 1);
        assert!(keyspace::has_role(&ks, keyspace::role_read(), &org, USER1), 2);
        assert!(keyspace::has_role(&ks, keyspace::role_write(), &org, USER1), 3);

        keyspace::multi_revoke(&mut ks, all, acl::player(USER1), &org, sc.ctx());
        assert!(keyspace::version(&ks) == 2, 4);
        assert!(!keyspace::has_role(&ks, keyspace::role_grant(), &org, USER1), 5);
        assert!(!keyspace::has_role(&ks, keyspace::role_read(), &org, USER1), 6);
        assert!(!keyspace::has_role(&ks, keyspace::role_write(), &org, USER1), 7);
        assert!(keyspace::has_role(&ks, keyspace::role_grant(), &org, ADMIN), 8);

        keyspace::test_destroy(ks);
        ts::return_shared(org);
        sc.end();
    }

    // An empty role list is a no-op for both calls.
    #[test]
    fun test_multi_grant_revoke_empty_roles() {
        let mut sc = ts::begin(ADMIN);
        let ou_id = make_ou(&mut sc, ADMIN, vector[ADMIN]);

        ts::next_tx(&mut sc, ADMIN);
        let org = ts::take_shared_by_id<OU>(&sc, ou_id);
        let mut ks = keyspace::test_create(b"Vault", sc.ctx());
        keyspace::multi_grant(&mut ks, vector[], acl::player(USER1), &org, sc.ctx());
        keyspace::multi_revoke(&mut ks, vector[], acl::player(USER1), &org, sc.ctx());
        assert!(keyspace::version(&ks) == 0, 0);

        keyspace::test_destroy(ks);
        ts::return_shared(org);
        sc.end();
    }

    #[test]
    #[expected_failure(abort_code = keyspace::ENotAllowed)]
    fun test_multi_grant_unauthorized_aborts() {
        let mut sc = ts::begin(ADMIN);
        let ou_id = make_ou(&mut sc, ADMIN, vector[ADMIN]);

        ts::next_tx(&mut sc, ADMIN);
        let mut ks = keyspace::test_create(b"Vault", sc.ctx());

        ts::next_tx(&mut sc, USER1);
        let org = ts::take_shared_by_id<OU>(&sc, ou_id);
        keyspace::multi_grant(
            &mut ks,
            vector[keyspace::role_read()],
            acl::player(USER1),
            &org,
            sc.ctx(),
        );
        abort 99
    }

    // A role the principal already holds makes the whole batch abort.
    #[test]
    #[expected_failure(abort_code = keyspace::EAlreadyGranted)]
    fun test_multi_grant_duplicate_aborts() {
        let mut sc = ts::begin(ADMIN);
        let ou_id = make_ou(&mut sc, ADMIN, vector[ADMIN]);

        ts::next_tx(&mut sc, ADMIN);
        let org = ts::take_shared_by_id<OU>(&sc, ou_id);
        let mut ks = keyspace::test_create(b"Vault", sc.ctx());
        keyspace::multi_grant(
            &mut ks,
            vector[keyspace::role_write(), keyspace::role_read()],
            acl::player(ADMIN),
            &org,
            sc.ctx(),
        );
        abort 99
    }

    #[test]
    #[expected_failure(abort_code = keyspace::ENotAllowed)]
    fun test_multi_revoke_unauthorized_aborts() {
        let mut sc = ts::begin(ADMIN);
        let ou_id = make_ou(&mut sc, ADMIN, vector[ADMIN]);

        ts::next_tx(&mut sc, ADMIN);
        let mut ks = keyspace::test_create(b"Vault", sc.ctx());

        ts::next_tx(&mut sc, USER1);
        let org = ts::take_shared_by_id<OU>(&sc, ou_id);
        keyspace::multi_revoke(
            &mut ks,
            vector[keyspace::role_read()],
            acl::player(ADMIN),
            &org,
            sc.ctx(),
        );
        abort 99
    }

    #[test]
    #[expected_failure(abort_code = keyspace::ENotGranted)]
    fun test_multi_revoke_not_granted_aborts() {
        let mut sc = ts::begin(ADMIN);
        let ou_id = make_ou(&mut sc, ADMIN, vector[ADMIN]);

        ts::next_tx(&mut sc, ADMIN);
        let org = ts::take_shared_by_id<OU>(&sc, ou_id);
        let mut ks = keyspace::test_create(b"Vault", sc.ctx());
        keyspace::multi_revoke(
            &mut ks,
            vector[keyspace::role_read()],
            acl::player(USER1),
            &org,
            sc.ctx(),
        );
        abort 99
    }

    #[test]
    #[expected_failure(abort_code = keyspace::ELastGrantor)]
    fun test_multi_revoke_last_grantor_aborts() {
        let mut sc = ts::begin(ADMIN);
        let ou_id = make_ou(&mut sc, ADMIN, vector[ADMIN]);

        ts::next_tx(&mut sc, ADMIN);
        let org = ts::take_shared_by_id<OU>(&sc, ou_id);
        let mut ks = keyspace::test_create(b"Vault", sc.ctx());
        keyspace::multi_revoke(
            &mut ks,
            vector[keyspace::role_grant()],
            acl::player(ADMIN),
            &org,
            sc.ctx(),
        );
        abort 99
    }

    #[test]
    #[expected_failure(abort_code = keyspace::ELastWriter)]
    fun test_multi_revoke_last_writer_aborts() {
        let mut sc = ts::begin(ADMIN);
        let ou_id = make_ou(&mut sc, ADMIN, vector[ADMIN]);

        ts::next_tx(&mut sc, ADMIN);
        let org = ts::take_shared_by_id<OU>(&sc, ou_id);
        let mut ks = keyspace::test_create(b"Vault", sc.ctx());
        keyspace::multi_revoke(
            &mut ks,
            vector[keyspace::role_write()],
            acl::player(ADMIN),
            &org,
            sc.ctx(),
        );
        abort 99
    }

    #[test]
    #[expected_failure(abort_code = keyspace::ELastReader)]
    fun test_multi_revoke_last_reader_aborts() {
        let mut sc = ts::begin(ADMIN);
        let ou_id = make_ou(&mut sc, ADMIN, vector[ADMIN]);

        ts::next_tx(&mut sc, ADMIN);
        let org = ts::take_shared_by_id<OU>(&sc, ou_id);
        let mut ks = keyspace::test_create(b"Vault", sc.ctx());
        keyspace::multi_revoke(
            &mut ks,
            vector[keyspace::role_read()],
            acl::player(ADMIN),
            &org,
            sc.ctx(),
        );
        abort 99
    }

    // ── seal_approve ─────────────────────────────────────────────────────────

    // A Read holder is approved for an id prefixed by the keyspace's object ID,
    // including via an OU principal.
    #[test]
    fun test_seal_approve_reader() {
        let mut sc = ts::begin(ADMIN);
        let ou_id = make_ou(&mut sc, ADMIN, vector[ADMIN, USER1]);

        ts::next_tx(&mut sc, ADMIN);
        let org = ts::take_shared_by_id<OU>(&sc, ou_id);
        let mut ks = keyspace::test_create(b"Vault", sc.ctx());
        keyspace::grant(&mut ks, keyspace::role_read(), acl::ou(ou_id), &org, sc.ctx());

        let mut id = object::id(&ks).to_bytes();
        id.append(b"nonce");
        keyspace::test_seal_approve(id, &ks, &org, sc.ctx());
        ts::return_shared(org);

        ts::next_tx(&mut sc, USER1);
        let org = ts::take_shared_by_id<OU>(&sc, ou_id);
        keyspace::test_seal_approve(id, &ks, &org, sc.ctx());

        keyspace::test_destroy(ks);
        ts::return_shared(org);
        sc.end();
    }

    // An id that is not prefixed by this keyspace's object ID is rejected.
    #[test]
    #[expected_failure(abort_code = keyspace::ENotAllowed)]
    fun test_seal_approve_wrong_id_aborts() {
        let mut sc = ts::begin(ADMIN);
        let ou_id = make_ou(&mut sc, ADMIN, vector[ADMIN]);

        ts::next_tx(&mut sc, ADMIN);
        let org = ts::take_shared_by_id<OU>(&sc, ou_id);
        let ks = keyspace::test_create(b"Vault", sc.ctx());
        keyspace::test_seal_approve(ou_id.to_bytes(), &ks, &org, sc.ctx());
        abort 99
    }

    // A caller without Read is rejected even with the right id.
    #[test]
    #[expected_failure(abort_code = keyspace::ENotAllowed)]
    fun test_seal_approve_non_reader_aborts() {
        let mut sc = ts::begin(ADMIN);
        let ou_id = make_ou(&mut sc, ADMIN, vector[ADMIN]);

        ts::next_tx(&mut sc, ADMIN);
        let ks = keyspace::test_create(b"Vault", sc.ctx());

        ts::next_tx(&mut sc, USER1);
        let org = ts::take_shared_by_id<OU>(&sc, ou_id);
        keyspace::test_seal_approve(object::id(&ks).to_bytes(), &ks, &org, sc.ctx());
        abort 99
    }

    // ── Entries ──────────────────────────────────────────────────────────────

    // publish_entry shares an entry stamped with the current version; a writer
    // can then edit its description and URI.
    #[test]
    fun test_publish_and_edit_shared_entry() {
        let mut sc = ts::begin(ADMIN);
        let ou_id = make_ou(&mut sc, ADMIN, vector[ADMIN]);
        let ks_id = share_personal(&mut sc, ADMIN);

        // Bump version to 1 so the published entry's epoch is observable.
        ts::next_tx(&mut sc, ADMIN);
        {
            let mut ks = ts::take_shared_by_id<Keyspace>(&sc, ks_id);
            let org = ts::take_shared_by_id<OU>(&sc, ou_id);
            keyspace::grant(&mut ks, keyspace::role_read(), acl::player(USER1), &org, sc.ctx());
            ts::return_shared(org);
            ts::return_shared(ks);
        };
        let entry_id = publish(&mut sc, ks_id, ou_id, ADMIN);

        ts::next_tx(&mut sc, ADMIN);
        let ks = ts::take_shared_by_id<Keyspace>(&sc, ks_id);
        let org = ts::take_shared_by_id<OU>(&sc, ou_id);
        let mut entry = ts::take_shared_by_id<EncryptedEntry>(&sc, entry_id);
        assert!(*keyspace::entry_uri(&entry) == b"QmPublished".to_string(), 0);
        assert!(*keyspace::entry_description(&entry) == b"first".to_string(), 1);
        assert!(keyspace::entry_epoch(&entry) == 1, 2);

        keyspace::edit_description(&ks, &mut entry, b"renamed", &org, sc.ctx());
        assert!(*keyspace::entry_description(&entry) == b"renamed".to_string(), 3);
        keyspace::edit_entry(&ks, &mut entry, b"QmEdited", &org, sc.ctx());
        assert!(*keyspace::entry_uri(&entry) == b"QmEdited".to_string(), 4);
        assert!(keyspace::entry_epoch(&entry) == 1, 5);

        ts::return_shared(entry);
        ts::return_shared(org);
        ts::return_shared(ks);
        sc.end();
    }

    #[test]
    #[expected_failure(abort_code = keyspace::ENotAllowed)]
    fun test_publish_entry_non_writer_aborts() {
        let mut sc = ts::begin(ADMIN);
        let ou_id = make_ou(&mut sc, ADMIN, vector[ADMIN]);
        let ks_id = share_personal(&mut sc, ADMIN);
        publish(&mut sc, ks_id, ou_id, USER1);
        abort 99
    }

    #[test]
    #[expected_failure(abort_code = keyspace::ENotAllowed)]
    fun test_edit_description_non_writer_aborts() {
        let mut sc = ts::begin(ADMIN);
        let ou_id = make_ou(&mut sc, ADMIN, vector[ADMIN]);

        ts::next_tx(&mut sc, ADMIN);
        let mut ks = keyspace::test_create(b"Vault", sc.ctx());
        let mut entry = keyspace::test_publish_entry(&mut ks, b"QmCid", b"desc", sc.ctx());

        ts::next_tx(&mut sc, USER1);
        let org = ts::take_shared_by_id<OU>(&sc, ou_id);
        keyspace::edit_description(&ks, &mut entry, b"hacked", &org, sc.ctx());
        abort 99
    }

    // Entries can only be mutated through the keyspace they were published in.
    #[test]
    #[expected_failure(abort_code = keyspace::EWrongKeyspace)]
    fun test_edit_description_wrong_keyspace_aborts() {
        let mut sc = ts::begin(ADMIN);
        let ou_id = make_ou(&mut sc, ADMIN, vector[ADMIN]);

        ts::next_tx(&mut sc, ADMIN);
        let org = ts::take_shared_by_id<OU>(&sc, ou_id);
        let mut home = keyspace::test_create(b"Home", sc.ctx());
        let other = keyspace::test_create(b"Other", sc.ctx());
        let mut entry = keyspace::test_publish_entry(&mut home, b"QmCid", b"desc", sc.ctx());
        keyspace::edit_description(&other, &mut entry, b"moved", &org, sc.ctx());
        abort 99
    }

    #[test]
    #[expected_failure(abort_code = keyspace::EWrongKeyspace)]
    fun test_edit_entry_wrong_keyspace_aborts() {
        let mut sc = ts::begin(ADMIN);
        let ou_id = make_ou(&mut sc, ADMIN, vector[ADMIN]);

        ts::next_tx(&mut sc, ADMIN);
        let org = ts::take_shared_by_id<OU>(&sc, ou_id);
        let mut home = keyspace::test_create(b"Home", sc.ctx());
        let other = keyspace::test_create(b"Other", sc.ctx());
        let mut entry = keyspace::test_publish_entry(&mut home, b"QmCid", b"desc", sc.ctx());
        keyspace::edit_entry(&other, &mut entry, b"QmMoved", &org, sc.ctx());
        abort 99
    }

    #[test]
    #[expected_failure(abort_code = keyspace::EWrongKeyspace)]
    fun test_update_entry_wrong_keyspace_aborts() {
        let mut sc = ts::begin(ADMIN);
        let ou_id = make_ou(&mut sc, ADMIN, vector[ADMIN]);

        ts::next_tx(&mut sc, ADMIN);
        let org = ts::take_shared_by_id<OU>(&sc, ou_id);
        let mut home = keyspace::test_create(b"Home", sc.ctx());
        let other = keyspace::test_create(b"Other", sc.ctx());
        let mut entry = keyspace::test_publish_entry(&mut home, b"QmCid", b"desc", sc.ctx());
        keyspace::update_entry(&other, &mut entry, b"QmMoved", &org, sc.ctx());
        abort 99
    }

    #[test]
    #[expected_failure(abort_code = keyspace::ENotAllowed)]
    fun test_update_entry_non_writer_aborts() {
        let mut sc = ts::begin(ADMIN);
        let ou_id = make_ou(&mut sc, ADMIN, vector[ADMIN]);

        ts::next_tx(&mut sc, ADMIN);
        let mut ks = keyspace::test_create(b"Vault", sc.ctx());
        let mut entry = keyspace::test_publish_entry(&mut ks, b"QmCid", b"desc", sc.ctx());

        ts::next_tx(&mut sc, USER1);
        let org = ts::take_shared_by_id<OU>(&sc, ou_id);
        keyspace::update_entry(&ks, &mut entry, b"QmNew", &org, sc.ctx());
        abort 99
    }
}
