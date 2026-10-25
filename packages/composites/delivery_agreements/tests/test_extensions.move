/// Minimal third-party extensions used by `extension_tests`: accept rules, an
/// identity rule and an observer ledger. Each one shows the shape a real
/// extension package would take.
#[test_only]
module delivery_agreements::test_extensions;

use agreements::request::{Frame, Request};
use agreements::requirement::{Self, Requirement};
use agreements::spec;
use delivery_agreements::delivery::{Self, Draft, OutcomeRecord};
use multicoin::multicoin::Balance;
use std::internal;
use sui::bcs;
use sui::transfer::Receiving;

#[error(code = 0)]
const ENotAllowed: vector<u8> = b"Actor is not on the allowlist";

// === Accept rules ===

/// Only the listed addresses may act.
public struct Allowlist has drop {
    allowed: vector<address>,
}

/// Stands in for a rule that verifies a world `AccessCap` and records the
/// character it authorises.
public struct Character has drop {}

/// Spawns an `Allowlist` follow-up when satisfied.
public struct Chain has drop {
    allowed: vector<address>,
}

public fun allowlist(allowed: vector<address>): Requirement {
    requirement::from_config(Allowlist { allowed })
}

public fun character(): Requirement { requirement::from_config(Character {}) }

public fun chain(allowed: vector<address>): Requirement {
    requirement::from_config(Chain { allowed })
}

public fun satisfy_allowlist(request: &mut Request) {
    let (req, frame) = request.take_next(internal::permit<Allowlist>());
    let allowed = bcs::new(req.data()).peel_vec_address();
    assert!(allowed.contains(&request.actor()), ENotAllowed);
    frame.destroy_empty_frame();
}

/// A rule that was not named the identity rule trying to set one anyway.
public fun allowlist_claims_identity(request: &mut Request, identity: ID) {
    request.set_identity(internal::permit<Allowlist>(), identity);
}

public fun satisfy_character(request: &mut Request, character_id: ID) {
    let (_, frame) = request.take_next(internal::permit<Character>());
    request.set_identity(internal::permit<Character>(), character_id);
    frame.destroy_empty_frame();
}

/// Satisfies the requirement but forgets to record the identity.
public fun satisfy_character_without_identity(request: &mut Request) {
    let (_, frame) = request.take_next(internal::permit<Character>());
    frame.destroy_empty_frame();
}

public fun satisfy_chain(request: &mut Request) {
    let (req, mut frame) = request.take_next(internal::permit<Chain>());
    let allowed = bcs::new(req.data()).peel_vec_address();
    frame.require(allowlist(allowed));
    request.enqueue(frame);
}

/// A badly written rule that hands its frame back to the caller instead of
/// enqueueing it.
public fun chain_returns_frame(request: &mut Request): Frame {
    let (req, mut frame) = request.take_next(internal::permit<Chain>());
    let allowed = bcs::new(req.data()).peel_vec_address();
    frame.require(allowlist(allowed));
    frame
}

/// Spawns its follow-up, then tries to discard it instead of enqueueing it.
public fun chain_drops_follow_up(request: &mut Request) {
    let (req, mut frame) = request.take_next(internal::permit<Chain>());
    let allowed = bcs::new(req.data()).peel_vec_address();
    frame.require(allowlist(allowed));
    frame.destroy_empty_frame();
}

/// The identity rule trying to overwrite the identity it already recorded.
public fun satisfy_character_twice(request: &mut Request, first: ID, second: ID) {
    let (_, frame) = request.take_next(internal::permit<Character>());
    request.set_identity(internal::permit<Character>(), first);
    request.set_identity(internal::permit<Character>(), second);
    frame.destroy_empty_frame();
}

// === Observer ===

/// A reputation ledger: counts outcomes and the fees that bought them.
public struct Ledger has key {
    id: UID,
    treasury: address,
    delivered: u64,
    defaulted: u64,
    forfeited: u64,
    cancelled: u64,
    fees_credited: u64,
    last_agreement_id: Option<ID>,
    last_hauler: Option<address>,
    last_hauler_identity: Option<ID>,
}

public fun new_ledger(treasury: address, ctx: &mut TxContext): ID {
    let ledger = Ledger {
        id: object::new(ctx),
        treasury,
        delivered: 0,
        defaulted: 0,
        forfeited: 0,
        cancelled: 0,
        fees_credited: 0,
        last_agreement_id: option::none(),
        last_hauler: option::none(),
        last_hauler_identity: option::none(),
    };
    let id = object::id(&ledger);
    transfer::share_object(ledger);
    id
}

/// Collect the fee and bind this ledger as the agreement's observer. The fee is
/// a multicoin balance, whatever coin the agreement is paid in.
public fun bind_ledger<T>(ledger: &Ledger, draft: &mut Draft<T>, fee: Balance) {
    let paid = spec::of(&fee);
    transfer::public_transfer(fee, ledger.treasury);
    draft.bind_observer(internal::permit<Ledger>(), object::id(ledger), option::some(paid));
}

/// Permissionless crank: fold one outcome record into the ledger.
public fun ingest(ledger: &mut Ledger, ticket: Receiving<OutcomeRecord>) {
    let record = delivery::receive_outcome(internal::permit<Ledger>(), &mut ledger.id, ticket);
    let outcome = record.record_outcome();
    if (outcome.outcome_is_delivered()) ledger.delivered = ledger.delivered + 1;
    if (outcome.outcome_is_defaulted()) ledger.defaulted = ledger.defaulted + 1;
    if (outcome.outcome_forfeited()) ledger.forfeited = ledger.forfeited + 1;
    if (outcome.outcome_is_cancelled()) ledger.cancelled = ledger.cancelled + 1;
    let fee = record.record_observer().binding_fee();
    if (fee.is_some()) ledger.fees_credited = ledger.fees_credited + fee.borrow().qty();
    ledger.last_agreement_id = option::some(record.record_agreement_id());
    ledger.last_hauler = record.record_hauler();
    ledger.last_hauler_identity = record.record_hauler_identity();
    record.delete_outcome();
}

/// Receive one outcome record without folding it in, so a test can inspect it.
public fun take_record(ledger: &mut Ledger, ticket: Receiving<OutcomeRecord>): OutcomeRecord {
    delivery::receive_outcome(internal::permit<Ledger>(), &mut ledger.id, ticket)
}

public fun delivered(l: &Ledger): u64 { l.delivered }

public fun defaulted(l: &Ledger): u64 { l.defaulted }

public fun forfeited(l: &Ledger): u64 { l.forfeited }

public fun cancelled(l: &Ledger): u64 { l.cancelled }

public fun fees_credited(l: &Ledger): u64 { l.fees_credited }

public fun last_agreement_id(l: &Ledger): Option<ID> { l.last_agreement_id }

public fun last_hauler(l: &Ledger): Option<address> { l.last_hauler }

public fun last_hauler_identity(l: &Ledger): Option<ID> { l.last_hauler_identity }

// === Imposter ===

/// A different extension type that reuses a real extension's instance ID.
public struct Imposter has drop {}

public fun bind_imposter_observer<T>(draft: &mut Draft<T>, instance: ID) {
    draft.bind_observer(internal::permit<Imposter>(), instance, option::none());
}
