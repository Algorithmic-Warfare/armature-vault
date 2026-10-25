/// Scenario: auctions (`test_auction`, built only on `agreements`) whose bids
/// are gated on the haulers OU's board, one freelancer and a courier bot. The
/// officers OU is a second OU that is not listed. A bid stands in for any
/// gated action; hauling-agreement accepts are tested in
/// packages/integration/hauling_claim_tests.
#[test_only]
module agreement_roles::claim_tests {
    use agreement_roles::{claim, test_auction::{Self, Auction, Bid}, test_ou};
    use agreements::{request, requirement};
    use armature::ou::OU;
    use roles::acl::{Self, Principal};
    use std::{internal, type_name, unit_test::assert_eq};
    use sui::{event, test_scenario::{Self as ts, Scenario}};

    const SELLER: address = @0xA;
    const HAULER_1: address = @0x11;
    const HAULER_2: address = @0x12;
    const FREELANCER: address = @0x21;
    const BOT: address = @0x22;
    const OFFICER: address = @0x31;
    const OUTSIDER: address = @0x41;

    public struct World {
        scenario: Scenario,
        haulers: ID,
        officers: ID,
    }

    /// A requirement of some other rule, for `principals_of`.
    public struct NotAGate has drop {}

    /// An action this test module defines, to forge a claim with.
    public struct Forged has drop {}

    // === Fixtures ===

    /// Two OUs. No auction yet.
    fun world(): World {
        let mut scenario = ts::begin(OFFICER);
        let haulers = test_ou::make(&mut scenario, HAULER_1, vector[HAULER_1, HAULER_2]);
        let officers = test_ou::make(&mut scenario, OFFICER, vector[OFFICER]);
        World { scenario, haulers, officers }
    }

    /// The standard gate: the haulers OU's board, the freelancer and the bot.
    fun gate(w: &World): vector<Principal> {
        vector[acl::ou(w.haulers), acl::player(FREELANCER), acl::machine(BOT)]
    }

    /// SELLER shares an auction whose bids must pass `gates`, in order.
    fun gated_auction(w: &mut World, gates: vector<vector<Principal>>): ID {
        w.scenario.next_tx(SELLER);
        test_auction::create(
            gates.map!(|principals| claim::requirement(principals)),
            w.scenario.ctx(),
        )
    }

    /// SELLER shares an auction only `principals` may bid on.
    fun auction(w: &mut World, principals: vector<Principal>): ID {
        gated_auction(w, vector[principals])
    }

    /// `who` bids, satisfying each gate as a member of `org_id` when given and
    /// directly as a listed player or machine otherwise.
    fun bid(w: &mut World, who: address, org_id: Option<ID>, auction_id: ID, gates: u64) {
        w.scenario.next_tx(who);
        let mut auction = w.scenario.take_shared_by_id<Auction>(auction_id);
        let mut req = auction.begin_bid(w.scenario.ctx());
        if (org_id.is_some()) {
            let org = w.scenario.take_shared_by_id<OU>(*org_id.borrow());
            gates.do!(|_| claim::satisfy(&mut req, &org));
            ts::return_shared(org);
        } else gates.do!(|_| claim::satisfy_directly(&mut req));
        auction.finish_bid(req);
        ts::return_shared(auction);
    }

    /// `who` bids on a one-gate auction, acting as a member of `org_id`.
    fun bid_as_member(w: &mut World, who: address, org_id: ID, auction_id: ID) {
        bid(w, who, option::some(org_id), auction_id, 1);
    }

    /// `who` bids on a one-gate auction as a listed `Player` or `Machine`.
    fun bid_directly(w: &mut World, who: address, auction_id: ID) {
        bid(w, who, option::none(), auction_id, 1);
    }

    /// The current transaction emitted exactly one claim: `who` matched
    /// `principal` on `agreement_id` for action `A`.
    fun assert_claimed<A>(who: address, principal: Principal, agreement_id: ID) {
        assert_eq!(
            event::events_by_type<claim::Claimed>(),
            vector[
                claim::claimed_event_for_testing(
                    agreement_id,
                    type_name::with_original_ids<A>(),
                    who,
                    principal,
                ),
            ],
        );
    }

    fun last_bidder(w: &mut World, auction_id: ID): Option<address> {
        w.scenario.next_tx(OUTSIDER);
        let auction = w.scenario.take_shared_by_id<Auction>(auction_id);
        let bidder = auction.last_bidder();
        ts::return_shared(auction);
        bidder
    }

    fun done(w: World) {
        let World { scenario, .. } = w;
        scenario.end();
    }

    // === Reserving for one player ===

    #[test]
    fun reservation_admits_its_player() {
        let mut w = world();
        let auction_id = auction(&mut w, vector[acl::player(FREELANCER)]);
        bid_directly(&mut w, FREELANCER, auction_id);
        assert_claimed<Bid>(FREELANCER, acl::player(FREELANCER), auction_id);
        assert_eq!(last_bidder(&mut w, auction_id), option::some(FREELANCER));
        done(w);
    }

    #[test, expected_failure(abort_code = claim::ENotAuthorized)]
    fun reservation_rejects_another_player() {
        let mut w = world();
        let auction_id = auction(&mut w, vector[acl::player(FREELANCER)]);
        bid_directly(&mut w, OUTSIDER, auction_id);
        done(w);
    }

    // === Claiming through each principal ===

    #[test]
    fun board_member_of_listed_ou_claims() {
        let mut w = world();
        let principals = gate(&w);
        let auction_id = auction(&mut w, principals);
        let haulers = w.haulers;
        bid_as_member(&mut w, HAULER_2, haulers, auction_id);
        assert_claimed<Bid>(HAULER_2, acl::ou(haulers), auction_id);
        assert_eq!(last_bidder(&mut w, auction_id), option::some(HAULER_2));
        done(w);
    }

    #[test]
    fun listed_player_claims_without_an_ou() {
        let mut w = world();
        let principals = gate(&w);
        let auction_id = auction(&mut w, principals);
        bid_directly(&mut w, FREELANCER, auction_id);
        assert_claimed<Bid>(FREELANCER, acl::player(FREELANCER), auction_id);
        assert_eq!(last_bidder(&mut w, auction_id), option::some(FREELANCER));
        done(w);
    }

    #[test]
    fun listed_machine_claims_without_an_ou() {
        let mut w = world();
        let principals = gate(&w);
        let auction_id = auction(&mut w, principals);
        bid_directly(&mut w, BOT, auction_id);
        assert_claimed<Bid>(BOT, acl::machine(BOT), auction_id);
        assert_eq!(last_bidder(&mut w, auction_id), option::some(BOT));
        done(w);
    }

    /// `satisfy` also matches listed players, whatever OU they pass.
    #[test]
    fun listed_player_claims_while_passing_any_ou() {
        let mut w = world();
        let principals = gate(&w);
        let auction_id = auction(&mut w, principals);
        let officers = w.officers;
        bid_as_member(&mut w, FREELANCER, officers, auction_id);
        assert_claimed<Bid>(FREELANCER, acl::player(FREELANCER), auction_id);
        assert_eq!(last_bidder(&mut w, auction_id), option::some(FREELANCER));
        done(w);
    }

    #[test, expected_failure(abort_code = claim::ENotAuthorized)]
    fun outsider_is_rejected() {
        let mut w = world();
        let principals = gate(&w);
        let auction_id = auction(&mut w, principals);
        let haulers = w.haulers;
        bid_as_member(&mut w, OUTSIDER, haulers, auction_id);
        done(w);
    }

    #[test, expected_failure(abort_code = claim::ENotAuthorized)]
    fun board_member_of_unlisted_ou_is_rejected() {
        let mut w = world();
        let principals = gate(&w);
        let auction_id = auction(&mut w, principals);
        let officers = w.officers;
        bid_as_member(&mut w, OFFICER, officers, auction_id);
        done(w);
    }

    #[test, expected_failure(abort_code = claim::ENotAuthorized)]
    fun ou_member_cannot_claim_directly() {
        let mut w = world();
        let principals = gate(&w);
        let auction_id = auction(&mut w, principals);
        bid_directly(&mut w, HAULER_1, auction_id);
        done(w);
    }

    /// OU principals are read at claim time, so leaving the board after the gate
    /// is set removes the right to claim.
    #[test, expected_failure(abort_code = claim::ENotAuthorized)]
    fun removed_board_member_loses_access() {
        let mut w = world();
        let principals = gate(&w);
        let auction_id = auction(&mut w, principals);
        let haulers = w.haulers;
        test_ou::remove_board_member(&mut w.scenario, haulers, HAULER_1);
        bid_as_member(&mut w, HAULER_1, haulers, auction_id);
        done(w);
    }

    /// Joining the board after the gate is set grants the right to claim.
    #[test]
    fun added_board_member_gains_access() {
        let mut w = world();
        let haulers = w.haulers;
        let auction_id = auction(&mut w, vector[acl::ou(haulers)]);
        test_ou::add_board_member(&mut w.scenario, haulers, OUTSIDER);
        bid_as_member(&mut w, OUTSIDER, haulers, auction_id);
        assert_eq!(last_bidder(&mut w, auction_id), option::some(OUTSIDER));
        done(w);
    }

    // === Gating on OUs ===

    /// Each listed OU admits its own board: here the second of two.
    #[test]
    fun board_member_of_any_listed_ou_claims() {
        let mut w = world();
        let principals = vector[acl::ou(w.officers), acl::ou(w.haulers)];
        let auction_id = auction(&mut w, principals);
        let haulers = w.haulers;
        bid_as_member(&mut w, HAULER_2, haulers, auction_id);
        assert_claimed<Bid>(HAULER_2, acl::ou(haulers), auction_id);
        done(w);
    }

    /// A player who is not on the listed OU's board cannot claim by passing it.
    #[test, expected_failure(abort_code = claim::ENotAuthorized)]
    fun ou_gate_rejects_player_off_the_board() {
        let mut w = world();
        let haulers = w.haulers;
        let auction_id = auction(&mut w, vector[acl::ou(haulers)]);
        bid_as_member(&mut w, FREELANCER, haulers, auction_id);
        done(w);
    }

    /// A member of both the listed OU and another must act as the listed one:
    /// being on the passed OU's board is not enough.
    #[test, expected_failure(abort_code = claim::ENotAuthorized)]
    fun board_member_passing_another_ou_is_rejected() {
        let mut w = world();
        let (haulers, officers) = (w.haulers, w.officers);
        let auction_id = auction(&mut w, vector[acl::ou(haulers)]);
        test_ou::add_board_member(&mut w.scenario, officers, HAULER_1);
        bid_as_member(&mut w, HAULER_1, officers, auction_id);
        done(w);
    }

    /// A board member who is also listed directly matches whichever principal is
    /// listed first, and the claim records that one.
    #[test]
    fun claim_records_the_first_matching_principal() {
        let mut w = world();
        let haulers = w.haulers;
        let player_first = auction(&mut w, vector[acl::player(HAULER_1), acl::ou(haulers)]);
        let ou_first = auction(&mut w, vector[acl::ou(haulers), acl::player(HAULER_1)]);
        bid_as_member(&mut w, HAULER_1, haulers, player_first);
        assert_claimed<Bid>(HAULER_1, acl::player(HAULER_1), player_first);
        bid_as_member(&mut w, HAULER_1, haulers, ou_first);
        assert_claimed<Bid>(HAULER_1, acl::ou(haulers), ou_first);
        done(w);
    }

    // === Composing and skipping gates ===

    #[test, expected_failure(abort_code = request::ERequestNotComplete)]
    fun action_cannot_skip_the_gate() {
        let mut w = world();
        let principals = gate(&w);
        let auction_id = auction(&mut w, principals);
        w.scenario.next_tx(HAULER_1);
        let mut auction = w.scenario.take_shared_by_id<Auction>(auction_id);
        let req = auction.begin_bid(w.scenario.ctx());
        auction.finish_bid(req);
        abort
    }

    /// Two gates on one action must both pass: here, a haulers board member who
    /// is also individually named.
    #[test]
    fun gates_compose_as_and() {
        let mut w = world();
        let haulers = w.haulers;
        let auction_id = gated_auction(
            &mut w,
            vector[vector[acl::ou(haulers)], vector[acl::player(HAULER_1)]],
        );
        bid(&mut w, HAULER_1, option::some(haulers), auction_id, 2);
        assert_eq!(event::events_by_type<claim::Claimed>().length(), 2);
        assert_eq!(last_bidder(&mut w, auction_id), option::some(HAULER_1));
        done(w);
    }

    #[test, expected_failure(abort_code = claim::ENotAuthorized)]
    fun second_gate_rejects_unnamed_board_member() {
        let mut w = world();
        let haulers = w.haulers;
        let auction_id = gated_auction(
            &mut w,
            vector[vector[acl::ou(haulers)], vector[acl::player(HAULER_1)]],
        );
        bid(&mut w, HAULER_2, option::some(haulers), auction_id, 2);
        done(w);
    }

    /// A request that passed the gate on one auction cannot complete on another,
    /// even one with the same gate.
    #[test, expected_failure(abort_code = request::EWrongAgreement)]
    fun request_cannot_complete_another_agreement() {
        let mut w = world();
        let first = auction(&mut w, vector[acl::player(FREELANCER)]);
        let second = auction(&mut w, vector[acl::player(FREELANCER)]);
        w.scenario.next_tx(FREELANCER);
        let first = w.scenario.take_shared_by_id<Auction>(first);
        let mut second = w.scenario.take_shared_by_id<Auction>(second);
        let mut req = first.begin_bid(w.scenario.ctx());
        claim::satisfy_directly(&mut req);
        second.finish_bid(req);
        abort
    }

    // === Trusting `Claimed` ===

    /// Anyone can open a request for their own action, name a real auction, gate
    /// it on themselves and complete it. The `Claimed` it emits names that auction,
    /// but its `action` is the forger's, not `Bid`, and the auction has no bidder:
    /// indexers must filter claims on `action`.
    #[test]
    fun forged_claim_carries_the_forging_action() {
        let mut w = world();
        let auction_id = auction(&mut w, vector[acl::player(FREELANCER)]);
        w.scenario.next_tx(OUTSIDER);
        let mut req = request::new(
            internal::permit<Forged>(),
            auction_id,
            option::none(),
            vector[claim::requirement(vector[acl::player(OUTSIDER)])],
            w.scenario.ctx(),
        );
        claim::satisfy_directly(&mut req);
        let (actor, _) = req.complete(internal::permit<Forged>(), auction_id);
        assert_eq!(actor, OUTSIDER);
        assert_claimed<Forged>(OUTSIDER, acl::player(OUTSIDER), auction_id);
        assert_eq!(last_bidder(&mut w, auction_id), option::none());
        done(w);
    }

    // === Building and reading gates ===

    #[test, expected_failure(abort_code = claim::EInvalidPrincipals)]
    fun gate_needs_a_principal() {
        claim::requirement(vector[]);
    }

    #[test]
    fun gate_allows_max_principals() {
        let principals = vector::tabulate!(
            claim::max_principals(),
            |i| acl::player(sui::address::from_u256((0x100 + i) as u256)),
        );
        assert_eq!(claim::principals_of(&claim::requirement(principals)), principals);
    }

    #[test, expected_failure(abort_code = claim::EInvalidPrincipals)]
    fun gate_rejects_more_than_max_principals() {
        let principals = vector::tabulate!(claim::max_principals() + 1, |_| acl::player(OUTSIDER));
        claim::requirement(principals);
    }

    #[test]
    fun principals_of_reads_every_variant() {
        let w = world();
        let principals = gate(&w);
        assert_eq!(claim::principals_of(&claim::requirement(principals)), principals);
        done(w);
    }

    #[test, expected_failure(abort_code = claim::ENotClaimGate)]
    fun principals_of_rejects_another_rule() {
        claim::principals_of(&requirement::from_config(NotAGate {}));
    }

    /// `satisfy` only takes a claim gate: another rule's requirement next in line
    /// aborts in the request.
    #[test, expected_failure(abort_code = request::EWrongRequirementType)]
    fun satisfy_rejects_another_rules_requirement() {
        let mut w = world();
        w.scenario.next_tx(SELLER);
        let auction_id = test_auction::create(
            vector[requirement::from_config(NotAGate {})],
            w.scenario.ctx(),
        );
        bid_directly(&mut w, FREELANCER, auction_id);
        done(w);
    }
}
