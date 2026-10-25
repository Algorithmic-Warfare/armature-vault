/// Protocol config: approved currencies, the posting fee paid when drafting,
/// the delivery fee taken from the reward on `deliver`, the snapshot each
/// agreement takes of the config, and the admin functions.
#[test_only]
module hauling_agreements::config_tests;

use agreements::spec::{Self, Spec};
use hauling_agreements::config::{Self, Config, AdminCap, ConfigUpdated, PostFee};
use hauling_agreements::hauling::{
    Self,
    HaulingAgreement,
    ListerCap,
    OutcomeRecord,
    AgreementPosted,
    AgreementDelivered,
    AgreementDefaulted
};
use hauling_agreements::terms::{Self, Terms};
use hauling_agreements::test_config::{Self, TOKEN};
use hauling_agreements::test_extensions::{Self as ext, Ledger};
use multicoin::multicoin::{Self, Balance};
use std::type_name::{Self, TypeName};
use std::unit_test::assert_eq;
use sui::clock::{Self, Clock};
use sui::coin::{Self, Coin};
use sui::event;
use sui::test_scenario::{Self as ts, Scenario};

/// A second currency, approved only where a test says so.
public struct GOLD has drop {}

/// The coin the posting fee is charged in, unless a test says otherwise.
public struct FEE has drop {}

const ADMIN: address = @0xAD;
const LISTER: address = @0xA;
const HAULER: address = @0xB;
const BENEFICIARY: address = @0xC;
const OTHER: address = @0xD;
const TREASURY: address = @0xF;
const NEW_TREASURY: address = @0xF2;

const ITEM: u64 = 7;
const CARGO_QTY: u64 = 10;
// Reward, collateral and the delivery fee in TOKEN; the posting fee in FEE.
const REWARD_QTY: u64 = 100;
const COLLATERAL_QTY: u64 = 500;
const POST_FEE_QTY: u64 = 5;
const NEW_POST_FEE_QTY: u64 = 8;
// The observer's own fee, a multicoin balance.
const OBSERVER_FEE_QTY: u64 = 3;
// An agreement paid in GOLD.
const GOLD_REWARD_QTY: u64 = 1_010;
const GOLD_COLLATERAL_QTY: u64 = 2_000;

// 2.5%: 2 of a 100 reward, rounded down from 2.5.
const FEE_BPS: u16 = 250;
const FEE_QTY: u64 = 2;
// 2.5% of a 1,010 GOLD reward: 25, rounded down from 25.25.
const GOLD_FEE_QTY: u64 = 25;
// 10%: 10 of a 100 reward.
const NEW_FEE_BPS: u16 = 1_000;
const NEW_FEE_QTY: u64 = 10;
const MAX_BPS: u16 = 10_000;

const START_MS: u64 = 1_000;
const ACCEPT_BY_MS: u64 = 5_000;
const ACCEPT_MS: u64 = 4_000; // ACCEPT_BY_MS - START_MS, posting at START_MS
const HAUL_MS: u64 = 10_000;
const ACCEPT_AT_MS: u64 = 2_000;
const DEADLINE_MS: u64 = 12_000; // ACCEPT_AT_MS + HAUL_MS

// === Fixtures ===

fun src(): ID { object::id_from_address(@0x51) }

fun dst(): ID { object::id_from_address(@0xD5) }

fun mint(collection: ID, asset_id: u64, qty: u64, scenario: &mut Scenario): Balance {
    multicoin::create_balance_for_testing(collection, asset_id, qty, scenario.ctx())
}

fun want(): Spec { spec::new(dst(), ITEM, CARGO_QTY) }

fun cargo_spec(): Spec { spec::new(src(), ITEM, CARGO_QTY) }

/// The standard want and windows, paying BENEFICIARY, with `collateral`.
fun standard_terms(collateral: u64): Terms {
    terms::new(want(), collateral, ACCEPT_MS, HAUL_MS, BENEFICIARY)
}

fun currency<T>(): TypeName { type_name::with_original_ids<T>() }

fun coin<T>(amount: u64, scenario: &mut Scenario): Coin<T> {
    coin::mint_for_testing(amount, scenario.ctx())
}

fun coins<T>(scenario: &Scenario, owner: address): u64 { test_config::coins<T>(scenario, owner) }

/// A posting fee of `amount` FEE.
fun post_fee(amount: u64): PostFee { config::post_fee_for_testing<FEE>(amount) }

/// ADMIN shares a config approving TOKEN, with `post_fee`, `bps` and TREASURY,
/// and holds the admin cap.
fun setup(post_fee: Option<PostFee>, bps: u16): (Scenario, Clock) {
    let mut scenario = ts::begin(ADMIN);
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(START_MS);
    let mut config = config::new_for_testing(post_fee, bps, TREASURY, scenario.ctx());
    config.approve_for_testing<TOKEN>();
    config.share_for_testing();
    transfer::public_transfer(config::new_admin_cap_for_testing(scenario.ctx()), ADMIN);
    (scenario, clock)
}

fun finish(scenario: Scenario, clock: Clock) {
    clock.destroy_for_testing();
    scenario.end();
}

/// In a new ADMIN transaction, run `f` on the config with the admin cap.
macro fun admin($scenario: &mut Scenario, $f: |&AdminCap, &mut Config|) {
    let scenario = $scenario;
    scenario.next_tx(ADMIN);
    let cap = scenario.take_from_sender<AdminCap>();
    let mut config = scenario.take_shared<Config>();
    $f(&cap, &mut config);
    ts::return_shared(config);
    scenario.return_to_sender(cap);
}

/// In the current LISTER transaction, post the standard cargo for `reward`,
/// asking `collateral` of the same coin and paying `post_fee`; LISTER keeps the
/// cap. Returns `(agreement_id, cap_id)`.
fun post_in<T, F>(
    reward: Coin<T>,
    collateral: u64,
    post_fee: Coin<F>,
    scenario: &mut Scenario,
    clock: &Clock,
): (ID, ID) {
    let config = scenario.take_shared<Config>();
    let cargo = mint(src(), ITEM, CARGO_QTY, scenario);
    let cap = hauling::post(
        cargo, reward, standard_terms(collateral), &config, post_fee, clock, scenario.ctx(),
    );
    ts::return_shared(config);
    let (agreement_id, cap_id) = (cap.cap_agreement_id(), object::id(&cap));
    transfer::public_transfer(cap, LISTER);
    (agreement_id, cap_id)
}

/// `post_in` for the standard TOKEN agreement with a reward of `reward_qty`.
fun post_with<F>(
    reward_qty: u64,
    post_fee: Coin<F>,
    scenario: &mut Scenario,
    clock: &Clock,
): (ID, ID) {
    let reward = coin<TOKEN>(reward_qty, scenario);
    post_in(reward, COLLATERAL_QTY, post_fee, scenario, clock)
}

/// LISTER posts the standard agreement, paying a posting fee of
/// `post_fee_qty` FEE. The posting transaction is still current.
fun post(post_fee_qty: u64, scenario: &mut Scenario, clock: &Clock): ID {
    scenario.next_tx(LISTER);
    let fee = coin<FEE>(post_fee_qty, scenario);
    let (agreement_id, _) = post_with(REWARD_QTY, fee, scenario, clock);
    agreement_id
}

/// LISTER posts the standard agreement with an empty posting fee.
fun post_free(scenario: &mut Scenario, clock: &Clock): ID {
    scenario.next_tx(LISTER);
    let fee = coin::zero<TOKEN>(scenario.ctx());
    let (agreement_id, _) = post_with(REWARD_QTY, fee, scenario, clock);
    agreement_id
}

/// HAULER accepts `agreement_id`, paid in `T`, at ACCEPT_AT_MS, locking
/// `collateral`, and keeps the cargo.
fun accept_in<T>(agreement_id: ID, collateral: u64, scenario: &mut Scenario, clock: &mut Clock) {
    clock.set_for_testing(ACCEPT_AT_MS);
    scenario.next_tx(HAULER);
    let collateral = coin<T>(collateral, scenario);
    let mut agreement = scenario.take_shared_by_id<HaulingAgreement<T>>(agreement_id);
    let cargo = agreement.accept(collateral, clock, scenario.ctx());
    transfer::public_transfer(cargo, HAULER);
    ts::return_shared(agreement);
}

/// HAULER accepts the standard TOKEN agreement `agreement_id`.
fun accept(agreement_id: ID, scenario: &mut Scenario, clock: &mut Clock) {
    accept_in<TOKEN>(agreement_id, COLLATERAL_QTY, scenario, clock);
}

/// OTHER delivers `agreement_id`, paid in `T`, just before the deadline. The
/// delivering transaction is still current.
fun deliver_in<T>(agreement_id: ID, scenario: &mut Scenario, clock: &mut Clock) {
    clock.set_for_testing(DEADLINE_MS - 1);
    scenario.next_tx(OTHER);
    let delivered = mint(dst(), ITEM, CARGO_QTY, scenario);
    let agreement = scenario.take_shared_by_id<HaulingAgreement<T>>(agreement_id);
    agreement.deliver(delivered, clock, scenario.ctx());
}

/// OTHER delivers the TOKEN agreement `agreement_id`.
fun deliver(agreement_id: ID, scenario: &mut Scenario, clock: &mut Clock) {
    deliver_in<TOKEN>(agreement_id, scenario, clock);
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

/// `T` coins of beneficiary, hauler, lister and treasury, checked in a fresh
/// transaction.
fun assert_coins<T>(
    scenario: &mut Scenario,
    beneficiary: u64,
    hauler: u64,
    lister: u64,
    treasury: u64,
) {
    scenario.next_tx(OTHER);
    assert_eq!(coins<T>(scenario, BENEFICIARY), beneficiary);
    assert_eq!(coins<T>(scenario, HAULER), hauler);
    assert_eq!(coins<T>(scenario, LISTER), lister);
    assert_eq!(coins<T>(scenario, TREASURY), treasury);
}

/// The single `AgreementDelivered` event of the standard TOKEN agreement, with
/// the hauler's net reward and the fee.
fun assert_delivered_event(agreement_id: ID, net_reward: u64, fee: u64, treasury: address) {
    assert_eq!(
        event::events_by_type<AgreementDelivered>(),
        vector[
            hauling::delivered_event_for_testing(
                agreement_id, LISTER, HAULER, option::none(), BENEFICIARY, want(),
                currency<TOKEN>(), net_reward, COLLATERAL_QTY, fee, treasury,
            ),
        ],
    );
}

// === Init ===

/// Publishing shares a config with no currencies and no fees that pays the
/// publisher, and gives the publisher the admin cap.
#[test]
fun init_shares_fee_free_config_and_gives_publisher_the_cap() {
    let mut scenario = ts::begin(ADMIN);
    config::init_for_testing(scenario.ctx());

    scenario.next_tx(ADMIN);
    let config = scenario.take_shared<Config>();
    assert_eq!(config.currencies(), vector[]);
    assert!(!config.is_approved<TOKEN>());
    assert_eq!(config.post_fee(), option::none());
    assert_eq!(config.delivery_fee_bps(), 0);
    assert_eq!(config.treasury(), ADMIN);
    let cap = scenario.take_from_sender<AdminCap>();
    ts::return_shared(config);
    scenario.return_to_sender(cap);
    scenario.end();
}

// === Admin ===

/// Each fee and treasury setter changes one field and emits the whole config
/// after the change, currencies included.
#[test]
fun admin_setters_update_config_and_emit_events() {
    let (mut scenario, clock) = setup(option::none(), 0);
    scenario.next_tx(ADMIN);
    let cap = scenario.take_from_sender<AdminCap>();
    let mut config = scenario.take_shared<Config>();
    let config_id = object::id(&config);

    config::set_post_fee<FEE>(&cap, &mut config, POST_FEE_QTY);
    let fee = config.post_fee().destroy_some();
    assert_eq!(fee.post_fee_currency(), currency<FEE>());
    assert_eq!(fee.post_fee_amount(), POST_FEE_QTY);
    config::set_delivery_fee_bps(&cap, &mut config, MAX_BPS);
    config::set_treasury(&cap, &mut config, NEW_TREASURY);
    assert_eq!(config.post_fee(), option::some(post_fee(POST_FEE_QTY)));
    assert_eq!(config.delivery_fee_bps(), MAX_BPS);
    assert_eq!(config.treasury(), NEW_TREASURY);
    // A new posting fee replaces the old one, coin type included.
    let gold_fee = config::post_fee_for_testing<GOLD>(NEW_POST_FEE_QTY);
    config::set_post_fee<GOLD>(&cap, &mut config, NEW_POST_FEE_QTY);
    assert_eq!(config.post_fee(), option::some(gold_fee));
    config::clear_post_fee(&cap, &mut config);
    assert_eq!(config.post_fee(), option::none());

    let tokens = vector[currency<TOKEN>()];
    let some_fee = option::some(post_fee(POST_FEE_QTY));
    assert_eq!(
        event::events_by_type<ConfigUpdated>(),
        vector[
            config::updated_event_for_testing(config_id, tokens, some_fee, 0, TREASURY),
            config::updated_event_for_testing(config_id, tokens, some_fee, MAX_BPS, TREASURY),
            config::updated_event_for_testing(config_id, tokens, some_fee, MAX_BPS, NEW_TREASURY),
            config::updated_event_for_testing(
                config_id, tokens, option::some(gold_fee), MAX_BPS, NEW_TREASURY,
            ),
            config::updated_event_for_testing(
                config_id, tokens, option::none(), MAX_BPS, NEW_TREASURY,
            ),
        ],
    );
    ts::return_shared(config);
    scenario.return_to_sender(cap);
    finish(scenario, clock);
}

/// Approving and revoking currencies emits the whole config, with the
/// currencies after the change in approval order.
#[test]
fun currency_admin_updates_currencies_and_emits_events() {
    let (mut scenario, clock) = setup(option::some(post_fee(POST_FEE_QTY)), FEE_BPS);
    scenario.next_tx(ADMIN);
    let cap = scenario.take_from_sender<AdminCap>();
    let mut config = scenario.take_shared<Config>();
    let config_id = object::id(&config);
    assert_eq!(config.currencies(), vector[currency<TOKEN>()]);
    assert!(!config.is_approved<GOLD>());

    config::approve_currency<GOLD>(&cap, &mut config);
    assert!(config.is_approved<GOLD>());
    assert_eq!(config.currencies(), vector[currency<TOKEN>(), currency<GOLD>()]);
    config::revoke_currency<TOKEN>(&cap, &mut config);
    assert!(!config.is_approved<TOKEN>());
    assert_eq!(config.currencies(), vector[currency<GOLD>()]);
    config::revoke_currency<GOLD>(&cap, &mut config);
    assert_eq!(config.currencies(), vector[]);

    let fee = option::some(post_fee(POST_FEE_QTY));
    assert_eq!(
        event::events_by_type<ConfigUpdated>(),
        vector[
            config::updated_event_for_testing(
                config_id, vector[currency<TOKEN>(), currency<GOLD>()], fee, FEE_BPS, TREASURY,
            ),
            config::updated_event_for_testing(
                config_id, vector[currency<GOLD>()], fee, FEE_BPS, TREASURY,
            ),
            config::updated_event_for_testing(config_id, vector[], fee, FEE_BPS, TREASURY),
        ],
    );
    ts::return_shared(config);
    scenario.return_to_sender(cap);
    finish(scenario, clock);
}

#[test, expected_failure(abort_code = config::ECurrencyAlreadyApproved)]
fun approve_currency_rejects_duplicate() {
    let (mut scenario, clock) = setup(option::none(), 0);
    admin!(&mut scenario, |cap, config| config::approve_currency<TOKEN>(cap, config));
    finish(scenario, clock);
}

#[test, expected_failure(abort_code = config::ECurrencyNotApproved)]
fun revoke_currency_rejects_unapproved() {
    let (mut scenario, clock) = setup(option::none(), 0);
    admin!(&mut scenario, |cap, config| config::revoke_currency<GOLD>(cap, config));
    finish(scenario, clock);
}

#[test, expected_failure(abort_code = config::EInvalidBps)]
fun set_delivery_fee_bps_rejects_over_10_000() {
    let (mut scenario, clock) = setup(option::none(), 0);
    admin!(&mut scenario, |cap, config| config::set_delivery_fee_bps(cap, config, MAX_BPS + 1));
    finish(scenario, clock);
}

/// A posting fee of 0 is not a fee; `clear_post_fee` is how to turn it off.
#[test, expected_failure(abort_code = config::EInvalidPostFee)]
fun set_post_fee_rejects_zero() {
    let (mut scenario, clock) = setup(option::none(), 0);
    admin!(&mut scenario, |cap, config| config::set_post_fee<FEE>(cap, config, 0));
    finish(scenario, clock);
}

/// The fee is computed in u128, so the largest reward at the largest rate
/// does not overflow.
#[test]
fun delivery_fee_on_rounds_down_without_overflow() {
    assert_eq!(config::delivery_fee_on(REWARD_QTY, FEE_BPS), FEE_QTY);
    assert_eq!(config::delivery_fee_on(GOLD_REWARD_QTY, FEE_BPS), GOLD_FEE_QTY);
    assert_eq!(config::delivery_fee_on(39, FEE_BPS), 0);
    assert_eq!(config::delivery_fee_on(40, FEE_BPS), 1);
    assert_eq!(config::delivery_fee_on(REWARD_QTY, 0), 0);
    assert_eq!(config::delivery_fee_on(std::u64::max_value!(), MAX_BPS), std::u64::max_value!());
    assert_eq!(config::delivery_fee_on(std::u64::max_value!(), 1), std::u64::max_value!() / 10_000);
}

// === Currencies ===

#[test, expected_failure(abort_code = config::ECurrencyNotApproved)]
fun draft_rejects_unapproved_currency() {
    let (mut scenario, clock) = setup(option::none(), 0);
    scenario.next_tx(LISTER);
    let reward = coin<GOLD>(GOLD_REWARD_QTY, &mut scenario);
    let fee = coin::zero<GOLD>(scenario.ctx());
    post_in(reward, GOLD_COLLATERAL_QTY, fee, &mut scenario, &clock);
    finish(scenario, clock);
}

/// Once approved, a currency can pay for agreements; the agreement and its
/// event record it.
#[test]
fun approved_currency_can_be_drafted_in() {
    let (mut scenario, clock) = setup(option::none(), FEE_BPS);
    admin!(&mut scenario, |cap, config| config::approve_currency<GOLD>(cap, config));
    scenario.next_tx(LISTER);
    let reward = coin<GOLD>(GOLD_REWARD_QTY, &mut scenario);
    let fee = coin::zero<GOLD>(scenario.ctx());
    let (agreement_id, cap_id) = post_in(reward, GOLD_COLLATERAL_QTY, fee, &mut scenario, &clock);
    assert_eq!(
        event::events_by_type<AgreementPosted>(),
        vector[
            hauling::posted_event_for_testing(
                agreement_id, LISTER, option::none(), cap_id, BENEFICIARY, false, cargo_spec(),
                want(), currency<GOLD>(), GOLD_REWARD_QTY, GOLD_COLLATERAL_QTY, ACCEPT_BY_MS, HAUL_MS,
                vector[],
                option::none(), option::none(), option::none(), FEE_BPS, TREASURY,
            ),
        ],
    );
    scenario.next_tx(OTHER);
    let agreement = scenario.take_shared_by_id<HaulingAgreement<GOLD>>(agreement_id);
    assert_eq!(agreement.currency(), currency<GOLD>());
    assert_eq!(agreement.reward(), GOLD_REWARD_QTY);
    assert_eq!(agreement.collateral_amount(), GOLD_COLLATERAL_QTY);
    ts::return_shared(agreement);
    finish(scenario, clock);
}

#[test, expected_failure(abort_code = config::ECurrencyNotApproved)]
fun revoked_currency_cannot_be_drafted_in() {
    let (mut scenario, clock) = setup(option::none(), 0);
    admin!(&mut scenario, |cap, config| config::revoke_currency<TOKEN>(cap, config));
    post_free(&mut scenario, &clock);
    finish(scenario, clock);
}

/// Revoking a currency stops only new agreements: one posted before is still
/// accepted and delivered in it, with its own delivery fee.
#[test]
fun revoke_currency_leaves_existing_agreements_to_deliver() {
    let (mut scenario, mut clock) = setup(option::none(), FEE_BPS);
    let agreement_id = post_free(&mut scenario, &clock);
    admin!(&mut scenario, |cap, config| config::revoke_currency<TOKEN>(cap, config));
    accept(agreement_id, &mut scenario, &mut clock);
    deliver(agreement_id, &mut scenario, &mut clock);
    assert_delivered_event(agreement_id, REWARD_QTY - FEE_QTY, FEE_QTY, TREASURY);
    assert_coins<TOKEN>(&mut scenario, 0, REWARD_QTY - FEE_QTY + COLLATERAL_QTY, 0, FEE_QTY);
    finish(scenario, clock);
}

/// An accepted agreement in a revoked currency still defaults in it.
#[test]
fun revoke_currency_leaves_existing_agreements_to_default() {
    let (mut scenario, mut clock) = setup(option::none(), FEE_BPS);
    let agreement_id = post_free(&mut scenario, &clock);
    accept(agreement_id, &mut scenario, &mut clock);
    admin!(&mut scenario, |cap, config| config::revoke_currency<TOKEN>(cap, config));

    clock.set_for_testing(DEADLINE_MS);
    scenario.next_tx(OTHER);
    let agreement = scenario.take_shared<HaulingAgreement<TOKEN>>();
    agreement.default(&clock, scenario.ctx());
    assert_eq!(event::events_by_type<AgreementDefaulted>().length(), 1);
    assert_coins<TOKEN>(&mut scenario, REWARD_QTY + COLLATERAL_QTY, 0, 0, 0);
    finish(scenario, clock);
}

/// An open agreement in a revoked currency can still be cancelled, returning
/// the reward in that currency.
#[test]
fun revoke_currency_leaves_open_agreements_cancellable() {
    let (mut scenario, clock) = setup(option::none(), 0);
    post_free(&mut scenario, &clock);
    admin!(&mut scenario, |cap, config| config::revoke_currency<TOKEN>(cap, config));

    scenario.next_tx(LISTER);
    let cap = scenario.take_from_sender<ListerCap>();
    let agreement = scenario.take_shared<HaulingAgreement<TOKEN>>();
    let (cargo, reward) = agreement.cancel(cap, &clock, scenario.ctx());
    assert_eq!(reward.value(), REWARD_QTY);
    transfer::public_transfer(cargo, LISTER);
    transfer::public_transfer(reward, LISTER);
    assert_coins<TOKEN>(&mut scenario, 0, 0, REWARD_QTY, 0);
    finish(scenario, clock);
}

/// Two agreements in two approved currencies: each takes its collateral and
/// pays its reward and delivery fee in its own coin.
#[test]
fun two_currencies_each_pay_out_in_their_own_coin() {
    let (mut scenario, mut clock) = setup(option::none(), FEE_BPS);
    admin!(&mut scenario, |cap, config| config::approve_currency<GOLD>(cap, config));
    let token_id = post_free(&mut scenario, &clock);
    scenario.next_tx(LISTER);
    let reward = coin<GOLD>(GOLD_REWARD_QTY, &mut scenario);
    let fee = coin::zero<GOLD>(scenario.ctx());
    let (gold_id, _) = post_in(reward, GOLD_COLLATERAL_QTY, fee, &mut scenario, &clock);

    accept(token_id, &mut scenario, &mut clock);
    accept_in<GOLD>(gold_id, GOLD_COLLATERAL_QTY, &mut scenario, &mut clock);
    deliver(token_id, &mut scenario, &mut clock);
    assert_delivered_event(token_id, REWARD_QTY - FEE_QTY, FEE_QTY, TREASURY);
    deliver_in<GOLD>(gold_id, &mut scenario, &mut clock);
    assert_eq!(
        event::events_by_type<AgreementDelivered>(),
        vector[
            hauling::delivered_event_for_testing(
                gold_id, LISTER, HAULER, option::none(), BENEFICIARY, want(), currency<GOLD>(),
                GOLD_REWARD_QTY - GOLD_FEE_QTY, GOLD_COLLATERAL_QTY, GOLD_FEE_QTY, TREASURY,
            ),
        ],
    );

    assert_coins<TOKEN>(&mut scenario, 0, REWARD_QTY - FEE_QTY + COLLATERAL_QTY, 0, FEE_QTY);
    assert_coins<GOLD>(
        &mut scenario,
        0,
        GOLD_REWARD_QTY - GOLD_FEE_QTY + GOLD_COLLATERAL_QTY,
        0,
        GOLD_FEE_QTY,
    );
    finish(scenario, clock);
}

// === Posting fee ===

/// The exact posting fee, in its own coin type, goes to the treasury; the
/// agreement and its event record the fee terms.
#[test]
fun post_fee_paid_exactly_goes_to_treasury() {
    let (mut scenario, clock) = setup(option::some(post_fee(POST_FEE_QTY)), FEE_BPS);
    scenario.next_tx(LISTER);
    let fee = coin<FEE>(POST_FEE_QTY, &mut scenario);
    let (agreement_id, cap_id) = post_with(REWARD_QTY, fee, &mut scenario, &clock);
    assert_eq!(
        event::events_by_type<AgreementPosted>(),
        vector[
            hauling::posted_event_for_testing(
                agreement_id, LISTER, option::none(), cap_id, BENEFICIARY, false, cargo_spec(),
                want(), currency<TOKEN>(), REWARD_QTY, COLLATERAL_QTY, ACCEPT_BY_MS, HAUL_MS, vector[],
                option::none(), option::none(), option::some(post_fee(POST_FEE_QTY)), FEE_BPS, TREASURY,
            ),
        ],
    );

    scenario.next_tx(OTHER);
    let agreement = scenario.take_shared<HaulingAgreement<TOKEN>>();
    assert_eq!(agreement.post_fee(), option::some(post_fee(POST_FEE_QTY)));
    assert_eq!(agreement.delivery_fee_bps(), FEE_BPS);
    assert_eq!(agreement.treasury(), TREASURY);
    ts::return_shared(agreement);
    assert_coins<FEE>(&mut scenario, 0, 0, 0, POST_FEE_QTY);
    assert_coins<TOKEN>(&mut scenario, 0, 0, 0, 0);
    finish(scenario, clock);
}

/// The posting fee may be charged in an approved currency too; it is then
/// paid separately from the reward.
#[test]
fun post_fee_may_be_in_the_reward_currency() {
    let fee = config::post_fee_for_testing<TOKEN>(POST_FEE_QTY);
    let (mut scenario, clock) = setup(option::some(fee), 0);
    scenario.next_tx(LISTER);
    let paid = coin<TOKEN>(POST_FEE_QTY, &mut scenario);
    post_with(REWARD_QTY, paid, &mut scenario, &clock);
    assert_coins<TOKEN>(&mut scenario, 0, 0, 0, POST_FEE_QTY);
    finish(scenario, clock);
}

#[test, expected_failure(abort_code = config::EWrongPostFeeAmount)]
fun post_rejects_short_post_fee() {
    let (mut scenario, clock) = setup(option::some(post_fee(POST_FEE_QTY)), 0);
    post(POST_FEE_QTY - 1, &mut scenario, &clock);
    finish(scenario, clock);
}

/// The posting fee is exact: overpaying is rejected, not partly refunded.
#[test, expected_failure(abort_code = config::EWrongPostFeeAmount)]
fun post_rejects_excess_post_fee() {
    let (mut scenario, clock) = setup(option::some(post_fee(POST_FEE_QTY)), 0);
    post(POST_FEE_QTY + 1, &mut scenario, &clock);
    finish(scenario, clock);
}

/// An empty coin is not a way around a posting fee.
#[test, expected_failure(abort_code = config::EWrongPostFeeAmount)]
fun post_rejects_empty_post_fee_when_one_is_set() {
    let (mut scenario, clock) = setup(option::some(post_fee(POST_FEE_QTY)), 0);
    post(0, &mut scenario, &clock);
    finish(scenario, clock);
}

#[test, expected_failure(abort_code = config::EWrongPostFeeCurrency)]
fun post_rejects_post_fee_in_wrong_coin_type() {
    let (mut scenario, clock) = setup(option::some(post_fee(POST_FEE_QTY)), 0);
    scenario.next_tx(LISTER);
    let fee = coin<GOLD>(POST_FEE_QTY, &mut scenario);
    post_with(REWARD_QTY, fee, &mut scenario, &clock);
    finish(scenario, clock);
}

/// Approving a coin for rewards does not make it the posting fee's coin.
#[test, expected_failure(abort_code = config::EWrongPostFeeCurrency)]
fun post_rejects_post_fee_in_reward_currency() {
    let (mut scenario, clock) = setup(option::some(post_fee(POST_FEE_QTY)), 0);
    scenario.next_tx(LISTER);
    let fee = coin<TOKEN>(POST_FEE_QTY, &mut scenario);
    post_with(REWARD_QTY, fee, &mut scenario, &clock);
    finish(scenario, clock);
}

/// With no posting fee set, paying one anyway aborts rather than gifting it to
/// the treasury.
#[test, expected_failure(abort_code = config::EUnexpectedFee)]
fun post_rejects_fee_when_none_is_set() {
    let (mut scenario, clock) = setup(option::none(), 0);
    post(1, &mut scenario, &clock);
    finish(scenario, clock);
}

/// With no posting fee set, an empty coin of any type, approved or not, is
/// accepted and destroyed; the treasury receives nothing.
#[test]
fun post_accepts_empty_coin_of_any_type_when_no_fee_is_set() {
    let (mut scenario, clock) = setup(option::none(), FEE_BPS);
    scenario.next_tx(LISTER);
    let fee = coin::zero<GOLD>(scenario.ctx());
    let (agreement_id, cap_id) = post_with(REWARD_QTY, fee, &mut scenario, &clock);
    assert_eq!(
        event::events_by_type<AgreementPosted>(),
        vector[
            hauling::posted_event_for_testing(
                agreement_id, LISTER, option::none(), cap_id, BENEFICIARY, false, cargo_spec(),
                want(), currency<TOKEN>(), REWARD_QTY, COLLATERAL_QTY, ACCEPT_BY_MS, HAUL_MS, vector[],
                option::none(), option::none(), option::none(), FEE_BPS, TREASURY,
            ),
        ],
    );
    scenario.next_tx(OTHER);
    assert_eq!(test_config::coin_count<GOLD>(TREASURY), 0);
    assert_eq!(test_config::coin_count<TOKEN>(TREASURY), 0);
    finish(scenario, clock);
}

/// Clearing the posting fee lets the next agreement post with an empty coin.
#[test]
fun clear_post_fee_lets_listers_post_free() {
    let (mut scenario, clock) = setup(option::some(post_fee(POST_FEE_QTY)), 0);
    admin!(&mut scenario, |cap, config| config::clear_post_fee(cap, config));
    let agreement_id = post_free(&mut scenario, &clock);
    scenario.next_tx(OTHER);
    let agreement = scenario.take_shared_by_id<HaulingAgreement<TOKEN>>(agreement_id);
    assert_eq!(agreement.post_fee(), option::none());
    ts::return_shared(agreement);
    assert_eq!(test_config::coin_count<FEE>(TREASURY), 0);
    finish(scenario, clock);
}

/// Cancelling returns cargo and reward to the cap holder; the posting fee
/// stays with the treasury.
#[test]
fun cancel_does_not_refund_post_fee() {
    let (mut scenario, clock) = setup(option::some(post_fee(POST_FEE_QTY)), FEE_BPS);
    post(POST_FEE_QTY, &mut scenario, &clock);

    scenario.next_tx(LISTER);
    let cap = scenario.take_from_sender<ListerCap>();
    let agreement = scenario.take_shared<HaulingAgreement<TOKEN>>();
    let (cargo, reward) = agreement.cancel(cap, &clock, scenario.ctx());
    assert_eq!(spec::of(&cargo), cargo_spec());
    assert_eq!(reward.value(), REWARD_QTY);
    transfer::public_transfer(cargo, LISTER);
    transfer::public_transfer(reward, LISTER);
    assert_coins<TOKEN>(&mut scenario, 0, 0, REWARD_QTY, 0);
    assert_coins<FEE>(&mut scenario, 0, 0, 0, POST_FEE_QTY);
    finish(scenario, clock);
}

// === Delivery fee ===

/// 250 bps of a 100 reward is 2.5, rounded down to 2 for the treasury. The
/// hauler gets the other 98 and all their collateral back.
#[test]
fun deliver_sends_fee_to_treasury_rounded_down() {
    let (mut scenario, mut clock) = setup(option::none(), FEE_BPS);
    let agreement_id = post_free(&mut scenario, &clock);
    accept(agreement_id, &mut scenario, &mut clock);
    deliver(agreement_id, &mut scenario, &mut clock);
    assert_delivered_event(agreement_id, REWARD_QTY - FEE_QTY, FEE_QTY, TREASURY);

    assert_coins<TOKEN>(&mut scenario, 0, REWARD_QTY - FEE_QTY + COLLATERAL_QTY, 0, FEE_QTY);
    scenario.next_tx(OTHER);
    assert_eq!(owned(&scenario, BENEFICIARY, dst(), ITEM), CARGO_QTY);
    finish(scenario, clock);
}

/// At 0 bps nothing is split off: no coin reaches the treasury, and the event
/// reports a 0 fee.
#[test]
fun deliver_at_zero_bps_takes_no_fee() {
    let (mut scenario, mut clock) = setup(option::none(), 0);
    let agreement_id = post_free(&mut scenario, &clock);
    accept(agreement_id, &mut scenario, &mut clock);
    deliver(agreement_id, &mut scenario, &mut clock);
    assert_delivered_event(agreement_id, REWARD_QTY, 0, TREASURY);

    scenario.next_tx(OTHER);
    assert_eq!(test_config::coin_count<TOKEN>(TREASURY), 0);
    assert_coins<TOKEN>(&mut scenario, 0, REWARD_QTY + COLLATERAL_QTY, 0, 0);
    finish(scenario, clock);
}

/// At 10,000 bps the whole reward is the fee; the hauler only gets their
/// collateral back, and no empty reward coin.
#[test]
fun deliver_at_max_bps_takes_whole_reward() {
    let (mut scenario, mut clock) = setup(option::none(), MAX_BPS);
    let agreement_id = post_free(&mut scenario, &clock);
    accept(agreement_id, &mut scenario, &mut clock);
    deliver(agreement_id, &mut scenario, &mut clock);
    assert_delivered_event(agreement_id, 0, REWARD_QTY, TREASURY);

    assert_coins<TOKEN>(&mut scenario, 0, COLLATERAL_QTY, 0, REWARD_QTY);
    assert_eq!(test_config::coin_count<TOKEN>(HAULER), 1);
    finish(scenario, clock);
}

/// A reward small enough that the fee rounds down to 0 pays no fee.
#[test]
fun deliver_fee_rounds_down_to_zero_on_small_reward() {
    let (mut scenario, mut clock) = setup(option::none(), FEE_BPS);
    scenario.next_tx(LISTER);
    let fee = coin::zero<TOKEN>(scenario.ctx());
    let (agreement_id, _) = post_with(39, fee, &mut scenario, &clock);
    accept(agreement_id, &mut scenario, &mut clock);
    deliver(agreement_id, &mut scenario, &mut clock);
    assert_delivered_event(agreement_id, 39, 0, TREASURY);

    scenario.next_tx(OTHER);
    assert_eq!(test_config::coin_count<TOKEN>(TREASURY), 0);
    assert_coins<TOKEN>(&mut scenario, 0, 39 + COLLATERAL_QTY, 0, 0);
    finish(scenario, clock);
}

/// An agreement may offer no reward; with a delivery fee set it pays a 0 fee.
/// Neither the hauler nor the treasury is sent an empty coin.
#[test]
fun deliver_zero_reward_pays_zero_fee() {
    let (mut scenario, mut clock) = setup(option::none(), FEE_BPS);
    scenario.next_tx(LISTER);
    let fee = coin::zero<TOKEN>(scenario.ctx());
    let (agreement_id, _) = post_with(0, fee, &mut scenario, &clock);
    accept(agreement_id, &mut scenario, &mut clock);
    deliver(agreement_id, &mut scenario, &mut clock);
    assert_delivered_event(agreement_id, 0, 0, TREASURY);

    scenario.next_tx(OTHER);
    assert_eq!(test_config::coin_count<TOKEN>(TREASURY), 0);
    assert_eq!(test_config::coin_count<TOKEN>(HAULER), 1);
    assert_coins<TOKEN>(&mut scenario, 0, COLLATERAL_QTY, 0, 0);
    finish(scenario, clock);
}

/// An observer's record keeps the escrowed reward, before the delivery fee,
/// and the currency it is paid in.
#[test]
fun outcome_record_keeps_gross_reward() {
    let (mut scenario, mut clock) = setup(option::none(), FEE_BPS);
    scenario.next_tx(OTHER);
    let ledger_id = ext::new_ledger(OTHER, scenario.ctx());

    scenario.next_tx(LISTER);
    let config = scenario.take_shared<Config>();
    let cargo = mint(src(), ITEM, CARGO_QTY, &mut scenario);
    let reward = coin<TOKEN>(REWARD_QTY, &mut scenario);
    let fee = coin::zero<TOKEN>(scenario.ctx());
    let mut d = hauling::draft(
        cargo, reward, standard_terms(COLLATERAL_QTY), &config, fee, &clock, scenario.ctx(),
    );
    ts::return_shared(config);
    let ledger = scenario.take_shared_by_id<Ledger>(ledger_id);
    let observer_fee = mint(object::id_from_address(@0x70), 0, OBSERVER_FEE_QTY, &mut scenario);
    ext::bind_ledger(&ledger, &mut d, observer_fee);
    ts::return_shared(ledger);
    let cap = d.publish();
    let agreement_id = cap.cap_agreement_id();
    transfer::public_transfer(cap, LISTER);

    accept(agreement_id, &mut scenario, &mut clock);
    deliver(agreement_id, &mut scenario, &mut clock);
    assert_delivered_event(agreement_id, REWARD_QTY - FEE_QTY, FEE_QTY, TREASURY);

    scenario.next_tx(OTHER);
    let mut ledger = scenario.take_shared_by_id<Ledger>(ledger_id);
    let ticket = ts::most_recent_receiving_ticket<OutcomeRecord>(&ledger_id);
    let record = ext::take_record(&mut ledger, ticket);
    assert_eq!(record.record_currency(), currency<TOKEN>());
    assert_eq!(record.record_reward(), REWARD_QTY);
    assert_eq!(record.record_collateral(), option::some(COLLATERAL_QTY));
    record.delete_outcome();
    ts::return_shared(ledger);
    finish(scenario, clock);
}

// === Default and forfeit ===

/// Default pays the beneficiary the whole reward and collateral; no fee.
#[test]
fun default_takes_no_delivery_fee() {
    let (mut scenario, mut clock) = setup(option::none(), FEE_BPS);
    let agreement_id = post_free(&mut scenario, &clock);
    accept(agreement_id, &mut scenario, &mut clock);

    clock.set_for_testing(DEADLINE_MS);
    scenario.next_tx(OTHER);
    let agreement = scenario.take_shared<HaulingAgreement<TOKEN>>();
    agreement.default(&clock, scenario.ctx());
    assert_eq!(
        event::events_by_type<AgreementDefaulted>(),
        vector[
            hauling::defaulted_event_for_testing(
                agreement_id, LISTER, HAULER, option::none(), BENEFICIARY, currency<TOKEN>(),
                REWARD_QTY, COLLATERAL_QTY, false,
            ),
        ],
    );
    assert_coins<TOKEN>(&mut scenario, REWARD_QTY + COLLATERAL_QTY, 0, 0, 0);
    finish(scenario, clock);
}

/// Forfeit pays the beneficiary the whole reward and collateral; no fee.
#[test]
fun forfeit_takes_no_delivery_fee() {
    let (mut scenario, mut clock) = setup(option::none(), FEE_BPS);
    let agreement_id = post_free(&mut scenario, &clock);
    accept(agreement_id, &mut scenario, &mut clock);

    scenario.next_tx(HAULER);
    let agreement = scenario.take_shared<HaulingAgreement<TOKEN>>();
    agreement.forfeit(&clock, scenario.ctx());
    assert_eq!(
        event::events_by_type<AgreementDefaulted>(),
        vector[
            hauling::defaulted_event_for_testing(
                agreement_id, LISTER, HAULER, option::none(), BENEFICIARY, currency<TOKEN>(),
                REWARD_QTY, COLLATERAL_QTY, true,
            ),
        ],
    );
    assert_coins<TOKEN>(&mut scenario, REWARD_QTY + COLLATERAL_QTY, 0, 0, 0);
    finish(scenario, clock);
}

/// Defaulting an agreement with no reward sends the beneficiary only the
/// collateral coin, not an empty reward coin.
#[test]
fun default_with_zero_reward_sends_only_collateral() {
    let (mut scenario, mut clock) = setup(option::none(), FEE_BPS);
    scenario.next_tx(LISTER);
    let fee = coin::zero<TOKEN>(scenario.ctx());
    let (agreement_id, _) = post_with(0, fee, &mut scenario, &clock);
    accept(agreement_id, &mut scenario, &mut clock);

    clock.set_for_testing(DEADLINE_MS);
    scenario.next_tx(OTHER);
    let agreement = scenario.take_shared<HaulingAgreement<TOKEN>>();
    agreement.default(&clock, scenario.ctx());
    assert_eq!(
        event::events_by_type<AgreementDefaulted>(),
        vector[
            hauling::defaulted_event_for_testing(
                agreement_id, LISTER, HAULER, option::none(), BENEFICIARY, currency<TOKEN>(), 0,
                COLLATERAL_QTY, false,
            ),
        ],
    );
    scenario.next_tx(OTHER);
    assert_eq!(test_config::coin_count<TOKEN>(BENEFICIARY), 1);
    assert_coins<TOKEN>(&mut scenario, COLLATERAL_QTY, 0, 0, 0);
    finish(scenario, clock);
}

// === Snapshot ===

/// Changing the config after posting leaves an existing agreement's terms
/// alone; an agreement drafted afterwards uses the new ones.
#[test]
fun config_changes_apply_only_to_later_agreements() {
    let (mut scenario, mut clock) = setup(option::none(), FEE_BPS);
    let old_id = post_free(&mut scenario, &clock);

    admin!(&mut scenario, |cap, config| {
        config::set_post_fee<FEE>(cap, config, NEW_POST_FEE_QTY);
        config::set_delivery_fee_bps(cap, config, NEW_FEE_BPS);
        config::set_treasury(cap, config, NEW_TREASURY);
    });
    let new_id = post(NEW_POST_FEE_QTY, &mut scenario, &clock);

    scenario.next_tx(OTHER);
    {
        let old = scenario.take_shared_by_id<HaulingAgreement<TOKEN>>(old_id);
        assert_eq!(old.post_fee(), option::none());
        assert_eq!(old.delivery_fee_bps(), FEE_BPS);
        assert_eq!(old.treasury(), TREASURY);
        ts::return_shared(old);
        let new = scenario.take_shared_by_id<HaulingAgreement<TOKEN>>(new_id);
        assert_eq!(new.post_fee(), option::some(post_fee(NEW_POST_FEE_QTY)));
        assert_eq!(new.delivery_fee_bps(), NEW_FEE_BPS);
        assert_eq!(new.treasury(), NEW_TREASURY);
        ts::return_shared(new);
    };
    // The new posting fee went to the new treasury.
    assert_eq!(coins<FEE>(&scenario, NEW_TREASURY), NEW_POST_FEE_QTY);
    assert_eq!(test_config::coin_count<FEE>(TREASURY), 0);
    assert_eq!(test_config::coin_count<TOKEN>(TREASURY), 0);

    accept(old_id, &mut scenario, &mut clock);
    accept(new_id, &mut scenario, &mut clock);
    deliver(old_id, &mut scenario, &mut clock);
    assert_delivered_event(old_id, REWARD_QTY - FEE_QTY, FEE_QTY, TREASURY);
    deliver(new_id, &mut scenario, &mut clock);
    assert_delivered_event(new_id, REWARD_QTY - NEW_FEE_QTY, NEW_FEE_QTY, NEW_TREASURY);

    scenario.next_tx(OTHER);
    assert_eq!(coins<TOKEN>(&scenario, TREASURY), FEE_QTY);
    assert_eq!(coins<TOKEN>(&scenario, NEW_TREASURY), NEW_FEE_QTY);
    assert_eq!(
        coins<TOKEN>(&scenario, HAULER),
        2 * (REWARD_QTY + COLLATERAL_QTY) - FEE_QTY - NEW_FEE_QTY,
    );
    finish(scenario, clock);
}
