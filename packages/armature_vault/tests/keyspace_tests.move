#[test_only]
module armature_vault::keyspace_tests {
    use armature::{dao::{Self, DAO}, governance};
    use armature_vault::{acl as acl, keyspace};
    use std::string;
    use sui::test_scenario as ts;

    const ADMIN: address = @0xA;
    const USER1: address = @0xB;
    const USER2: address = @0xC;

    // ── Helpers ──────────────────────────────────────────────────────────────

    fun make_dao(sc: &mut ts::Scenario, creator: address, members: vector<address>): ID {
        ts::next_tx(sc, creator);
        let init = governance::init_board(members);
        dao::create(
            &init,
            string::utf8(b"DAO"),
            string::utf8(b"https://example.com/i.png"),
            sc.ctx(),
        )
    }

    // ── Tests ─────────────────────────────────────────────────────────────────

    // Creator is seeded into all three roles; non-creators have none.
    #[test]
    fun test_create_seeds_all_roles() {
        let mut sc = ts::begin(ADMIN);
        let dao_id = make_dao(&mut sc, ADMIN, vector[ADMIN]);

        ts::next_tx(&mut sc, ADMIN);
        let dao = ts::take_shared_by_id<DAO>(&sc, dao_id);
        let allowlist = keyspace::test_create(b"My Vault", sc.ctx());

        assert!(keyspace::has_role(&allowlist, keyspace::role_grant(), &dao, ADMIN), 0);
        assert!(keyspace::has_role(&allowlist, keyspace::role_read(), &dao, ADMIN), 1);
        assert!(keyspace::has_role(&allowlist, keyspace::role_write(), &dao, ADMIN), 2);
        assert!(!keyspace::has_role(&allowlist, keyspace::role_read(), &dao, USER1), 3);

        keyspace::test_destroy(allowlist);
        ts::return_shared(dao);
        sc.end();
    }

    // Grant a Read principal → has_role; revoke → no longer has_role.
    #[test]
    fun test_grant_and_revoke_read() {
        let mut sc = ts::begin(ADMIN);
        let dao_id = make_dao(&mut sc, ADMIN, vector[ADMIN]);

        ts::next_tx(&mut sc, ADMIN);
        let dao = ts::take_shared_by_id<DAO>(&sc, dao_id);
        let mut allowlist = keyspace::test_create(b"Vault", sc.ctx());

        keyspace::grant(
            &mut allowlist,
            keyspace::role_read(),
            acl::player(USER1),
            &dao,
            sc.ctx(),
        );
        assert!(keyspace::has_role(&allowlist, keyspace::role_read(), &dao, USER1), 0);
        assert!(!keyspace::has_role(&allowlist, keyspace::role_read(), &dao, USER2), 1);

        keyspace::revoke(
            &mut allowlist,
            keyspace::role_read(),
            acl::player(USER1),
            &dao,
            sc.ctx(),
        );
        assert!(!keyspace::has_role(&allowlist, keyspace::role_read(), &dao, USER1), 2);

        keyspace::test_destroy(allowlist);
        ts::return_shared(dao);
        sc.end();
    }

    // Granting the same principal to the same role twice must abort (EAlreadyGranted).
    #[test]
    #[expected_failure]
    fun test_duplicate_grant_aborts() {
        let mut sc = ts::begin(ADMIN);
        let dao_id = make_dao(&mut sc, ADMIN, vector[ADMIN]);

        ts::next_tx(&mut sc, ADMIN);
        let dao = ts::take_shared_by_id<DAO>(&sc, dao_id);
        let mut allowlist = keyspace::test_create(b"Vault", sc.ctx());

        keyspace::grant(
            &mut allowlist,
            keyspace::role_read(),
            acl::player(USER1),
            &dao,
            sc.ctx(),
        );
        keyspace::grant(
            &mut allowlist,
            keyspace::role_read(),
            acl::player(USER1),
            &dao,
            sc.ctx(),
        ); // abort

        keyspace::test_destroy(allowlist);
        ts::return_shared(dao);
        sc.end();
    }

    // Revoking a principal that was never granted must abort (ENotGranted).
    #[test]
    #[expected_failure]
    fun test_revoke_absent_aborts() {
        let mut sc = ts::begin(ADMIN);
        let dao_id = make_dao(&mut sc, ADMIN, vector[ADMIN]);

        ts::next_tx(&mut sc, ADMIN);
        let dao = ts::take_shared_by_id<DAO>(&sc, dao_id);
        let mut allowlist = keyspace::test_create(b"Vault", sc.ctx());

        keyspace::revoke(
            &mut allowlist,
            keyspace::role_read(),
            acl::player(USER1),
            &dao,
            sc.ctx(),
        ); // abort

        keyspace::test_destroy(allowlist);
        ts::return_shared(dao);
        sc.end();
    }

    // Caller without Grant role cannot call grant (ENotAllowed).
    #[test]
    #[expected_failure]
    fun test_unauthorized_grant_aborts() {
        let mut sc = ts::begin(ADMIN);
        let dao_id = make_dao(&mut sc, ADMIN, vector[ADMIN]);

        ts::next_tx(&mut sc, ADMIN);
        let dao = ts::take_shared_by_id<DAO>(&sc, dao_id);
        let mut allowlist = keyspace::test_create(b"Vault", sc.ctx());
        ts::return_shared(dao);
        sc.end();

        // USER2 has no Grant role — should abort
        let mut sc = ts::begin(USER2);
        let dao = ts::take_shared_by_id<DAO>(&sc, dao_id);
        keyspace::grant(
            &mut allowlist,
            keyspace::role_read(),
            acl::player(USER2),
            &dao,
            sc.ctx(),
        ); // abort

        keyspace::test_destroy(allowlist);
        ts::return_shared(dao);
        sc.end();
    }

    // Cannot revoke the last Grant principal (ELastGrantor).
    #[test]
    #[expected_failure]
    fun test_revoke_last_grantor_aborts() {
        let mut sc = ts::begin(ADMIN);
        let dao_id = make_dao(&mut sc, ADMIN, vector[ADMIN]);

        ts::next_tx(&mut sc, ADMIN);
        let dao = ts::take_shared_by_id<DAO>(&sc, dao_id);
        let mut allowlist = keyspace::test_create(b"Vault", sc.ctx());

        // ADMIN is the only Grant principal — revoking them must abort
        keyspace::revoke(
            &mut allowlist,
            keyspace::role_grant(),
            acl::player(ADMIN),
            &dao,
            sc.ctx(),
        ); // abort

        keyspace::test_destroy(allowlist);
        ts::return_shared(dao);
        sc.end();
    }

    // Multiple roles across multiple principals; verify correct membership after revoke.
    #[test]
    fun test_multi_member_lifecycle() {
        let mut sc = ts::begin(ADMIN);
        let dao_id = make_dao(&mut sc, ADMIN, vector[ADMIN]);

        ts::next_tx(&mut sc, ADMIN);
        let dao = ts::take_shared_by_id<DAO>(&sc, dao_id);
        let mut allowlist = keyspace::test_create(b"Team Vault", sc.ctx());

        keyspace::grant(
            &mut allowlist,
            keyspace::role_read(),
            acl::player(USER1),
            &dao,
            sc.ctx(),
        );
        keyspace::grant(
            &mut allowlist,
            keyspace::role_read(),
            acl::player(USER2),
            &dao,
            sc.ctx(),
        );
        assert!(keyspace::has_role(&allowlist, keyspace::role_read(), &dao, USER1), 0);
        assert!(keyspace::has_role(&allowlist, keyspace::role_read(), &dao, USER2), 1);

        keyspace::revoke(
            &mut allowlist,
            keyspace::role_read(),
            acl::player(USER1),
            &dao,
            sc.ctx(),
        );
        assert!(!keyspace::has_role(&allowlist, keyspace::role_read(), &dao, USER1), 2);
        assert!(keyspace::has_role(&allowlist, keyspace::role_read(), &dao, USER2), 3);
        assert!(keyspace::has_role(&allowlist, keyspace::role_grant(), &dao, ADMIN), 4);

        keyspace::test_destroy(allowlist);
        ts::return_shared(dao);
        sc.end();
    }

    // Granting Read bumps version; other roles do not.
    #[test]
    fun test_version_bumps_only_on_read_changes() {
        let mut sc = ts::begin(ADMIN);
        let dao_id = make_dao(&mut sc, ADMIN, vector[ADMIN]);

        ts::next_tx(&mut sc, ADMIN);
        let dao = ts::take_shared_by_id<DAO>(&sc, dao_id);
        let mut allowlist = keyspace::test_create(b"Vault", sc.ctx());

        // Grant/Write changes do not bump version
        keyspace::grant(
            &mut allowlist,
            keyspace::role_write(),
            acl::player(USER1),
            &dao,
            sc.ctx(),
        );
        keyspace::grant(
            &mut allowlist,
            keyspace::role_grant(),
            acl::player(USER1),
            &dao,
            sc.ctx(),
        );
        assert!(keyspace::version(&allowlist) == 0, 0);

        // Read grant bumps version
        keyspace::grant(
            &mut allowlist,
            keyspace::role_read(),
            acl::player(USER1),
            &dao,
            sc.ctx(),
        );
        assert!(keyspace::version(&allowlist) == 1, 1);

        // Read revoke bumps version again
        keyspace::revoke(
            &mut allowlist,
            keyspace::role_read(),
            acl::player(USER1),
            &dao,
            sc.ctx(),
        );
        assert!(keyspace::version(&allowlist) == 2, 2);

        keyspace::test_destroy(allowlist);
        ts::return_shared(dao);
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
        let dao_id = make_dao(&mut sc, ADMIN, vector[ADMIN]);

        ts::next_tx(&mut sc, ADMIN);
        let dao = ts::take_shared_by_id<DAO>(&sc, dao_id);
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
            &dao,
            sc.ctx(),
        );
        ts::return_shared(dao);
        sc.end();

        let mut sc = ts::begin(USER1);
        let dao = ts::take_shared_by_id<DAO>(&sc, dao_id);
        keyspace::edit_entry(&allowlist, &mut entry, b"QmUpdatedByWriter", &dao, sc.ctx());
        assert!(*keyspace::entry_uri(&entry) == b"QmUpdatedByWriter".to_string(), 0);

        keyspace::test_destroy_entry(entry);
        keyspace::test_destroy(allowlist);
        ts::return_shared(dao);
        sc.end();
    }

    // Caller without Write role cannot edit an entry (ENotAllowed).
    #[test]
    #[expected_failure]
    fun test_non_writer_cannot_edit_entry() {
        let mut sc = ts::begin(ADMIN);
        let dao_id = make_dao(&mut sc, ADMIN, vector[ADMIN]);

        ts::next_tx(&mut sc, ADMIN);
        let dao = ts::take_shared_by_id<DAO>(&sc, dao_id);
        let mut allowlist = keyspace::test_create(b"Vault", sc.ctx());
        let mut entry = keyspace::test_publish_entry(
            &mut allowlist,
            b"QmCid",
            b"desc",
            sc.ctx(),
        );
        ts::return_shared(dao);
        sc.end();

        // USER2 has no Write role — should abort
        let mut sc = ts::begin(USER2);
        let dao = ts::take_shared_by_id<DAO>(&sc, dao_id);
        keyspace::edit_entry(&allowlist, &mut entry, b"QmHacked", &dao, sc.ctx()); // abort

        keyspace::test_destroy_entry(entry);
        keyspace::test_destroy(allowlist);
        ts::return_shared(dao);
        sc.end();
    }

    // Granting Read bumps version; update_entry succeeds on epoch mismatch.
    #[test]
    fun test_update_entry_after_read_grant() {
        let mut sc = ts::begin(ADMIN);
        let dao_id = make_dao(&mut sc, ADMIN, vector[ADMIN]);

        ts::next_tx(&mut sc, ADMIN);
        let dao = ts::take_shared_by_id<DAO>(&sc, dao_id);
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
            &dao,
            sc.ctx(),
        );
        assert!(keyspace::version(&allowlist) == 1, 1);

        // ADMIN has Write — update_entry now succeeds (epoch 0 ≠ version 1)
        keyspace::update_entry(&allowlist, &mut entry, b"QmRotated", &dao, sc.ctx());
        assert!(*keyspace::entry_uri(&entry) == b"QmRotated".to_string(), 2);
        assert!(keyspace::entry_epoch(&entry) == 1, 3);

        keyspace::test_destroy_entry(entry);
        keyspace::test_destroy(allowlist);
        ts::return_shared(dao);
        sc.end();
    }

    // update_entry aborts when epoch already matches version (EAlreadyCurrentEpoch).
    #[test]
    #[expected_failure]
    fun test_update_entry_same_epoch_aborts() {
        let mut sc = ts::begin(ADMIN);
        let dao_id = make_dao(&mut sc, ADMIN, vector[ADMIN]);

        ts::next_tx(&mut sc, ADMIN);
        let dao = ts::take_shared_by_id<DAO>(&sc, dao_id);
        let mut allowlist = keyspace::test_create(b"Vault", sc.ctx());
        let mut entry = keyspace::test_publish_entry(
            &mut allowlist,
            b"QmCid",
            b"desc",
            sc.ctx(),
        );

        // epoch == version == 0 → abort
        keyspace::update_entry(&allowlist, &mut entry, b"QmNew", &dao, sc.ctx());

        keyspace::test_destroy_entry(entry);
        keyspace::test_destroy(allowlist);
        ts::return_shared(dao);
        sc.end();
    }

    // ── v2 principals ─────────────────────────────────────────────────────────

    // A machine principal granted Read satisfies the role for its address and
    // nobody else.  Machines are ordinary v2 principals: same grant/revoke
    // shape, same satisfies_role check, distinct kind.
    #[test]
    fun test_grant_and_revoke_read_machine() {
        let mut sc = ts::begin(ADMIN);
        let dao_id = make_dao(&mut sc, ADMIN, vector[ADMIN]);

        ts::next_tx(&mut sc, ADMIN);
        let dao = ts::take_shared_by_id<DAO>(&sc, dao_id);
        let mut allowlist = keyspace::test_create(b"Vault", sc.ctx());

        keyspace::grant_v2(
            &mut allowlist,
            keyspace::role_read(),
            acl::machine_v2(USER1),
            &dao,
            sc.ctx(),
        );
        assert!(keyspace::has_role(&allowlist, keyspace::role_read(), &dao, USER1), 0);
        assert!(!keyspace::has_role(&allowlist, keyspace::role_read(), &dao, USER2), 1);
        assert!(keyspace::principals_v2(&allowlist, keyspace::role_read()).length() == 1, 2);

        keyspace::revoke_v2(
            &mut allowlist,
            keyspace::role_read(),
            acl::machine_v2(USER1),
            &dao,
            sc.ctx(),
        );
        assert!(!keyspace::has_role(&allowlist, keyspace::role_read(), &dao, USER1), 3);
        assert!(keyspace::principals_v2(&allowlist, keyspace::role_read()).is_empty(), 4);

        keyspace::test_destroy(allowlist);
        ts::return_shared(dao);
        sc.end();
    }

    // player_v2 and ou_v2 authorize identically to their v1 counterparts —
    // the v2 store is a full replacement, not a machine-only side channel.
    #[test]
    fun test_v2_player_and_ou_principals() {
        let mut sc = ts::begin(ADMIN);
        let dao_id = make_dao(&mut sc, ADMIN, vector[ADMIN, USER2]);

        ts::next_tx(&mut sc, ADMIN);
        let dao = ts::take_shared_by_id<DAO>(&sc, dao_id);
        let mut allowlist = keyspace::test_create(b"Vault", sc.ctx());

        keyspace::grant_v2(
            &mut allowlist,
            keyspace::role_write(),
            acl::player_v2(USER1),
            &dao,
            sc.ctx(),
        );
        assert!(keyspace::has_role(&allowlist, keyspace::role_write(), &dao, USER1), 0);

        // An ou_v2 principal admits any governance member of that DAO.
        keyspace::grant_v2(
            &mut allowlist,
            keyspace::role_read(),
            acl::ou_v2(dao_id),
            &dao,
            sc.ctx(),
        );
        assert!(keyspace::has_role(&allowlist, keyspace::role_read(), &dao, USER2), 1);

        keyspace::test_destroy(allowlist);
        ts::return_shared(dao);
        sc.end();
    }

    // An unknown kind authorizes nobody — satisfies_v2 fails closed, so a
    // principal written by a future upgrade can never grant access here.
    #[test]
    fun test_unknown_v2_kind_grants_nothing() {
        let mut sc = ts::begin(ADMIN);
        let dao_id = make_dao(&mut sc, ADMIN, vector[ADMIN]);

        ts::next_tx(&mut sc, ADMIN);
        let dao = ts::take_shared_by_id<DAO>(&sc, dao_id);
        let mut allowlist = keyspace::test_create(b"Vault", sc.ctx());

        keyspace::grant_v2(
            &mut allowlist,
            keyspace::role_write(),
            acl::principal_v2(200, USER1, vector[]),
            &dao,
            sc.ctx(),
        );
        assert!(!keyspace::has_role(&allowlist, keyspace::role_write(), &dao, USER1), 0);

        keyspace::test_destroy(allowlist);
        ts::return_shared(dao);
        sc.end();
    }

    // A v2 Read grant/revoke bumps the keyspace version — same epoch semantics
    // as a v1 Read change.
    #[test]
    fun test_v2_read_changes_bump_version() {
        let mut sc = ts::begin(ADMIN);
        let dao_id = make_dao(&mut sc, ADMIN, vector[ADMIN]);

        ts::next_tx(&mut sc, ADMIN);
        let dao = ts::take_shared_by_id<DAO>(&sc, dao_id);
        let mut allowlist = keyspace::test_create(b"Vault", sc.ctx());
        let v0 = keyspace::version(&allowlist);

        keyspace::grant_v2(
            &mut allowlist,
            keyspace::role_read(),
            acl::machine_v2(USER1),
            &dao,
            sc.ctx(),
        );
        assert!(keyspace::version(&allowlist) == v0 + 1, 0);

        keyspace::revoke_v2(
            &mut allowlist,
            keyspace::role_read(),
            acl::machine_v2(USER1),
            &dao,
            sc.ctx(),
        );
        assert!(keyspace::version(&allowlist) == v0 + 2, 1);

        keyspace::test_destroy(allowlist);
        ts::return_shared(dao);
        sc.end();
    }

    // Kind is part of identity: machine_v2(A) and player_v2(A) are different
    // principals, so revoking one leaves the other's access intact.
    #[test]
    fun test_v2_kinds_are_distinct_identities() {
        let mut sc = ts::begin(ADMIN);
        let dao_id = make_dao(&mut sc, ADMIN, vector[ADMIN]);

        ts::next_tx(&mut sc, ADMIN);
        let dao = ts::take_shared_by_id<DAO>(&sc, dao_id);
        let mut allowlist = keyspace::test_create(b"Vault", sc.ctx());

        keyspace::grant_v2(
            &mut allowlist,
            keyspace::role_read(),
            acl::player_v2(USER1),
            &dao,
            sc.ctx(),
        );
        // Same address, different kind — not a duplicate grant.
        keyspace::grant_v2(
            &mut allowlist,
            keyspace::role_read(),
            acl::machine_v2(USER1),
            &dao,
            sc.ctx(),
        );
        assert!(keyspace::principals_v2(&allowlist, keyspace::role_read()).length() == 2, 0);

        keyspace::revoke_v2(
            &mut allowlist,
            keyspace::role_read(),
            acl::machine_v2(USER1),
            &dao,
            sc.ctx(),
        );
        // The player_v2 grant still satisfies Read for USER1.
        assert!(keyspace::has_role(&allowlist, keyspace::role_read(), &dao, USER1), 1);

        keyspace::test_destroy(allowlist);
        ts::return_shared(dao);
        sc.end();
    }

    // A machine grant is address-scoped: a DAO board member who is not the
    // machine's address gains nothing from it.
    #[test]
    fun test_machine_grant_does_not_leak_to_board() {
        let mut sc = ts::begin(ADMIN);
        let dao_id = make_dao(&mut sc, ADMIN, vector[ADMIN, USER2]);

        ts::next_tx(&mut sc, ADMIN);
        let dao = ts::take_shared_by_id<DAO>(&sc, dao_id);
        let mut allowlist = keyspace::test_create(b"Vault", sc.ctx());

        keyspace::grant_v2(
            &mut allowlist,
            keyspace::role_read(),
            acl::machine_v2(USER1),
            &dao,
            sc.ctx(),
        );
        // USER2 is on the DAO board but is not the machine address.
        assert!(!keyspace::has_role(&allowlist, keyspace::role_read(), &dao, USER2), 0);

        keyspace::test_destroy(allowlist);
        ts::return_shared(dao);
        sc.end();
    }

    // Role invariants span both stores: with the Grant role held only in v2,
    // the last v1 Grant principal can be revoked (this is what makes migrating
    // a role off the frozen v1 store possible).
    #[test]
    fun test_v2_grant_covers_last_v1_grantor() {
        let mut sc = ts::begin(ADMIN);
        let dao_id = make_dao(&mut sc, ADMIN, vector[ADMIN]);

        ts::next_tx(&mut sc, ADMIN);
        let dao = ts::take_shared_by_id<DAO>(&sc, dao_id);
        let mut allowlist = keyspace::test_create(b"Vault", sc.ctx());

        keyspace::grant_v2(
            &mut allowlist,
            keyspace::role_grant(),
            acl::player_v2(ADMIN),
            &dao,
            sc.ctx(),
        );
        // ADMIN is the only v1 Grant principal, but the v2 grant covers it.
        keyspace::revoke(
            &mut allowlist,
            keyspace::role_grant(),
            acl::player(ADMIN),
            &dao,
            sc.ctx(),
        );
        assert!(keyspace::has_role(&allowlist, keyspace::role_grant(), &dao, ADMIN), 0);
        assert!(keyspace::role_count(&allowlist, keyspace::role_grant()) == 1, 1);

        keyspace::test_destroy(allowlist);
        ts::return_shared(dao);
        sc.end();
    }

    // Granting the same v2 principal the same role twice must abort.
    #[test]
    #[expected_failure]
    fun test_duplicate_v2_grant_aborts() {
        let mut sc = ts::begin(ADMIN);
        let dao_id = make_dao(&mut sc, ADMIN, vector[ADMIN]);

        ts::next_tx(&mut sc, ADMIN);
        let dao = ts::take_shared_by_id<DAO>(&sc, dao_id);
        let mut allowlist = keyspace::test_create(b"Vault", sc.ctx());

        keyspace::grant_v2(
            &mut allowlist,
            keyspace::role_read(),
            acl::machine_v2(USER1),
            &dao,
            sc.ctx(),
        );
        keyspace::grant_v2(
            &mut allowlist,
            keyspace::role_read(),
            acl::machine_v2(USER1),
            &dao,
            sc.ctx(),
        ); // abort

        keyspace::test_destroy(allowlist);
        ts::return_shared(dao);
        sc.end();
    }

    // Revoking a v2 principal that was never granted must abort (ENotGranted).
    #[test]
    #[expected_failure]
    fun test_revoke_absent_v2_aborts() {
        let mut sc = ts::begin(ADMIN);
        let dao_id = make_dao(&mut sc, ADMIN, vector[ADMIN]);

        ts::next_tx(&mut sc, ADMIN);
        let dao = ts::take_shared_by_id<DAO>(&sc, dao_id);
        let mut allowlist = keyspace::test_create(b"Vault", sc.ctx());

        keyspace::revoke_v2(
            &mut allowlist,
            keyspace::role_read(),
            acl::machine_v2(USER1),
            &dao,
            sc.ctx(),
        ); // abort

        keyspace::test_destroy(allowlist);
        ts::return_shared(dao);
        sc.end();
    }

    // Caller without Grant role cannot grant a v2 principal (ENotAllowed).
    #[test]
    #[expected_failure]
    fun test_unauthorized_v2_grant_aborts() {
        let mut sc = ts::begin(ADMIN);
        let dao_id = make_dao(&mut sc, ADMIN, vector[ADMIN]);

        ts::next_tx(&mut sc, ADMIN);
        let dao = ts::take_shared_by_id<DAO>(&sc, dao_id);
        let mut allowlist = keyspace::test_create(b"Vault", sc.ctx());
        ts::return_shared(dao);
        sc.end();

        // USER2 has no Grant role — should abort
        let mut sc = ts::begin(USER2);
        let dao = ts::take_shared_by_id<DAO>(&sc, dao_id);
        keyspace::grant_v2(
            &mut allowlist,
            keyspace::role_read(),
            acl::machine_v2(USER1),
            &dao,
            sc.ctx(),
        ); // abort

        keyspace::test_destroy(allowlist);
        ts::return_shared(dao);
        sc.end();
    }
}
