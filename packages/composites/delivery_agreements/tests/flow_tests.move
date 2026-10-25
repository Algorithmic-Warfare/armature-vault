/// End-to-end flows: each test drives one agreement from `draft` to a terminal
/// transition and checks every balance, event, view and outcome record along
/// the way. Also covers the defensive re-checks in `finish_accept` and the
/// `request` aborts an accept can hit.
#[test_only]
module delivery_agreements::flow_tests;

use agreements::request;
use agreements::spec::{Self, Spec};
use delivery_agreements::delivery::{
    Self,
    DeliveryAgreement,
    Draft,
    ListerCap,
    OutcomeRecord,
    AgreementPosted,
    AgreementAccepted,
    AgreementDelivered,
    AgreementDefaulted,
    AgreementCancelled
};
use delivery_agreements::terms;
use delivery_agreements::test_extensions::{Self as ext, Ledger, Character};
use delivery_agreements::test_config::{Self, TOKEN};
use multicoin::multicoin::{Self, Balance};
use std::type_name;
use std::unit_test::assert_eq;
use sui::clock::{Self, Clock};
use sui::event;
use sui::test_scenario::{Self as ts, Scenario};

const LISTER: address = @0xA;
const HAULER: address = @0xB;
const BENEFICIARY: address = @0xC;
const OTHER: address = @0xD;
const TREASURY: address = @0xF;

const ITEM: u64 = 7;
const CARGO_QTY: u64 = 10;
// Reward and collateral, in TOKEN.
const REWARD_QTY: u64 = 100;
const COLLATERAL_QTY: u64 = 500;
// The observer's fee, a multicoin balance paid to TREASURY.
const FEE_ASSET: u64 = 0;
const FEE_QTY: u64 = 3;

const START_MS: u64 = 1_000;
const ACCEPT_BY_MS: u64 = 5_000;
const ACCEPT_MS: u64 = 4_000; // ACCEPT_BY_MS - START_MS, posting at START_MS
const HAUL_MS: u64 = 10_000;
const ACCEPT_AT_MS: u64 = 2_000;
const DEADLINE_MS: u64 = 12_000; // ACCEPT_AT_MS + HAUL_MS

// === Fixtures ===

fun src(): ID { object::id_from_address(@0x51) }

fun dst(): ID { object::id_from_address(@0xD5) }

fun fee_collection(): ID { object::id_from_address(@0x70) }

fun character_id(): ID { object::id_from_address(@0xC4A) }

fun mint(collection: ID, asset_id: u64, qty: u64, scenario: &mut Scenario): Balance {
    multicoin::create_balance_for_testing(collection, asset_id, qty, scenario.ctx())
}

fun want(): Spec { spec::new(dst(), ITEM, CARGO_QTY) }

fun cargo_spec(): Spec { spec::new(src(), ITEM, CARGO_QTY) }

fun fee_spec(): Spec { spec::new(fee_collection(), FEE_ASSET, FEE_QTY) }

fun setup(): (Scenario, Clock) {
    let mut scenario = ts::begin(LISTER);
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(START_MS);
    (scenario, clock)
}

fun finish(scenario: Scenario, clock: Clock) {
    clock.destroy_for_testing();
    scenario.end();
}

fun create_ledger(scenario: &mut Scenario): ID {
    scenario.next_tx(OTHER);
    ext::new_ledger(TREASURY, scenario.ctx())
}

/// Start a new LISTER transaction drafting the standard agreement.
fun new_draft(scenario: &mut Scenario, clock: &Clock): Draft<TOKEN> {
    scenario.next_tx(LISTER);
    let cargo = mint(src(), ITEM, CARGO_QTY, scenario);
    let reward = test_config::mint(REWARD_QTY, scenario.ctx());
    test_config::draft(
        cargo, reward, want(), COLLATERAL_QTY, ACCEPT_MS, HAUL_MS, BENEFICIARY, clock,
        scenario.ctx(),
    )
}

fun publish(draft: Draft<TOKEN>): (ID, ID) {
    let cap = draft.publish();
    let (agreement_id, cap_id) = (cap.cap_agreement_id(), object::id(&cap));
    transfer::public_transfer(cap, LISTER);
    (agreement_id, cap_id)
}

fun bind_ledger(draft: &mut Draft<TOKEN>, ledger_id: ID, scenario: &mut Scenario) {
    let ledger = scenario.take_shared_by_id<Ledger>(ledger_id);
    let fee = mint(fee_collection(), FEE_ASSET, FEE_QTY, scenario);
    ext::bind_ledger(&ledger, draft, fee);
    ts::return_shared(ledger);
}

/// An observed agreement with no other extensions. Returns `(agreement_id, ledger_id)`.
fun observed(scenario: &mut Scenario, clock: &Clock): (ID, ID) {
    let ledger_id = create_ledger(scenario);
    let mut d = new_draft(scenario, clock);
    bind_ledger(&mut d, ledger_id, scenario);
    let (agreement_id, _) = publish(d);
    (agreement_id, ledger_id)
}

fun accept_plain(scenario: &mut Scenario, clock: &mut Clock) {
    clock.set_for_testing(ACCEPT_AT_MS);
    scenario.next_tx(HAULER);
    let collateral = test_config::mint(COLLATERAL_QTY, scenario.ctx());
    let mut agreement = scenario.take_shared<DeliveryAgreement<TOKEN>>();
    let cargo = agreement.accept(collateral, clock, scenario.ctx());
    transfer::public_transfer(cargo, HAULER);
    ts::return_shared(agreement);
}

/// Receive the ledger's most recent outcome record for inspection.
fun take_record(ledger_id: ID, scenario: &mut Scenario): OutcomeRecord {
    scenario.next_tx(OTHER);
    let mut ledger = scenario.take_shared_by_id<Ledger>(ledger_id);
    let ticket = ts::most_recent_receiving_ticket<OutcomeRecord>(&ledger_id);
    let record = ext::take_record(&mut ledger, ticket);
    ts::return_shared(ledger);
    record
}

/// Total of `(collection, asset_id)` balances owned by `owner`.
fun owned(scenario: &Scenario, owner: address, collection: ID, asset_id: u64): u64 {
    let mut total = 0;
    ts::ids_for_address<Balance>(owner).do!(|id| {
        let balance = scenario.take_from_address_by_id<Balance>(owner, id);
        if (multicoin::collection_id(&balance) == collection
            && multicoin::asset_id(&balance) == asset_id) {
            total = total + multicoin::value(&balance);
        };
        ts::return_to_address(owner, balance);
    });
    total
}

/// TOKEN coins of beneficiary, hauler and lister, and the observer fee the
/// ledger's TREASURY holds, each checked in a fresh transaction so owned
/// objects can be taken again. The fee-free protocol treasury gets nothing.
fun assert_tokens(
    scenario: &mut Scenario,
    beneficiary: u64,
    hauler: u64,
    lister: u64,
    observer_fee: u64,
) {
    scenario.next_tx(OTHER);
    assert_eq!(test_config::coins<TOKEN>(scenario, BENEFICIARY), beneficiary);
    assert_eq!(test_config::coins<TOKEN>(scenario, HAULER), hauler);
    assert_eq!(test_config::coins<TOKEN>(scenario, LISTER), lister);
    assert_eq!(owned(scenario, TREASURY, fee_collection(), FEE_ASSET), observer_fee);
    assert_eq!(test_config::coin_count<TOKEN>(test_config::treasury()), 0);
}

/// The fields every record of the standard observed agreement shares.
fun assert_record_common(record: &OutcomeRecord, agreement_id: ID, ledger_id: ID) {
    assert_eq!(record.record_agreement_id(), agreement_id);
    assert_eq!(
        record.record_observer(),
        delivery::new_binding_for_testing<Ledger>(ledger_id, option::some(fee_spec())),
    );
    assert_eq!(record.record_lister(), LISTER);
    assert_eq!(record.record_on_behalf_of(), option::none());
    assert_eq!(record.record_beneficiary(), BENEFICIARY);
    assert_eq!(record.record_cargo(), cargo_spec());
    assert_eq!(record.record_want(), want());
    assert_eq!(record.record_currency(), test_config::token());
    assert_eq!(record.record_reward(), REWARD_QTY);
    assert_eq!(record.record_posted_at_ms(), START_MS);
}

/// Records of agreements with no identity rule say so.
fun assert_no_identity_rule(record: &OutcomeRecord) {
    assert_eq!(record.record_identity_rule(), option::none());
}

/// The fields every record of an accepted standard agreement shares.
fun assert_accepted_record(record: &OutcomeRecord, closed_at_ms: u64) {
    assert_eq!(record.record_hauler(), option::some(HAULER));
    assert_eq!(record.record_hauler_identity(), option::none());
    assert_eq!(record.record_collateral(), option::some(COLLATERAL_QTY));
    assert_eq!(record.record_deadline_ms(), DEADLINE_MS);
    assert_eq!(record.record_closed_at_ms(), closed_at_ms);
}

// === Full flows ===

/// Every extension at once: gated accept with identity and an observer. The
/// hauler delivers, and the event and record carry the identity.
#[test]
fun flow_every_extension_deliver() {
    let (mut scenario, mut clock) = setup();
    let ledger_id = create_ledger(&mut scenario);
    let agreement_id = draft_every_extension(ledger_id, &mut scenario, &clock);
    accept_with_identity(agreement_id, &mut scenario, &mut clock);

    clock.set_for_testing(DEADLINE_MS - 1);
    scenario.next_tx(OTHER);
    let agreement = scenario.take_shared<DeliveryAgreement<TOKEN>>();
    agreement.deliver(mint(dst(), ITEM, CARGO_QTY, &mut scenario), &clock, scenario.ctx());
    assert_eq!(
        event::events_by_type<AgreementDelivered>(),
        vector[
            delivery::delivered_event_for_testing(
                agreement_id, LISTER, HAULER, option::some(character_id()), BENEFICIARY, want(),
                test_config::token(), REWARD_QTY, COLLATERAL_QTY, 0, test_config::treasury(),
            ),
        ],
    );
    // The fee went to the treasury when the ledger bound.
    assert_tokens(&mut scenario, 0, REWARD_QTY + COLLATERAL_QTY, 0, FEE_QTY);
    scenario.next_tx(OTHER);
    assert_eq!(owned(&scenario, BENEFICIARY, dst(), ITEM), CARGO_QTY);
    assert_eq!(owned(&scenario, HAULER, src(), ITEM), CARGO_QTY);

    // The record carries the identity and the rule that attested it.
    let record = take_record(ledger_id, &mut scenario);
    assert_record_common(&record, agreement_id, ledger_id);
    assert_eq!(record.record_identity_rule(), option::some(type_name::with_original_ids<Character>()));
    assert_eq!(record.record_hauler(), option::some(HAULER));
    assert_eq!(record.record_hauler_identity(), option::some(character_id()));
    assert_eq!(record.record_collateral(), option::some(COLLATERAL_QTY));
    assert_eq!(record.record_deadline_ms(), DEADLINE_MS);
    assert_eq!(record.record_closed_at_ms(), DEADLINE_MS - 1);
    let outcome = record.record_outcome();
    assert!(outcome.outcome_is_delivered());
    assert!(!outcome.outcome_is_defaulted());
    assert!(!outcome.outcome_forfeited());
    assert!(!outcome.outcome_is_cancelled());
    record.delete_outcome();
    finish(scenario, clock);
}

/// Draft with every extension, checking the draft's views before and after
/// they are attached, then publish. Returns the agreement ID.
fun draft_every_extension(ledger_id: ID, scenario: &mut Scenario, clock: &Clock): ID {
    let mut d = new_draft(scenario, clock);
    assert_bare_draft(&d);
    d.require_to_accept(ext::allowlist(vector[HAULER]));
    d.require_identity_to_accept(ext::character());
    bind_ledger(&mut d, ledger_id, scenario);
    assert_draft_extensions(&d, ledger_id);
    let (agreement_id, cap_id) = publish(d);
    assert_eq!(
        event::events_by_type<AgreementPosted>(),
        vector[
            delivery::posted_event_for_testing(
                agreement_id, LISTER, option::none(), cap_id, BENEFICIARY, false, cargo_spec(),
                want(), test_config::token(), REWARD_QTY, COLLATERAL_QTY, ACCEPT_BY_MS, HAUL_MS,
                vector[ext::allowlist(vector[HAULER]), ext::character()],
                option::some(type_name::with_original_ids<Character>()),
                option::some(delivery::new_binding_for_testing<Ledger>(
                    ledger_id, option::some(fee_spec()),
                )),
                option::none(), 0, test_config::treasury(),
            ),
        ],
    );
    agreement_id
}

fun assert_bare_draft(d: &Draft<TOKEN>) {
    let a = d.draft_agreement();
    assert_eq!(a.lister(), LISTER);
    assert_eq!(a.on_behalf_of(), option::none());
    assert_eq!(a.beneficiary(), BENEFICIARY);
    assert!(!a.pays_cap_holder());
    assert_eq!(
        a.terms(),
        terms::new(want(), COLLATERAL_QTY, ACCEPT_MS, HAUL_MS, BENEFICIARY),
    );
    assert_eq!(a.accept_by_ms(), ACCEPT_BY_MS);
    assert_eq!(a.haul_ms(), HAUL_MS);
    assert_eq!(a.posted_at_ms(), START_MS);
    assert_eq!(a.accept_requirements(), vector[]);
    assert_eq!(a.identity_rule(), option::none());
    assert_eq!(a.observer(), option::none());
    assert_eq!(a.hauler(), option::none());
    assert_eq!(a.hauler_identity(), option::none());
    assert_eq!(a.deadline_ms(), 0);
    assert_eq!(a.cargo_spec(), cargo_spec());
    assert!(a.is_open());
    let w = a.want();
    assert_eq!(w.collection(), dst());
    assert_eq!(w.asset_id(), ITEM);
    assert_eq!(w.qty(), CARGO_QTY);
}

fun assert_draft_extensions(d: &Draft<TOKEN>, ledger_id: ID) {
    let a = d.draft_agreement();
    assert_eq!(a.accept_requirements(), vector[ext::allowlist(vector[HAULER]), ext::character()]);
    assert_eq!(a.identity_rule(), option::some(type_name::with_original_ids<Character>()));
    let observer = a.observer().destroy_some();
    assert_eq!(observer.binding_kind(), type_name::with_original_ids<Ledger>());
    assert_eq!(observer.binding_instance(), ledger_id);
    assert_eq!(observer.binding_fee(), option::some(fee_spec()));
}

/// HAULER walks both accept requirements in order and records the character.
fun accept_with_identity(agreement_id: ID, scenario: &mut Scenario, clock: &mut Clock) {
    clock.set_for_testing(ACCEPT_AT_MS);
    scenario.next_tx(HAULER);
    let mut agreement = scenario.take_shared<DeliveryAgreement<TOKEN>>();
    let mut req = agreement.begin_accept(clock, scenario.ctx());
    assert_eq!(req.agreement_id(), agreement_id);
    assert_eq!(req.actor(), HAULER);
    assert_eq!(req.identity(), option::none());
    assert_eq!(req.identity_rule(), option::some(type_name::with_original_ids<Character>()));
    assert_eq!(req.requires().length(), 2);
    assert!(req.next().is<ext::Allowlist>());
    ext::satisfy_allowlist(&mut req);
    assert!(req.next().is<Character>());
    ext::satisfy_character(&mut req, character_id());
    assert_eq!(req.identity(), option::some(character_id()));
    assert_eq!(req.requires().length(), 0);
    let collateral = test_config::mint(COLLATERAL_QTY, scenario.ctx());
    let cargo = agreement.finish_accept(req, collateral, clock);
    assert_eq!(multicoin::collection_id(&cargo), src());
    assert_eq!(multicoin::value(&cargo), CARGO_QTY);
    transfer::public_transfer(cargo, HAULER);
    assert_eq!(agreement.cargo_spec(), cargo_spec());
    assert!(!agreement.is_open());
    assert_eq!(agreement.hauler(), option::some(HAULER));
    assert_eq!(agreement.hauler_identity(), option::some(character_id()));
    assert_eq!(agreement.deadline_ms(), DEADLINE_MS);
    ts::return_shared(agreement);
    assert_eq!(
        event::events_by_type<AgreementAccepted>(),
        vector[
            delivery::accepted_event_for_testing(
                agreement_id, HAULER, option::some(character_id()),
                option::some(type_name::with_original_ids<Character>()), DEADLINE_MS,
            ),
        ],
    );
}

#[test]
fun flow_observed_deliver() {
    let (mut scenario, mut clock) = setup();
    let (agreement_id, ledger_id) = observed(&mut scenario, &clock);
    accept_plain(&mut scenario, &mut clock);

    clock.set_for_testing(DEADLINE_MS - 1);
    scenario.next_tx(OTHER);
    let agreement = scenario.take_shared<DeliveryAgreement<TOKEN>>();
    agreement.deliver(mint(dst(), ITEM, CARGO_QTY, &mut scenario), &clock, scenario.ctx());
    assert_eq!(
        event::events_by_type<AgreementDelivered>(),
        vector[
            delivery::delivered_event_for_testing(
                agreement_id, LISTER, HAULER, option::none(), BENEFICIARY, want(),
                test_config::token(), REWARD_QTY, COLLATERAL_QTY, 0, test_config::treasury(),
            ),
        ],
    );
    assert_tokens(&mut scenario, 0, REWARD_QTY + COLLATERAL_QTY, 0, FEE_QTY);
    scenario.next_tx(OTHER);
    assert_eq!(owned(&scenario, BENEFICIARY, dst(), ITEM), CARGO_QTY);
    assert_eq!(owned(&scenario, HAULER, src(), ITEM), CARGO_QTY);

    let record = take_record(ledger_id, &mut scenario);
    assert_record_common(&record, agreement_id, ledger_id);
    assert_no_identity_rule(&record);
    assert_accepted_record(&record, DEADLINE_MS - 1);
    let outcome = record.record_outcome();
    assert!(outcome.outcome_is_delivered());
    assert!(!outcome.outcome_is_defaulted());
    assert!(!outcome.outcome_is_cancelled());
    record.delete_outcome();
    finish(scenario, clock);
}

#[test]
fun flow_observed_default() {
    let (mut scenario, mut clock) = setup();
    let (agreement_id, ledger_id) = observed(&mut scenario, &clock);
    accept_plain(&mut scenario, &mut clock);

    clock.set_for_testing(DEADLINE_MS);
    scenario.next_tx(OTHER);
    let agreement = scenario.take_shared<DeliveryAgreement<TOKEN>>();
    agreement.default(&clock, scenario.ctx());
    assert_eq!(
        event::events_by_type<AgreementDefaulted>(),
        vector[
            delivery::defaulted_event_for_testing(
                agreement_id, LISTER, HAULER, option::none(), BENEFICIARY, test_config::token(),
                REWARD_QTY, COLLATERAL_QTY, false,
            ),
        ],
    );
    assert_tokens(&mut scenario, REWARD_QTY + COLLATERAL_QTY, 0, 0, FEE_QTY);

    let record = take_record(ledger_id, &mut scenario);
    assert_record_common(&record, agreement_id, ledger_id);
    assert_no_identity_rule(&record);
    assert_accepted_record(&record, DEADLINE_MS);
    let outcome = record.record_outcome();
    assert!(outcome.outcome_is_defaulted());
    assert!(!outcome.outcome_forfeited());
    record.delete_outcome();
    finish(scenario, clock);
}

#[test]
fun flow_observed_forfeit() {
    let (mut scenario, mut clock) = setup();
    let (agreement_id, ledger_id) = observed(&mut scenario, &clock);
    accept_plain(&mut scenario, &mut clock);

    clock.set_for_testing(ACCEPT_AT_MS + 1);
    scenario.next_tx(HAULER);
    let agreement = scenario.take_shared<DeliveryAgreement<TOKEN>>();
    agreement.forfeit(&clock, scenario.ctx());
    assert_eq!(
        event::events_by_type<AgreementDefaulted>(),
        vector[
            delivery::defaulted_event_for_testing(
                agreement_id, LISTER, HAULER, option::none(), BENEFICIARY, test_config::token(),
                REWARD_QTY, COLLATERAL_QTY, true,
            ),
        ],
    );
    assert_tokens(&mut scenario, REWARD_QTY + COLLATERAL_QTY, 0, 0, FEE_QTY);

    let record = take_record(ledger_id, &mut scenario);
    assert_record_common(&record, agreement_id, ledger_id);
    assert_no_identity_rule(&record);
    assert_accepted_record(&record, ACCEPT_AT_MS + 1);
    let outcome = record.record_outcome();
    assert!(outcome.outcome_is_defaulted());
    assert!(outcome.outcome_forfeited());
    record.delete_outcome();
    finish(scenario, clock);
}

#[test]
fun flow_observed_cancel_before_accept() {
    let (mut scenario, mut clock) = setup();
    let (agreement_id, ledger_id) = observed(&mut scenario, &clock);

    clock.set_for_testing(ACCEPT_AT_MS);
    scenario.next_tx(LISTER);
    let cap = scenario.take_from_sender<ListerCap>();
    assert_eq!(cap.cap_agreement_id(), agreement_id);
    let agreement = scenario.take_shared<DeliveryAgreement<TOKEN>>();
    let (cargo, reward) = agreement.cancel(cap, &clock, scenario.ctx());
    assert_eq!(multicoin::value(&cargo), CARGO_QTY);
    assert_eq!(reward.value(), REWARD_QTY);
    assert_eq!(
        event::events_by_type<AgreementCancelled>(),
        vector[
            delivery::cancelled_event_for_testing(
                agreement_id, LISTER, cargo_spec(), test_config::token(), REWARD_QTY,
            ),
        ],
    );
    transfer::public_transfer(cargo, LISTER);
    transfer::public_transfer(reward, LISTER);
    assert_tokens(&mut scenario, 0, 0, REWARD_QTY, FEE_QTY);

    // Nobody accepted: no hauler, collateral or deadline.
    let record = take_record(ledger_id, &mut scenario);
    assert_record_common(&record, agreement_id, ledger_id);
    assert_no_identity_rule(&record);
    assert_eq!(record.record_hauler(), option::none());
    assert_eq!(record.record_hauler_identity(), option::none());
    assert_eq!(record.record_collateral(), option::none());
    assert_eq!(record.record_deadline_ms(), 0);
    assert_eq!(record.record_closed_at_ms(), ACCEPT_AT_MS);
    let outcome = record.record_outcome();
    assert!(outcome.outcome_is_cancelled());
    assert!(!outcome.outcome_is_delivered());
    assert!(!outcome.outcome_is_defaulted());
    record.delete_outcome();
    finish(scenario, clock);
}

/// A hauler who missed the deadline cannot forfeit, so the failure is recorded
/// by `default` (`forfeited = false`), never as giving up.
#[test, expected_failure(abort_code = delivery::ETooLate)]
fun flow_observed_forfeit_at_deadline_is_rejected() {
    let (mut scenario, mut clock) = setup();
    observed(&mut scenario, &clock);
    accept_plain(&mut scenario, &mut clock);
    clock.set_for_testing(DEADLINE_MS);
    scenario.next_tx(HAULER);
    let agreement = scenario.take_shared<DeliveryAgreement<TOKEN>>();
    agreement.forfeit(&clock, scenario.ctx());
    finish(scenario, clock);
}

// === Defensive re-checks in finish_accept ===
// A transaction sees one clock, so the ETooLate re-check is only reachable by
// moving the test clock between begin and finish. They guard against a request
// outliving the moment it was begun if that ever becomes possible.

/// Two accept requests begun in one transaction: only the first can finish.
#[test, expected_failure(abort_code = delivery::ENotOpen)]
fun finish_accept_rejects_second_request_in_one_transaction() {
    let (mut scenario, clock) = setup();
    publish(new_draft(&mut scenario, &clock));
    scenario.next_tx(HAULER);
    let mut agreement = scenario.take_shared<DeliveryAgreement<TOKEN>>();
    let first = agreement.begin_accept(&clock, scenario.ctx());
    let second = agreement.begin_accept(&clock, scenario.ctx());
    let c1 = test_config::mint(COLLATERAL_QTY, scenario.ctx());
    let cargo = agreement.finish_accept(first, c1, &clock);
    transfer::public_transfer(cargo, HAULER);
    let c2 = test_config::mint(COLLATERAL_QTY, scenario.ctx());
    let cargo = agreement.finish_accept(second, c2, &clock);
    transfer::public_transfer(cargo, HAULER);
    ts::return_shared(agreement);
    finish(scenario, clock);
}

#[test, expected_failure(abort_code = delivery::ETooLate)]
fun finish_accept_rechecks_accept_by() {
    let (mut scenario, mut clock) = setup();
    publish(new_draft(&mut scenario, &clock));
    scenario.next_tx(HAULER);
    let mut agreement = scenario.take_shared<DeliveryAgreement<TOKEN>>();
    let req = agreement.begin_accept(&clock, scenario.ctx());
    clock.set_for_testing(ACCEPT_BY_MS);
    let collateral = test_config::mint(COLLATERAL_QTY, scenario.ctx());
    let cargo = agreement.finish_accept(req, collateral, &clock);
    transfer::public_transfer(cargo, HAULER);
    ts::return_shared(agreement);
    finish(scenario, clock);
}

// === Request aborts ===

#[test, expected_failure(abort_code = request::ENoRequirements)]
fun take_next_rejects_empty_request() {
    let (mut scenario, clock) = setup();
    publish(new_draft(&mut scenario, &clock));
    scenario.next_tx(HAULER);
    let agreement = scenario.take_shared<DeliveryAgreement<TOKEN>>();
    let mut req = agreement.begin_accept(&clock, scenario.ctx());
    ext::satisfy_allowlist(&mut req);
    req.destroy_for_testing();
    ts::return_shared(agreement);
    finish(scenario, clock);
}

#[test, expected_failure(abort_code = request::ENoRequirements)]
fun next_rejects_empty_request() {
    let (mut scenario, clock) = setup();
    publish(new_draft(&mut scenario, &clock));
    scenario.next_tx(HAULER);
    let agreement = scenario.take_shared<DeliveryAgreement<TOKEN>>();
    let req = agreement.begin_accept(&clock, scenario.ctx());
    req.next();
    req.destroy_for_testing();
    ts::return_shared(agreement);
    finish(scenario, clock);
}

#[test, expected_failure(abort_code = request::EFrameNotEmpty)]
fun follow_up_cannot_be_discarded() {
    let (mut scenario, clock) = setup();
    let mut d = new_draft(&mut scenario, &clock);
    d.require_to_accept(ext::chain(vector[HAULER]));
    publish(d);
    scenario.next_tx(HAULER);
    let agreement = scenario.take_shared<DeliveryAgreement<TOKEN>>();
    let mut req = agreement.begin_accept(&clock, scenario.ctx());
    ext::chain_drops_follow_up(&mut req);
    req.destroy_for_testing();
    ts::return_shared(agreement);
    finish(scenario, clock);
}

#[test, expected_failure(abort_code = request::EIdentityAlreadySet)]
fun identity_cannot_be_overwritten() {
    let (mut scenario, clock) = setup();
    let mut d = new_draft(&mut scenario, &clock);
    d.require_identity_to_accept(ext::character());
    publish(d);
    scenario.next_tx(HAULER);
    let agreement = scenario.take_shared<DeliveryAgreement<TOKEN>>();
    let mut req = agreement.begin_accept(&clock, scenario.ctx());
    ext::satisfy_character_twice(&mut req, character_id(), object::id_from_address(@0xBAD));
    req.destroy_for_testing();
    ts::return_shared(agreement);
    finish(scenario, clock);
}

/// Without an identity rule, no rule may record an identity.
#[test, expected_failure(abort_code = request::ENotIdentityRule)]
fun identity_rejected_when_agreement_has_no_identity_rule() {
    let (mut scenario, clock) = setup();
    let mut d = new_draft(&mut scenario, &clock);
    d.require_to_accept(ext::allowlist(vector[HAULER]));
    publish(d);
    scenario.next_tx(HAULER);
    let agreement = scenario.take_shared<DeliveryAgreement<TOKEN>>();
    let mut req = agreement.begin_accept(&clock, scenario.ctx());
    ext::allowlist_claims_identity(&mut req, character_id());
    req.destroy_for_testing();
    ts::return_shared(agreement);
    finish(scenario, clock);
}

// === Frames stay with their request ===

/// A rule that leaks its frame cannot move the follow-up to another agreement.
#[test, expected_failure(abort_code = request::EWrongFrame)]
fun frame_cannot_move_to_another_agreement() {
    let (mut scenario, clock) = setup();
    let mut gated = new_draft(&mut scenario, &clock);
    gated.require_to_accept(ext::chain(vector[OTHER]));
    let (gated_id, _) = publish(gated);
    let (open_id, _) = publish(new_draft(&mut scenario, &clock));

    scenario.next_tx(HAULER);
    let gated = scenario.take_shared_by_id<DeliveryAgreement<TOKEN>>(gated_id);
    let open = scenario.take_shared_by_id<DeliveryAgreement<TOKEN>>(open_id);
    let mut gated_req = gated.begin_accept(&clock, scenario.ctx());
    let frame = ext::chain_returns_frame(&mut gated_req);
    let mut open_req = open.begin_accept(&clock, scenario.ctx());
    open_req.enqueue(frame);
    gated_req.destroy_for_testing();
    open_req.destroy_for_testing();
    ts::return_shared(gated);
    ts::return_shared(open);
    finish(scenario, clock);
}

// === Other compositions ===

/// Someone already holding the wanted receipts accepts and delivers in one
/// transaction: the haul window is irrelevant and everyone is paid at once.
#[test]
fun flow_accept_and_deliver_in_one_transaction() {
    let (mut scenario, mut clock) = setup();
    let (agreement_id, ledger_id) = observed(&mut scenario, &clock);
    clock.set_for_testing(ACCEPT_AT_MS);
    scenario.next_tx(HAULER);
    let mut agreement = scenario.take_shared<DeliveryAgreement<TOKEN>>();
    let collateral = test_config::mint(COLLATERAL_QTY, scenario.ctx());
    let cargo = agreement.accept(collateral, &clock, scenario.ctx());
    transfer::public_transfer(cargo, HAULER);
    agreement.deliver(mint(dst(), ITEM, CARGO_QTY, &mut scenario), &clock, scenario.ctx());
    assert_eq!(event::events_by_type<AgreementAccepted>().length(), 1);
    assert_eq!(
        event::events_by_type<AgreementDelivered>(),
        vector[
            delivery::delivered_event_for_testing(
                agreement_id, LISTER, HAULER, option::none(), BENEFICIARY, want(),
                test_config::token(), REWARD_QTY, COLLATERAL_QTY, 0, test_config::treasury(),
            ),
        ],
    );
    assert_tokens(&mut scenario, 0, REWARD_QTY + COLLATERAL_QTY, 0, FEE_QTY);
    scenario.next_tx(OTHER);
    assert_eq!(owned(&scenario, BENEFICIARY, dst(), ITEM), CARGO_QTY);
    let record = take_record(ledger_id, &mut scenario);
    assert_accepted_record(&record, ACCEPT_AT_MS);
    assert!(record.record_outcome().outcome_is_delivered());
    record.delete_outcome();
    finish(scenario, clock);
}

/// Cancelling an agreement with every extension: the record still names the
/// identity rule, with no hauler, collateral or deadline.
#[test]
fun flow_every_extension_cancel() {
    let (mut scenario, mut clock) = setup();
    let ledger_id = create_ledger(&mut scenario);
    let agreement_id = draft_every_extension(ledger_id, &mut scenario, &clock);

    clock.set_for_testing(ACCEPT_BY_MS);
    scenario.next_tx(LISTER);
    let cap = scenario.take_from_sender<ListerCap>();
    let agreement = scenario.take_shared<DeliveryAgreement<TOKEN>>();
    let (cargo, reward) = agreement.cancel(cap, &clock, scenario.ctx());
    transfer::public_transfer(cargo, LISTER);
    transfer::public_transfer(reward, LISTER);
    assert_tokens(&mut scenario, 0, 0, REWARD_QTY, FEE_QTY);
    scenario.next_tx(OTHER);
    assert_eq!(owned(&scenario, LISTER, src(), ITEM), CARGO_QTY);

    let record = take_record(ledger_id, &mut scenario);
    assert_record_common(&record, agreement_id, ledger_id);
    assert_eq!(record.record_identity_rule(), option::some(type_name::with_original_ids<Character>()));
    assert_eq!(record.record_hauler(), option::none());
    assert_eq!(record.record_hauler_identity(), option::none());
    assert_eq!(record.record_collateral(), option::none());
    assert_eq!(record.record_deadline_ms(), 0);
    assert_eq!(record.record_closed_at_ms(), ACCEPT_BY_MS);
    assert!(record.record_outcome().outcome_is_cancelled());
    record.delete_outcome();
    finish(scenario, clock);
}

/// Nothing stops the beneficiary from accepting. If they then forfeit, the
/// collateral comes straight back to them with the reward, and they keep the
/// cargo: collateral protects the lister only when the beneficiary is honest.
/// (An address check would not help: a second wallet can accept for them.)
#[test]
fun beneficiary_can_accept_then_forfeit() {
    let (mut scenario, mut clock) = setup();
    publish(new_draft(&mut scenario, &clock));
    clock.set_for_testing(ACCEPT_AT_MS);
    scenario.next_tx(BENEFICIARY);
    let mut agreement = scenario.take_shared<DeliveryAgreement<TOKEN>>();
    let collateral = test_config::mint(COLLATERAL_QTY, scenario.ctx());
    let cargo = agreement.accept(collateral, &clock, scenario.ctx());
    transfer::public_transfer(cargo, BENEFICIARY);
    ts::return_shared(agreement);

    scenario.next_tx(BENEFICIARY);
    let agreement = scenario.take_shared<DeliveryAgreement<TOKEN>>();
    agreement.forfeit(&clock, scenario.ctx());
    assert_tokens(&mut scenario, REWARD_QTY + COLLATERAL_QTY, 0, 0, 0);
    scenario.next_tx(OTHER);
    assert_eq!(owned(&scenario, BENEFICIARY, src(), ITEM), CARGO_QTY);
    finish(scenario, clock);
}
