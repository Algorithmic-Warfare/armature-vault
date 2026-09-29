#[test_only]
module armature_vault::keyspace_tests {
    use armature::{ou::{Self, OU}, governance, proposal, remove_member::RemoveMember};
    use armature_vault::{acl as acl, keyspace};
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
}
