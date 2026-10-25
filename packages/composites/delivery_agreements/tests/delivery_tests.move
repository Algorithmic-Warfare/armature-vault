#[test_only]
module delivery_agreements::delivery_tests;

use agreements::spec::{Self, Spec};
use delivery_agreements::config;
use delivery_agreements::delivery::{
    Self,
    DeliveryAgreement,
    ListerCap,
    AgreementPosted,
    AgreementAccepted,
    AgreementDelivered,
    AgreementDefaulted,
    AgreementCancelled,
    AgreementLapsed
};
use delivery_agreements::test_config::{Self, TOKEN};
use multicoin::multicoin::{Self, Balance};
use std::unit_test::assert_eq;
use sui::clock::{Self, Clock};
use sui::coin::Coin;
use sui::event;
use sui::test_scenario::{Self as ts, Scenario};

const LISTER: address = @0xA;
const HAULER: address = @0xB;
const BENEFICIARY: address = @0xC;
const OTHER: address = @0xD;
const ADMIN: address = @0xE;

// Item type 7 at the source SSU's collection, delivered at the destination's.
const ITEM: u64 = 7;
const CARGO_QTY: u64 = 10;
// Reward and collateral, in TOKEN.
const REWARD_QTY: u64 = 100;
const COLLATERAL_QTY: u64 = 500;

const START_MS: u64 = 1_000;
const ACCEPT_BY_MS: u64 = 5_000;
const HAUL_MS: u64 = 10_000;
const ACCEPT_AT_MS: u64 = 2_000;
const DEADLINE_MS: u64 = 12_000; // ACCEPT_AT_MS + HAUL_MS

fun src(): ID { object::id_from_address(@0x51) }

fun dst(): ID { object::id_from_address(@0xD5) }

fun mint(collection: ID, asset_id: u64, qty: u64, scenario: &mut Scenario): Balance {
    multicoin::create_balance_for_testing(collection, asset_id, qty, scenario.ctx())
}

fun want(): Spec { spec::new(dst(), ITEM, CARGO_QTY) }

fun setup(): (Scenario, Clock) {
    let mut scenario = ts::begin(LISTER);
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(START_MS);
    (scenario, clock)
}

fun cargo_spec(): Spec { spec::new(src(), ITEM, CARGO_QTY) }

/// LISTER posts the standard agreement and keeps the cap. Returns
/// `(agreement_id, cap_id)`; the posting transaction is still current, so its
/// events remain visible to the caller.
fun post(scenario: &mut Scenario, clock: &Clock): (ID, ID) {
    scenario.next_tx(LISTER);
    let cargo = mint(src(), ITEM, CARGO_QTY, scenario);
    let reward = test_config::mint(REWARD_QTY, scenario.ctx());
    let cap = test_config::post(
        cargo, reward, want(), COLLATERAL_QTY, ACCEPT_BY_MS, HAUL_MS, BENEFICIARY, clock,
        scenario.ctx(),
    );
    let (agreement_id, cap_id) = (cap.cap_agreement_id(), object::id(&cap));
    transfer::public_transfer(cap, LISTER);
    (agreement_id, cap_id)
}

/// HAULER accepts at ACCEPT_AT_MS and keeps the cargo.
fun accept(scenario: &mut Scenario, clock: &mut Clock) {
    clock.set_for_testing(ACCEPT_AT_MS);
    scenario.next_tx(HAULER);
    let collateral = test_config::mint(COLLATERAL_QTY, scenario.ctx());
    let mut agreement = scenario.take_shared<DeliveryAgreement<TOKEN>>();
    let cargo = agreement.accept(collateral, clock, scenario.ctx());
    transfer::public_transfer(cargo, HAULER);
    ts::return_shared(agreement);
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

/// Total of the TOKEN coins owned by `owner`.
fun coins(scenario: &Scenario, owner: address): u64 { test_config::coins<TOKEN>(scenario, owner) }

fun finish(scenario: Scenario, clock: Clock) {
    clock.destroy_for_testing();
    scenario.end();
}

// === Happy paths ===

#[test]
fun post_then_accept_releases_cargo_and_locks_collateral() {
    let (mut scenario, mut clock) = setup();
    let (agreement_id, cap_id) = post(&mut scenario, &clock);
    assert_eq!(
        event::events_by_type<AgreementPosted>(),
        vector[
            delivery::posted_event_for_testing(
                agreement_id, LISTER, cap_id, BENEFICIARY, cargo_spec(), want(),
                test_config::token(), REWARD_QTY, COLLATERAL_QTY, ACCEPT_BY_MS, HAUL_MS, vector[],
                option::none(), option::none(), option::none(), 0, test_config::treasury(),
            ),
        ],
    );

    scenario.next_tx(OTHER);
    {
        let agreement = scenario.take_shared<DeliveryAgreement<TOKEN>>();
        assert!(agreement.is_open());
        assert_eq!(agreement.beneficiary(), BENEFICIARY);
        assert_eq!(agreement.want(), want());
        assert_eq!(agreement.currency(), test_config::token());
        assert_eq!(agreement.collateral_amount(), COLLATERAL_QTY);
        assert_eq!(agreement.collateral_locked(), 0);
        assert_eq!(multicoin::value(agreement.cargo().borrow()), CARGO_QTY);
        assert_eq!(agreement.reward(), REWARD_QTY);
        assert_eq!(agreement.deadline_ms(), 0);
        ts::return_shared(agreement);
    };

    accept(&mut scenario, &mut clock);
    assert_eq!(
        event::events_by_type<AgreementAccepted>(),
        vector[delivery::accepted_event_for_testing(
            agreement_id, HAULER, option::none(), option::none(), DEADLINE_MS,
        )],
    );

    scenario.next_tx(OTHER);
    {
        let agreement = scenario.take_shared<DeliveryAgreement<TOKEN>>();
        assert!(!agreement.is_open());
        assert_eq!(agreement.hauler(), option::some(HAULER));
        assert_eq!(agreement.deadline_ms(), DEADLINE_MS);
        assert!(agreement.cargo().is_none());
        assert_eq!(agreement.collateral_amount(), COLLATERAL_QTY);
        assert_eq!(agreement.collateral_locked(), COLLATERAL_QTY);
        assert_eq!(agreement.reward(), REWARD_QTY);
        ts::return_shared(agreement);
    };
    assert_eq!(owned(&scenario, HAULER, src(), ITEM), CARGO_QTY);
    finish(scenario, clock);
}

#[test]
fun deliver_pays_beneficiary_and_returns_reward_and_collateral() {
    let (mut scenario, mut clock) = setup();
    let (agreement_id, _) = post(&mut scenario, &clock);
    accept(&mut scenario, &mut clock);

    // Anyone may submit the delivery; payouts are fixed.
    clock.set_for_testing(DEADLINE_MS - 1);
    scenario.next_tx(OTHER);
    let delivered = mint(dst(), ITEM, CARGO_QTY, &mut scenario);
    let agreement = scenario.take_shared<DeliveryAgreement<TOKEN>>();
    agreement.deliver(delivered, &clock, scenario.ctx());
    assert_eq!(
        event::events_by_type<AgreementDelivered>(),
        vector[
            delivery::delivered_event_for_testing(
                agreement_id, LISTER, HAULER, option::none(), BENEFICIARY, want(),
                test_config::token(), REWARD_QTY, COLLATERAL_QTY, 0, test_config::treasury(),
            ),
        ],
    );

    scenario.next_tx(OTHER);
    assert_eq!(owned(&scenario, BENEFICIARY, dst(), ITEM), CARGO_QTY);
    assert_eq!(coins(&scenario, HAULER), REWARD_QTY + COLLATERAL_QTY);
    // Reward and collateral arrive as two coins.
    assert_eq!(test_config::coin_count<TOKEN>(HAULER), 2);
    assert_eq!(coins(&scenario, OTHER), 0);
    assert_eq!(ts::ids_for_address<Balance>(LISTER).length(), 0);
    assert_eq!(ts::ids_for_address<Coin<TOKEN>>(LISTER).length(), 0);
    finish(scenario, clock);
}

#[test]
fun default_at_deadline_pays_beneficiary() {
    let (mut scenario, mut clock) = setup();
    let (agreement_id, _) = post(&mut scenario, &clock);
    accept(&mut scenario, &mut clock);

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

    scenario.next_tx(OTHER);
    assert_eq!(coins(&scenario, BENEFICIARY), REWARD_QTY + COLLATERAL_QTY);
    assert_eq!(coins(&scenario, HAULER), 0);
    // The hauler keeps the cargo they took. (Owned objects can be taken once
    // per transaction, so query them again in a fresh one.)
    scenario.next_tx(OTHER);
    assert_eq!(owned(&scenario, HAULER, src(), ITEM), CARGO_QTY);
    finish(scenario, clock);
}

#[test]
fun cancel_returns_cargo_and_reward_to_cap_holder() {
    let (mut scenario, clock) = setup();
    let (agreement_id, _) = post(&mut scenario, &clock);

    // The cap is transferable; whoever holds it cancels and is recorded.
    scenario.next_tx(LISTER);
    let cap = scenario.take_from_sender<ListerCap>();
    transfer::public_transfer(cap, OTHER);
    scenario.next_tx(OTHER);
    let cap = scenario.take_from_sender<ListerCap>();
    let agreement = scenario.take_shared<DeliveryAgreement<TOKEN>>();
    assert_eq!(object::id(&agreement), agreement_id);
    let (cargo, reward) = agreement.cancel(cap, &clock, scenario.ctx());
    assert_eq!(multicoin::collection_id(&cargo), src());
    assert_eq!(multicoin::value(&cargo), CARGO_QTY);
    assert_eq!(reward.value(), REWARD_QTY);
    assert_eq!(
        event::events_by_type<AgreementCancelled>(),
        vector[
            delivery::cancelled_event_for_testing(
                agreement_id, OTHER, cargo_spec(), test_config::token(), REWARD_QTY,
            ),
        ],
    );
    transfer::public_transfer(cargo, LISTER);
    transfer::public_transfer(reward, LISTER);
    finish(scenario, clock);
}

#[test]
fun cancel_after_accept_window_lapses() {
    let (mut scenario, mut clock) = setup();
    post(&mut scenario, &clock);

    clock.set_for_testing(ACCEPT_BY_MS + 1);
    scenario.next_tx(LISTER);
    let cap = scenario.take_from_sender<ListerCap>();
    let agreement = scenario.take_shared<DeliveryAgreement<TOKEN>>();
    let (cargo, reward) = agreement.cancel(cap, &clock, scenario.ctx());
    transfer::public_transfer(cargo, LISTER);
    transfer::public_transfer(reward, LISTER);
    finish(scenario, clock);
}

#[test]
fun close_lapsed_returns_cargo_and_reward_to_lister() {
    let (mut scenario, mut clock) = setup();
    let (agreement_id, _) = post(&mut scenario, &clock);

    // LISTER keeps the cap; the admin closes without it and receives nothing.
    clock.set_for_testing(ACCEPT_BY_MS);
    scenario.next_tx(ADMIN);
    let admin_cap = config::new_admin_cap_for_testing(scenario.ctx());
    let agreement = scenario.take_shared<DeliveryAgreement<TOKEN>>();
    agreement.close_lapsed(&admin_cap, &clock, scenario.ctx());
    assert_eq!(
        event::events_by_type<AgreementLapsed>(),
        vector[
            delivery::lapsed_event_for_testing(
                agreement_id, LISTER, ADMIN, cargo_spec(), test_config::token(), REWARD_QTY,
            ),
        ],
    );
    transfer::public_transfer(admin_cap, ADMIN);

    scenario.next_tx(OTHER);
    assert_eq!(owned(&scenario, LISTER, src(), ITEM), CARGO_QTY);
    assert_eq!(coins(&scenario, LISTER), REWARD_QTY);
    assert_eq!(ts::ids_for_address<Balance>(ADMIN).length(), 0);
    assert_eq!(ts::ids_for_address<Coin<TOKEN>>(ADMIN).length(), 0);
    finish(scenario, clock);
}

#[test]
fun close_lapsed_sends_nothing_for_empty_cargo_and_reward() {
    let (mut scenario, mut clock) = setup();
    scenario.next_tx(LISTER);
    let cargo = mint(src(), ITEM, 0, &mut scenario);
    let reward = test_config::mint(0, scenario.ctx());
    let cap = test_config::post(
        cargo, reward, want(), COLLATERAL_QTY, ACCEPT_BY_MS, HAUL_MS, BENEFICIARY, &clock,
        scenario.ctx(),
    );
    transfer::public_transfer(cap, LISTER);

    clock.set_for_testing(ACCEPT_BY_MS);
    scenario.next_tx(ADMIN);
    let admin_cap = config::new_admin_cap_for_testing(scenario.ctx());
    let agreement = scenario.take_shared<DeliveryAgreement<TOKEN>>();
    agreement.close_lapsed(&admin_cap, &clock, scenario.ctx());
    transfer::public_transfer(admin_cap, ADMIN);

    scenario.next_tx(OTHER);
    assert_eq!(ts::ids_for_address<Balance>(LISTER).length(), 0);
    assert_eq!(ts::ids_for_address<Coin<TOKEN>>(LISTER).length(), 0);
    finish(scenario, clock);
}

// === Posting ===

#[test, expected_failure(abort_code = delivery::EInvalidTerms)]
fun post_rejects_past_accept_by() {
    let (mut scenario, clock) = setup();
    let cargo = mint(src(), ITEM, CARGO_QTY, &mut scenario);
    let reward = test_config::mint(REWARD_QTY, scenario.ctx());
    let cap = test_config::post(
        cargo, reward, want(), COLLATERAL_QTY, START_MS, HAUL_MS, BENEFICIARY, &clock,
        scenario.ctx(),
    );
    transfer::public_transfer(cap, LISTER);
    finish(scenario, clock);
}

#[test, expected_failure(abort_code = delivery::EInvalidTerms)]
fun post_rejects_zero_haul_window() {
    let (mut scenario, clock) = setup();
    let cargo = mint(src(), ITEM, CARGO_QTY, &mut scenario);
    let reward = test_config::mint(REWARD_QTY, scenario.ctx());
    let cap = test_config::post(
        cargo, reward, want(), COLLATERAL_QTY, ACCEPT_BY_MS, 0, BENEFICIARY, &clock,
        scenario.ctx(),
    );
    transfer::public_transfer(cap, LISTER);
    finish(scenario, clock);
}

#[test, expected_failure(abort_code = delivery::EInvalidTerms)]
fun post_rejects_zero_want() {
    let (mut scenario, clock) = setup();
    let cargo = mint(src(), ITEM, CARGO_QTY, &mut scenario);
    let reward = test_config::mint(REWARD_QTY, scenario.ctx());
    let cap = test_config::post(
        cargo, reward, spec::new(dst(), ITEM, 0), COLLATERAL_QTY, ACCEPT_BY_MS,
        HAUL_MS, BENEFICIARY, &clock, scenario.ctx(),
    );
    transfer::public_transfer(cap, LISTER);
    finish(scenario, clock);
}

#[test, expected_failure(abort_code = delivery::EInvalidTerms)]
fun post_rejects_zero_collateral() {
    let (mut scenario, clock) = setup();
    let cargo = mint(src(), ITEM, CARGO_QTY, &mut scenario);
    let reward = test_config::mint(REWARD_QTY, scenario.ctx());
    let cap = test_config::post(
        cargo, reward, want(), 0, ACCEPT_BY_MS,
        HAUL_MS, BENEFICIARY, &clock, scenario.ctx(),
    );
    transfer::public_transfer(cap, LISTER);
    finish(scenario, clock);
}

#[test]
fun post_allows_windows_of_max_duration() {
    let (mut scenario, clock) = setup();
    let max = delivery::max_duration_ms();
    let cargo = mint(src(), ITEM, CARGO_QTY, &mut scenario);
    let reward = test_config::mint(REWARD_QTY, scenario.ctx());
    let cap = test_config::post(
        cargo, reward, want(), COLLATERAL_QTY, START_MS + max, max, BENEFICIARY, &clock,
        scenario.ctx(),
    );
    transfer::public_transfer(cap, LISTER);
    finish(scenario, clock);
}

#[test, expected_failure(abort_code = delivery::EInvalidTerms)]
fun post_rejects_accept_window_over_max() {
    let (mut scenario, clock) = setup();
    let cargo = mint(src(), ITEM, CARGO_QTY, &mut scenario);
    let reward = test_config::mint(REWARD_QTY, scenario.ctx());
    let cap = test_config::post(
        cargo, reward, want(), COLLATERAL_QTY, START_MS + delivery::max_duration_ms() + 1,
        HAUL_MS, BENEFICIARY, &clock, scenario.ctx(),
    );
    transfer::public_transfer(cap, LISTER);
    finish(scenario, clock);
}

#[test, expected_failure(abort_code = delivery::EInvalidTerms)]
fun post_rejects_haul_window_over_max() {
    let (mut scenario, clock) = setup();
    let cargo = mint(src(), ITEM, CARGO_QTY, &mut scenario);
    let reward = test_config::mint(REWARD_QTY, scenario.ctx());
    let cap = test_config::post(
        cargo, reward, want(), COLLATERAL_QTY, ACCEPT_BY_MS, delivery::max_duration_ms() + 1,
        BENEFICIARY, &clock, scenario.ctx(),
    );
    transfer::public_transfer(cap, LISTER);
    finish(scenario, clock);
}

// === Accepting ===

#[test, expected_failure(abort_code = delivery::ETooLate)]
fun accept_rejects_at_accept_by() {
    let (mut scenario, mut clock) = setup();
    post(&mut scenario, &clock);
    clock.set_for_testing(ACCEPT_BY_MS);
    scenario.next_tx(HAULER);
    let collateral = test_config::mint(COLLATERAL_QTY, scenario.ctx());
    let mut agreement = scenario.take_shared<DeliveryAgreement<TOKEN>>();
    let cargo = agreement.accept(collateral, &clock, scenario.ctx());
    transfer::public_transfer(cargo, HAULER);
    ts::return_shared(agreement);
    finish(scenario, clock);
}

/// `accept_by_ms` is exclusive: the last millisecond before it still accepts,
/// and the haul window runs from that moment.
#[test]
fun accept_allowed_just_before_accept_by() {
    let (mut scenario, mut clock) = setup();
    post(&mut scenario, &clock);
    clock.set_for_testing(ACCEPT_BY_MS - 1);
    scenario.next_tx(HAULER);
    let collateral = test_config::mint(COLLATERAL_QTY, scenario.ctx());
    let mut agreement = scenario.take_shared<DeliveryAgreement<TOKEN>>();
    let cargo = agreement.accept(collateral, &clock, scenario.ctx());
    assert_eq!(agreement.deadline_ms(), ACCEPT_BY_MS - 1 + HAUL_MS);
    transfer::public_transfer(cargo, HAULER);
    ts::return_shared(agreement);
    finish(scenario, clock);
}

#[test, expected_failure(abort_code = delivery::ENotOpen)]
fun accept_rejects_second_hauler() {
    let (mut scenario, mut clock) = setup();
    post(&mut scenario, &clock);
    accept(&mut scenario, &mut clock);
    scenario.next_tx(OTHER);
    let collateral = test_config::mint(COLLATERAL_QTY, scenario.ctx());
    let mut agreement = scenario.take_shared<DeliveryAgreement<TOKEN>>();
    let cargo = agreement.accept(collateral, &clock, scenario.ctx());
    transfer::public_transfer(cargo, OTHER);
    ts::return_shared(agreement);
    finish(scenario, clock);
}

/// Collateral is a `Coin<T>` in the agreement's own currency, so the type
/// system rules out any other coin; only the amount is checked.
#[test, expected_failure(abort_code = delivery::EWrongCollateral)]
fun accept_rejects_short_collateral() {
    let (mut scenario, clock) = setup();
    post(&mut scenario, &clock);
    scenario.next_tx(HAULER);
    let collateral = test_config::mint(COLLATERAL_QTY - 1, scenario.ctx());
    let mut agreement = scenario.take_shared<DeliveryAgreement<TOKEN>>();
    let cargo = agreement.accept(collateral, &clock, scenario.ctx());
    transfer::public_transfer(cargo, HAULER);
    ts::return_shared(agreement);
    finish(scenario, clock);
}

/// Collateral is exact: overpaying is rejected, not partly refunded.
#[test, expected_failure(abort_code = delivery::EWrongCollateral)]
fun accept_rejects_excess_collateral() {
    let (mut scenario, clock) = setup();
    post(&mut scenario, &clock);
    scenario.next_tx(HAULER);
    let collateral = test_config::mint(COLLATERAL_QTY + 1, scenario.ctx());
    let mut agreement = scenario.take_shared<DeliveryAgreement<TOKEN>>();
    let cargo = agreement.accept(collateral, &clock, scenario.ctx());
    transfer::public_transfer(cargo, HAULER);
    ts::return_shared(agreement);
    finish(scenario, clock);
}

#[test, expected_failure(abort_code = delivery::EWrongCollateral)]
fun accept_rejects_empty_collateral() {
    let (mut scenario, clock) = setup();
    post(&mut scenario, &clock);
    scenario.next_tx(HAULER);
    let collateral = test_config::mint(0, scenario.ctx());
    let mut agreement = scenario.take_shared<DeliveryAgreement<TOKEN>>();
    let cargo = agreement.accept(collateral, &clock, scenario.ctx());
    transfer::public_transfer(cargo, HAULER);
    ts::return_shared(agreement);
    finish(scenario, clock);
}

// === Delivering ===

#[test, expected_failure(abort_code = delivery::ENotAccepted)]
fun deliver_rejects_open_agreement() {
    let (mut scenario, clock) = setup();
    post(&mut scenario, &clock);
    scenario.next_tx(HAULER);
    let delivered = mint(dst(), ITEM, CARGO_QTY, &mut scenario);
    let agreement = scenario.take_shared<DeliveryAgreement<TOKEN>>();
    agreement.deliver(delivered, &clock, scenario.ctx());
    finish(scenario, clock);
}

#[test, expected_failure(abort_code = delivery::ETooLate)]
fun deliver_rejects_at_deadline() {
    let (mut scenario, mut clock) = setup();
    post(&mut scenario, &clock);
    accept(&mut scenario, &mut clock);
    clock.set_for_testing(DEADLINE_MS);
    scenario.next_tx(HAULER);
    let delivered = mint(dst(), ITEM, CARGO_QTY, &mut scenario);
    let agreement = scenario.take_shared<DeliveryAgreement<TOKEN>>();
    agreement.deliver(delivered, &clock, scenario.ctx());
    finish(scenario, clock);
}

#[test, expected_failure(abort_code = spec::EWrongAsset)]
fun deliver_rejects_source_collection() {
    let (mut scenario, mut clock) = setup();
    post(&mut scenario, &clock);
    accept(&mut scenario, &mut clock);
    // Handing the cargo straight back is not delivery.
    scenario.next_tx(HAULER);
    let cargo = scenario.take_from_sender<Balance>();
    let agreement = scenario.take_shared<DeliveryAgreement<TOKEN>>();
    agreement.deliver(cargo, &clock, scenario.ctx());
    finish(scenario, clock);
}

#[test, expected_failure(abort_code = spec::EWrongAmount)]
fun deliver_rejects_partial_quantity() {
    let (mut scenario, mut clock) = setup();
    post(&mut scenario, &clock);
    accept(&mut scenario, &mut clock);
    scenario.next_tx(HAULER);
    let delivered = mint(dst(), ITEM, CARGO_QTY - 1, &mut scenario);
    let agreement = scenario.take_shared<DeliveryAgreement<TOKEN>>();
    agreement.deliver(delivered, &clock, scenario.ctx());
    finish(scenario, clock);
}

/// Delivery is exact: more than `want` is rejected, not partly refunded.
#[test, expected_failure(abort_code = spec::EWrongAmount)]
fun deliver_rejects_excess_quantity() {
    let (mut scenario, mut clock) = setup();
    post(&mut scenario, &clock);
    accept(&mut scenario, &mut clock);
    scenario.next_tx(HAULER);
    let delivered = mint(dst(), ITEM, CARGO_QTY + 1, &mut scenario);
    let agreement = scenario.take_shared<DeliveryAgreement<TOKEN>>();
    agreement.deliver(delivered, &clock, scenario.ctx());
    finish(scenario, clock);
}

#[test, expected_failure(abort_code = spec::EWrongAsset)]
fun deliver_rejects_wrong_item_type() {
    let (mut scenario, mut clock) = setup();
    post(&mut scenario, &clock);
    accept(&mut scenario, &mut clock);
    scenario.next_tx(HAULER);
    let delivered = mint(dst(), ITEM + 1, CARGO_QTY, &mut scenario);
    let agreement = scenario.take_shared<DeliveryAgreement<TOKEN>>();
    agreement.deliver(delivered, &clock, scenario.ctx());
    finish(scenario, clock);
}

// === Defaulting ===

#[test, expected_failure(abort_code = delivery::ETooEarly)]
fun default_rejects_before_deadline() {
    let (mut scenario, mut clock) = setup();
    post(&mut scenario, &clock);
    accept(&mut scenario, &mut clock);
    clock.set_for_testing(DEADLINE_MS - 1);
    scenario.next_tx(OTHER);
    let agreement = scenario.take_shared<DeliveryAgreement<TOKEN>>();
    agreement.default(&clock, scenario.ctx());
    finish(scenario, clock);
}

#[test, expected_failure(abort_code = delivery::ENotAccepted)]
fun default_rejects_open_agreement() {
    let (mut scenario, mut clock) = setup();
    post(&mut scenario, &clock);
    clock.set_for_testing(DEADLINE_MS);
    scenario.next_tx(OTHER);
    let agreement = scenario.take_shared<DeliveryAgreement<TOKEN>>();
    agreement.default(&clock, scenario.ctx());
    finish(scenario, clock);
}

// === Forfeiting ===

#[test]
fun forfeit_pays_beneficiary_before_deadline() {
    let (mut scenario, mut clock) = setup();
    let (agreement_id, _) = post(&mut scenario, &clock);
    accept(&mut scenario, &mut clock);

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

    scenario.next_tx(OTHER);
    assert_eq!(coins(&scenario, BENEFICIARY), REWARD_QTY + COLLATERAL_QTY);
    assert_eq!(coins(&scenario, HAULER), 0);
    scenario.next_tx(OTHER);
    assert_eq!(owned(&scenario, HAULER, src(), ITEM), CARGO_QTY);
    finish(scenario, clock);
}

#[test, expected_failure(abort_code = delivery::ENotHauler)]
fun forfeit_rejects_non_hauler() {
    let (mut scenario, mut clock) = setup();
    post(&mut scenario, &clock);
    accept(&mut scenario, &mut clock);
    // Not even the beneficiary can force an early forfeit.
    scenario.next_tx(BENEFICIARY);
    let agreement = scenario.take_shared<DeliveryAgreement<TOKEN>>();
    agreement.forfeit(&clock, scenario.ctx());
    finish(scenario, clock);
}

#[test, expected_failure(abort_code = delivery::ENotAccepted)]
fun forfeit_rejects_open_agreement() {
    let (mut scenario, clock) = setup();
    post(&mut scenario, &clock);
    scenario.next_tx(HAULER);
    let agreement = scenario.take_shared<DeliveryAgreement<TOKEN>>();
    agreement.forfeit(&clock, scenario.ctx());
    finish(scenario, clock);
}

// === Cancelling ===

#[test, expected_failure(abort_code = delivery::ENotOpen)]
fun cancel_rejects_accepted_agreement() {
    let (mut scenario, mut clock) = setup();
    post(&mut scenario, &clock);
    accept(&mut scenario, &mut clock);
    scenario.next_tx(LISTER);
    let cap = scenario.take_from_sender<ListerCap>();
    let agreement = scenario.take_shared<DeliveryAgreement<TOKEN>>();
    let (cargo, reward) = agreement.cancel(cap, &clock, scenario.ctx());
    transfer::public_transfer(cargo, LISTER);
    transfer::public_transfer(reward, LISTER);
    finish(scenario, clock);
}

#[test, expected_failure(abort_code = delivery::EWrongCap)]
fun cancel_rejects_other_agreements_cap() {
    let (mut scenario, clock) = setup();
    post(&mut scenario, &clock);
    scenario.next_tx(LISTER);
    let first_id = ts::most_recent_id_shared<DeliveryAgreement<TOKEN>>().destroy_some();
    let first_cap = scenario.take_from_sender<ListerCap>();
    transfer::public_transfer(first_cap, OTHER);
    post(&mut scenario, &clock);
    scenario.next_tx(LISTER);
    // LISTER now holds only the second agreement's cap.
    let second_cap = scenario.take_from_sender<ListerCap>();
    let first = scenario.take_shared_by_id<DeliveryAgreement<TOKEN>>(first_id);
    let (cargo, reward) = first.cancel(second_cap, &clock, scenario.ctx());
    transfer::public_transfer(cargo, LISTER);
    transfer::public_transfer(reward, LISTER);
    finish(scenario, clock);
}

// === Closing lapsed agreements ===

#[test, expected_failure(abort_code = delivery::ENotLapsed)]
fun close_lapsed_rejects_before_accept_by() {
    let (mut scenario, mut clock) = setup();
    post(&mut scenario, &clock);
    clock.set_for_testing(ACCEPT_BY_MS - 1);
    scenario.next_tx(ADMIN);
    let admin_cap = config::new_admin_cap_for_testing(scenario.ctx());
    let agreement = scenario.take_shared<DeliveryAgreement<TOKEN>>();
    agreement.close_lapsed(&admin_cap, &clock, scenario.ctx());
    transfer::public_transfer(admin_cap, ADMIN);
    finish(scenario, clock);
}

#[test, expected_failure(abort_code = delivery::ENotOpen)]
fun close_lapsed_rejects_accepted_agreement() {
    let (mut scenario, mut clock) = setup();
    post(&mut scenario, &clock);
    accept(&mut scenario, &mut clock);
    // Past the accept window, but a hauler holds the cargo.
    clock.set_for_testing(ACCEPT_BY_MS);
    scenario.next_tx(ADMIN);
    let admin_cap = config::new_admin_cap_for_testing(scenario.ctx());
    let agreement = scenario.take_shared<DeliveryAgreement<TOKEN>>();
    agreement.close_lapsed(&admin_cap, &clock, scenario.ctx());
    transfer::public_transfer(admin_cap, ADMIN);
    finish(scenario, clock);
}
