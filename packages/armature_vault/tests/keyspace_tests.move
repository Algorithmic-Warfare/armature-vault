#[test_only]
module armature_vault::keyspace_tests {
    use armature::{dao::{Self, DAO}, governance};
    use armature_vault::{acl as acl, acl_v2 as acl_v2, keyspace};
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
            acl_v2::machine(USER1),
            &dao,
            sc.ctx(),
        );
        assert!(keyspace::has_role(&allowlist, keyspace::role_read(), &dao, USER1), 0);
        assert!(!keyspace::has_role(&allowlist, keyspace::role_read(), &dao, USER2), 1);
        assert!(keyspace::principals_v2(&allowlist, keyspace::role_read()).length() == 1, 2);

        keyspace::revoke_v2(
            &mut allowlist,
            keyspace::role_read(),
            acl_v2::machine(USER1),
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
            acl_v2::player(USER1),
            &dao,
            sc.ctx(),
        );
        assert!(keyspace::has_role(&allowlist, keyspace::role_write(), &dao, USER1), 0);

        // An ou_v2 principal admits any governance member of that DAO.
        keyspace::grant_v2(
            &mut allowlist,
            keyspace::role_read(),
            acl_v2::ou(dao_id),
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
            acl_v2::principal(200, USER1, vector[]),
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
            acl_v2::machine(USER1),
            &dao,
            sc.ctx(),
        );
        assert!(keyspace::version(&allowlist) == v0 + 1, 0);

        keyspace::revoke_v2(
            &mut allowlist,
            keyspace::role_read(),
            acl_v2::machine(USER1),
            &dao,
            sc.ctx(),
        );
        assert!(keyspace::version(&allowlist) == v0 + 2, 1);

        keyspace::test_destroy(allowlist);
        ts::return_shared(dao);
        sc.end();
    }

    // player_v2(A) and machine_v2(A) authorize the same sender, so the store
    // holds them as ONE identity: the second grant is refused rather than
    // stacking a differently-labelled twin that a revoke of the first would
    // leave standing.
    #[test]
    #[expected_failure]
    fun test_v2_address_kinds_are_one_identity() {
        let mut sc = ts::begin(ADMIN);
        let dao_id = make_dao(&mut sc, ADMIN, vector[ADMIN]);

        ts::next_tx(&mut sc, ADMIN);
        let dao = ts::take_shared_by_id<DAO>(&sc, dao_id);
        let mut allowlist = keyspace::test_create(b"Vault", sc.ctx());

        keyspace::grant_v2(
            &mut allowlist,
            keyspace::role_read(),
            acl_v2::player(USER1),
            &dao,
            sc.ctx(),
        );
        // Same address, different kind — same authority, so EAlreadyGranted.
        keyspace::grant_v2(
            &mut allowlist,
            keyspace::role_read(),
            acl_v2::machine(USER1),
            &dao,
            sc.ctx(),
        );

        keyspace::test_destroy(allowlist);
        ts::return_shared(dao);
        sc.end();
    }

    // A machine principal planted in the v2 store does not survive the ordinary
    // v1 revoke of the same address. This is the backdoor the audit found: the
    // v2 store is a dynamic field and never appears in the keyspace object's
    // `acl` field, so an admin cleaning up after a departing holder sees nothing
    // left behind while the holder keeps the role.
    #[test]
    fun test_v1_revoke_clears_machine_twin() {
        let mut sc = ts::begin(ADMIN);
        let dao_id = make_dao(&mut sc, ADMIN, vector[ADMIN]);

        ts::next_tx(&mut sc, ADMIN);
        let dao = ts::take_shared_by_id<DAO>(&sc, dao_id);
        let mut allowlist = keyspace::test_create(b"Vault", sc.ctx());

        keyspace::grant_v2(
            &mut allowlist,
            keyspace::role_read(),
            acl_v2::machine(USER1),
            &dao,
            sc.ctx(),
        );
        assert!(keyspace::has_role(&allowlist, keyspace::role_read(), &dao, USER1), 0);

        // Revoke names the *player* kind — the only one an admin reading the
        // object would know about.
        keyspace::revoke(
            &mut allowlist,
            keyspace::role_read(),
            acl::player(USER1),
            &dao,
            sc.ctx(),
        );
        assert!(!keyspace::has_role(&allowlist, keyspace::role_read(), &dao, USER1), 1);
        assert!(keyspace::principals_v2(&allowlist, keyspace::role_read()).is_empty(), 2);

        keyspace::test_destroy(allowlist);
        ts::return_shared(dao);
        sc.end();
    }

    // The reverse direction: revoking machine(A) clears a v1 Player { A }, since
    // the two admit the same sender.
    #[test]
    fun test_v2_machine_revoke_clears_v1_player() {
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

        keyspace::revoke_v2(
            &mut allowlist,
            keyspace::role_read(),
            acl_v2::machine(USER1),
            &dao,
            sc.ctx(),
        );
        assert!(!keyspace::has_role(&allowlist, keyspace::role_read(), &dao, USER1), 1);

        keyspace::test_destroy(allowlist);
        ts::return_shared(dao);
        sc.end();
    }

    // Grant is administration: it cannot be handed to a machine key (or any
    // other v2 kind) through the v2 store. Losing that key would leave the
    // keyspace unadministrable and Read permanently unrevokable.
    #[test]
    #[expected_failure]
    fun test_grant_v2_refuses_the_grant_role() {
        let mut sc = ts::begin(ADMIN);
        let dao_id = make_dao(&mut sc, ADMIN, vector[ADMIN]);

        ts::next_tx(&mut sc, ADMIN);
        let dao = ts::take_shared_by_id<DAO>(&sc, dao_id);
        let mut allowlist = keyspace::test_create(b"Vault", sc.ctx());

        keyspace::grant_v2(
            &mut allowlist,
            keyspace::role_grant(),
            acl_v2::machine(USER1),
            &dao,
            sc.ctx(),
        );

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
            acl_v2::machine(USER1),
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
    /// `migrate_acl_to_v2` is how a role moves off the frozen v1 store: access is
    /// preserved, the identity ends up in exactly one store, and `role_count`
    /// spans both so the last-grantor guard still sees it.
    ///
    /// This previously granted `acl_v2::player(ADMIN)` alongside the existing v1
    /// `acl::player(ADMIN)` and then revoked the v1 copy. That is no longer
    /// allowed: one identity in both stores is what let a revoke report success
    /// while leaving the sender authorized, so `grant_v2` now rejects it
    /// (`test_grant_v2_rejects_identity_already_in_v1`).
    fun test_migration_moves_last_grantor_to_v2() {
        let mut sc = ts::begin(ADMIN);
        let dao_id = make_dao(&mut sc, ADMIN, vector[ADMIN]);

        ts::next_tx(&mut sc, ADMIN);
        let dao = ts::take_shared_by_id<DAO>(&sc, dao_id);
        let mut allowlist = keyspace::test_create(b"Vault", sc.ctx());

        keyspace::migrate_acl_to_v2(&mut allowlist, &dao, sc.ctx());

        // Access is unchanged, and Grant now lives solely in the v2 store.
        assert!(keyspace::has_role(&allowlist, keyspace::role_grant(), &dao, ADMIN), 0);
        assert!(keyspace::role_count(&allowlist, keyspace::role_grant()) == 1, 1);
        assert!(keyspace::principals(&allowlist, keyspace::role_grant()).is_empty(), 2);
        assert!(keyspace::principals_v2(&allowlist, keyspace::role_grant()).length() == 1, 3);

        keyspace::test_destroy(allowlist);
        ts::return_shared(dao);
        sc.end();
    }

    // ── Regression tests for the pre-publish security review ──────────────────

    #[test]
    #[expected_failure]
    /// One identity must never be grantable into both stores: the union read
    /// would authorize it twice, and a single-store revoke would then look
    /// successful while leaving access intact.
    fun test_grant_v2_rejects_identity_already_in_v1() {
        let mut sc = ts::begin(ADMIN);
        let dao_id = make_dao(&mut sc, ADMIN, vector[ADMIN]);

        ts::next_tx(&mut sc, ADMIN);
        let dao = ts::take_shared_by_id<DAO>(&sc, dao_id);
        let mut allowlist = keyspace::test_create(b"Vault", sc.ctx());

        // ADMIN already holds Grant in v1 from test_create.
        keyspace::grant_v2(
            &mut allowlist,
            keyspace::role_grant(),
            acl_v2::player(ADMIN),
            &dao,
            sc.ctx(),
        );

        keyspace::test_destroy(allowlist);
        ts::return_shared(dao);
        sc.end();
    }

    #[test]
    #[expected_failure]
    /// The same rule in the other direction.
    fun test_grant_rejects_identity_already_in_v2() {
        let mut sc = ts::begin(ADMIN);
        let dao_id = make_dao(&mut sc, ADMIN, vector[ADMIN]);

        ts::next_tx(&mut sc, ADMIN);
        let dao = ts::take_shared_by_id<DAO>(&sc, dao_id);
        let mut allowlist = keyspace::test_create(b"Vault", sc.ctx());

        keyspace::grant_v2(
            &mut allowlist,
            keyspace::role_read(),
            acl_v2::player(USER1),
            &dao,
            sc.ctx(),
        );
        keyspace::grant(
            &mut allowlist,
            keyspace::role_read(),
            acl::player(USER1),
            &dao,
            sc.ctx(),
        );

        keyspace::test_destroy(allowlist);
        ts::return_shared(dao);
        sc.end();
    }

    #[test]
    /// A v1-API revoke must still remove a principal that migration relocated to
    /// the v2 store. Before the fix this removed nothing while `AccessRevoked`
    /// was emitted and `version` bumped — the caller believed access was gone.
    fun test_v1_revoke_reaches_migrated_principal() {
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
        keyspace::migrate_acl_to_v2(&mut allowlist, &dao, sc.ctx());
        assert!(keyspace::has_role(&allowlist, keyspace::role_read(), &dao, USER1), 0);

        // Revoke through the v1 API even though the principal now lives in v2.
        keyspace::revoke(
            &mut allowlist,
            keyspace::role_read(),
            acl::player(USER1),
            &dao,
            sc.ctx(),
        );
        assert!(!keyspace::has_role(&allowlist, keyspace::role_read(), &dao, USER1), 1);

        keyspace::test_destroy(allowlist);
        ts::return_shared(dao);
        sc.end();
    }

    #[test]
    #[expected_failure]
    /// The brick: grant a principal nobody can satisfy (an unknown kind), then
    /// revoke the only real grantor. `role_count` stays at 1 so `ELastGrantor`
    /// passes, but nothing could ever administer the keyspace again — including
    /// changing `Read`, so `seal_approve` access could never be revoked.
    fun test_cannot_revoke_self_behind_unsatisfiable_grantor() {
        let mut sc = ts::begin(ADMIN);
        let dao_id = make_dao(&mut sc, ADMIN, vector[ADMIN]);

        ts::next_tx(&mut sc, ADMIN);
        let dao = ts::take_shared_by_id<DAO>(&sc, dao_id);
        let mut allowlist = keyspace::test_create(b"Vault", sc.ctx());

        // Kind 200 is not evaluatable, so `satisfies` denies it for every sender.
        keyspace::grant_v2(
            &mut allowlist,
            keyspace::role_grant(),
            acl_v2::principal(200, @0x0, vector[]),
            &dao,
            sc.ctx(),
        );
        keyspace::revoke(
            &mut allowlist,
            keyspace::role_grant(),
            acl::player(ADMIN),
            &dao,
            sc.ctx(),
        );

        keyspace::test_destroy(allowlist);
        ts::return_shared(dao);
        sc.end();
    }

    #[test]
    /// A grantor can still hand off and be removed — by the successor, who is
    /// demonstrably satisfiable. This is what `EWouldLockSelf` leaves open.
    fun test_successor_can_revoke_previous_grantor() {
        let mut sc = ts::begin(ADMIN);
        let dao_id = make_dao(&mut sc, ADMIN, vector[ADMIN, USER1]);

        ts::next_tx(&mut sc, ADMIN);
        let dao = ts::take_shared_by_id<DAO>(&sc, dao_id);
        let mut allowlist = keyspace::test_create(b"Vault", sc.ctx());

        keyspace::grant(
            &mut allowlist,
            keyspace::role_grant(),
            acl::player(USER1),
            &dao,
            sc.ctx(),
        );

        // USER1 (the successor) removes ADMIN — USER1 still satisfies Grant.
        ts::next_tx(&mut sc, USER1);
        keyspace::revoke(
            &mut allowlist,
            keyspace::role_grant(),
            acl::player(ADMIN),
            &dao,
            sc.ctx(),
        );
        assert!(keyspace::has_role(&allowlist, keyspace::role_grant(), &dao, USER1), 0);
        assert!(!keyspace::has_role(&allowlist, keyspace::role_grant(), &dao, ADMIN), 1);

        keyspace::test_destroy(allowlist);
        ts::return_shared(dao);
        sc.end();
    }

    // ── Migration ─────────────────────────────────────────────────────────────

    // Migration lifts v1 principals into the v2 store without changing who can
    // read, and without bumping version (which would strand every entry).
    #[test]
    fun test_migrate_acl_to_v2_preserves_access() {
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
        let version_before = keyspace::version(&allowlist);
        assert!(keyspace::principals_v2(&allowlist, keyspace::role_read()).is_empty(), 0);

        keyspace::migrate_acl_to_v2(&mut allowlist, &dao, sc.ctx());

        // Same access, now sourced from the v2 store.
        assert!(keyspace::has_role(&allowlist, keyspace::role_read(), &dao, USER1), 1);
        assert!(keyspace::has_role(&allowlist, keyspace::role_grant(), &dao, ADMIN), 2);
        assert!(keyspace::principals_v2(&allowlist, keyspace::role_read()).length() == 2, 3);
        // The v1 list is drained, so the count must come from v2 alone.
        assert!(keyspace::role_count(&allowlist, keyspace::role_read()) == 2, 4);
        // Access is unchanged, so entries must not be marked stale.
        assert!(keyspace::version(&allowlist) == version_before, 5);

        keyspace::test_destroy(allowlist);
        ts::return_shared(dao);
        sc.end();
    }

    // Migration is idempotent and does not duplicate principals already in v2.
    #[test]
    fun test_migrate_acl_to_v2_is_idempotent() {
        let mut sc = ts::begin(ADMIN);
        let dao_id = make_dao(&mut sc, ADMIN, vector[ADMIN]);

        ts::next_tx(&mut sc, ADMIN);
        let dao = ts::take_shared_by_id<DAO>(&sc, dao_id);
        let mut allowlist = keyspace::test_create(b"Vault", sc.ctx());

        // ADMIN holds Read in v1 from test_create. A second migration must find
        // the v1 list already drained and change nothing.
        //
        // This used to pre-seed `acl_v2::player(ADMIN)` alongside the v1 entry to
        // exercise migration's dedup branch. The public API no longer allows one
        // identity in both stores (see
        // `test_grant_v2_rejects_identity_already_in_v1`), so that branch is now
        // defensive only and unreachable from here.
        keyspace::migrate_acl_to_v2(&mut allowlist, &dao, sc.ctx());
        let after_first = keyspace::role_count(&allowlist, keyspace::role_read());

        keyspace::migrate_acl_to_v2(&mut allowlist, &dao, sc.ctx());
        assert!(keyspace::role_count(&allowlist, keyspace::role_read()) == after_first, 0);
        assert!(after_first == 1, 1);
        assert!(keyspace::has_role(&allowlist, keyspace::role_read(), &dao, ADMIN), 2);

        keyspace::test_destroy(allowlist);
        ts::return_shared(dao);
        sc.end();
    }

    // Grant/revoke keep working against a fully migrated keyspace.
    #[test]
    fun test_grant_and_revoke_after_migration() {
        let mut sc = ts::begin(ADMIN);
        let dao_id = make_dao(&mut sc, ADMIN, vector[ADMIN]);

        ts::next_tx(&mut sc, ADMIN);
        let dao = ts::take_shared_by_id<DAO>(&sc, dao_id);
        let mut allowlist = keyspace::test_create(b"Vault", sc.ctx());

        keyspace::migrate_acl_to_v2(&mut allowlist, &dao, sc.ctx());
        // ADMIN's Grant role now lives in v2 and must still authorize.
        keyspace::grant_v2(
            &mut allowlist,
            keyspace::role_read(),
            acl_v2::machine(USER1),
            &dao,
            sc.ctx(),
        );
        assert!(keyspace::has_role(&allowlist, keyspace::role_read(), &dao, USER1), 0);

        keyspace::revoke_v2(
            &mut allowlist,
            keyspace::role_read(),
            acl_v2::machine(USER1),
            &dao,
            sc.ctx(),
        );
        assert!(!keyspace::has_role(&allowlist, keyspace::role_read(), &dao, USER1), 1);

        keyspace::test_destroy(allowlist);
        ts::return_shared(dao);
        sc.end();
    }

    // A caller without Grant cannot migrate.
    #[test]
    #[expected_failure]
    fun test_unauthorized_migrate_aborts() {
        let mut sc = ts::begin(ADMIN);
        let dao_id = make_dao(&mut sc, ADMIN, vector[ADMIN]);

        ts::next_tx(&mut sc, ADMIN);
        let dao = ts::take_shared_by_id<DAO>(&sc, dao_id);
        let mut allowlist = keyspace::test_create(b"Vault", sc.ctx());
        ts::return_shared(dao);
        sc.end();

        let mut sc = ts::begin(USER2);
        let dao = ts::take_shared_by_id<DAO>(&sc, dao_id);
        keyspace::migrate_acl_to_v2(&mut allowlist, &dao, sc.ctx()); // abort

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
            acl_v2::machine(USER1),
            &dao,
            sc.ctx(),
        );
        keyspace::grant_v2(
            &mut allowlist,
            keyspace::role_read(),
            acl_v2::machine(USER1),
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
            acl_v2::machine(USER1),
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
            acl_v2::machine(USER1),
            &dao,
            sc.ctx(),
        ); // abort

        keyspace::test_destroy(allowlist);
        ts::return_shared(dao);
        sc.end();
    }
}
