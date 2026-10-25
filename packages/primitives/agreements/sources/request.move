/// Transaction-scoped checklist for one agreement action.
///
/// Adapted from world-contracts `core::request`. `Request` has no abilities: it
/// cannot be stored, copied or dropped. An agreement module opens one with
/// `new` for one of its actions, the transaction satisfies every requirement,
/// and the same module closes it with `complete` against the same agreement.
///
/// An action is a marker type `A` the agreement module defines, such as
/// delivery's `AcceptAction`. `new` and `complete` take `Permit<A>`, so only
/// that module can open or close a request for its actions; a request opened
/// for any other action or agreement cannot complete there.
///
/// Requirements resolve in declaration order. A rule module satisfies the next
/// one with `take_next(Permit<T>)`, may push follow-up requirements through the
/// returned `Frame`, and must return the frame with `enqueue` or
/// `destroy_empty_frame`. A frame belongs to the agreement and action of the
/// request it came from and can only be enqueued back onto a matching request.
/// It doesn't record the request itself, so a rule should return its frame
/// before handing control back: a leaked frame can be enqueued later, or onto
/// another open request for the same agreement and action.
///
/// Anyone can open a request for an action type they define. A rule that only
/// means to gate some agreement types should check `is_action<A>` before it
/// takes anything of value.
module agreements::request;

use agreements::requirement::Requirement;
use std::internal::Permit;
use std::type_name::{Self, TypeName};

// === Errors ===

#[error(code = 0)]
const EWrongRequirementType: vector<u8> = b"Next requirement does not match the expected type";
#[error(code = 1)]
const EFrameNotEmpty: vector<u8> = b"Frame still holds an unconsumed requirement";
#[error(code = 2)]
const ERequestNotComplete: vector<u8> = b"Request has unsatisfied requirements";
#[error(code = 3)]
const ENoRequirements: vector<u8> = b"Request has no requirements to take";
#[error(code = 4)]
const EWrongAgreement: vector<u8> = b"Request was created for a different agreement";
#[error(code = 5)]
const ENotIdentityRule: vector<u8> = b"Only the agreement's identity rule may set the identity";
#[error(code = 6)]
const EIdentityAlreadySet: vector<u8> = b"Identity has already been set";
#[error(code = 7)]
const EIdentityMissing: vector<u8> = b"The identity rule did not set an identity";
#[error(code = 8)]
const EWrongAction: vector<u8> = b"Request was created for a different action";
#[error(code = 9)]
const EWrongFrame: vector<u8> = b"Frame came from a request for a different agreement or action";

// === Structs ===

public struct Request {
    /// Agreement this request was created for. `complete` rejects any other.
    agreement_id: ID,
    /// The action's marker type. `complete` rejects any other.
    action: TypeName,
    /// Sender of the transaction that created the request.
    actor: address,
    /// The one rule allowed to record `identity`, if the agreement names one.
    identity_rule: Option<TypeName>,
    /// Identity the identity rule resolved for `actor`, e.g. a character ID.
    identity: Option<ID>,
    /// Outstanding requirements, stored in reverse of declaration order.
    requires: vector<Requirement>,
}

/// Requirements spawned by a rule before they are pushed back onto a request.
/// Bound to the agreement and action of the request `take_next` popped from,
/// so follow-ups cannot be moved onto a request for anything else.
public struct Frame {
    agreement_id: ID,
    action: TypeName,
    pending: vector<Requirement>,
}

// === Opening and completing ===

/// Open a request for action `A` on `agreement_id`, acting as the sender. Only
/// `A`'s module can call this. `requires` is in declaration order, and
/// `identity_rule` names the one requirement type that may record the actor's
/// identity.
public fun new<A>(
    _: Permit<A>,
    agreement_id: ID,
    identity_rule: Option<TypeName>,
    mut requires: vector<Requirement>,
    ctx: &TxContext,
): Request {
    // Stored reversed so `pop_back` yields the first declared requirement first.
    requires.reverse();
    Request {
        agreement_id,
        action: type_name::with_original_ids<A>(),
        actor: ctx.sender(),
        identity_rule,
        identity: option::none(),
        requires,
    }
}

/// Complete a request for action `A` on `agreement_id`, returning
/// `(actor, identity)`. Only `A`'s module can call this. Aborts unless the
/// request was opened for this agreement and action, every requirement has
/// been satisfied, and the identity rule (if any) recorded an identity.
public fun complete<A>(
    request: Request,
    _: Permit<A>,
    agreement_id: ID,
): (address, Option<ID>) {
    let Request {
        agreement_id: for_agreement,
        action,
        actor,
        identity_rule,
        identity,
        requires,
    } = request;
    assert!(for_agreement == agreement_id, EWrongAgreement);
    assert!(action == type_name::with_original_ids<A>(), EWrongAction);
    assert!(requires.length() == 0, ERequestNotComplete);
    assert!(identity_rule.is_none() || identity.is_some(), EIdentityMissing);
    (actor, identity)
}

// === Satisfying requirements ===

/// Pop the next requirement, proving the caller owns type `T` via a `Permit`.
/// Returns the requirement plus a `Frame` the rule can push follow-ups into.
public fun take_next<T>(request: &mut Request, _: Permit<T>): (Requirement, Frame) {
    assert!(request.requires.length() > 0, ENoRequirements);
    let next = request.requires.pop_back();
    assert!(next.is<T>(), EWrongRequirementType);
    (next, Frame { agreement_id: request.agreement_id, action: request.action, pending: vector[] })
}

/// Add a follow-up requirement to a `Frame`. Follow-ups resolve next, in the
/// order they were added.
public fun require(frame: &mut Frame, requirement: Requirement) {
    frame.pending.push_back(requirement);
}

/// Discard an empty `Frame` without touching the request.
public fun destroy_empty_frame(frame: Frame) {
    let Frame { pending, .. } = frame;
    assert!(pending.length() == 0, EFrameNotEmpty);
    pending.destroy_empty();
}

/// Push a rule's follow-up requirements onto the request, ahead of the
/// remaining declared ones. The frame must come from a request for the same
/// agreement and action.
public fun enqueue(request: &mut Request, frame: Frame) {
    let Frame { agreement_id, action, mut pending } = frame;
    assert!(agreement_id == request.agreement_id && action == request.action, EWrongFrame);
    while (!pending.is_empty()) request.requires.push_back(pending.pop_back());
    pending.destroy_empty();
}

/// Record the identity the agreement's identity rule resolved for the actor.
/// Only the rule the agreement named as its identity rule can call this, and
/// only once per request.
public fun set_identity<T>(request: &mut Request, _: Permit<T>, identity: ID) {
    assert!(
        request.identity_rule.is_some_and!(|t| *t == type_name::with_original_ids<T>()),
        ENotIdentityRule,
    );
    assert!(request.identity.is_none(), EIdentityAlreadySet);
    request.identity.fill(identity);
}

// === View Functions ===

public fun agreement_id(r: &Request): ID { r.agreement_id }

/// The action's marker type.
public fun action(r: &Request): TypeName { r.action }

/// True when the request was opened for action `A`.
public fun is_action<A>(r: &Request): bool { r.action == type_name::with_original_ids<A>() }

public fun actor(r: &Request): address { r.actor }

/// The rule allowed to call `set_identity`, if the agreement names one. Lets a
/// rule that can resolve identities tell whether it is expected to.
public fun identity_rule(r: &Request): Option<TypeName> { r.identity_rule }

public fun identity(r: &Request): Option<ID> { r.identity }

/// The outstanding requirements, next one last: the reverse of declaration
/// order, so `take_next` pops from the back. Use `next` for the one it takes.
public fun requires(r: &Request): &vector<Requirement> { &r.requires }

/// Borrow the next requirement (the one `take_next` would pop) without removing
/// it.
public fun next(r: &Request): &Requirement {
    let len = r.requires.length();
    assert!(len > 0, ENoRequirements);
    &r.requires[len - 1]
}

// === Test Functions ===

#[test_only]
public fun destroy_for_testing(r: Request) {
    let Request { .. } = r;
}
