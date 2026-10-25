/// Make a delivery agreement claimable only by a list of principals.
///
/// A `CanClaim` requirement names the principals, from the shared
/// `roles::acl::Principal`, that may act on the agreement. The actor must
/// satisfy any one of them:
///
/// - `Player { addr }` or `Machine { addr }`: that wallet or service key. A
///   single `Player` reserves the agreement for one player.
/// - `Ou { ou_id }`: any current board member of that OU. It is read live at
///   claim time, so board changes after posting apply to open agreements.
///
/// The list is part of the agreement and is fixed when it is published; who
/// belongs to an OU is not. An agreement with no gate is open to anyone.
///
/// Every successful claim emits `Claimed`, naming the principal the actor
/// matched, so indexers can tell which OU, if any, an actor claimed for.
///
/// The gate does not check the action or the agreement type. `satisfy` and
/// `satisfy_directly` take any `agreements::request::Request`, so the same
/// requirement gates a delivery accept or an action of any other agreement
/// type built on `agreements`. Only `require_to_claim` and
/// `post_for` are specific to delivery.
///
/// ```move
/// // Lister: the haulers OU's board and one freelancer may claim.
/// claim::require_to_claim(&mut draft, vector[acl::ou(haulers_id), acl::player(freelancer)]);
///
/// // A board member of the haulers OU claims, acting as that OU.
/// let mut req = agreement.begin_accept(&clock, ctx);
/// claim::satisfy(&mut req, &haulers);
/// let cargo = agreement.finish_accept(req, collateral, &clock);
///
/// // The freelancer is listed directly and needs no OU.
/// let mut req = agreement.begin_accept(&clock, ctx);
/// claim::satisfy_directly(&mut req);
/// let cargo = agreement.finish_accept(req, collateral, &clock);
/// ```
module agreement_roles::claim;

use agreements::request::Request;
use agreements::requirement::{Self, Requirement};
use agreements::spec::Spec;
use armature::ou::OU;
use delivery_agreements::config::Config;
use delivery_agreements::delivery::{Self, Draft, ListerCap};
use multicoin::multicoin::Balance;
use roles::acl::{Self, Principal};
use std::internal;
use std::type_name::TypeName;
use sui::bcs;
use sui::clock::Clock;
use sui::coin::Coin;
use sui::event;

// === Errors ===

#[error(code = 0)]
const ENotAuthorized: vector<u8> = b"Sender does not satisfy any principal allowed to claim";
#[error(code = 1)]
const EInvalidPrincipals: vector<u8> = b"A claim gate needs between 1 and 32 principals";
#[error(code = 2)]
const ENotClaimGate: vector<u8> = b"Requirement is not a claim gate";

// === Constants ===

/// Most principals one gate may list. Satisfying checks them one by one.
const MAX_PRINCIPALS: u64 = 32;

// === Structs ===

/// Requirement config: the actor must satisfy one of `principals`.
public struct CanClaim has drop {
    principals: vector<Principal>,
}

// === Events ===

/// `actor` satisfied a claim gate on `agreement_id` for `action` (for a
/// delivery accept, `delivery::AcceptAction`) by matching `principal`, the
/// first listed principal they satisfy. An `Ou` principal means they claimed
/// as a board member of that OU. Emitted only if the action completes, since
/// the request must be finished in the same transaction.
public struct Claimed has copy, drop {
    agreement_id: ID,
    action: TypeName,
    actor: address,
    principal: Principal,
}

// === Public Functions ===

/// A requirement only `principals` can satisfy. Attach it with
/// `require_to_accept`, or to another agreement type's action.
public fun requirement(principals: vector<Principal>): Requirement {
    let len = principals.length();
    assert!(len > 0 && len <= MAX_PRINCIPALS, EInvalidPrincipals);
    requirement::from_config(CanClaim { principals })
}

/// Only `principals` may accept the draft.
public fun require_to_claim<T>(draft: &mut Draft<T>, principals: vector<Principal>) {
    draft.require_to_accept(requirement(principals));
}

/// Post an agreement only `principals` can accept: `draft`,
/// `require_to_claim`, `publish`.
public fun post_for<T, F>(
    cargo: Balance,
    reward: Coin<T>,
    want: Spec,
    collateral: u64,
    accept_by_ms: u64,
    haul_ms: u64,
    beneficiary: address,
    principals: vector<Principal>,
    config: &Config,
    post_fee: Coin<F>,
    clock: &Clock,
    ctx: &mut TxContext,
): ListerCap {
    let mut draft = delivery::draft(
        cargo, reward, want, collateral, accept_by_ms, haul_ms, beneficiary, config, post_fee,
        clock, ctx,
    );
    require_to_claim(&mut draft, principals);
    draft.publish(ctx)
}

/// Satisfy the request's next requirement, a claim gate, acting as a member of
/// `org`. `Player` and `Machine` principals match whatever `org` is passed.
public fun satisfy(request: &mut Request, org: &OU) {
    let principals = take_gate(request);
    let actor = request.actor();
    let matched = principals.find_index!(|p| p.satisfies(org, actor));
    emit_claimed(request, principals, matched);
}

/// Satisfy the request's next requirement, a claim gate, as a listed `Player`
/// or `Machine`. No OU is needed.
public fun satisfy_directly(request: &mut Request) {
    let principals = take_gate(request);
    let actor = request.actor();
    let matched = principals.find_index!(|p| p.satisfies_directly(actor));
    emit_claimed(request, principals, matched);
}

/// The principals a claim gate lists. Aborts for other requirements.
public fun principals_of(req: &Requirement): vector<Principal> {
    assert!(req.is<CanClaim>(), ENotClaimGate);
    let mut config = bcs::new(req.data());
    let len = config.peel_vec_length();
    vector::tabulate!(len, |_| acl::peel_principal(&mut config))
}

public fun max_principals(): u64 { MAX_PRINCIPALS }

// === Internal ===

/// Pop the next requirement as a claim gate and return its principals.
fun take_gate(request: &mut Request): vector<Principal> {
    let (req, frame) = request.take_next(internal::permit<CanClaim>());
    frame.destroy_empty_frame();
    principals_of(&req)
}

/// Abort unless a principal matched, then record which one.
fun emit_claimed(request: &Request, principals: vector<Principal>, matched: Option<u64>) {
    assert!(matched.is_some(), ENotAuthorized);
    event::emit(Claimed {
        agreement_id: request.agreement_id(),
        action: request.action(),
        actor: request.actor(),
        principal: principals[matched.destroy_some()],
    });
}

// === Test helpers ===

#[test_only]
public fun claimed_event_for_testing(
    agreement_id: ID, action: TypeName, actor: address, principal: Principal,
): Claimed {
    Claimed { agreement_id, action, actor, principal }
}
