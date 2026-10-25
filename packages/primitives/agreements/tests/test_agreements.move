/// Two stand-in agreement types and a few rules, for the request tests.
///
/// `Lease` and `Auction` each define their own action markers, as a real
/// agreement module would, and only they can open or complete requests for
/// those actions. The rules show the shapes a rule module takes: an allowlist,
/// an identity rule, and a rule that spawns a follow-up.
#[test_only]
module agreements::test_agreements;

use agreements::request::{Self, Frame, Request};
use agreements::requirement::{Self, Requirement};
use std::internal;
use std::type_name;
use sui::bcs;

#[error(code = 0)]
const ENotAllowed: vector<u8> = b"Actor is not on the allowlist";

// === Lease: two actions ===

/// Lease's "sign" action.
public struct Sign has drop {}

/// Lease's "renew" action.
public struct Renew has drop {}

public fun open_sign(
    lease_id: ID,
    identity_rule: Option<type_name::TypeName>,
    requires: vector<Requirement>,
    ctx: &TxContext,
): Request {
    request::new(internal::permit<Sign>(), lease_id, identity_rule, requires, ctx)
}

public fun complete_sign(request: Request, lease_id: ID): (address, Option<ID>) {
    request.complete(internal::permit<Sign>(), lease_id)
}

public fun open_renew(lease_id: ID, requires: vector<Requirement>, ctx: &TxContext): Request {
    request::new(internal::permit<Renew>(), lease_id, option::none(), requires, ctx)
}

public fun complete_renew(request: Request, lease_id: ID): (address, Option<ID>) {
    request.complete(internal::permit<Renew>(), lease_id)
}

// === Rules ===

/// Only the listed addresses may act.
public struct Allowlist has drop {
    allowed: vector<address>,
}

/// Records a character ID for the actor.
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

/// The allowlist rule trying to record an identity it was not trusted with.
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

/// The identity rule trying to record a second identity.
public fun satisfy_character_twice(request: &mut Request, first: ID, second: ID) {
    let (_, frame) = request.take_next(internal::permit<Character>());
    request.set_identity(internal::permit<Character>(), first);
    request.set_identity(internal::permit<Character>(), second);
    frame.destroy_empty_frame();
}

public fun satisfy_chain(request: &mut Request) {
    let (req, mut frame) = request.take_next(internal::permit<Chain>());
    let allowed = bcs::new(req.data()).peel_vec_address();
    frame.require(allowlist(allowed));
    request.enqueue(frame);
}

/// Hands its frame back instead of enqueueing it, so a test can misuse it.
public fun chain_returns_frame(request: &mut Request): Frame {
    let (req, mut frame) = request.take_next(internal::permit<Chain>());
    let allowed = bcs::new(req.data()).peel_vec_address();
    frame.require(allowlist(allowed));
    frame
}

/// Spawns a follow-up, then tries to discard it.
public fun chain_drops_follow_up(request: &mut Request) {
    let (req, mut frame) = request.take_next(internal::permit<Chain>());
    let allowed = bcs::new(req.data()).peel_vec_address();
    frame.require(allowlist(allowed));
    frame.destroy_empty_frame();
}
