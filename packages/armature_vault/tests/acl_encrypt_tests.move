#[test_only]
module armature_vault::acl_encrypt_tests {
    use armature_vault::acl_encrypt;
    use sui::test_scenario as ts;

    const ADMIN: address = @0xA;
    const USER1: address = @0xB;
    const USER2: address = @0xC;

    // Owner is implicitly allowed; non-members are not.
    #[test]
    fun test_create_and_default_access() {
        let mut sc = ts::begin(ADMIN);
        {
            let ctx = sc.ctx();
            let (allowlist, cap) = acl_encrypt::test_create(b"My Vault", ctx);
            assert!(acl_encrypt::owner(&allowlist) == ADMIN, 0);
            assert!(acl_encrypt::is_allowed(&allowlist, ADMIN), 1);
            assert!(!acl_encrypt::is_allowed(&allowlist, USER1), 2);
            acl_encrypt::test_destroy(allowlist);
            acl_encrypt::test_destroy_cap(cap);
        };
        sc.end();
    }

    // Add a grantee → access; remove → no access.
    #[test]
    fun test_grant_and_revoke() {
        let mut sc = ts::begin(ADMIN);
        {
            let ctx = sc.ctx();
            let (mut allowlist, cap) = acl_encrypt::test_create(b"Vault", ctx);

            acl_encrypt::add(&mut allowlist, &cap, USER1, ctx);
            assert!(acl_encrypt::is_allowed(&allowlist, USER1), 0);
            assert!(!acl_encrypt::is_allowed(&allowlist, USER2), 1);

            acl_encrypt::remove(&mut allowlist, &cap, USER1, ctx);
            assert!(!acl_encrypt::is_allowed(&allowlist, USER1), 2);

            acl_encrypt::test_destroy(allowlist);
            acl_encrypt::test_destroy_cap(cap);
        };
        sc.end();
    }

    // Adding the same address twice must abort (EAlreadyInList = 2).
    #[test]
    #[expected_failure]
    fun test_duplicate_add_aborts() {
        let mut sc = ts::begin(ADMIN);
        {
            let ctx = sc.ctx();
            let (mut allowlist, cap) = acl_encrypt::test_create(b"Vault", ctx);
            acl_encrypt::add(&mut allowlist, &cap, USER1, ctx);
            acl_encrypt::add(&mut allowlist, &cap, USER1, ctx); // should abort
            acl_encrypt::test_destroy(allowlist);
            acl_encrypt::test_destroy_cap(cap);
        };
        sc.end();
    }

    // Removing an address that was never added must abort (ENotInList = 3).
    #[test]
    #[expected_failure]
    fun test_remove_absent_aborts() {
        let mut sc = ts::begin(ADMIN);
        {
            let ctx = sc.ctx();
            let (mut allowlist, cap) = acl_encrypt::test_create(b"Vault", ctx);
            acl_encrypt::remove(&mut allowlist, &cap, USER1, ctx); // should abort
            acl_encrypt::test_destroy(allowlist);
            acl_encrypt::test_destroy_cap(cap);
        };
        sc.end();
    }

    // Using a cap for a different allowlist must abort (EWrongCap = 0).
    #[test]
    #[expected_failure]
    fun test_wrong_cap_aborts() {
        let mut sc = ts::begin(ADMIN);
        {
            let ctx = sc.ctx();
            let (mut al1, cap1) = acl_encrypt::test_create(b"A", ctx);
            let (al2, cap2) = acl_encrypt::test_create(b"B", ctx);
            // cap2 belongs to al2 — using it on al1 must abort
            acl_encrypt::add(&mut al1, &cap2, USER1, ctx);
            acl_encrypt::test_destroy(al1);
            acl_encrypt::test_destroy(al2);
            acl_encrypt::test_destroy_cap(cap1);
            acl_encrypt::test_destroy_cap(cap2);
        };
        sc.end();
    }

    // Owner plus two grantees; one removed. Verify final membership.
    #[test]
    fun test_multi_member_lifecycle() {
        let mut sc = ts::begin(ADMIN);
        {
            let ctx = sc.ctx();
            let (mut allowlist, cap) = acl_encrypt::test_create(b"Team Vault", ctx);

            acl_encrypt::add(&mut allowlist, &cap, USER1, ctx);
            acl_encrypt::add(&mut allowlist, &cap, USER2, ctx);
            assert!(acl_encrypt::is_allowed(&allowlist, USER1), 0);
            assert!(acl_encrypt::is_allowed(&allowlist, USER2), 1);

            acl_encrypt::remove(&mut allowlist, &cap, USER1, ctx);
            assert!(!acl_encrypt::is_allowed(&allowlist, USER1), 2);
            assert!(acl_encrypt::is_allowed(&allowlist, USER2), 3);
            // Owner always allowed
            assert!(acl_encrypt::is_allowed(&allowlist, ADMIN), 4);

            acl_encrypt::test_destroy(allowlist);
            acl_encrypt::test_destroy_cap(cap);
        };
        sc.end();
    }

    // Publishing an entry stores its ID in the allowlist entries vector.
    #[test]
    fun test_publish_entry_tracks_in_allowlist() {
        let mut sc = ts::begin(ADMIN);
        {
            let ctx = sc.ctx();
            let (mut allowlist, cap) = acl_encrypt::test_create(b"Vault", ctx);

            let entry = acl_encrypt::test_publish_entry(
                &mut allowlist,
                b"QmFakeCid1",
                b"first entry",
                ctx,
            );
            assert!(acl_encrypt::entry_epoch(&entry) == 0, 0);
            assert!(acl_encrypt::version(&allowlist) == 0, 1);

            acl_encrypt::test_destroy_entry(entry);
            acl_encrypt::test_destroy(allowlist);
            acl_encrypt::test_destroy_cap(cap);
        };
        sc.end();
    }

    // Any member can edit an entry (collaborative write).
    #[test]
    fun test_member_can_edit_entry() {
        let mut sc = ts::begin(ADMIN);
        let (mut allowlist, cap) = {
            let ctx = sc.ctx();
            let (al, cap) = acl_encrypt::test_create(b"Vault", ctx);
            (al, cap)
        };

        // Admin publishes an entry
        let mut entry = {
            let ctx = sc.ctx();
            acl_encrypt::test_publish_entry(&mut allowlist, b"QmOriginal", b"desc", ctx)
        };

        // Add USER1 to the allowlist
        {
            let ctx = sc.ctx();
            acl_encrypt::add(&mut allowlist, &cap, USER1, ctx);
        };

        sc.end();

        // USER1 edits the entry
        let mut sc = ts::begin(USER1);
        {
            let ctx = sc.ctx();
            acl_encrypt::edit_entry(&allowlist, &mut entry, b"QmUpdatedByMember", ctx);
            assert!(*acl_encrypt::entry_location(&entry) == b"QmUpdatedByMember".to_string(), 0);
        };

        acl_encrypt::test_destroy_entry(entry);
        acl_encrypt::test_destroy(allowlist);
        acl_encrypt::test_destroy_cap(cap);
        sc.end();
    }

    // Non-member cannot edit an entry.
    #[test]
    #[expected_failure]
    fun test_non_member_cannot_edit_entry() {
        let mut sc = ts::begin(ADMIN);
        let (mut allowlist, cap) = {
            let ctx = sc.ctx();
            acl_encrypt::test_create(b"Vault", ctx)
        };
        let mut entry = {
            let ctx = sc.ctx();
            acl_encrypt::test_publish_entry(&mut allowlist, b"QmCid", b"desc", ctx)
        };
        sc.end();

        // USER2 (not a member) tries to edit
        let mut sc = ts::begin(USER2);
        {
            let ctx = sc.ctx();
            acl_encrypt::edit_entry(&allowlist, &mut entry, b"QmHacked", ctx);
        };

        acl_encrypt::test_destroy_entry(entry);
        acl_encrypt::test_destroy(allowlist);
        acl_encrypt::test_destroy_cap(cap);
        sc.end();
    }

    // update_entry requires epoch mismatch (key rotation scenario).
    // Both add and remove bump version, so either triggers re-encryption.
    #[test]
    fun test_update_entry_after_version_change() {
        let mut sc = ts::begin(ADMIN);
        {
            let ctx = sc.ctx();
            let (mut allowlist, cap) = acl_encrypt::test_create(b"Vault", ctx);

            let mut entry = acl_encrypt::test_publish_entry(
                &mut allowlist,
                b"QmOld",
                b"desc",
                ctx,
            );
            assert!(acl_encrypt::entry_epoch(&entry) == 0, 0);

            // Bump version by adding a member
            acl_encrypt::add(&mut allowlist, &cap, USER1, ctx);
            assert!(acl_encrypt::version(&allowlist) == 1, 1);

            // Now update_entry should succeed (epoch mismatch)
            acl_encrypt::update_entry(&allowlist, &mut entry, b"QmRotated", ctx);
            assert!(*acl_encrypt::entry_location(&entry) == b"QmRotated".to_string(), 2);
            assert!(acl_encrypt::entry_epoch(&entry) == 1, 3);

            acl_encrypt::test_destroy_entry(entry);
            acl_encrypt::test_destroy(allowlist);
            acl_encrypt::test_destroy_cap(cap);
        };
        sc.end();
    }

    // update_entry aborts if epoch already matches (EAlreadyCurrentEpoch).
    #[test]
    #[expected_failure]
    fun test_update_entry_same_epoch_aborts() {
        let mut sc = ts::begin(ADMIN);
        {
            let ctx = sc.ctx();
            let (mut allowlist, cap) = acl_encrypt::test_create(b"Vault", ctx);

            let mut entry = acl_encrypt::test_publish_entry(
                &mut allowlist,
                b"QmCid",
                b"desc",
                ctx,
            );
            // epoch == version == 0, so this must abort
            acl_encrypt::update_entry(&allowlist, &mut entry, b"QmNew", ctx);

            acl_encrypt::test_destroy_entry(entry);
            acl_encrypt::test_destroy(allowlist);
            acl_encrypt::test_destroy_cap(cap);
        };
        sc.end();
    }
}
