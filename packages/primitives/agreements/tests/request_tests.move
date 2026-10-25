#[test_only]
module agreements::request_tests {
    use agreements::{
        request,
        test_agreements::{Self as lease, Allowlist, Character, Chain, Sign, Renew},
        test_auction::{Self as auction, Bid}
    };
    use std::{type_name, unit_test::assert_eq};
    use sui::test_scenario as ts;

    const ALICE: address = @0xA;
    const BOB: address = @0xB;

    fun lease_id(): ID { object::id_from_address(@0x1EA5E) }

    fun other_lease_id(): ID { object::id_from_address(@0x1EA5F) }

    fun auction_id(): ID { object::id_from_address(@0xA0C) }

    fun character_id(): ID { object::id_from_address(@0xC4A) }

    // === Opening and completing ===

    /// A request with no requirements completes at once and returns the sender.
    #[test]
    fun request_without_requirements_completes() {
        let mut sc = ts::begin(ALICE);
        let req = lease::open_sign(lease_id(), option::none(), vector[], sc.ctx());
        assert_eq!(req.agreement_id(), lease_id());
        assert_eq!(req.actor(), ALICE);
        assert_eq!(req.action(), type_name::with_original_ids<Sign>());
        assert!(req.is_action<Sign>());
        assert!(!req.is_action<Renew>());
        assert!(!req.is_action<Bid>());
        assert_eq!(req.identity_rule(), option::none());
        assert_eq!(req.identity(), option::none());
        assert!(req.requires().is_empty());
        let (actor, identity) = lease::complete_sign(req, lease_id());
        assert_eq!(actor, ALICE);
        assert_eq!(identity, option::none());
        sc.end();
    }

    /// The actor is always the sender of the transaction that opened the request.
    #[test]
    fun actor_is_the_sender() {
        let mut sc = ts::begin(ALICE);
        sc.next_tx(BOB);
        let req = lease::open_sign(lease_id(), option::none(), vector[], sc.ctx());
        assert_eq!(req.actor(), BOB);
        let (actor, _) = lease::complete_sign(req, lease_id());
        assert_eq!(actor, BOB);
        sc.end();
    }

    /// Requirements resolve in declaration order, and the identity rule's identity
    /// comes back from `complete`.
    #[test]
    fun requirements_resolve_in_order_and_identity_is_returned() {
        let mut sc = ts::begin(ALICE);
        let mut req = lease::open_sign(
            lease_id(),
            option::some(type_name::with_original_ids<Character>()),
            vector[lease::allowlist(vector[ALICE]), lease::character()],
            sc.ctx(),
        );
        assert_eq!(req.identity_rule(), option::some(type_name::with_original_ids<Character>()));
        assert_eq!(req.requires().length(), 2);
        assert!(req.next().is<Allowlist>());
        lease::satisfy_allowlist(&mut req);
        assert!(req.next().is<Character>());
        lease::satisfy_character(&mut req, character_id());
        assert_eq!(req.identity(), option::some(character_id()));
        let (actor, identity) = lease::complete_sign(req, lease_id());
        assert_eq!(actor, ALICE);
        assert_eq!(identity, option::some(character_id()));
        sc.end();
    }

    /// A follow-up resolves next, ahead of the requirements declared after the
    /// rule that spawned it.
    #[test]
    fun follow_ups_resolve_before_remaining_requirements() {
        let mut sc = ts::begin(ALICE);
        let mut req = lease::open_sign(
            lease_id(),
            option::some(type_name::with_original_ids<Character>()),
            vector[lease::chain(vector[ALICE]), lease::character()],
            sc.ctx(),
        );
        assert!(req.next().is<Chain>());
        lease::satisfy_chain(&mut req);
        assert_eq!(req.requires().length(), 2);
        assert!(req.next().is<Allowlist>());
        lease::satisfy_allowlist(&mut req);
        assert!(req.next().is<Character>());
        lease::satisfy_character(&mut req, character_id());
        lease::complete_sign(req, lease_id());
        sc.end();
    }

    /// Two actions of one agreement type are told apart.
    #[test]
    fun each_action_completes_its_own_requests() {
        let mut sc = ts::begin(ALICE);
        let sign = lease::open_sign(lease_id(), option::none(), vector[], sc.ctx());
        let renew = lease::open_renew(lease_id(), vector[], sc.ctx());
        assert!(sign.action() != renew.action());
        assert!(renew.is_action<Renew>());
        lease::complete_sign(sign, lease_id());
        lease::complete_renew(renew, lease_id());
        sc.end();
    }

    /// One rule type gates actions of different agreement types.
    #[test]
    fun one_rule_gates_different_agreement_types() {
        let mut sc = ts::begin(ALICE);
        let mut sign = lease::open_sign(
            lease_id(),
            option::none(),
            vector[lease::allowlist(vector[ALICE])],
            sc.ctx(),
        );
        let mut bid = auction::open_bid(
            auction_id(),
            vector[lease::allowlist(vector[ALICE])],
            sc.ctx(),
        );
        lease::satisfy_allowlist(&mut sign);
        lease::satisfy_allowlist(&mut bid);
        lease::complete_sign(sign, lease_id());
        auction::complete_bid(bid, auction_id());
        sc.end();
    }

    // === Completing the wrong request ===

    #[test, expected_failure(abort_code = request::EWrongAgreement)]
    fun request_cannot_complete_another_agreement() {
        let mut sc = ts::begin(ALICE);
        let req = lease::open_sign(lease_id(), option::none(), vector[], sc.ctx());
        lease::complete_sign(req, other_lease_id());
        sc.end();
    }

    #[test, expected_failure(abort_code = request::EWrongAction)]
    fun request_cannot_complete_another_action() {
        let mut sc = ts::begin(ALICE);
        let req = lease::open_renew(lease_id(), vector[], sc.ctx());
        lease::complete_sign(req, lease_id());
        sc.end();
    }

    /// An auction bid opened on the lease's ID still cannot complete a lease
    /// action: the action type belongs to another module.
    #[test, expected_failure(abort_code = request::EWrongAction)]
    fun request_cannot_complete_another_agreement_type() {
        let mut sc = ts::begin(ALICE);
        let req = auction::open_bid(lease_id(), vector[], sc.ctx());
        lease::complete_sign(req, lease_id());
        sc.end();
    }

    #[test, expected_failure(abort_code = request::ERequestNotComplete)]
    fun unsatisfied_request_cannot_complete() {
        let mut sc = ts::begin(ALICE);
        let req = lease::open_sign(
            lease_id(),
            option::none(),
            vector[lease::allowlist(vector[ALICE])],
            sc.ctx(),
        );
        lease::complete_sign(req, lease_id());
        sc.end();
    }

    #[test, expected_failure(abort_code = request::EIdentityMissing)]
    fun identity_rule_must_record_an_identity() {
        let mut sc = ts::begin(ALICE);
        let mut req = lease::open_sign(
            lease_id(),
            option::some(type_name::with_original_ids<Character>()),
            vector[lease::character()],
            sc.ctx(),
        );
        lease::satisfy_character_without_identity(&mut req);
        lease::complete_sign(req, lease_id());
        sc.end();
    }

    // === Satisfying requirements ===

    #[test, expected_failure(abort_code = lease::ENotAllowed)]
    fun rule_rejects_an_unlisted_actor() {
        let mut sc = ts::begin(BOB);
        let mut req = lease::open_sign(
            lease_id(),
            option::none(),
            vector[lease::allowlist(vector[ALICE])],
            sc.ctx(),
        );
        lease::satisfy_allowlist(&mut req);
        req.destroy_for_testing();
        sc.end();
    }

    /// Requirements cannot be satisfied out of order.
    #[test, expected_failure(abort_code = request::EWrongRequirementType)]
    fun next_requirement_must_match_the_rule() {
        let mut sc = ts::begin(ALICE);
        let mut req = lease::open_sign(
            lease_id(),
            option::some(type_name::with_original_ids<Character>()),
            vector[lease::allowlist(vector[ALICE]), lease::character()],
            sc.ctx(),
        );
        lease::satisfy_character(&mut req, character_id());
        req.destroy_for_testing();
        sc.end();
    }

    #[test, expected_failure(abort_code = request::ENoRequirements)]
    fun take_next_on_an_empty_request_aborts() {
        let mut sc = ts::begin(ALICE);
        let mut req = lease::open_sign(lease_id(), option::none(), vector[], sc.ctx());
        lease::satisfy_allowlist(&mut req);
        req.destroy_for_testing();
        sc.end();
    }

    #[test, expected_failure(abort_code = request::ENoRequirements)]
    fun next_on_an_empty_request_aborts() {
        let mut sc = ts::begin(ALICE);
        let req = lease::open_sign(lease_id(), option::none(), vector[], sc.ctx());
        req.next();
        req.destroy_for_testing();
        sc.end();
    }

    #[test, expected_failure(abort_code = request::EFrameNotEmpty)]
    fun follow_ups_cannot_be_dropped() {
        let mut sc = ts::begin(ALICE);
        let mut req = lease::open_sign(
            lease_id(),
            option::none(),
            vector[lease::chain(vector[ALICE])],
            sc.ctx(),
        );
        lease::chain_drops_follow_up(&mut req);
        req.destroy_for_testing();
        sc.end();
    }

    #[test, expected_failure(abort_code = request::EWrongFrame)]
    fun frame_cannot_move_to_another_agreement() {
        let mut sc = ts::begin(ALICE);
        let mut from = lease::open_sign(
            lease_id(),
            option::none(),
            vector[lease::chain(vector[ALICE])],
            sc.ctx(),
        );
        let mut to = lease::open_sign(other_lease_id(), option::none(), vector[], sc.ctx());
        let frame = lease::chain_returns_frame(&mut from);
        to.enqueue(frame);
        from.destroy_for_testing();
        to.destroy_for_testing();
        sc.end();
    }

    #[test, expected_failure(abort_code = request::EWrongFrame)]
    fun frame_cannot_move_to_another_action() {
        let mut sc = ts::begin(ALICE);
        let mut from = lease::open_sign(
            lease_id(),
            option::none(),
            vector[lease::chain(vector[ALICE])],
            sc.ctx(),
        );
        let mut to = lease::open_renew(lease_id(), vector[], sc.ctx());
        let frame = lease::chain_returns_frame(&mut from);
        to.enqueue(frame);
        from.destroy_for_testing();
        to.destroy_for_testing();
        sc.end();
    }

    #[test, expected_failure(abort_code = request::EWrongFrame)]
    fun frame_cannot_move_to_another_agreement_type() {
        let mut sc = ts::begin(ALICE);
        let mut from = lease::open_sign(
            lease_id(),
            option::none(),
            vector[lease::chain(vector[ALICE])],
            sc.ctx(),
        );
        let mut to = auction::open_bid(lease_id(), vector[], sc.ctx());
        let frame = lease::chain_returns_frame(&mut from);
        to.enqueue(frame);
        from.destroy_for_testing();
        to.destroy_for_testing();
        sc.end();
    }

    // === Identity ===

    #[test, expected_failure(abort_code = request::ENotIdentityRule)]
    fun only_the_identity_rule_sets_identity() {
        let mut sc = ts::begin(ALICE);
        let mut req = lease::open_sign(
            lease_id(),
            option::some(type_name::with_original_ids<Character>()),
            vector[lease::character()],
            sc.ctx(),
        );
        lease::allowlist_claims_identity(&mut req, character_id());
        req.destroy_for_testing();
        sc.end();
    }

    /// Without a named identity rule, no rule may set an identity.
    #[test, expected_failure(abort_code = request::ENotIdentityRule)]
    fun no_identity_without_an_identity_rule() {
        let mut sc = ts::begin(ALICE);
        let mut req = lease::open_sign(
            lease_id(),
            option::none(),
            vector[lease::character()],
            sc.ctx(),
        );
        lease::satisfy_character(&mut req, character_id());
        req.destroy_for_testing();
        sc.end();
    }

    #[test, expected_failure(abort_code = request::EIdentityAlreadySet)]
    fun identity_is_set_once() {
        let mut sc = ts::begin(ALICE);
        let mut req = lease::open_sign(
            lease_id(),
            option::some(type_name::with_original_ids<Character>()),
            vector[lease::character()],
            sc.ctx(),
        );
        lease::satisfy_character_twice(&mut req, character_id(), object::id_from_address(@0xC4B));
        req.destroy_for_testing();
        sc.end();
    }
}
