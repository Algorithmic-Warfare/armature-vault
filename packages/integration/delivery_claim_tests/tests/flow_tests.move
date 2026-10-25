/// End-to-end flows through `delivery_agreements` with a claim gate: each test
/// posts a gated, observed agreement, has a permitted player claim it, and
/// drives it to a terminal transition, checking every event, balance and
/// outcome record. The hauler is always the claiming player, never the OU, and
/// the OU's other board members gain nothing.
#[test_only]
module delivery_claim_tests::flow_tests;

use agreement_roles::claim;
use delivery_claim_tests::test_config::{Self, TOKEN};
use delivery_claim_tests::test_ledger::{Self, TestLedger};
use delivery_claim_tests::test_ou;
use agreements::spec::{Self, Spec};
use armature::ou::OU;
use delivery_agreements::delivery::{
    Self,
    DeliveryAgreement,
    OutcomeRecord,
    AgreementPosted,
    AgreementAccepted,
    AgreementDelivered,
    AgreementDefaulted
};
use delivery_agreements::terms;
use multicoin::multicoin::{Self, Balance};
use roles::acl::{Self, Principal};
use std::type_name;
use std::unit_test::assert_eq;
use sui::clock::{Self, Clock};
use sui::coin::Coin;
use sui::event;
use sui::test_scenario::{Self as ts, Scenario};

const LISTER: address = @0xA;
const BENEFICIARY: address = @0xC;
const HAULER_1: address = @0x11;
const HAULER_2: address = @0x12;
const FREELANCER: address = @0x21;
const NEWCOMER: address = @0x23;
const OTHER: address = @0x41;

const ITEM: u64 = 7;
const QTY: u64 = 10;
// Reward and collateral, in TOKEN.
const REWARD_QTY: u64 = 100;
const COLLATERAL_QTY: u64 = 500;

const START_MS: u64 = 1_000;
const ACCEPT_BY_MS: u64 = 5_000;
const ACCEPT_MS: u64 = 4_000; // ACCEPT_BY_MS - START_MS, posting at START_MS
const HAUL_MS: u64 = 10_000;
const ACCEPT_AT_MS: u64 = 2_000;
const DEADLINE_MS: u64 = 12_000; // ACCEPT_AT_MS + HAUL_MS

public struct World {
    scenario: Scenario,
    clock: Clock,
    haulers: ID,
    ledger: ID,
}

/// One posted agreement and its gate.
public struct Posted has drop {
    agreement_id: ID,
    gate: vector<Principal>,
}

// === Fixtures ===

fun src(): ID { object::id_from_address(@0x51) }

fun dst(): ID { object::id_from_address(@0xD5) }

fun cargo_spec(): Spec { spec::new(src(), ITEM, QTY) }

fun want(): Spec { spec::new(dst(), ITEM, QTY) }

fun mint(collection: ID, asset_id: u64, qty: u64, scenario: &mut Scenario): Balance {
    multicoin::create_balance_for_testing(collection, asset_id, qty, scenario.ctx())
}

/// The haulers OU (HAULER_1 and HAULER_2 on its board) and a ledger.
fun world(): World {
    let mut scenario = ts::begin(OTHER);
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(START_MS);
    let haulers = test_ou::make(&mut scenario, HAULER_1, vector[HAULER_1, HAULER_2]);
    scenario.next_tx(OTHER);
    let ledger = test_ledger::new(scenario.ctx());
    World { scenario, clock, haulers, ledger }
}

fun done(w: World) {
    let World { scenario, clock, .. } = w;
    clock.destroy_for_testing();
    scenario.end();
}

/// LISTER posts an observed agreement only `gate` may claim, and the posted
/// event carries the gate as its only accept requirement.
fun post(w: &mut World, gate: vector<Principal>): Posted {
    w.scenario.next_tx(LISTER);
    let cargo = mint(src(), ITEM, QTY, &mut w.scenario);
    let reward = test_config::mint(REWARD_QTY, w.scenario.ctx());
    let config = test_config::no_fees(w.scenario.ctx());
    let terms = terms::new(want(), COLLATERAL_QTY, ACCEPT_MS, HAUL_MS, BENEFICIARY);
    let mut draft = delivery::draft(
        cargo, reward, terms, &config, test_config::empty(w.scenario.ctx()), &w.clock,
        w.scenario.ctx(),
    );
    config.destroy_for_testing();
    let ledger = w.scenario.take_shared_by_id<TestLedger>(w.ledger);
    test_ledger::bind(&ledger, &mut draft);
    ts::return_shared(ledger);
    draft.require_to_accept(claim::requirement(gate));
    let cap = draft.publish();
    let (agreement_id, cap_id) = (cap.cap_agreement_id(), object::id(&cap));
    transfer::public_transfer(cap, LISTER);
    assert_eq!(
        event::events_by_type<AgreementPosted>(),
        vector[
            delivery::posted_event_for_testing(
                agreement_id, LISTER, option::none(), cap_id, BENEFICIARY, false, cargo_spec(),
                want(), test_config::token(), REWARD_QTY, COLLATERAL_QTY, ACCEPT_BY_MS, HAUL_MS,
                vector[claim::requirement(gate)], option::none(), option::some(observer(w)),
                option::none(), 0, test_config::treasury(),
            ),
        ],
    );
    Posted { agreement_id, gate }
}

fun observer(w: &World): delivery::Binding {
    delivery::new_binding_for_testing<TestLedger>(w.ledger, option::none())
}

/// `who` claims `p` at ACCEPT_AT_MS, acting as a member of `org_id` when given,
/// directly as a listed player otherwise. Checks the claimed and accepted
/// events, the cargo and that only `who` became the hauler.
fun claim_as(w: &mut World, p: &Posted, who: address, org_id: Option<ID>) {
    w.clock.set_for_testing(ACCEPT_AT_MS);
    w.scenario.next_tx(who);
    let mut agreement = w.scenario.take_shared_by_id<DeliveryAgreement<TOKEN>>(p.agreement_id);
    assert_eq!(agreement.accept_requirements(), vector[claim::requirement(p.gate)]);
    let mut req = agreement.begin_accept(&w.clock, w.scenario.ctx());
    if (org_id.is_some()) {
        let org = w.scenario.take_shared_by_id<OU>(*org_id.borrow());
        claim::satisfy(&mut req, &org);
        ts::return_shared(org);
    } else {
        claim::satisfy_directly(&mut req);
    };
    let collateral = test_config::mint(COLLATERAL_QTY, w.scenario.ctx());
    let cargo = agreement.finish_accept(req, collateral, &w.clock);
    assert_eq!(cargo.value(), QTY);
    transfer::public_transfer(cargo, who);
    let principal = if (org_id.is_some()) acl::ou(*org_id.borrow()) else acl::player(who);
    assert_eq!(
        event::events_by_type<claim::Claimed>(),
        vector[
            claim::claimed_event_for_testing(
                p.agreement_id, type_name::with_original_ids<delivery::AcceptAction>(), who,
                principal,
            ),
        ],
    );
    assert_eq!(
        event::events_by_type<AgreementAccepted>(),
        vector[
            delivery::accepted_event_for_testing(
                p.agreement_id, who, option::none(), option::none(), DEADLINE_MS,
            ),
        ],
    );
    assert_eq!(agreement.hauler(), option::some(who));
    assert_eq!(agreement.deadline_ms(), DEADLINE_MS);
    assert!(!agreement.is_open());
    ts::return_shared(agreement);
}

/// Anyone delivers the wanted balance just before the deadline.
fun deliver(w: &mut World, p: &Posted, hauler: address) {
    w.clock.set_for_testing(DEADLINE_MS - 1);
    w.scenario.next_tx(OTHER);
    let agreement = w.scenario.take_shared_by_id<DeliveryAgreement<TOKEN>>(p.agreement_id);
    agreement.deliver(mint(dst(), ITEM, QTY, &mut w.scenario), &w.clock, w.scenario.ctx());
    assert_eq!(
        event::events_by_type<AgreementDelivered>(),
        vector[
            delivery::delivered_event_for_testing(
                p.agreement_id, LISTER, hauler, option::none(), BENEFICIARY, want(),
                test_config::token(), REWARD_QTY, COLLATERAL_QTY, 0, test_config::treasury(),
            ),
        ],
    );
}

/// Total of `(collection, asset_id)` balances owned by `owner`.
fun owned(w: &mut World, owner: address, collection: ID, asset_id: u64): u64 {
    w.scenario.next_tx(OTHER);
    let mut total = 0;
    ts::ids_for_address<Balance>(owner).do!(|id| {
        let balance = w.scenario.take_from_address_by_id<Balance>(owner, id);
        if (balance.collection_id() == collection && balance.asset_id() == asset_id) {
            total = total + balance.value();
        };
        ts::return_to_address(owner, balance);
    });
    total
}

/// Total of the TOKEN coins owned by `owner`.
fun tokens(w: &mut World, owner: address): u64 {
    w.scenario.next_tx(OTHER);
    let mut total = 0;
    ts::ids_for_address<Coin<TOKEN>>(owner).do!(|id| {
        let coin = w.scenario.take_from_address_by_id<Coin<TOKEN>>(owner, id);
        total = total + coin.value();
        ts::return_to_address(owner, coin);
    });
    total
}

/// Receive the ledger's most recent outcome record and check the fields every
/// accepted, gated agreement shares: the hauler is the claiming player.
fun take_record(w: &mut World, p: &Posted, hauler: address, closed_at_ms: u64): OutcomeRecord {
    w.scenario.next_tx(OTHER);
    let mut ledger = w.scenario.take_shared_by_id<TestLedger>(w.ledger);
    let ticket = ts::most_recent_receiving_ticket<OutcomeRecord>(&w.ledger);
    let record = test_ledger::take_record(&mut ledger, ticket);
    ts::return_shared(ledger);
    assert_eq!(record.record_agreement_id(), p.agreement_id);
    assert_eq!(record.record_observer(), observer(w));
    assert_eq!(record.record_lister(), LISTER);
    assert_eq!(record.record_beneficiary(), BENEFICIARY);
    assert_eq!(record.record_hauler(), option::some(hauler));
    assert_eq!(record.record_hauler_identity(), option::none());
    assert_eq!(record.record_identity_rule(), option::none());
    assert_eq!(record.record_cargo(), cargo_spec());
    assert_eq!(record.record_want(), want());
    assert_eq!(record.record_currency(), test_config::token());
    assert_eq!(record.record_reward(), REWARD_QTY);
    assert_eq!(record.record_collateral(), option::some(COLLATERAL_QTY));
    assert_eq!(record.record_posted_at_ms(), START_MS);
    assert_eq!(record.record_deadline_ms(), DEADLINE_MS);
    assert_eq!(record.record_closed_at_ms(), closed_at_ms);
    record
}

fun assert_delivered(w: &mut World, p: &Posted, hauler: address) {
    assert_eq!(owned(w, BENEFICIARY, dst(), ITEM), QTY);
    assert_eq!(owned(w, hauler, src(), ITEM), QTY);
    assert_eq!(tokens(w, hauler), REWARD_QTY + COLLATERAL_QTY);
    assert_eq!(tokens(w, BENEFICIARY), 0);
    let record = take_record(w, p, hauler, DEADLINE_MS - 1);
    assert!(record.record_outcome().outcome_is_delivered());
    record.delete_outcome();
}

// === Flows ===

/// A board member of the listed OU claims, hauls and delivers. The reward and
/// collateral go to that member; the rest of the board gets nothing.
#[test]
fun flow_ou_member_claims_and_delivers() {
    let mut w = world();
    let haulers = w.haulers;
    let p = post(&mut w, vector[acl::ou(haulers)]);
    claim_as(&mut w, &p, HAULER_2, option::some(haulers));
    deliver(&mut w, &p, HAULER_2);
    assert_delivered(&mut w, &p, HAULER_2);
    assert_eq!(tokens(&mut w, HAULER_1), 0);
    assert_eq!(owned(&mut w, HAULER_1, src(), ITEM), 0);
    done(w);
}

/// A board member of the listed OU claims and misses the deadline: reward and
/// collateral go to the beneficiary and the member keeps the cargo.
#[test]
fun flow_ou_member_claims_then_defaults() {
    let mut w = world();
    let haulers = w.haulers;
    let p = post(&mut w, vector[acl::ou(haulers)]);
    claim_as(&mut w, &p, HAULER_1, option::some(haulers));

    w.clock.set_for_testing(DEADLINE_MS);
    w.scenario.next_tx(OTHER);
    let agreement = w.scenario.take_shared_by_id<DeliveryAgreement<TOKEN>>(p.agreement_id);
    agreement.default(&w.clock, w.scenario.ctx());
    assert_eq!(
        event::events_by_type<AgreementDefaulted>(),
        vector[
            delivery::defaulted_event_for_testing(
                p.agreement_id, LISTER, HAULER_1, option::none(), BENEFICIARY,
                test_config::token(), REWARD_QTY, COLLATERAL_QTY, false,
            ),
        ],
    );
    assert_eq!(tokens(&mut w, BENEFICIARY), REWARD_QTY + COLLATERAL_QTY);
    assert_eq!(tokens(&mut w, HAULER_1), 0);
    assert_eq!(owned(&mut w, HAULER_1, src(), ITEM), QTY);
    let record = take_record(&mut w, &p, HAULER_1, DEADLINE_MS);
    assert!(record.record_outcome().outcome_is_defaulted());
    assert!(!record.record_outcome().outcome_forfeited());
    record.delete_outcome();
    done(w);
}

/// Two agreements gated on the same OU: each board member claims and delivers
/// one, and each is paid only for their own.
#[test]
fun flow_two_ou_members_each_claim_one() {
    let mut w = world();
    let haulers = w.haulers;
    let first = post(&mut w, vector[acl::ou(haulers)]);
    let second = post(&mut w, vector[acl::ou(haulers)]);
    claim_as(&mut w, &first, HAULER_1, option::some(haulers));
    claim_as(&mut w, &second, HAULER_2, option::some(haulers));
    deliver(&mut w, &first, HAULER_1);
    assert_delivered(&mut w, &first, HAULER_1);
    deliver(&mut w, &second, HAULER_2);
    assert_eq!(owned(&mut w, BENEFICIARY, dst(), ITEM), 2 * QTY);
    assert_eq!(tokens(&mut w, HAULER_2), REWARD_QTY + COLLATERAL_QTY);
    let record = take_record(&mut w, &second, HAULER_2, DEADLINE_MS - 1);
    assert!(record.record_outcome().outcome_is_delivered());
    record.delete_outcome();
    done(w);
}

/// A player who joins the board after the agreement is posted can claim it
/// and is paid on delivery.
#[test]
fun flow_member_added_after_posting_claims_and_delivers() {
    let mut w = world();
    let haulers = w.haulers;
    let p = post(&mut w, vector[acl::ou(haulers)]);
    test_ou::add_board_member(&mut w.scenario, haulers, NEWCOMER);
    claim_as(&mut w, &p, NEWCOMER, option::some(haulers));
    deliver(&mut w, &p, NEWCOMER);
    assert_delivered(&mut w, &p, NEWCOMER);
    done(w);
}

/// A gate listing the haulers OU and a freelancer: the freelancer claims
/// directly, with no OU, and is paid on delivery.
#[test]
fun flow_listed_player_claims_directly_and_delivers() {
    let mut w = world();
    let haulers = w.haulers;
    let p = post(&mut w, vector[acl::ou(haulers), acl::player(FREELANCER)]);
    claim_as(&mut w, &p, FREELANCER, option::none());
    deliver(&mut w, &p, FREELANCER);
    assert_delivered(&mut w, &p, FREELANCER);
    done(w);
}

/// A player off the listed OU's board cannot claim, even passing that OU.
#[test, expected_failure(abort_code = claim::ENotAuthorized)]
fun flow_player_off_the_board_cannot_claim() {
    let mut w = world();
    let haulers = w.haulers;
    let p = post(&mut w, vector[acl::ou(haulers)]);
    claim_as(&mut w, &p, OTHER, option::some(haulers));
    done(w);
}

/// A board member of an OU the gate does not list cannot claim through it.
#[test, expected_failure(abort_code = claim::ENotAuthorized)]
fun flow_member_of_unlisted_ou_cannot_claim() {
    let mut w = world();
    let haulers = w.haulers;
    let p = post(&mut w, vector[acl::ou(haulers)]);
    let officers = test_ou::make(&mut w.scenario, OTHER, vector[OTHER]);
    claim_as(&mut w, &p, OTHER, option::some(officers));
    done(w);
}

/// A member removed from the board after posting can no longer claim.
#[test, expected_failure(abort_code = claim::ENotAuthorized)]
fun flow_removed_member_cannot_claim() {
    let mut w = world();
    let haulers = w.haulers;
    let p = post(&mut w, vector[acl::ou(haulers)]);
    test_ou::remove_board_member(&mut w.scenario, haulers, HAULER_2);
    claim_as(&mut w, &p, HAULER_2, option::some(haulers));
    done(w);
}
