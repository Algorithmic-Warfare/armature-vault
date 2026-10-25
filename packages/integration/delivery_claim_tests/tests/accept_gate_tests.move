/// A claim gate attached as a delivery accept requirement: what the posted
/// agreement records, and that no accept path can skip it. The gate's own
/// checks are tested in agreement_roles.
#[test_only]
module delivery_claim_tests::accept_gate_tests;

use agreement_roles::claim;
use agreement_roles::test_ou;
use agreements::request::{Self, Request};
use agreements::spec;
use armature::ou::OU;
use delivery_agreements::delivery::{DeliveryAgreement, Draft};
use delivery_agreements::test_config::{Self, TOKEN};
use delivery_agreements::terms::{Self, Terms};
use multicoin::multicoin;
use roles::acl::{Self, Principal};
use std::unit_test::assert_eq;
use sui::clock::{Self, Clock};
use sui::test_scenario::{Self as ts, Scenario};

const LISTER: address = @0xA;
const BENEFICIARY: address = @0xC;
const HAULER_1: address = @0x11;
const HAULER_2: address = @0x12;
const FREELANCER: address = @0x21;
const OUTSIDER: address = @0x41;

const ITEM: u64 = 7;
const QTY: u64 = 10;
const REWARD_QTY: u64 = 100;
const COLLATERAL_QTY: u64 = 500;
const START_MS: u64 = 1_000;
const ACCEPT_MS: u64 = 4_000;
const HAUL_MS: u64 = 10_000;

public struct World {
    scenario: Scenario,
    clock: Clock,
    haulers: ID,
}

// === Fixtures ===

fun src(): ID { object::id_from_address(@0x51) }

fun dst(): ID { object::id_from_address(@0xD5) }

/// The haulers OU, with HAULER_1 and HAULER_2 on its board.
fun world(): World {
    let mut scenario = ts::begin(OUTSIDER);
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(START_MS);
    let haulers = test_ou::make(&mut scenario, HAULER_1, vector[HAULER_1, HAULER_2]);
    World { scenario, clock, haulers }
}

/// The standard want and windows, paying BENEFICIARY.
fun standard_terms(): Terms {
    terms::new(spec::new(dst(), ITEM, QTY), COLLATERAL_QTY, ACCEPT_MS, HAUL_MS, BENEFICIARY)
}

/// Start a LISTER transaction drafting an agreement on `terms`.
fun new_draft(w: &mut World, terms: Terms): Draft<TOKEN> {
    w.scenario.next_tx(LISTER);
    let cargo = multicoin::create_balance_for_testing(src(), ITEM, QTY, w.scenario.ctx());
    let reward = test_config::mint(REWARD_QTY, w.scenario.ctx());
    test_config::draft_with_terms(cargo, reward, terms, &w.clock, w.scenario.ctx())
}

/// LISTER posts an agreement on `terms` only `principals` may accept, and
/// returns the cap's address.
fun post(w: &mut World, terms: Terms, principals: vector<Principal>): address {
    let mut draft = new_draft(w, terms);
    draft.require_to_accept(claim::requirement(principals));
    let cap = draft.publish();
    let cap_address = object::id(&cap).to_address();
    transfer::public_transfer(cap, LISTER);
    cap_address
}

fun finish_accept(
    w: &mut World,
    mut agreement: DeliveryAgreement<TOKEN>,
    req: Request,
    who: address,
) {
    let collateral = test_config::mint(COLLATERAL_QTY, w.scenario.ctx());
    let cargo = agreement.finish_accept(req, collateral, &w.clock);
    transfer::public_transfer(cargo, who);
    ts::return_shared(agreement);
}

fun hauler_of(w: &mut World): Option<address> {
    w.scenario.next_tx(OUTSIDER);
    let agreement = w.scenario.take_shared<DeliveryAgreement<TOKEN>>();
    let hauler = agreement.hauler();
    ts::return_shared(agreement);
    hauler
}

fun done(w: World) {
    let World { scenario, clock, .. } = w;
    clock.destroy_for_testing();
    scenario.end();
}

// === Attaching the gate ===

/// One `Player` reserves the agreement: the gate is its only accept
/// requirement, it decodes back to that player, and only they can claim.
#[test]
fun gate_reserves_an_agreement_for_one_player() {
    let mut w = world();
    post(&mut w, standard_terms(), vector[acl::player(FREELANCER)]);

    w.scenario.next_tx(OUTSIDER);
    let agreement = w.scenario.take_shared<DeliveryAgreement<TOKEN>>();
    let reqs = agreement.accept_requirements();
    assert_eq!(reqs.length(), 1);
    assert_eq!(claim::principals_of(&reqs[0]), vector[acl::player(FREELANCER)]);
    ts::return_shared(agreement);

    w.scenario.next_tx(FREELANCER);
    let agreement = w.scenario.take_shared<DeliveryAgreement<TOKEN>>();
    let mut req = agreement.begin_accept(&w.clock, w.scenario.ctx());
    claim::satisfy_directly(&mut req);
    finish_accept(&mut w, agreement, req, FREELANCER);
    assert_eq!(hauler_of(&mut w), option::some(FREELANCER));
    done(w);
}

/// A gate keeps the terms it is posted on, so a wrapper can limit an agreement
/// to an OU's board and have its payouts go to the cap it holds.
#[test]
fun gate_keeps_terms_that_pay_the_cap_holder() {
    let mut w = world();
    let terms = terms::new_for_cap_holder(
        spec::new(dst(), ITEM, QTY), COLLATERAL_QTY, ACCEPT_MS, HAUL_MS,
    );
    let haulers = w.haulers;
    let cap_address = post(&mut w, terms, vector[acl::ou(haulers)]);

    w.scenario.next_tx(OUTSIDER);
    let agreement = w.scenario.take_shared<DeliveryAgreement<TOKEN>>();
    assert_eq!(agreement.terms(), terms);
    assert_eq!(agreement.beneficiary(), cap_address);
    ts::return_shared(agreement);

    w.scenario.next_tx(HAULER_1);
    let org = w.scenario.take_shared_by_id<OU>(haulers);
    let agreement = w.scenario.take_shared<DeliveryAgreement<TOKEN>>();
    let mut req = agreement.begin_accept(&w.clock, w.scenario.ctx());
    claim::satisfy(&mut req, &org);
    finish_accept(&mut w, agreement, req, HAULER_1);
    ts::return_shared(org);
    assert_eq!(hauler_of(&mut w), option::some(HAULER_1));
    done(w);
}

// === No accept path skips it ===

#[test, expected_failure(abort_code = request::ERequestNotComplete)]
fun plain_accept_cannot_skip_the_gate() {
    let mut w = world();
    post(&mut w, standard_terms(), vector[acl::player(HAULER_1)]);
    w.scenario.next_tx(HAULER_1);
    let mut agreement = w.scenario.take_shared<DeliveryAgreement<TOKEN>>();
    let collateral = test_config::mint(COLLATERAL_QTY, w.scenario.ctx());
    let cargo = agreement.accept(collateral, &w.clock, w.scenario.ctx());
    transfer::public_transfer(cargo, HAULER_1);
    ts::return_shared(agreement);
    done(w);
}

/// `begin_accept` straight into `finish_accept` cannot skip the gate either.
#[test, expected_failure(abort_code = request::ERequestNotComplete)]
fun finish_accept_cannot_skip_the_gate() {
    let mut w = world();
    let haulers = w.haulers;
    post(&mut w, standard_terms(), vector[acl::ou(haulers)]);
    w.scenario.next_tx(HAULER_1);
    let agreement = w.scenario.take_shared<DeliveryAgreement<TOKEN>>();
    let req = agreement.begin_accept(&w.clock, w.scenario.ctx());
    finish_accept(&mut w, agreement, req, HAULER_1);
    done(w);
}
