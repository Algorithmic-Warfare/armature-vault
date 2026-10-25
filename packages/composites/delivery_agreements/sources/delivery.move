/// Delivery agreements: a collateralized forward swap of items, paid in a coin.
///
/// A lister escrows `cargo` (a multicoin balance of items) and a `reward` in
/// coin type `T`, and names what counts as delivery (`want`: an exact
/// collection, asset and quantity) and the collateral, also in `T`, a hauler
/// must lock. Accepting locks that collateral and releases the cargo to the
/// hauler at once. Delivering the wanted balance before the deadline pays it to
/// the beneficiary and returns reward plus collateral to the hauler. Missing
/// the deadline lets anyone send reward and collateral to the beneficiary; the
/// hauler may also forfeit them early.
///
/// `T` must be one of the currencies approved in `config` when the agreement
/// is drafted. Reward, collateral and the delivery fee are all in `T`.
///
/// With warehouse receipts, a balance's collection identifies its storage unit
/// and its asset ID the item type, so `cargo` in the source SSU's collection
/// and `want` in the destination's describe a haul between two SSUs. Delivery
/// is a type-and-amount check, so there is nothing to dispute and no adapter
/// to trust. The contract does not check that a collection is a real
/// warehouse-receipt vault; parties must verify collections before posting or
/// accepting.
///
/// Collateral is the lister's only protection once cargo is released. Without
/// an oracle the lister prices it; collateral below the cargo's value plus the
/// reward makes keeping the cargo the hauler's rational choice.
///
/// Delivery also depends on the destination vault being able to mint `want`.
/// Whoever controls that storage unit (often the lister) can take it offline
/// until the deadline and collect the collateral by default. Haulers should
/// check who controls both endpoints before accepting.
///
/// Protocol fees (see `config`): the lister pays the config's flat posting fee
/// when drafting, and delivering sends the agreement's delivery fee, a share of
/// the reward, to the treasury before the hauler is paid. Each agreement fixes
/// its delivery rate and treasury when drafted. Default, forfeit and cancel
/// take no fee, and the posting fee is not refunded.
///
/// The lister and the hauler are the addresses that signed `draft` and the
/// accept. Payouts follow those addresses, not the `ListerCap` or a wrapper
/// object that funded the agreement.
///
/// Extensions. An agreement is built as a `Draft` and frozen by `publish`.
/// Before publishing, the lister may attach two optional extensions, both
/// fixed for the agreement's life:
///
/// - **Accept requirements** decide who may accept. Rule modules satisfy them
///   through a `Request` (see `agreements::request`), and one rule may be trusted to record
///   the hauler's identity, for example a character ID.
/// - **An observer** receives an `OutcomeRecord` for every terminal transition.
///   Records are transferred to the observer's object, so closing an agreement
///   never runs observer code and no party can suppress a record.
///
/// Observers bind with their own `Permit`, so only their module can bind them;
/// they collect any fee in the same call and declare it here.
///
/// Lifecycle: draft -> published (open) -> accepted -> deleted by `deliver`,
/// `forfeit` or `default`. An open agreement is deleted by `cancel`, or, once
/// `accept_by_ms` passes with nobody accepting, by the config admin's
/// `close_lapsed`, which sends the cargo and reward back to the lister.
module delivery_agreements::delivery;

use agreements::request::{Self, Request};
use agreements::requirement::Requirement;
use agreements::spec::{Self, Spec};
use delivery_agreements::config::{Self, AdminCap, Config, PostFee};
use multicoin::multicoin::Balance;
use std::internal::{Self, Permit};
use std::type_name::{Self, TypeName};
use sui::balance;
use sui::clock::Clock;
use sui::coin::{Self, Coin};
use sui::event;
use sui::transfer::Receiving;

// === Errors ===

#[error(code = 0)]
const EInvalidTerms: vector<u8> = b"Agreement terms are invalid";
#[error(code = 1)]
const ENotOpen: vector<u8> = b"Agreement has already been accepted";
#[error(code = 2)]
const ENotAccepted: vector<u8> = b"Agreement has not been accepted";
#[error(code = 3)]
const ETooLate: vector<u8> = b"Deadline has passed";
#[error(code = 4)]
const ETooEarly: vector<u8> = b"Deadline has not passed";
// Codes 5 and 6 (wrong asset, wrong amount) are now `agreements::spec`'s.
#[error(code = 7)]
const EWrongCap: vector<u8> = b"ListerCap belongs to a different agreement";
#[error(code = 8)]
const ENotHauler: vector<u8> = b"Only the hauler can forfeit";
#[error(code = 9)]
const EAlreadyBound: vector<u8> = b"Extension slot is already bound";
#[error(code = 10)]
const EIdentityRuleSet: vector<u8> = b"Agreement already has an identity rule";
#[error(code = 11)]
const EWrongCollateral: vector<u8> = b"Collateral is not exactly the agreed amount";
// Codes 12 to 17, 19 and 20 belonged to arbitration, which has been removed.
#[error(code = 18)]
const EWrongObserver: vector<u8> = b"Record is bound to a different observer";
#[error(code = 21)]
const ENotLapsed: vector<u8> = b"Accept window has not closed";

// === Constants ===

/// Longest accept window (`accept_by_ms` from drafting) and haul window: 30
/// days. Also keeps every derived timestamp from overflowing.
const MAX_DURATION_MS: u64 = 30 * 24 * 60 * 60 * 1000;

// === Structs ===

/// The accept action. Only this module can open or complete a request for it.
public struct AcceptAction has drop {}

/// An extension bound to an agreement before it is shared. `kind` is the
/// extension's marker type: only its module can create `Permit` of it.
/// `instance` says which observer of that kind, for example a registry
/// object. `fee` is what the extension declared it collected when it bound;
/// this module never holds extension fees.
public struct Binding has store, copy, drop {
    kind: TypeName,
    instance: ID,
    fee: Option<Spec>,
}

/// An agreement paid in coin type `T`.
public struct DeliveryAgreement<phantom T> has key {
    id: UID,
    /// Sender of `draft`. Cancelling needs the cap, not this address.
    lister: address,
    /// Receives the delivery, or reward and collateral on default.
    beneficiary: address,
    /// Released to the hauler on accept.
    cargo: Option<Balance>,
    /// What `cargo` held when drafted; kept after accept for outcome records.
    cargo_spec: Spec,
    reward: balance::Balance<T>,
    want: Spec,
    /// What the hauler must lock, in `T`.
    collateral_amount: u64,
    /// Empty until accepted.
    collateral: balance::Balance<T>,
    accept_by_ms: u64,
    haul_ms: u64,
    posted_at_ms: u64,
    /// Resolved in declaration order by `begin_accept`'s request.
    accept_requirements: vector<Requirement>,
    /// The one accept rule trusted to record the hauler's identity.
    identity_rule: Option<TypeName>,
    observer: Option<Binding>,
    /// `none` while open.
    hauler: Option<address>,
    /// Set by the identity rule at accept, if there is one.
    hauler_identity: Option<ID>,
    /// 0 until accepted.
    deadline_ms: u64,
    /// The posting fee paid when drafted, if any.
    post_fee: Option<PostFee>,
    /// Share of the reward taken on delivery, fixed when drafted.
    delivery_fee_bps: u16,
    /// Receives the delivery fee, fixed when drafted.
    treasury: address,
}

/// An agreement being built. Has no abilities, so the transaction that drafts
/// it must `publish` it; extensions can only be attached in between.
public struct Draft<phantom T> {
    agreement: DeliveryAgreement<T>,
}

/// Right to cancel an open agreement. Has `store` so a DAO or other wrapper
/// can custody it.
public struct ListerCap has key, store {
    id: UID,
    agreement_id: ID,
}

/// How an agreement ended. `Lapsed` is the config admin's `close_lapsed`.
public enum Outcome has store, copy, drop {
    Delivered,
    Defaulted { forfeited: bool },
    Cancelled,
    Lapsed,
}

/// Unforgeable record of a terminal transition, sent to the bound observer's
/// `instance` object. Only this module mints records, and the observer collects
/// them with `receive_outcome` whenever it chooses.
public struct OutcomeRecord has key {
    id: UID,
    agreement_id: ID,
    observer: Binding,
    outcome: Outcome,
    lister: address,
    beneficiary: address,
    hauler: Option<address>,
    hauler_identity: Option<ID>,
    /// The rule that attested `hauler_identity`. The lister chooses it, so an
    /// observer must ignore identities from rules it does not trust.
    identity_rule: Option<TypeName>,
    cargo: Spec,
    want: Spec,
    /// The coin type of `reward` and `collateral`.
    currency: TypeName,
    /// The escrowed reward, before any delivery fee.
    reward: u64,
    /// `none` when the agreement was cancelled or lapsed before anyone
    /// accepted.
    collateral: Option<u64>,
    posted_at_ms: u64,
    /// 0 when the agreement was cancelled or lapsed before anyone accepted.
    deadline_ms: u64,
    closed_at_ms: u64,
}

// === Events ===
// Terminal events delete the agreement, so each one records who received
// what; indexers need not join back to `AgreementPosted` to notify parties.
// `currency` is the coin type of every reward, collateral and delivery fee
// amount in the event.

public struct AgreementPosted has copy, drop {
    agreement_id: ID,
    /// Sender of `draft`; may differ from `beneficiary` (e.g. a DAO listing
    /// for its treasury).
    lister: address,
    cap_id: ID,
    beneficiary: address,
    cargo: Spec,
    want: Spec,
    currency: TypeName,
    reward: u64,
    collateral: u64,
    accept_by_ms: u64,
    haul_ms: u64,
    /// In the order an accepting transaction must satisfy them.
    accept_requirements: vector<Requirement>,
    identity_rule: Option<TypeName>,
    observer: Option<Binding>,
    /// Paid to `treasury` by the lister when drafting.
    post_fee: Option<PostFee>,
    /// Share of the reward `deliver` sends to `treasury`.
    delivery_fee_bps: u16,
    treasury: address,
}

public struct AgreementAccepted has copy, drop {
    agreement_id: ID,
    hauler: address,
    hauler_identity: Option<ID>,
    /// The rule that attested `hauler_identity`.
    identity_rule: Option<TypeName>,
    deadline_ms: u64,
}

/// `delivered` went to `beneficiary`; `reward` and `collateral` to `hauler`;
/// `delivery_fee` to `treasury`. `reward` is what the hauler received, after
/// the fee; the two add up to the escrowed reward.
public struct AgreementDelivered has copy, drop {
    agreement_id: ID,
    lister: address,
    hauler: address,
    hauler_identity: Option<ID>,
    beneficiary: address,
    delivered: Spec,
    currency: TypeName,
    reward: u64,
    collateral: u64,
    delivery_fee: u64,
    treasury: address,
}

/// `reward` and `collateral` went to `beneficiary`; `hauler` kept the cargo.
/// `forfeited` is true when the hauler gave up via `forfeit`, false when the
/// deadline passed and anyone called `default`.
public struct AgreementDefaulted has copy, drop {
    agreement_id: ID,
    lister: address,
    hauler: address,
    hauler_identity: Option<ID>,
    beneficiary: address,
    currency: TypeName,
    reward: u64,
    collateral: u64,
    forfeited: bool,
}

/// `cargo` and `reward` were returned to the caller holding the cap.
public struct AgreementCancelled has copy, drop {
    agreement_id: ID,
    cancelled_by: address,
    cargo: Spec,
    currency: TypeName,
    reward: u64,
}

/// Nobody accepted before `accept_by_ms`, and the config admin closed the
/// agreement: `cargo` and `reward` went back to `lister`. `closed_by` sent the
/// transaction.
public struct AgreementLapsed has copy, drop {
    agreement_id: ID,
    lister: address,
    closed_by: address,
    cargo: Spec,
    currency: TypeName,
    reward: u64,
}

// === Drafting ===

/// Start an agreement escrowing `cargo` and `reward`, paid in coin type `T`,
/// which `config` must approve. `collateral` is the amount of `T` a hauler must
/// lock. `accept_by_ms` is an absolute timestamp; `haul_ms` is the delivery
/// window measured from accept. Both windows are at most `max_duration_ms`.
/// `post_fee` must be exactly `config`'s posting fee in its coin type `F` (an
/// empty coin of any type when there is none); it goes to the treasury now and
/// is not refunded. The agreement fixes `config`'s delivery rate and treasury.
/// Attach extensions, then `publish`.
public fun draft<T, F>(
    cargo: Balance,
    reward: Coin<T>,
    want: Spec,
    collateral: u64,
    accept_by_ms: u64,
    haul_ms: u64,
    beneficiary: address,
    config: &Config,
    post_fee: Coin<F>,
    clock: &Clock,
    ctx: &mut TxContext,
): Draft<T> {
    let now = clock.timestamp_ms();
    assert!(accept_by_ms > now && accept_by_ms - now <= MAX_DURATION_MS, EInvalidTerms);
    assert!(haul_ms > 0 && haul_ms <= MAX_DURATION_MS, EInvalidTerms);
    assert!(want.qty() > 0 && collateral > 0, EInvalidTerms);
    config.assert_approved<T>();
    config.collect_post_fee(post_fee);
    Draft {
        agreement: DeliveryAgreement {
            id: object::new(ctx),
            lister: ctx.sender(),
            beneficiary,
            cargo_spec: spec::of(&cargo),
            cargo: option::some(cargo),
            reward: reward.into_balance(),
            want,
            collateral_amount: collateral,
            collateral: balance::zero(),
            accept_by_ms,
            haul_ms,
            posted_at_ms: now,
            accept_requirements: vector[],
            identity_rule: option::none(),
            observer: option::none(),
            hauler: option::none(),
            hauler_identity: option::none(),
            deadline_ms: 0,
            post_fee: config.post_fee(),
            delivery_fee_bps: config.delivery_fee_bps(),
            treasury: config.treasury(),
        },
    }
}

/// Require accepting transactions to satisfy `requirement`, after any added
/// before it.
public fun require_to_accept<T>(draft: &mut Draft<T>, requirement: Requirement) {
    draft.agreement.accept_requirements.push_back(requirement);
}

/// Like `require_to_accept`, and also trust this requirement's rule to record
/// the hauler's identity. An agreement has at most one identity rule, and an
/// accept cannot complete unless it records an identity.
public fun require_identity_to_accept<T>(draft: &mut Draft<T>, requirement: Requirement) {
    assert!(draft.agreement.identity_rule.is_none(), EIdentityRuleSet);
    draft.agreement.identity_rule.fill(requirement.type_name());
    draft.agreement.accept_requirements.push_back(requirement);
}

/// Bind observer `O`; outcome records go to `instance`. Only `O`'s module can
/// call this. It collects any fee itself and declares it as `fee`.
public fun bind_observer<T, O>(
    draft: &mut Draft<T>,
    _: Permit<O>,
    instance: ID,
    fee: Option<Spec>,
) {
    assert!(draft.agreement.observer.is_none(), EAlreadyBound);
    draft.agreement.observer.fill(new_binding<O>(instance, fee));
}

/// Share the agreement. Its terms and extensions are fixed from here.
public fun publish<T>(draft: Draft<T>, ctx: &mut TxContext): ListerCap {
    let Draft { agreement } = draft;
    let agreement_id = object::id(&agreement);
    let cap = ListerCap { id: object::new(ctx), agreement_id };
    event::emit(AgreementPosted {
        agreement_id,
        lister: agreement.lister,
        cap_id: object::id(&cap),
        beneficiary: agreement.beneficiary,
        cargo: spec::of(agreement.cargo.borrow()),
        want: agreement.want,
        currency: type_name::with_original_ids<T>(),
        reward: agreement.reward.value(),
        collateral: agreement.collateral_amount,
        accept_by_ms: agreement.accept_by_ms,
        haul_ms: agreement.haul_ms,
        accept_requirements: agreement.accept_requirements,
        identity_rule: agreement.identity_rule,
        observer: agreement.observer,
        post_fee: agreement.post_fee,
        delivery_fee_bps: agreement.delivery_fee_bps,
        treasury: agreement.treasury,
    });
    transfer::share_object(agreement);
    cap
}

/// `draft` then `publish`, for an agreement with no extensions.
public fun post<T, F>(
    cargo: Balance,
    reward: Coin<T>,
    want: Spec,
    collateral: u64,
    accept_by_ms: u64,
    haul_ms: u64,
    beneficiary: address,
    config: &Config,
    post_fee: Coin<F>,
    clock: &Clock,
    ctx: &mut TxContext,
): ListerCap {
    draft(
        cargo, reward, want, collateral, accept_by_ms, haul_ms, beneficiary, config, post_fee,
        clock, ctx,
    ).publish(ctx)
}

// === Accepting ===

/// Start accepting. Returns the request every accept requirement must be
/// satisfied on, in order, before `finish_accept`.
public fun begin_accept<T>(
    self: &DeliveryAgreement<T>,
    clock: &Clock,
    ctx: &mut TxContext,
): Request {
    assert!(self.hauler.is_none(), ENotOpen);
    assert!(clock.timestamp_ms() < self.accept_by_ms, ETooLate);
    request::new(
        internal::permit<AcceptAction>(),
        object::id(self),
        self.identity_rule,
        self.accept_requirements,
        ctx,
    )
}

/// Lock exactly the agreed collateral and receive the cargo. The request must
/// come from `begin_accept` on this agreement with every requirement
/// satisfied. How the cargo is moved is the hauler's business.
public fun finish_accept<T>(
    self: &mut DeliveryAgreement<T>,
    request: Request,
    collateral: Coin<T>,
    clock: &Clock,
): Balance {
    let (hauler, hauler_identity) = request.complete(
        internal::permit<AcceptAction>(),
        object::id(self),
    );
    assert!(self.hauler.is_none(), ENotOpen);
    let now = clock.timestamp_ms();
    assert!(now < self.accept_by_ms, ETooLate);
    assert!(collateral.value() == self.collateral_amount, EWrongCollateral);
    self.collateral.join(collateral.into_balance());
    self.hauler.fill(hauler);
    self.hauler_identity = hauler_identity;
    self.deadline_ms = now + self.haul_ms;
    event::emit(AgreementAccepted {
        agreement_id: object::id(self),
        hauler,
        hauler_identity,
        identity_rule: self.identity_rule,
        deadline_ms: self.deadline_ms,
    });
    self.cargo.extract()
}

/// `begin_accept` then `finish_accept`. Aborts if the agreement has accept
/// requirements, so they cannot be bypassed.
public fun accept<T>(
    self: &mut DeliveryAgreement<T>,
    collateral: Coin<T>,
    clock: &Clock,
    ctx: &mut TxContext,
): Balance {
    let request = self.begin_accept(clock, ctx);
    self.finish_accept(request, collateral, clock)
}

// === Delivering and defaulting ===

/// Hand in exactly the wanted balance before the deadline. Permissionless:
/// recipients are fixed, so it does not matter who submits. The delivery fee,
/// `reward * delivery_fee_bps / 10,000` rounded down, goes to the treasury and
/// the rest of the reward to the hauler.
public fun deliver<T>(
    self: DeliveryAgreement<T>,
    delivered: Balance,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(self.hauler.is_some(), ENotAccepted);
    assert!(clock.timestamp_ms() < self.deadline_ms, ETooLate);
    self.want.assert_matches(&delivered);
    self.record(Outcome::Delivered, clock, ctx);
    let (agreement_id, lister) = (object::id(&self), self.lister);
    let hauler_identity = self.hauler_identity;
    let (fee_bps, treasury) = (self.delivery_fee_bps, self.treasury);
    let (beneficiary, hauler, mut reward, collateral) = close(self);
    let delivery_fee = config::delivery_fee_on(reward.value(), fee_bps);
    pay(reward.split(delivery_fee), treasury, ctx);
    event::emit(AgreementDelivered {
        agreement_id,
        lister,
        hauler,
        hauler_identity,
        beneficiary,
        delivered: spec::of(&delivered),
        currency: type_name::with_original_ids<T>(),
        reward: reward.value(),
        collateral: collateral.value(),
        delivery_fee,
        treasury,
    });
    transfer::public_transfer(delivered, beneficiary);
    pay(reward, hauler, ctx);
    pay(collateral, hauler, ctx);
}

/// After the deadline, send reward and collateral to the beneficiary.
/// Permissionless, so funds never wait on a party who has walked away. The
/// hauler keeps whatever cargo they still hold.
public fun default<T>(self: DeliveryAgreement<T>, clock: &Clock, ctx: &mut TxContext) {
    assert!(self.hauler.is_some(), ENotAccepted);
    assert!(clock.timestamp_ms() >= self.deadline_ms, ETooEarly);
    pay_default(self, false, clock, ctx);
}

/// The hauler gives up: reward and collateral go to the beneficiary now
/// instead of after the deadline. Same payout as `default`; the hauler keeps
/// whatever cargo they still hold.
public fun forfeit<T>(self: DeliveryAgreement<T>, clock: &Clock, ctx: &mut TxContext) {
    assert!(self.hauler.is_some(), ENotAccepted);
    assert!(*self.hauler.borrow() == ctx.sender(), ENotHauler);
    pay_default(self, true, clock, ctx);
}

/// Delete an open agreement, returning `(cargo, reward)` to the cap holder.
/// Allowed before or after `accept_by_ms`.
public fun cancel<T>(
    self: DeliveryAgreement<T>,
    cap: ListerCap,
    clock: &Clock,
    ctx: &mut TxContext,
): (Balance, Coin<T>) {
    let ListerCap { id: cap_id, agreement_id } = cap;
    cap_id.delete();
    assert!(agreement_id == object::id(&self), EWrongCap);
    assert!(self.hauler.is_none(), ENotOpen);
    self.record(Outcome::Cancelled, clock, ctx);
    let (returned, reward) = close_open(self);
    event::emit(AgreementCancelled {
        agreement_id,
        cancelled_by: ctx.sender(),
        cargo: spec::of(&returned),
        currency: type_name::with_original_ids<T>(),
        reward: reward.value(),
    });
    (returned, coin::from_balance(reward, ctx))
}

/// Delete an open agreement nobody accepted before `accept_by_ms`, sending the
/// cargo and reward to the lister. Only the config's `AdminCap` holder can call
/// it, so a listing whose `ListerCap` was lost, or is held by a wrapper with no
/// way to cancel, still ends. The escrow goes only to the lister, never to the
/// caller.
public fun close_lapsed<T>(
    self: DeliveryAgreement<T>,
    _: &AdminCap,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(self.hauler.is_none(), ENotOpen);
    assert!(clock.timestamp_ms() >= self.accept_by_ms, ENotLapsed);
    self.record(Outcome::Lapsed, clock, ctx);
    let (agreement_id, lister) = (object::id(&self), self.lister);
    let (cargo, reward) = close_open(self);
    event::emit(AgreementLapsed {
        agreement_id,
        lister,
        closed_by: ctx.sender(),
        cargo: spec::of(&cargo),
        currency: type_name::with_original_ids<T>(),
        reward: reward.value(),
    });
    // Like `pay`, send nothing rather than an empty balance.
    if (cargo.value() == 0) cargo.destroy_zero()
    else transfer::public_transfer(cargo, lister);
    pay(reward, lister, ctx);
}

// === Observing ===

/// Collect an outcome record sent to observer `O`'s `parent` object. Only `O`'s
/// module can call this, and only for records bound to `O` as `parent`;
/// records from a binding that merely reused `parent`'s ID are rejected.
public fun receive_outcome<O>(
    _: Permit<O>,
    parent: &mut UID,
    record: Receiving<OutcomeRecord>,
): OutcomeRecord {
    let record = transfer::receive(parent, record);
    assert!(
        record.observer.kind == type_name::with_original_ids<O>()
            && record.observer.instance == parent.to_inner(),
        EWrongObserver,
    );
    record
}

public fun delete_outcome(record: OutcomeRecord) {
    let OutcomeRecord { id, .. } = record;
    id.delete();
}

// === Views ===

/// The longest accept or haul window an agreement may have: 30 days.
public fun max_duration_ms(): u64 { MAX_DURATION_MS }

public fun lister<T>(self: &DeliveryAgreement<T>): address { self.lister }

public fun beneficiary<T>(self: &DeliveryAgreement<T>): address { self.beneficiary }

public fun cargo<T>(self: &DeliveryAgreement<T>): &Option<Balance> { &self.cargo }

/// What the cargo held when drafted, before or after it is released.
public fun cargo_spec<T>(self: &DeliveryAgreement<T>): Spec { self.cargo_spec }

/// The coin type the agreement is paid in.
public fun currency<T>(_: &DeliveryAgreement<T>): TypeName { type_name::with_original_ids<T>() }

/// The escrowed reward, before any delivery fee.
public fun reward<T>(self: &DeliveryAgreement<T>): u64 { self.reward.value() }

public fun want<T>(self: &DeliveryAgreement<T>): Spec { self.want }

/// The collateral a hauler must lock.
public fun collateral_amount<T>(self: &DeliveryAgreement<T>): u64 { self.collateral_amount }

/// The collateral locked: 0 while open.
public fun collateral_locked<T>(self: &DeliveryAgreement<T>): u64 { self.collateral.value() }

public fun accept_by_ms<T>(self: &DeliveryAgreement<T>): u64 { self.accept_by_ms }

public fun haul_ms<T>(self: &DeliveryAgreement<T>): u64 { self.haul_ms }

public fun posted_at_ms<T>(self: &DeliveryAgreement<T>): u64 { self.posted_at_ms }

public fun accept_requirements<T>(self: &DeliveryAgreement<T>): vector<Requirement> {
    self.accept_requirements
}

public fun identity_rule<T>(self: &DeliveryAgreement<T>): Option<TypeName> { self.identity_rule }

public fun observer<T>(self: &DeliveryAgreement<T>): Option<Binding> { self.observer }

public fun hauler<T>(self: &DeliveryAgreement<T>): Option<address> { self.hauler }

public fun hauler_identity<T>(self: &DeliveryAgreement<T>): Option<ID> { self.hauler_identity }

public fun deadline_ms<T>(self: &DeliveryAgreement<T>): u64 { self.deadline_ms }

/// The posting fee the lister paid, if any.
public fun post_fee<T>(self: &DeliveryAgreement<T>): Option<PostFee> { self.post_fee }

public fun delivery_fee_bps<T>(self: &DeliveryAgreement<T>): u16 { self.delivery_fee_bps }

/// Receives this agreement's delivery fee.
public fun treasury<T>(self: &DeliveryAgreement<T>): address { self.treasury }

public fun is_open<T>(self: &DeliveryAgreement<T>): bool { self.hauler.is_none() }

public fun cap_agreement_id(cap: &ListerCap): ID { cap.agreement_id }

public fun draft_agreement<T>(draft: &Draft<T>): &DeliveryAgreement<T> { &draft.agreement }

public fun binding_kind(self: &Binding): TypeName { self.kind }

public fun binding_instance(self: &Binding): ID { self.instance }

public fun binding_fee(self: &Binding): Option<Spec> { self.fee }

public fun outcome_is_delivered(self: &Outcome): bool {
    match (self) { Outcome::Delivered => true, _ => false }
}

/// True for both `default` and `forfeit`; see `outcome_forfeited`.
public fun outcome_is_defaulted(self: &Outcome): bool {
    match (self) { Outcome::Defaulted { .. } => true, _ => false }
}

public fun outcome_forfeited(self: &Outcome): bool {
    match (self) { Outcome::Defaulted { forfeited } => *forfeited, _ => false }
}

public fun outcome_is_cancelled(self: &Outcome): bool {
    match (self) { Outcome::Cancelled => true, _ => false }
}

public fun outcome_is_lapsed(self: &Outcome): bool {
    match (self) { Outcome::Lapsed => true, _ => false }
}

public fun record_agreement_id(self: &OutcomeRecord): ID { self.agreement_id }

public fun record_observer(self: &OutcomeRecord): Binding { self.observer }

public fun record_outcome(self: &OutcomeRecord): Outcome { self.outcome }

public fun record_lister(self: &OutcomeRecord): address { self.lister }

public fun record_beneficiary(self: &OutcomeRecord): address { self.beneficiary }

public fun record_hauler(self: &OutcomeRecord): Option<address> { self.hauler }

public fun record_hauler_identity(self: &OutcomeRecord): Option<ID> { self.hauler_identity }

/// The rule that attested `record_hauler_identity`. Check it before trusting
/// the identity.
public fun record_identity_rule(self: &OutcomeRecord): Option<TypeName> { self.identity_rule }

public fun record_cargo(self: &OutcomeRecord): Spec { self.cargo }

public fun record_want(self: &OutcomeRecord): Spec { self.want }

public fun record_currency(self: &OutcomeRecord): TypeName { self.currency }

public fun record_reward(self: &OutcomeRecord): u64 { self.reward }

public fun record_collateral(self: &OutcomeRecord): Option<u64> { self.collateral }

public fun record_posted_at_ms(self: &OutcomeRecord): u64 { self.posted_at_ms }

public fun record_deadline_ms(self: &OutcomeRecord): u64 { self.deadline_ms }

public fun record_closed_at_ms(self: &OutcomeRecord): u64 { self.closed_at_ms }

// === Internal ===

fun new_binding<O>(instance: ID, fee: Option<Spec>): Binding {
    Binding { kind: type_name::with_original_ids<O>(), instance, fee }
}

/// Send an outcome record to the bound observer, if there is one. Called
/// before the agreement is unpacked so the record can describe it.
fun record<T>(self: &DeliveryAgreement<T>, outcome: Outcome, clock: &Clock, ctx: &mut TxContext) {
    if (self.observer.is_none()) return;
    let observer = *self.observer.borrow();
    let record = OutcomeRecord {
        id: object::new(ctx),
        agreement_id: object::id(self),
        observer,
        outcome,
        lister: self.lister,
        beneficiary: self.beneficiary,
        hauler: self.hauler,
        hauler_identity: self.hauler_identity,
        identity_rule: self.identity_rule,
        cargo: self.cargo_spec,
        want: self.want,
        currency: type_name::with_original_ids<T>(),
        reward: self.reward.value(),
        collateral: if (self.hauler.is_some()) option::some(self.collateral.value())
        else option::none(),
        posted_at_ms: self.posted_at_ms,
        deadline_ms: self.deadline_ms,
        closed_at_ms: clock.timestamp_ms(),
    };
    transfer::transfer(record, observer.instance.to_address());
}

fun pay_default<T>(
    self: DeliveryAgreement<T>,
    forfeited: bool,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    self.record(Outcome::Defaulted { forfeited }, clock, ctx);
    let (agreement_id, lister) = (object::id(&self), self.lister);
    let hauler_identity = self.hauler_identity;
    let (beneficiary, hauler, reward, collateral) = close(self);
    event::emit(AgreementDefaulted {
        agreement_id,
        lister,
        hauler,
        hauler_identity,
        beneficiary,
        currency: type_name::with_original_ids<T>(),
        reward: reward.value(),
        collateral: collateral.value(),
        forfeited,
    });
    pay(reward, beneficiary, ctx);
    pay(collateral, beneficiary, ctx);
}

fun close<T>(
    self: DeliveryAgreement<T>,
): (address, address, balance::Balance<T>, balance::Balance<T>) {
    let DeliveryAgreement { id, beneficiary, cargo, reward, collateral, hauler, .. } = self;
    id.delete();
    cargo.destroy_none();
    (beneficiary, hauler.destroy_some(), reward, collateral)
}

/// Delete an open agreement, returning its `(cargo, reward)`.
fun close_open<T>(self: DeliveryAgreement<T>): (Balance, balance::Balance<T>) {
    let DeliveryAgreement { id, mut cargo, reward, collateral, hauler, .. } = self;
    id.delete();
    collateral.destroy_zero();
    hauler.destroy_none();
    let returned = cargo.extract();
    cargo.destroy_none();
    (returned, reward)
}

/// Send `funds` to `to` as a coin, or destroy them when empty so nobody is
/// sent a zero-value coin.
fun pay<T>(funds: balance::Balance<T>, to: address, ctx: &mut TxContext) {
    if (funds.value() == 0) funds.destroy_zero()
    else transfer::public_transfer(coin::from_balance(funds, ctx), to);
}

// === Test helpers ===

#[test_only]
public fun posted_event_for_testing(
    agreement_id: ID, lister: address, cap_id: ID, beneficiary: address, cargo: Spec,
    want: Spec, currency: TypeName, reward: u64, collateral: u64, accept_by_ms: u64,
    haul_ms: u64, accept_requirements: vector<Requirement>, identity_rule: Option<TypeName>,
    observer: Option<Binding>, post_fee: Option<PostFee>, delivery_fee_bps: u16,
    treasury: address,
): AgreementPosted {
    AgreementPosted {
        agreement_id, lister, cap_id, beneficiary, cargo, want, currency, reward, collateral,
        accept_by_ms, haul_ms, accept_requirements, identity_rule, observer, post_fee,
        delivery_fee_bps, treasury,
    }
}

#[test_only]
public fun accepted_event_for_testing(
    agreement_id: ID, hauler: address, hauler_identity: Option<ID>,
    identity_rule: Option<TypeName>, deadline_ms: u64,
): AgreementAccepted {
    AgreementAccepted { agreement_id, hauler, hauler_identity, identity_rule, deadline_ms }
}

#[test_only]
public fun delivered_event_for_testing(
    agreement_id: ID, lister: address, hauler: address, hauler_identity: Option<ID>,
    beneficiary: address, delivered: Spec, currency: TypeName, reward: u64, collateral: u64,
    delivery_fee: u64, treasury: address,
): AgreementDelivered {
    AgreementDelivered {
        agreement_id, lister, hauler, hauler_identity, beneficiary, delivered, currency, reward,
        collateral, delivery_fee, treasury,
    }
}

#[test_only]
public fun defaulted_event_for_testing(
    agreement_id: ID, lister: address, hauler: address, hauler_identity: Option<ID>,
    beneficiary: address, currency: TypeName, reward: u64, collateral: u64, forfeited: bool,
): AgreementDefaulted {
    AgreementDefaulted {
        agreement_id, lister, hauler, hauler_identity, beneficiary, currency, reward, collateral,
        forfeited,
    }
}

#[test_only]
public fun cancelled_event_for_testing(
    agreement_id: ID, cancelled_by: address, cargo: Spec, currency: TypeName, reward: u64,
): AgreementCancelled {
    AgreementCancelled { agreement_id, cancelled_by, cargo, currency, reward }
}

#[test_only]
public fun lapsed_event_for_testing(
    agreement_id: ID, lister: address, closed_by: address, cargo: Spec, currency: TypeName,
    reward: u64,
): AgreementLapsed {
    AgreementLapsed { agreement_id, lister, closed_by, cargo, currency, reward }
}

#[test_only]
public fun new_binding_for_testing<O>(instance: ID, fee: Option<Spec>): Binding {
    new_binding<O>(instance, fee)
}
