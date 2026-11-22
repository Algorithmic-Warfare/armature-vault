/// ARMATURE-46: a single board member must not be able to take an OU keyspace
/// from its OU. The anchor OU is always on Grant, can't be revoked, and moves
/// only to the successor the anchor OU voted for. Mirrors `anchor_tests` for
/// the receipt vault (ARMATURE-43).
#[test_only]
module armature_vault::keyspace_anchor_tests {
    use armature::{
        ou::{Self, OU},
        governance,
        proposal,
        remove_member::RemoveMember,
        spawn_ou::SpawnOU
    };
    use armature_vault::keyspace::{Self, Keyspace};
    use roles::acl;
    use std::string;
    use sui::test_scenario as ts;

    /// Rogue board member of the anchor OU.
    const ROGUE: address = @0xA1;
    /// Honest board member of the anchor OU.
    const HONEST: address = @0xA2;
    /// Anyone.
    const ANYONE: address = @0x0E;

    fun make_ou(sc: &mut ts::Scenario, creator: address, members: vector<address>): ID {
        ts::next_tx(sc, creator);
        let init = governance::init_board(members);
        ou::create(&init, string::utf8(b"OU"), string::utf8(b"u"), sc.ctx())
    }

    /// OU `a` (ROGUE and HONEST on its board) and an OU keyspace anchored to
    /// it, where `a` also holds Read. Returns `a`.
    fun anchored_keyspace(sc: &mut ts::Scenario): ID {
        let a = make_ou(sc, HONEST, vector[ROGUE, HONEST]);
        ts::next_tx(sc, HONEST);
        let org = ts::take_shared_by_id<OU>(sc, a);
        keyspace::create_keyspace_for_ou(
            b"Org",
            &org,
            &org,
            vector[],
            vector[acl::ou(a)],
            vector[acl::ou(a)],
            sc.ctx(),
        );
        ts::return_shared(org);
        a
    }

    fun remove_board_member(sc: &mut ts::Scenario, ou_id: ID, member: address) {
        ts::next_tx(sc, HONEST);
        let mut org = ts::take_shared_by_id<OU>(sc, ou_id);
        let req = proposal::new_execution_request_for_testing<RemoveMember>(
            ou_id,
            object::id_from_address(@0x9999),
        );
        org.remove_board_member_governance(member, &req);
        proposal::consume_execution_request_for_testing(req);
        ts::return_shared(org);
    }

    fun start_migration(sc: &mut ts::Scenario, ou_id: ID, successor: ID) {
        ts::next_tx(sc, ANYONE);
        let mut org = ts::take_shared_by_id<OU>(sc, ou_id);
        let req = proposal::new_execution_request_for_testing<SpawnOU>(
            ou_id,
            object::id_from_address(@0x9998),
        );
        org.set_migrating(successor, &req);
        proposal::consume_execution_request_for_testing(req);
        ts::return_shared(org);
    }

    /// Creation lists the anchor on Grant and records it.
    #[test]
    fun create_records_the_anchor() {
        let mut sc = ts::begin(HONEST);
        let officers = make_ou(&mut sc, HONEST, vector[HONEST]);
        let members = make_ou(&mut sc, ROGUE, vector[ROGUE, HONEST]);

        // A member of `members` creates a keyspace the officers administer.
        ts::next_tx(&mut sc, ROGUE);
        let org = ts::take_shared_by_id<OU>(&sc, members);
        let anchor = ts::take_shared_by_id<OU>(&sc, officers);
        keyspace::create_keyspace_for_ou(
            b"Org",
            &org,
            &anchor,
            vector[acl::ou(officers)],
            vector[acl::ou(members)],
            vector[],
            sc.ctx(),
        );
        ts::return_shared(anchor);
        ts::return_shared(org);

        let effects = ts::next_tx(&mut sc, HONEST);
        // KeyspaceCreated + AnchorSet + one AccessGranted per seeded principal.
        assert!(ts::num_user_events(&effects) == 4, 0);
        let ks = ts::take_shared<Keyspace>(&sc);
        assert!(keyspace::anchor_ou_id(&ks) == option::some(officers), 1);
        assert!(keyspace::principals(&ks, keyspace::role_grant()) == vector[acl::ou(officers)], 2);
        ts::return_shared(ks);
        sc.end();
    }

    /// A personal keyspace has no anchor.
    #[test]
    fun personal_keyspace_has_no_anchor() {
        let mut sc = ts::begin(HONEST);
        keyspace::create_keyspace(b"Mine", sc.ctx());
        ts::next_tx(&mut sc, HONEST);
        let ks = ts::take_shared<Keyspace>(&sc);
        assert!(keyspace::anchor_ou_id(&ks).is_none(), 0);
        ts::return_shared(ks);
        sc.end();
    }

    // === Takeover paths ===

    /// Path 1: grant your own Player Grant, then revoke the board's OU.
    #[test]
    #[expected_failure(abort_code = keyspace::EAnchorNotRevocable)]
    fun takeover_via_personal_grant_aborts() {
        let mut sc = ts::begin(HONEST);
        let a = anchored_keyspace(&mut sc);

        ts::next_tx(&mut sc, ROGUE);
        let mut ks = ts::take_shared<Keyspace>(&sc);
        let a_ou = ts::take_shared_by_id<OU>(&sc, a);
        keyspace::grant(&mut ks, keyspace::role_grant(), acl::player(ROGUE), &a_ou, sc.ctx());
        keyspace::revoke(&mut ks, keyspace::role_grant(), acl::ou(a), &a_ou, sc.ctx());
        abort
    }

    /// Path 2: list an OU you alone control on Grant, then revoke the board's
    /// OU acting as your own.
    #[test]
    #[expected_failure(abort_code = keyspace::EAnchorNotRevocable)]
    fun takeover_via_throwaway_ou_aborts() {
        let mut sc = ts::begin(HONEST);
        let a = anchored_keyspace(&mut sc);
        let b = make_ou(&mut sc, ROGUE, vector[ROGUE]);

        ts::next_tx(&mut sc, ROGUE);
        let mut ks = ts::take_shared<Keyspace>(&sc);
        let a_ou = ts::take_shared_by_id<OU>(&sc, a);
        let b_ou = ts::take_shared_by_id<OU>(&sc, b);
        keyspace::grant(&mut ks, keyspace::role_grant(), acl::ou(b), &a_ou, sc.ctx());
        keyspace::revoke(&mut ks, keyspace::role_grant(), acl::ou(a), &b_ou, sc.ctx());
        abort
    }

    /// `multi_revoke` can't drop the anchor's Grant either.
    #[test]
    #[expected_failure(abort_code = keyspace::EAnchorNotRevocable)]
    fun multi_revoke_of_the_anchor_aborts() {
        let mut sc = ts::begin(HONEST);
        let a = anchored_keyspace(&mut sc);

        ts::next_tx(&mut sc, ROGUE);
        let mut ks = ts::take_shared<Keyspace>(&sc);
        let a_ou = ts::take_shared_by_id<OU>(&sc, a);
        keyspace::grant(&mut ks, keyspace::role_read(), acl::player(ROGUE), &a_ou, sc.ctx());
        keyspace::multi_revoke(
            &mut ks,
            vector[keyspace::role_read(), keyspace::role_grant()],
            acl::ou(a),
            &a_ou,
            sc.ctx(),
        );
        abort
    }

    /// Only the anchor's place on Grant is pinned; it can leave Write.
    #[test]
    fun anchor_can_leave_other_roles() {
        let mut sc = ts::begin(HONEST);
        let a = anchored_keyspace(&mut sc);

        ts::next_tx(&mut sc, HONEST);
        let mut ks = ts::take_shared<Keyspace>(&sc);
        let a_ou = ts::take_shared_by_id<OU>(&sc, a);
        keyspace::grant(&mut ks, keyspace::role_write(), acl::player(HONEST), &a_ou, sc.ctx());
        keyspace::revoke(&mut ks, keyspace::role_write(), acl::ou(a), &a_ou, sc.ctx());
        assert!(keyspace::principals(&ks, keyspace::role_write()) == vector[acl::player(HONEST)], 0);
        assert!(keyspace::principals(&ks, keyspace::role_grant()) == vector[acl::ou(a)], 1);
        ts::return_shared(a_ou);
        ts::return_shared(ks);
        sc.end();
    }

    // === Recovery ===

    /// A rogue member grants themselves Grant and Read, then is removed. The
    /// board revokes both through the anchor, and the rogue can no longer pass
    /// the Seal decryption gate.
    #[test]
    #[expected_failure(abort_code = keyspace::ENotAllowed)]
    fun board_recovers_and_rogue_loses_decryption() {
        let mut sc = ts::begin(HONEST);
        let a = anchored_keyspace(&mut sc);

        ts::next_tx(&mut sc, ROGUE);
        {
            let mut ks = ts::take_shared<Keyspace>(&sc);
            let a_ou = ts::take_shared_by_id<OU>(&sc, a);
            keyspace::multi_grant(
                &mut ks,
                vector[keyspace::role_grant(), keyspace::role_read()],
                acl::player(ROGUE),
                &a_ou,
                sc.ctx(),
            );
            ts::return_shared(a_ou);
            ts::return_shared(ks);
        };
        remove_board_member(&mut sc, a, ROGUE);

        ts::next_tx(&mut sc, HONEST);
        {
            let mut ks = ts::take_shared<Keyspace>(&sc);
            let a_ou = ts::take_shared_by_id<OU>(&sc, a);
            keyspace::multi_revoke(
                &mut ks,
                vector[keyspace::role_grant(), keyspace::role_read()],
                acl::player(ROGUE),
                &a_ou,
                sc.ctx(),
            );
            assert!(keyspace::principals(&ks, keyspace::role_grant()) == vector[acl::ou(a)], 0);
            ts::return_shared(a_ou);
            ts::return_shared(ks);
        };

        ts::next_tx(&mut sc, ROGUE);
        let ks = ts::take_shared<Keyspace>(&sc);
        let a_ou = ts::take_shared_by_id<OU>(&sc, a);
        keyspace::test_seal_approve(object::id(&ks).to_bytes(), &ks, &a_ou, sc.ctx());
        abort
    }

    // === Rotation ===

    /// Rotation lists the successor on Grant and makes it the anchor; the old OU
    /// becomes revocable and the new one is pinned.
    #[test]
    fun rotate_moves_the_anchor_to_the_recorded_successor() {
        let mut sc = ts::begin(HONEST);
        let a = anchored_keyspace(&mut sc);
        let s = make_ou(&mut sc, HONEST, vector[HONEST]);
        start_migration(&mut sc, a, s);

        ts::next_tx(&mut sc, ANYONE);
        {
            let mut ks = ts::take_shared<Keyspace>(&sc);
            let a_ou = ts::take_shared_by_id<OU>(&sc, a);
            let s_ou = ts::take_shared_by_id<OU>(&sc, s);
            keyspace::rotate_anchor_to_successor(&mut ks, &a_ou, &s_ou, sc.ctx());
            assert!(keyspace::anchor_ou_id(&ks) == option::some(s), 0);
            assert!(keyspace::principals(&ks, keyspace::role_grant()) == vector[acl::ou(a), acl::ou(s)], 1);
            ts::return_shared(s_ou);
            ts::return_shared(a_ou);
            ts::return_shared(ks);
        };
        let effects = ts::next_tx(&mut sc, HONEST);
        assert!(ts::num_user_events(&effects) == 2, 2);
        {
            let mut ks = ts::take_shared<Keyspace>(&sc);
            let s_ou = ts::take_shared_by_id<OU>(&sc, s);
            keyspace::revoke(&mut ks, keyspace::role_grant(), acl::ou(a), &s_ou, sc.ctx());
            assert!(keyspace::principals(&ks, keyspace::role_grant()) == vector[acl::ou(s)], 3);
            ts::return_shared(s_ou);
            ts::return_shared(ks);
        };
        sc.end();
    }

    /// Once rotated, the successor is pinned.
    #[test]
    #[expected_failure(abort_code = keyspace::EAnchorNotRevocable)]
    fun rotated_anchor_is_not_revocable() {
        let mut sc = ts::begin(HONEST);
        let a = anchored_keyspace(&mut sc);
        let s = make_ou(&mut sc, HONEST, vector[HONEST]);
        start_migration(&mut sc, a, s);

        ts::next_tx(&mut sc, ANYONE);
        {
            let mut ks = ts::take_shared<Keyspace>(&sc);
            let a_ou = ts::take_shared_by_id<OU>(&sc, a);
            let s_ou = ts::take_shared_by_id<OU>(&sc, s);
            keyspace::rotate_anchor_to_successor(&mut ks, &a_ou, &s_ou, sc.ctx());
            ts::return_shared(s_ou);
            ts::return_shared(a_ou);
            ts::return_shared(ks);
        };
        ts::next_tx(&mut sc, ROGUE);
        let mut ks = ts::take_shared<Keyspace>(&sc);
        let a_ou = ts::take_shared_by_id<OU>(&sc, a);
        keyspace::revoke(&mut ks, keyspace::role_grant(), acl::ou(s), &a_ou, sc.ctx());
        abort
    }

    #[test]
    #[expected_failure(abort_code = keyspace::EAnchorNotMigrating)]
    fun rotate_rejects_an_active_anchor() {
        let mut sc = ts::begin(HONEST);
        let a = anchored_keyspace(&mut sc);
        let b = make_ou(&mut sc, ROGUE, vector[ROGUE]);

        ts::next_tx(&mut sc, ROGUE);
        let mut ks = ts::take_shared<Keyspace>(&sc);
        let a_ou = ts::take_shared_by_id<OU>(&sc, a);
        let b_ou = ts::take_shared_by_id<OU>(&sc, b);
        keyspace::rotate_anchor_to_successor(&mut ks, &a_ou, &b_ou, sc.ctx());
        abort
    }

    #[test]
    #[expected_failure(abort_code = keyspace::ENotSuccessor)]
    fun rotate_rejects_another_ou_as_successor() {
        let mut sc = ts::begin(HONEST);
        let a = anchored_keyspace(&mut sc);
        let s = make_ou(&mut sc, HONEST, vector[HONEST]);
        let b = make_ou(&mut sc, ROGUE, vector[ROGUE]);
        start_migration(&mut sc, a, s);

        ts::next_tx(&mut sc, ROGUE);
        let mut ks = ts::take_shared<Keyspace>(&sc);
        let a_ou = ts::take_shared_by_id<OU>(&sc, a);
        let b_ou = ts::take_shared_by_id<OU>(&sc, b);
        keyspace::rotate_anchor_to_successor(&mut ks, &a_ou, &b_ou, sc.ctx());
        abort
    }

    /// A migrating OU that merely holds Grant can't hand the anchor over.
    #[test]
    #[expected_failure(abort_code = keyspace::EAnchorMismatch)]
    fun rotate_rejects_an_ou_that_is_not_the_anchor() {
        let mut sc = ts::begin(HONEST);
        let a = anchored_keyspace(&mut sc);
        let b = make_ou(&mut sc, ROGUE, vector[ROGUE]);
        let c = make_ou(&mut sc, ROGUE, vector[ROGUE]);

        ts::next_tx(&mut sc, ROGUE);
        {
            let mut ks = ts::take_shared<Keyspace>(&sc);
            let a_ou = ts::take_shared_by_id<OU>(&sc, a);
            keyspace::grant(&mut ks, keyspace::role_grant(), acl::ou(b), &a_ou, sc.ctx());
            ts::return_shared(a_ou);
            ts::return_shared(ks);
        };
        start_migration(&mut sc, b, c);

        ts::next_tx(&mut sc, ROGUE);
        let mut ks = ts::take_shared<Keyspace>(&sc);
        let b_ou = ts::take_shared_by_id<OU>(&sc, b);
        let c_ou = ts::take_shared_by_id<OU>(&sc, c);
        keyspace::rotate_anchor_to_successor(&mut ks, &b_ou, &c_ou, sc.ctx());
        abort
    }

    /// A personal keyspace has no anchor to rotate.
    #[test]
    #[expected_failure(abort_code = keyspace::EAnchorMismatch)]
    fun rotate_rejects_a_personal_keyspace() {
        let mut sc = ts::begin(HONEST);
        let a = make_ou(&mut sc, HONEST, vector[HONEST]);
        let s = make_ou(&mut sc, HONEST, vector[HONEST]);
        ts::next_tx(&mut sc, HONEST);
        keyspace::create_keyspace(b"Mine", sc.ctx());
        start_migration(&mut sc, a, s);

        ts::next_tx(&mut sc, HONEST);
        let mut ks = ts::take_shared<Keyspace>(&sc);
        let a_ou = ts::take_shared_by_id<OU>(&sc, a);
        let s_ou = ts::take_shared_by_id<OU>(&sc, s);
        keyspace::rotate_anchor_to_successor(&mut ks, &a_ou, &s_ou, sc.ctx());
        abort
    }
}
