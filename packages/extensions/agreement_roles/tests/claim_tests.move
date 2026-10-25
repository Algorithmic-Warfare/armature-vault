/// Scenario: agreements gated on the haulers OU's board, one freelancer and a
/// courier bot. The officers OU is a second OU that is not listed.
#[test_only]
module agreement_roles::claim_tests;

use agreement_roles::claim;
use agreement_roles::test_config::{Self, TOKEN};
use agreement_roles::test_ou;
use agreements::request::{Self, Request};
use agreements::requirement;
use agreements::spec;
use armature::ou::OU;
use delivery_agreements::delivery::{Self, DeliveryAgreement, Draft};
use delivery_agreements::config;
use multicoin::multicoin::{Self, Balance};
use roles::acl::{Self, Principal};
use std::unit_test::assert_eq;
use sui::clock::{Self, Clock};
use sui::coin::{Self, Coin};
use sui::test_scenario::{Self as ts, Scenario};

const LISTER: address = @0xA;
const BENEFICIARY: address = @0xC;
const HAULER_1: address = @0x11;
const HAULER_2: address = @0x12;
const FREELANCER: address = @0x21;
const BOT: address = @0x22;
const OFFICER: address = @0x31;
const OUTSIDER: address = @0x41;

const ITEM: u64 = 7;
const QTY: u64 = 10;
// Reward and collateral in TOKEN, the posting fee in FEE.
const REWARD_QTY: u64 = 100;
const COLLATERAL_QTY: u64 = 500;
const POST_FEE_QTY: u64 = 7;
const DELIVERY_FEE_BPS: u16 = 250;
const START_MS: u64 = 1_000;
const ACCEPT_BY_MS: u64 = 5_000;
const HAUL_MS: u64 = 10_000;

public struct World {
    scenario: Scenario,
    clock: Clock,
    haulers: ID,
    officers: ID,
}

/// A requirement of some other rule, for `principals_of`.
public struct NotAGate has drop {}

/// The coin the posting fee is charged in. Not an approved currency.
public struct FEE has drop {}

// === Fixtures ===

fun src(): ID { object::id_from_address(@0x51) }

fun dst(): ID { object::id_from_address(@0xD5) }

fun mint(collection: ID, asset_id: u64, qty: u64, scenario: &mut Scenario): Balance {
    multicoin::create_balance_for_testing(collection, asset_id, qty, scenario.ctx())
}

/// Two OUs. No agreement yet.
fun world(): World {
    let mut scenario = ts::begin(OFFICER);
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(START_MS);
    let haulers = test_ou::make(&mut scenario, HAULER_1, vector[HAULER_1, HAULER_2]);
    let officers = test_ou::make(&mut scenario, OFFICER, vector[OFFICER]);
    World { scenario, clock, haulers, officers }
}

/// The standard gate: the haulers OU's board, the freelancer and the bot.
fun gate(w: &World): vector<Principal> {
    vector[acl::ou(w.haulers), acl::player(FREELANCER), acl::machine(BOT)]
}

/// Start a LISTER transaction drafting the standard agreement.
fun new_draft(w: &mut World): Draft<TOKEN> {
    w.scenario.next_tx(LISTER);
    let cargo = mint(src(), ITEM, QTY, &mut w.scenario);
    let reward = test_config::mint(REWARD_QTY, w.scenario.ctx());
    let config = test_config::no_fees(w.scenario.ctx());
    let draft = delivery::draft(
        cargo, reward, spec::new(dst(), ITEM, QTY), COLLATERAL_QTY, ACCEPT_BY_MS, HAUL_MS,
        BENEFICIARY, &config, test_config::empty(w.scenario.ctx()), &w.clock, w.scenario.ctx(),
    );
    config.destroy_for_testing();
    draft
}

fun publish(w: &mut World, draft: Draft<TOKEN>) {
    let cap = draft.publish(w.scenario.ctx());
    transfer::public_transfer(cap, LISTER);
}

/// LISTER posts an agreement only `principals` may accept.
fun post(w: &mut World, principals: vector<Principal>) {
    let mut draft = new_draft(w);
    claim::require_to_claim(&mut draft, principals);
    publish(w, draft);
}

/// `who` claims, acting as a member of `org_id`.
fun claim_as_member(w: &mut World, who: address, org_id: ID) {
    w.scenario.next_tx(who);
    let org = w.scenario.take_shared_by_id<OU>(org_id);
    let agreement = w.scenario.take_shared<DeliveryAgreement<TOKEN>>();
    let mut req = agreement.begin_accept(&w.clock, w.scenario.ctx());
    claim::satisfy(&mut req, &org);
    finish_accept(w, agreement, req, who);
    ts::return_shared(org);
}

/// `who` claims as a listed `Player` or `Machine`.
fun claim_directly(w: &mut World, who: address) {
    w.scenario.next_tx(who);
    let agreement = w.scenario.take_shared<DeliveryAgreement<TOKEN>>();
    let mut req = agreement.begin_accept(&w.clock, w.scenario.ctx());
    claim::satisfy_directly(&mut req);
    finish_accept(w, agreement, req, who);
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

// === Reserving for one player ===

#[test]
fun post_for_reserves_for_one_player() {
    let mut w = world();
    w.scenario.next_tx(LISTER);
    let cargo = mint(src(), ITEM, QTY, &mut w.scenario);
    let reward = test_config::mint(REWARD_QTY, w.scenario.ctx());
    let config = test_config::no_fees(w.scenario.ctx());
    let cap = claim::post_for(
        cargo, reward, spec::new(dst(), ITEM, QTY), COLLATERAL_QTY, ACCEPT_BY_MS, HAUL_MS,
        BENEFICIARY, vector[acl::player(FREELANCER)], &config,
        test_config::empty(w.scenario.ctx()), &w.clock, w.scenario.ctx(),
    );
    config.destroy_for_testing();
    transfer::public_transfer(cap, LISTER);

    w.scenario.next_tx(OUTSIDER);
    let agreement = w.scenario.take_shared<DeliveryAgreement<TOKEN>>();
    let reqs = agreement.accept_requirements();
    assert_eq!(reqs.length(), 1);
    assert_eq!(claim::principals_of(&reqs[0]), vector[acl::player(FREELANCER)]);
    ts::return_shared(agreement);

    claim_directly(&mut w, FREELANCER);
    assert_eq!(hauler_of(&mut w), option::some(FREELANCER));
    done(w);
}

/// `post_for` charges the posting fee like `draft`, and the agreement keeps the
/// config's delivery rate and treasury.
#[test]
fun post_for_charges_the_posting_fee() {
    let mut w = world();
    w.scenario.next_tx(LISTER);
    let cargo = mint(src(), ITEM, QTY, &mut w.scenario);
    let reward = test_config::mint(REWARD_QTY, w.scenario.ctx());
    let post_fee = config::post_fee_for_testing<FEE>(POST_FEE_QTY);
    let mut config = config::new_for_testing(
        option::some(post_fee), DELIVERY_FEE_BPS, test_config::treasury(), w.scenario.ctx(),
    );
    config.approve_for_testing<TOKEN>();
    let cap = claim::post_for(
        cargo, reward, spec::new(dst(), ITEM, QTY), COLLATERAL_QTY, ACCEPT_BY_MS, HAUL_MS,
        BENEFICIARY, vector[acl::player(FREELANCER)], &config,
        coin::mint_for_testing<FEE>(POST_FEE_QTY, w.scenario.ctx()), &w.clock, w.scenario.ctx(),
    );
    config.destroy_for_testing();
    transfer::public_transfer(cap, LISTER);

    w.scenario.next_tx(OUTSIDER);
    let agreement = w.scenario.take_shared<DeliveryAgreement<TOKEN>>();
    assert_eq!(agreement.post_fee(), option::some(post_fee));
    assert_eq!(agreement.delivery_fee_bps(), DELIVERY_FEE_BPS);
    assert_eq!(agreement.treasury(), test_config::treasury());
    ts::return_shared(agreement);
    let paid = w.scenario.take_from_address<Coin<FEE>>(test_config::treasury());
    assert_eq!(paid.value(), POST_FEE_QTY);
    ts::return_to_address(test_config::treasury(), paid);
    done(w);
}

/// `post_for` drafts like `draft`, so the reward's coin must be approved.
#[test, expected_failure(abort_code = config::ECurrencyNotApproved)]
fun post_for_rejects_unapproved_currency() {
    let mut w = world();
    w.scenario.next_tx(LISTER);
    let cargo = mint(src(), ITEM, QTY, &mut w.scenario);
    let reward = coin::mint_for_testing<FEE>(REWARD_QTY, w.scenario.ctx());
    let config = test_config::no_fees(w.scenario.ctx());
    let cap = claim::post_for(
        cargo, reward, spec::new(dst(), ITEM, QTY), COLLATERAL_QTY, ACCEPT_BY_MS, HAUL_MS,
        BENEFICIARY, vector[acl::player(FREELANCER)], &config,
        test_config::empty(w.scenario.ctx()), &w.clock, w.scenario.ctx(),
    );
    config.destroy_for_testing();
    transfer::public_transfer(cap, LISTER);
    done(w);
}

#[test, expected_failure(abort_code = claim::ENotAuthorized)]
fun reservation_rejects_another_player() {
    let mut w = world();
    post(&mut w, vector[acl::player(FREELANCER)]);
    claim_directly(&mut w, OUTSIDER);
    done(w);
}

// === Claiming through each principal ===

#[test]
fun board_member_of_listed_ou_claims() {
    let mut w = world();
    let principals = gate(&w);
    post(&mut w, principals);
    let haulers = w.haulers;
    claim_as_member(&mut w, HAULER_2, haulers);
    assert_eq!(hauler_of(&mut w), option::some(HAULER_2));
    done(w);
}

#[test]
fun listed_player_claims_without_an_ou() {
    let mut w = world();
    let principals = gate(&w);
    post(&mut w, principals);
    claim_directly(&mut w, FREELANCER);
    assert_eq!(hauler_of(&mut w), option::some(FREELANCER));
    done(w);
}

#[test]
fun listed_machine_claims_without_an_ou() {
    let mut w = world();
    let principals = gate(&w);
    post(&mut w, principals);
    claim_directly(&mut w, BOT);
    assert_eq!(hauler_of(&mut w), option::some(BOT));
    done(w);
}

/// `satisfy` also matches listed players, whatever OU they pass.
#[test]
fun listed_player_claims_while_passing_any_ou() {
    let mut w = world();
    let principals = gate(&w);
    post(&mut w, principals);
    let officers = w.officers;
    claim_as_member(&mut w, FREELANCER, officers);
    assert_eq!(hauler_of(&mut w), option::some(FREELANCER));
    done(w);
}

#[test, expected_failure(abort_code = claim::ENotAuthorized)]
fun outsider_is_rejected() {
    let mut w = world();
    let principals = gate(&w);
    post(&mut w, principals);
    let haulers = w.haulers;
    claim_as_member(&mut w, OUTSIDER, haulers);
    done(w);
}

#[test, expected_failure(abort_code = claim::ENotAuthorized)]
fun board_member_of_unlisted_ou_is_rejected() {
    let mut w = world();
    let principals = gate(&w);
    post(&mut w, principals);
    let officers = w.officers;
    claim_as_member(&mut w, OFFICER, officers);
    done(w);
}

#[test, expected_failure(abort_code = claim::ENotAuthorized)]
fun ou_member_cannot_claim_directly() {
    let mut w = world();
    let principals = gate(&w);
    post(&mut w, principals);
    claim_directly(&mut w, HAULER_1);
    done(w);
}

/// OU principals are read at claim time, so leaving the board after posting
/// removes the right to claim.
#[test, expected_failure(abort_code = claim::ENotAuthorized)]
fun removed_board_member_loses_access() {
    let mut w = world();
    let principals = gate(&w);
    post(&mut w, principals);
    let haulers = w.haulers;
    test_ou::remove_board_member(&mut w.scenario, haulers, HAULER_1);
    claim_as_member(&mut w, HAULER_1, haulers);
    done(w);
}

/// Joining the board after posting grants the right to claim.
#[test]
fun added_board_member_gains_access() {
    let mut w = world();
    let haulers = w.haulers;
    post(&mut w, vector[acl::ou(haulers)]);
    test_ou::add_board_member(&mut w.scenario, haulers, OUTSIDER);
    claim_as_member(&mut w, OUTSIDER, haulers);
    assert_eq!(hauler_of(&mut w), option::some(OUTSIDER));
    done(w);
}

// === Gating on an OU alone ===

/// `post_for` with only an OU: any of its board members may claim, and the
/// hauler is the member, not the OU.
#[test]
fun post_for_ou_lets_a_board_member_claim() {
    let mut w = world();
    w.scenario.next_tx(LISTER);
    let cargo = mint(src(), ITEM, QTY, &mut w.scenario);
    let reward = test_config::mint(REWARD_QTY, w.scenario.ctx());
    let config = test_config::no_fees(w.scenario.ctx());
    let cap = claim::post_for(
        cargo, reward, spec::new(dst(), ITEM, QTY), COLLATERAL_QTY, ACCEPT_BY_MS, HAUL_MS,
        BENEFICIARY, vector[acl::ou(w.haulers)], &config, test_config::empty(w.scenario.ctx()),
        &w.clock, w.scenario.ctx(),
    );
    config.destroy_for_testing();
    transfer::public_transfer(cap, LISTER);
    let haulers = w.haulers;
    claim_as_member(&mut w, HAULER_1, haulers);
    assert_eq!(hauler_of(&mut w), option::some(HAULER_1));
    done(w);
}

/// Each listed OU admits its own board: here the second of two.
#[test]
fun board_member_of_any_listed_ou_claims() {
    let mut w = world();
    let principals = vector[acl::ou(w.officers), acl::ou(w.haulers)];
    post(&mut w, principals);
    let haulers = w.haulers;
    claim_as_member(&mut w, HAULER_2, haulers);
    assert_eq!(hauler_of(&mut w), option::some(HAULER_2));
    done(w);
}

/// A player who is not on the listed OU's board cannot claim by passing it.
#[test, expected_failure(abort_code = claim::ENotAuthorized)]
fun ou_gate_rejects_player_off_the_board() {
    let mut w = world();
    let haulers = w.haulers;
    post(&mut w, vector[acl::ou(haulers)]);
    claim_as_member(&mut w, FREELANCER, haulers);
    done(w);
}

/// A member of both the listed OU and another must act as the listed one:
/// being on the passed OU's board is not enough.
#[test, expected_failure(abort_code = claim::ENotAuthorized)]
fun board_member_passing_another_ou_is_rejected() {
    let mut w = world();
    let (haulers, officers) = (w.haulers, w.officers);
    post(&mut w, vector[acl::ou(haulers)]);
    test_ou::add_board_member(&mut w.scenario, officers, HAULER_1);
    claim_as_member(&mut w, HAULER_1, officers);
    done(w);
}

#[test, expected_failure(abort_code = request::ERequestNotComplete)]
fun plain_accept_cannot_skip_the_gate() {
    let mut w = world();
    let principals = gate(&w);
    post(&mut w, principals);
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
    post(&mut w, vector[acl::ou(haulers)]);
    w.scenario.next_tx(HAULER_1);
    let agreement = w.scenario.take_shared<DeliveryAgreement<TOKEN>>();
    let req = agreement.begin_accept(&w.clock, w.scenario.ctx());
    finish_accept(&mut w, agreement, req, HAULER_1);
    done(w);
}

/// Two gates on one agreement must both pass: here, a haulers board member who
/// is also individually named.
#[test]
fun gates_compose_as_and() {
    let mut w = world();
    let mut draft = new_draft(&mut w);
    claim::require_to_claim(&mut draft, vector[acl::ou(w.haulers)]);
    claim::require_to_claim(&mut draft, vector[acl::player(HAULER_1)]);
    publish(&mut w, draft);
    w.scenario.next_tx(HAULER_1);
    let org = w.scenario.take_shared_by_id<OU>(w.haulers);
    let agreement = w.scenario.take_shared<DeliveryAgreement<TOKEN>>();
    let mut req = agreement.begin_accept(&w.clock, w.scenario.ctx());
    claim::satisfy(&mut req, &org);
    claim::satisfy_directly(&mut req);
    finish_accept(&mut w, agreement, req, HAULER_1);
    ts::return_shared(org);
    assert_eq!(hauler_of(&mut w), option::some(HAULER_1));
    done(w);
}

#[test, expected_failure(abort_code = claim::ENotAuthorized)]
fun second_gate_rejects_unnamed_board_member() {
    let mut w = world();
    let mut draft = new_draft(&mut w);
    claim::require_to_claim(&mut draft, vector[acl::ou(w.haulers)]);
    claim::require_to_claim(&mut draft, vector[acl::player(HAULER_1)]);
    publish(&mut w, draft);
    w.scenario.next_tx(HAULER_2);
    let org = w.scenario.take_shared_by_id<OU>(w.haulers);
    let agreement = w.scenario.take_shared<DeliveryAgreement<TOKEN>>();
    let mut req = agreement.begin_accept(&w.clock, w.scenario.ctx());
    claim::satisfy(&mut req, &org);
    claim::satisfy_directly(&mut req);
    finish_accept(&mut w, agreement, req, HAULER_2);
    ts::return_shared(org);
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
    let mut draft = new_draft(&mut w);
    draft.require_to_accept(requirement::from_config(NotAGate {}));
    publish(&mut w, draft);
    w.scenario.next_tx(FREELANCER);
    let agreement = w.scenario.take_shared<DeliveryAgreement<TOKEN>>();
    let mut req = agreement.begin_accept(&w.clock, w.scenario.ctx());
    claim::satisfy_directly(&mut req);
    req.destroy_for_testing();
    ts::return_shared(agreement);
    done(w);
}
