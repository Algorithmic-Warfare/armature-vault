/// The claim gate on an agreement type other than delivery: `test_auction`,
/// built only on `agreements`. The same `claim::requirement` gates its bids,
/// with OU boards read live, and requests stay bound to their own agreement
/// type.
#[test_only]
module agreement_roles::any_agreement_tests;

use agreement_roles::claim;
use agreement_roles::test_auction::{Self, Auction, Bid};
use agreement_roles::test_config::{Self, TOKEN};
use agreement_roles::test_ou;
use agreements::request;
use agreements::spec;
use armature::ou::OU;
use delivery_agreements::delivery::{Self, DeliveryAgreement};
use delivery_agreements::terms;
use multicoin::multicoin;
use roles::acl::{Self, Principal};
use std::type_name;
use std::unit_test::assert_eq;
use sui::clock;
use sui::event;
use sui::test_scenario::{Self as ts, Scenario};

const SELLER: address = @0xA;
const MEMBER_1: address = @0x11;
const MEMBER_2: address = @0x12;
const FREELANCER: address = @0x21;
const BOT: address = @0x22;
const OUTSIDER: address = @0x41;

/// The bidders' OU (MEMBER_1 and MEMBER_2) and an auction gated on its board,
/// the freelancer and the bot. Returns `(scenario, ou_id, auction_id)`.
fun setup(): (Scenario, ID, ID) {
    let mut sc = ts::begin(SELLER);
    let bidders = test_ou::make(&mut sc, MEMBER_1, vector[MEMBER_1, MEMBER_2]);
    sc.next_tx(SELLER);
    let gate = claim::requirement(
        vector[acl::ou(bidders), acl::player(FREELANCER), acl::machine(BOT)],
    );
    let auction_id = test_auction::create(vector[gate], sc.ctx());
    (sc, bidders, auction_id)
}

/// `who` bids as a board member of `ou_id`; the claim must record that OU.
fun bid_as_member(sc: &mut Scenario, who: address, ou_id: ID, auction_id: ID) {
    bid_through(sc, who, option::some(ou_id), auction_id);
    assert_claimed(who, acl::ou(ou_id), auction_id);
}

/// `who` bids as the listed `principal`, with no OU.
fun bid_directly(sc: &mut Scenario, who: address, principal: Principal, auction_id: ID) {
    bid_through(sc, who, option::none(), auction_id);
    assert_claimed(who, principal, auction_id);
}

fun bid_through(sc: &mut Scenario, who: address, ou_id: Option<ID>, auction_id: ID) {
    sc.next_tx(who);
    let mut auction = sc.take_shared_by_id<Auction>(auction_id);
    let mut req = auction.begin_bid(sc.ctx());
    if (ou_id.is_some()) {
        let org = sc.take_shared_by_id<OU>(*ou_id.borrow());
        claim::satisfy(&mut req, &org);
        ts::return_shared(org);
    } else {
        claim::satisfy_directly(&mut req);
    };
    auction.finish_bid(req);
    ts::return_shared(auction);
}

/// The bid's claim event names the auction, the `Bid` action, `who` and the
/// principal they matched.
fun assert_claimed(who: address, principal: Principal, auction_id: ID) {
    assert_eq!(
        event::events_by_type<claim::Claimed>(),
        vector[
            claim::claimed_event_for_testing(
                auction_id, type_name::with_original_ids<Bid>(), who, principal,
            ),
        ],
    );
}

fun last_bidder(sc: &mut Scenario, auction_id: ID): Option<address> {
    sc.next_tx(OUTSIDER);
    let auction = sc.take_shared_by_id<Auction>(auction_id);
    let bidder = auction.last_bidder();
    ts::return_shared(auction);
    bidder
}

#[test]
fun board_members_and_listed_keys_can_bid() {
    let (mut sc, bidders, auction_id) = setup();
    bid_as_member(&mut sc, MEMBER_1, bidders, auction_id);
    assert_eq!(last_bidder(&mut sc, auction_id), option::some(MEMBER_1));
    bid_as_member(&mut sc, MEMBER_2, bidders, auction_id);
    assert_eq!(last_bidder(&mut sc, auction_id), option::some(MEMBER_2));
    bid_directly(&mut sc, FREELANCER, acl::player(FREELANCER), auction_id);
    assert_eq!(last_bidder(&mut sc, auction_id), option::some(FREELANCER));
    bid_directly(&mut sc, BOT, acl::machine(BOT), auction_id);
    assert_eq!(last_bidder(&mut sc, auction_id), option::some(BOT));
    sc.end();
}

/// The board is read at bid time: a member added after the auction was
/// created can bid, and a removed member cannot.
#[test]
fun board_changes_apply_to_an_open_auction() {
    let (mut sc, bidders, auction_id) = setup();
    test_ou::add_board_member(&mut sc, bidders, OUTSIDER);
    bid_as_member(&mut sc, OUTSIDER, bidders, auction_id);
    assert_eq!(last_bidder(&mut sc, auction_id), option::some(OUTSIDER));
    sc.end();
}

/// A board member who is also listed directly matches whichever principal is
/// listed first, and the claim event records that one.
#[test]
fun claim_records_the_first_matching_principal() {
    let (mut sc, bidders, _) = setup();
    sc.next_tx(SELLER);
    let player_first = test_auction::create(
        vector[claim::requirement(vector[acl::player(MEMBER_1), acl::ou(bidders)])],
        sc.ctx(),
    );
    let ou_first = test_auction::create(
        vector[claim::requirement(vector[acl::ou(bidders), acl::player(MEMBER_1)])],
        sc.ctx(),
    );
    bid_through(&mut sc, MEMBER_1, option::some(bidders), player_first);
    assert_claimed(MEMBER_1, acl::player(MEMBER_1), player_first);
    bid_through(&mut sc, MEMBER_1, option::some(bidders), ou_first);
    assert_claimed(MEMBER_1, acl::ou(bidders), ou_first);
    sc.end();
}

#[test, expected_failure(abort_code = claim::ENotAuthorized)]
fun removed_member_cannot_bid() {
    let (mut sc, bidders, auction_id) = setup();
    test_ou::remove_board_member(&mut sc, bidders, MEMBER_2);
    bid_as_member(&mut sc, MEMBER_2, bidders, auction_id);
    sc.end();
}

#[test, expected_failure(abort_code = claim::ENotAuthorized)]
fun outsider_cannot_bid() {
    let (mut sc, _, auction_id) = setup();
    bid_directly(&mut sc, OUTSIDER, acl::player(OUTSIDER), auction_id);
    sc.end();
}

/// A member of an unlisted OU cannot bid by passing that OU.
#[test, expected_failure(abort_code = claim::ENotAuthorized)]
fun member_of_another_ou_cannot_bid() {
    let (mut sc, _, auction_id) = setup();
    let others = test_ou::make(&mut sc, OUTSIDER, vector[OUTSIDER]);
    bid_as_member(&mut sc, OUTSIDER, others, auction_id);
    sc.end();
}

/// A bid cannot skip the gate.
#[test, expected_failure(abort_code = request::ERequestNotComplete)]
fun bid_cannot_skip_the_gate() {
    let (mut sc, _, auction_id) = setup();
    sc.next_tx(MEMBER_1);
    let mut auction = sc.take_shared_by_id<Auction>(auction_id);
    let req = auction.begin_bid(sc.ctx());
    auction.finish_bid(req);
    abort
}

/// A delivery accept request that passed the same gate still cannot place a
/// bid: a request completes only on the agreement it was opened for.
#[test, expected_failure(abort_code = request::EWrongAgreement)]
fun delivery_request_cannot_complete_a_bid() {
    let (mut sc, bidders, auction_id) = setup();
    let mut clk = clock::create_for_testing(sc.ctx());
    clk.set_for_testing(1_000);
    sc.next_tx(SELLER);
    let (src, dst) = (object::id_from_address(@0x70), object::id_from_address(@0x71));
    let config = test_config::no_fees(sc.ctx());
    let mut draft = delivery::draft(
        multicoin::create_balance_for_testing(src, 0, 1, sc.ctx()),
        test_config::mint(1, sc.ctx()),
        terms::new(spec::new(dst, 0, 1), 1, 4_000, 10_000, SELLER),
        &config,
        test_config::empty(sc.ctx()),
        &clk,
        sc.ctx(),
    );
    config.destroy_for_testing();
    claim::require_to_claim(&mut draft, vector[acl::ou(bidders)]);
    transfer::public_transfer(draft.publish(), SELLER);

    sc.next_tx(MEMBER_1);
    let org = sc.take_shared_by_id<OU>(bidders);
    let agreement = sc.take_shared<DeliveryAgreement<TOKEN>>();
    let mut auction = sc.take_shared_by_id<Auction>(auction_id);
    let mut req = agreement.begin_accept(&clk, sc.ctx());
    claim::satisfy(&mut req, &org);
    auction.finish_bid(req);
    abort
}
