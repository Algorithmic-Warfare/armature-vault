/// ARMATURE-43: a single board member must not be able to take a vault away
/// from its OU. Each vault has an anchor OU that is always on `Edit`, can't be
/// revoked, and moves only to the successor the anchor OU voted for.
///
/// The takeover tests below reproduce the two paths found in review. Both
/// succeeded before the anchor existed: the first through a personal grant,
/// the second through an OU the member creates with themselves as its only
/// board member.
#[test_only]
module armature_vault::anchor_tests {
    use armature::{
        ou::{Self, OU},
        governance,
        proposal,
        remove_member::RemoveMember,
        spawn_ou::SpawnOU
    };
    use armature_vault::ou_receipt_vault::{Self as vault, OuReceiptVault, OuReceiptVaultRegistry, Role};
    use roles::acl::{Self, Principal};
    use std::string;
    use sui::{test_scenario as ts, vec_map};

    /// Rogue board member of the anchor OU.
    const ROGUE: address = @0xA1;
    /// Honest board member of the anchor OU.
    const HONEST: address = @0xA2;
    /// Anyone.
    const ANYONE: address = @0x0E;

    const SSU: address = @0x5501;

    fun make_ou(scenario: &mut ts::Scenario, creator: address, members: vector<address>): ID {
        ts::next_tx(scenario, creator);
        let init = governance::init_board(members);
        ou::create(&init, string::utf8(b"OU"), string::utf8(b"u"), scenario.ctx())
    }

    /// The anchor OU `a` (ROGUE and HONEST on its board) and a vault anchored to
    /// it, where `a` also holds Withdraw. Returns `(a, vault_id)`.
    fun anchored_vault(scenario: &mut ts::Scenario): (ID, ID) {
        let a = make_ou(scenario, HONEST, vector[ROGUE, HONEST]);
        ts::next_tx(scenario, HONEST);
        let mut acl_map = vec_map::empty<Role, vector<Principal>>();
        acl_map.insert(vault::role_edit(), vector[acl::ou(a)]);
        acl_map.insert(vault::role_withdraw(), vector[acl::ou(a)]);
        let mut v = vault::new_for_testing(
            object::id_from_address(SSU),
            object::id_from_address(@0xC0),
            acl_map,
            scenario.ctx(),
        );
        vault::set_registrant_ou_id_for_testing(&mut v, a);
        let id = object::id(&v);
        vault::share_for_testing(v);
        // Registered under (SSU, a, a), as `initialize_ou_vault` would.
        vault::init_for_testing(scenario.ctx());
        ts::next_tx(scenario, HONEST);
        let mut reg = ts::take_shared<OuReceiptVaultRegistry>(scenario);
        vault::register_for_testing(&mut reg, object::id_from_address(SSU), a, a, id);
        ts::return_shared(reg);
        (a, id)
    }

    fun remove_board_member(scenario: &mut ts::Scenario, ou_id: ID, member: address) {
        ts::next_tx(scenario, HONEST);
        let mut org = ts::take_shared_by_id<OU>(scenario, ou_id);
        let req = proposal::new_execution_request_for_testing<RemoveMember>(
            ou_id,
            object::id_from_address(@0x9999),
        );
        org.remove_board_member_governance(member, &req);
        proposal::consume_execution_request_for_testing(req);
        ts::return_shared(org);
    }

    /// Mark `ou_id` Migrating towards `successor` as an executed SpawnOU would.
    fun start_migration(scenario: &mut ts::Scenario, ou_id: ID, successor: ID) {
        ts::next_tx(scenario, ANYONE);
        let mut org = ts::take_shared_by_id<OU>(scenario, ou_id);
        let req = proposal::new_execution_request_for_testing<SpawnOU>(
            ou_id,
            object::id_from_address(@0x9998),
        );
        org.set_migrating(successor, &req);
        proposal::consume_execution_request_for_testing(req);
        ts::return_shared(org);
    }

    // === Takeover paths ===

    /// Path 1: grant your own Player Edit, then revoke the board's OU.
    #[test]
    #[expected_failure(abort_code = vault::EAnchorNotRevocable)]
    fun takeover_via_personal_grant_aborts() {
        let mut sc = ts::begin(HONEST);
        let (a, v_id) = anchored_vault(&mut sc);

        ts::next_tx(&mut sc, ROGUE);
        let mut v = ts::take_shared_by_id<OuReceiptVault>(&sc, v_id);
        let a_ou = ts::take_shared_by_id<OU>(&sc, a);
        vault::grant(&mut v, &a_ou, vector[vault::role_edit()], vector[acl::player(ROGUE)], sc.ctx());
        vault::revoke(&mut v, &a_ou, vector[vault::role_edit()], vector[acl::ou(a)], sc.ctx());
        abort
    }

    /// Path 2: create an OU with yourself as its only board member, list it on
    /// Edit, then revoke the board's OU acting as your own.
    #[test]
    #[expected_failure(abort_code = vault::EAnchorNotRevocable)]
    fun takeover_via_throwaway_ou_aborts() {
        let mut sc = ts::begin(HONEST);
        let (a, v_id) = anchored_vault(&mut sc);
        let b = make_ou(&mut sc, ROGUE, vector[ROGUE]);

        ts::next_tx(&mut sc, ROGUE);
        let mut v = ts::take_shared_by_id<OuReceiptVault>(&sc, v_id);
        let a_ou = ts::take_shared_by_id<OU>(&sc, a);
        let b_ou = ts::take_shared_by_id<OU>(&sc, b);
        vault::grant_edit_ou(&mut v, &a_ou, &b_ou, sc.ctx());
        vault::revoke(&mut v, &b_ou, vector[vault::role_edit()], vector[acl::ou(a)], sc.ctx());
        abort
    }

    /// The anchor can't be dropped as one pair of a larger batch either.
    #[test]
    #[expected_failure(abort_code = vault::EAnchorNotRevocable)]
    fun anchor_in_a_mixed_batch_aborts() {
        let mut sc = ts::begin(HONEST);
        let (a, v_id) = anchored_vault(&mut sc);

        ts::next_tx(&mut sc, HONEST);
        let mut v = ts::take_shared_by_id<OuReceiptVault>(&sc, v_id);
        let a_ou = ts::take_shared_by_id<OU>(&sc, a);
        vault::grant(&mut v, &a_ou, vector[vault::role_edit()], vector[acl::player(HONEST)], sc.ctx());
        vault::revoke(
            &mut v,
            &a_ou,
            vector[vault::role_withdraw(), vault::role_edit()],
            vector[acl::ou(a), acl::ou(a)],
            sc.ctx(),
        );
        abort
    }

    /// Revoking the anchor OU from another role (Withdraw) is allowed: only its
    /// place on Edit is pinned.
    #[test]
    fun anchor_can_leave_other_roles() {
        let mut sc = ts::begin(HONEST);
        let (a, v_id) = anchored_vault(&mut sc);

        ts::next_tx(&mut sc, HONEST);
        let mut v = ts::take_shared_by_id<OuReceiptVault>(&sc, v_id);
        let a_ou = ts::take_shared_by_id<OU>(&sc, a);
        vault::revoke(&mut v, &a_ou, vector[vault::role_withdraw()], vector[acl::ou(a)], sc.ctx());
        assert!(vault::principals(&v, vault::role_withdraw()) == vector[], 0);
        assert!(vault::principals(&v, vault::role_edit()) == vector[acl::ou(a)], 1);
        ts::return_shared(a_ou);
        ts::return_shared(v);
        sc.end();
    }

    // === Recovery ===

    /// A rogue member grants themselves Edit and Withdraw and is then removed
    /// from the board. The board, through the anchor, revokes both grants, and
    /// the rogue can no longer administer or withdraw.
    #[test]
    fun board_recovers_after_removing_a_rogue_member() {
        let mut sc = ts::begin(HONEST);
        let (a, v_id) = anchored_vault(&mut sc);
        let b = make_ou(&mut sc, ROGUE, vector[ROGUE]);

        ts::next_tx(&mut sc, ROGUE);
        {
            let mut v = ts::take_shared_by_id<OuReceiptVault>(&sc, v_id);
            let a_ou = ts::take_shared_by_id<OU>(&sc, a);
            let b_ou = ts::take_shared_by_id<OU>(&sc, b);
            vault::grant(
                &mut v,
                &a_ou,
                vector[vault::role_edit(), vault::role_withdraw()],
                vector[acl::player(ROGUE), acl::player(ROGUE)],
                sc.ctx(),
            );
            vault::grant_edit_ou(&mut v, &a_ou, &b_ou, sc.ctx());
            ts::return_shared(b_ou);
            ts::return_shared(a_ou);
            ts::return_shared(v);
        };

        remove_board_member(&mut sc, a, ROGUE);

        ts::next_tx(&mut sc, HONEST);
        {
            let mut v = ts::take_shared_by_id<OuReceiptVault>(&sc, v_id);
            let a_ou = ts::take_shared_by_id<OU>(&sc, a);
            vault::revoke(
                &mut v,
                &a_ou,
                vector[vault::role_edit(), vault::role_withdraw(), vault::role_edit()],
                vector[acl::player(ROGUE), acl::player(ROGUE), acl::ou(b)],
                sc.ctx(),
            );
            assert!(vault::principals(&v, vault::role_edit()) == vector[acl::ou(a)], 0);
            assert!(vault::principals(&v, vault::role_withdraw()) == vector[acl::ou(a)], 1);
            ts::return_shared(a_ou);
            ts::return_shared(v);
        };
        sc.end();
    }

    /// After recovery the removed member fails the Edit check through every
    /// route they had: their own key and the OU they created.
    #[test]
    #[expected_failure(abort_code = vault::ENotAuthorized)]
    fun removed_rogue_cannot_edit_after_recovery() {
        let mut sc = ts::begin(HONEST);
        let (a, v_id) = anchored_vault(&mut sc);
        let b = make_ou(&mut sc, ROGUE, vector[ROGUE]);

        ts::next_tx(&mut sc, ROGUE);
        {
            let mut v = ts::take_shared_by_id<OuReceiptVault>(&sc, v_id);
            let a_ou = ts::take_shared_by_id<OU>(&sc, a);
            let b_ou = ts::take_shared_by_id<OU>(&sc, b);
            vault::grant_edit_ou(&mut v, &a_ou, &b_ou, sc.ctx());
            ts::return_shared(b_ou);
            ts::return_shared(a_ou);
            ts::return_shared(v);
        };
        remove_board_member(&mut sc, a, ROGUE);
        ts::next_tx(&mut sc, HONEST);
        {
            let mut v = ts::take_shared_by_id<OuReceiptVault>(&sc, v_id);
            let a_ou = ts::take_shared_by_id<OU>(&sc, a);
            vault::revoke(&mut v, &a_ou, vector[vault::role_edit()], vector[acl::ou(b)], sc.ctx());
            ts::return_shared(a_ou);
            ts::return_shared(v);
        };

        ts::next_tx(&mut sc, ROGUE);
        let mut v = ts::take_shared_by_id<OuReceiptVault>(&sc, v_id);
        let b_ou = ts::take_shared_by_id<OU>(&sc, b);
        vault::grant(&mut v, &b_ou, vector[vault::role_withdraw()], vector[acl::player(ROGUE)], sc.ctx());
        abort
    }

    // === Rotation ===

    /// Rotation lists the successor on Edit and makes it the anchor. The old OU
    /// becomes revocable and the new one is pinned.
    #[test]
    fun rotate_moves_the_anchor_to_the_recorded_successor() {
        let mut sc = ts::begin(HONEST);
        let (a, v_id) = anchored_vault(&mut sc);
        let s = make_ou(&mut sc, HONEST, vector[HONEST]);
        start_migration(&mut sc, a, s);

        ts::next_tx(&mut sc, ANYONE);
        {
            let mut v = ts::take_shared_by_id<OuReceiptVault>(&sc, v_id);
            let a_ou = ts::take_shared_by_id<OU>(&sc, a);
            let s_ou = ts::take_shared_by_id<OU>(&sc, s);
            let mut reg = ts::take_shared<OuReceiptVaultRegistry>(&sc);
            vault::rotate_anchor_to_successor(&mut reg, &mut v, &a_ou, &s_ou, sc.ctx());
            assert!(vault::anchor_ou_id(&v) == s, 0);
            assert!(vault::principals(&v, vault::role_edit()) == vector[acl::ou(a), acl::ou(s)], 1);
            // The registry key follows the anchor.
            let ssu = object::id_from_address(SSU);
            assert!(vault::lookup(&reg, ssu, a, s) == option::some(v_id), 4);
            assert!(vault::lookup(&reg, ssu, a, a).is_none(), 5);
            ts::return_shared(s_ou);
            ts::return_shared(a_ou);
            ts::return_shared(v);
            ts::return_shared(reg);
        };
        // RegistryKeyUpdated + Grant + AnchorSet.
        let effects = ts::next_tx(&mut sc, HONEST);
        assert!(ts::num_user_events(&effects) == 3, 2);

        {
            let mut v = ts::take_shared_by_id<OuReceiptVault>(&sc, v_id);
            let s_ou = ts::take_shared_by_id<OU>(&sc, s);
            vault::revoke(&mut v, &s_ou, vector[vault::role_edit()], vector[acl::ou(a)], sc.ctx());
            assert!(vault::principals(&v, vault::role_edit()) == vector[acl::ou(s)], 3);
            ts::return_shared(s_ou);
            ts::return_shared(v);
        };
        sc.end();
    }

    /// Once rotated, the successor is pinned like the original anchor was.
    #[test]
    #[expected_failure(abort_code = vault::EAnchorNotRevocable)]
    fun rotated_anchor_is_not_revocable() {
        let mut sc = ts::begin(HONEST);
        let (a, v_id) = anchored_vault(&mut sc);
        let s = make_ou(&mut sc, HONEST, vector[HONEST]);
        start_migration(&mut sc, a, s);

        ts::next_tx(&mut sc, ANYONE);
        {
            let mut v = ts::take_shared_by_id<OuReceiptVault>(&sc, v_id);
            let a_ou = ts::take_shared_by_id<OU>(&sc, a);
            let s_ou = ts::take_shared_by_id<OU>(&sc, s);
            let mut reg = ts::take_shared<OuReceiptVaultRegistry>(&sc);
            vault::rotate_anchor_to_successor(&mut reg, &mut v, &a_ou, &s_ou, sc.ctx());
            ts::return_shared(s_ou);
            ts::return_shared(a_ou);
            ts::return_shared(v);
            ts::return_shared(reg);
        };

        // ROGUE is still on the old OU's board; it can't drop the new anchor.
        ts::next_tx(&mut sc, ROGUE);
        let mut v = ts::take_shared_by_id<OuReceiptVault>(&sc, v_id);
        let a_ou = ts::take_shared_by_id<OU>(&sc, a);
        vault::revoke(&mut v, &a_ou, vector[vault::role_edit()], vector[acl::ou(s)], sc.ctx());
        abort
    }

    /// A rotation that finds the successor already on Edit adds no duplicate.
    #[test]
    fun rotate_to_a_successor_already_on_edit_adds_nothing() {
        let mut sc = ts::begin(HONEST);
        let (a, v_id) = anchored_vault(&mut sc);
        let s = make_ou(&mut sc, HONEST, vector[HONEST]);

        ts::next_tx(&mut sc, HONEST);
        {
            let mut v = ts::take_shared_by_id<OuReceiptVault>(&sc, v_id);
            let a_ou = ts::take_shared_by_id<OU>(&sc, a);
            let s_ou = ts::take_shared_by_id<OU>(&sc, s);
            vault::grant_edit_ou(&mut v, &a_ou, &s_ou, sc.ctx());
            ts::return_shared(s_ou);
            ts::return_shared(a_ou);
            ts::return_shared(v);
        };
        start_migration(&mut sc, a, s);

        ts::next_tx(&mut sc, ANYONE);
        let mut v = ts::take_shared_by_id<OuReceiptVault>(&sc, v_id);
        let a_ou = ts::take_shared_by_id<OU>(&sc, a);
        let s_ou = ts::take_shared_by_id<OU>(&sc, s);
        let mut reg = ts::take_shared<OuReceiptVaultRegistry>(&sc);
        vault::rotate_anchor_to_successor(&mut reg, &mut v, &a_ou, &s_ou, sc.ctx());
        assert!(vault::anchor_ou_id(&v) == s, 0);
        assert!(vault::principals(&v, vault::role_edit()) == vector[acl::ou(a), acl::ou(s)], 1);
        ts::return_shared(s_ou);
        ts::return_shared(a_ou);
        ts::return_shared(v);
        ts::return_shared(reg);
        sc.end();
    }

    /// No rotation while the anchor OU is Active: no vote has named a successor.
    #[test]
    #[expected_failure(abort_code = vault::EAnchorNotMigrating)]
    fun rotate_rejects_an_active_anchor() {
        let mut sc = ts::begin(HONEST);
        let (a, v_id) = anchored_vault(&mut sc);
        let b = make_ou(&mut sc, ROGUE, vector[ROGUE]);

        ts::next_tx(&mut sc, ROGUE);
        let mut v = ts::take_shared_by_id<OuReceiptVault>(&sc, v_id);
        let a_ou = ts::take_shared_by_id<OU>(&sc, a);
        let b_ou = ts::take_shared_by_id<OU>(&sc, b);
        let mut reg = ts::take_shared<OuReceiptVaultRegistry>(&sc);
        vault::rotate_anchor_to_successor(&mut reg, &mut v, &a_ou, &b_ou, sc.ctx());
        abort
    }

    /// Only the recorded successor can become the anchor.
    #[test]
    #[expected_failure(abort_code = vault::ENotSuccessor)]
    fun rotate_rejects_another_ou_as_successor() {
        let mut sc = ts::begin(HONEST);
        let (a, v_id) = anchored_vault(&mut sc);
        let s = make_ou(&mut sc, HONEST, vector[HONEST]);
        let b = make_ou(&mut sc, ROGUE, vector[ROGUE]);
        start_migration(&mut sc, a, s);

        ts::next_tx(&mut sc, ROGUE);
        let mut v = ts::take_shared_by_id<OuReceiptVault>(&sc, v_id);
        let a_ou = ts::take_shared_by_id<OU>(&sc, a);
        let b_ou = ts::take_shared_by_id<OU>(&sc, b);
        let mut reg = ts::take_shared<OuReceiptVaultRegistry>(&sc);
        vault::rotate_anchor_to_successor(&mut reg, &mut v, &a_ou, &b_ou, sc.ctx());
        abort
    }

    /// The OU passed as the anchor must be the vault's anchor: a migrating OU
    /// that merely sits on Edit can't hand the anchor to its own successor.
    #[test]
    #[expected_failure(abort_code = vault::EAnchorMismatch)]
    fun rotate_rejects_an_ou_that_is_not_the_anchor() {
        let mut sc = ts::begin(HONEST);
        let (a, v_id) = anchored_vault(&mut sc);
        let b = make_ou(&mut sc, ROGUE, vector[ROGUE]);
        let c = make_ou(&mut sc, ROGUE, vector[ROGUE]);

        ts::next_tx(&mut sc, ROGUE);
        {
            let mut v = ts::take_shared_by_id<OuReceiptVault>(&sc, v_id);
            let a_ou = ts::take_shared_by_id<OU>(&sc, a);
            let b_ou = ts::take_shared_by_id<OU>(&sc, b);
            vault::grant_edit_ou(&mut v, &a_ou, &b_ou, sc.ctx());
            ts::return_shared(b_ou);
            ts::return_shared(a_ou);
            ts::return_shared(v);
        };
        start_migration(&mut sc, b, c);

        ts::next_tx(&mut sc, ROGUE);
        let mut v = ts::take_shared_by_id<OuReceiptVault>(&sc, v_id);
        let b_ou = ts::take_shared_by_id<OU>(&sc, b);
        let c_ou = ts::take_shared_by_id<OU>(&sc, c);
        let mut reg = ts::take_shared<OuReceiptVaultRegistry>(&sc);
        vault::rotate_anchor_to_successor(&mut reg, &mut v, &b_ou, &c_ou, sc.ctx());
        abort
    }

    /// A deinitialized vault stays dead: rotation can't put an editor back.
    #[test]
    #[expected_failure(abort_code = vault::ENotAuthorized)]
    fun rotate_rejects_a_deinitialized_vault() {
        let mut sc = ts::begin(HONEST);
        let (a, v_id) = anchored_vault(&mut sc);
        let s = make_ou(&mut sc, HONEST, vector[HONEST]);

        ts::next_tx(&mut sc, HONEST);
        {
            let mut reg = ts::take_shared<OuReceiptVaultRegistry>(&sc);
            let mut v = ts::take_shared_by_id<OuReceiptVault>(&sc, v_id);
            let a_ou = ts::take_shared_by_id<OU>(&sc, a);
            vault::deinitialize_ou_vault(&mut reg, &mut v, &a_ou, sc.ctx());
            ts::return_shared(a_ou);
            ts::return_shared(v);
            ts::return_shared(reg);
        };
        start_migration(&mut sc, a, s);

        ts::next_tx(&mut sc, ANYONE);
        let mut v = ts::take_shared_by_id<OuReceiptVault>(&sc, v_id);
        let a_ou = ts::take_shared_by_id<OU>(&sc, a);
        let s_ou = ts::take_shared_by_id<OU>(&sc, s);
        let mut reg = ts::take_shared<OuReceiptVaultRegistry>(&sc);
        vault::rotate_anchor_to_successor(&mut reg, &mut v, &a_ou, &s_ou, sc.ctx());
        abort
    }

    /// Rotation re-keys the registry; if the successor's key is already taken
    /// the rotation aborts rather than overwrite it.
    #[test]
    #[expected_failure(abort_code = vault::EVaultAlreadyExists)]
    fun rotate_rejects_a_taken_successor_key() {
        let mut sc = ts::begin(HONEST);
        let (a, v_id) = anchored_vault(&mut sc);
        let s = make_ou(&mut sc, HONEST, vector[HONEST]);
        start_migration(&mut sc, a, s);

        ts::next_tx(&mut sc, ANYONE);
        let mut reg = ts::take_shared<OuReceiptVaultRegistry>(&sc);
        vault::register_for_testing(&mut reg, object::id_from_address(SSU), a, s, object::id_from_address(@0xBEEF));
        let mut v = ts::take_shared_by_id<OuReceiptVault>(&sc, v_id);
        let a_ou = ts::take_shared_by_id<OU>(&sc, a);
        let s_ou = ts::take_shared_by_id<OU>(&sc, s);
        vault::rotate_anchor_to_successor(&mut reg, &mut v, &a_ou, &s_ou, sc.ctx());
        abort
    }

    /// A vault whose registry slot doesn't hold it can't be rotated.
    #[test]
    #[expected_failure(abort_code = vault::EVaultRegistryMismatch)]
    fun rotate_rejects_an_unregistered_vault() {
        let mut sc = ts::begin(HONEST);
        let (a, _) = anchored_vault(&mut sc);
        let s = make_ou(&mut sc, HONEST, vector[HONEST]);

        // A second vault with the same anchor and registrant, never registered.
        ts::next_tx(&mut sc, HONEST);
        let mut acl_map = vec_map::empty<Role, vector<Principal>>();
        acl_map.insert(vault::role_edit(), vector[acl::ou(a)]);
        let mut v2 = vault::new_for_testing(
            object::id_from_address(SSU),
            object::id_from_address(@0xC0),
            acl_map,
            sc.ctx(),
        );
        vault::set_registrant_ou_id_for_testing(&mut v2, a);
        let v2_id = object::id(&v2);
        vault::share_for_testing(v2);
        start_migration(&mut sc, a, s);

        ts::next_tx(&mut sc, ANYONE);
        let mut reg = ts::take_shared<OuReceiptVaultRegistry>(&sc);
        let mut v = ts::take_shared_by_id<OuReceiptVault>(&sc, v2_id);
        let a_ou = ts::take_shared_by_id<OU>(&sc, a);
        let s_ou = ts::take_shared_by_id<OU>(&sc, s);
        vault::rotate_anchor_to_successor(&mut reg, &mut v, &a_ou, &s_ou, sc.ctx());
        abort
    }
}
