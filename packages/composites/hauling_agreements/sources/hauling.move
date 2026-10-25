/// Hauling agreements: a collateralized forward swap of items, paid in a coin.
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
/// accept. The agreement's `Terms` (see `terms`) choose where the lister's side
/// of the payouts goes: a beneficiary address, or the agreement's `ListerCap`.
/// With the cap, every payout to the lister's side arrives as one `Proceeds`
/// sent to the cap, which its holder opens with `collect`, so payouts follow
/// the cap to a wallet, a DAO or any other wrapper that holds it. The hauler is
/// always paid at the address that signed the accept.
///
/// Extensions. An agreement is built as a `Draft` and frozen by `publish`.
/// Before publishing, the lister may attach three optional extensions, all
/// fixed for the agreement's life:
///
/// - **Accept requirements** decide who may accept. Rule modules satisfy them
///   through a `Request` (see `agreements::request`), and one rule may be trusted to record
///   the hauler's identity, for example a character ID.
/// - **An observer** receives an `OutcomeRecord` for every terminal transition.
///   Records are transferred to the observer's object, so closing an agreement
///   never runs observer code and no party can suppress a record.
/// - **An entity** the lister drafts for, such as a DAO, recorded by a wrapper
///   with `set_on_behalf_of`, so events and outcome records credit the entity
///   rather than the signer.
///
/// Observers bind with their own `Permit`, so only their module can bind them;
/// they collect any fee in the same call and declare it here. A wrapper
/// records an entity with its own `Permit` the same way.
///
/// Lifecycle: draft -> published (open) -> accepted -> deleted by `deliver`,
/// `forfeit` or `default`. An open agreement is deleted by `cancel`, or, once
/// `accept_by_ms` passes with nobody accepting, by the config admin's
/// `close_lapsed`, which sends the cargo and reward back to the lister, or to
/// the cap when the terms pay the cap holder. `cancel` consumes the
/// `ListerCap`, and so does `collect` for terms that pay the cap holder. After
/// any other ending, the holder of a cap for a beneficiary address can reclaim
/// its storage with `delete_cap`.
module hauling_agreements::hauling;

use agreements::payout;
use agreements::request::{Self, Request};
use agreements::requirement::Requirement;
use agreements::spec::{Self, Spec};
use hauling_agreements::config::{Self, AdminCap, Config, PostFee};
use hauling_agreements::terms::Terms;
use multicoin::multicoin::{Self, Balance};
use std::internal::{Self, Permit};
use std::type_name::{Self, TypeName};
use sui::balance;
use sui::clock::Clock;
use sui::coin::{Self, Coin};
use sui::event;
use sui::transfer::Receiving;

// === Errors ===

// Code 0 (invalid terms) is now `terms`'.
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
#[error(code = 22)]
const ECapReceivesProceeds: vector<u8> =
    b"Cap receives its agreement's proceeds; collect them instead of deleting it";

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

/// The entity a wrapper module drafts for, such as an armature OU. `kind` is
/// the wrapper's marker type: only its module can create `Permit` of it, and
/// that module vouches that the signer of `draft` speaks for `id`.
public struct Entity has store, copy, drop {
    kind: TypeName,
    id: ID,
}

/// An agreement paid in coin type `T`.
public struct HaulingAgreement<phantom T> has key {
    id: UID,
    /// Sender of `draft`. Cancelling needs the cap, not this address.
    lister: address,
    /// Who `lister` drafts for, as a wrapper vouched with `set_on_behalf_of`.
    on_behalf_of: Option<Entity>,
    /// Want, collateral, windows and who receives the lister's side.
    terms: Terms,
    /// Drafting time plus the terms' `accept_ms`; exclusive.
    accept_by_ms: u64,
    /// Receives the delivery, or reward and collateral on default: the terms'
    /// beneficiary, or the `ListerCap`'s address when they pay the cap holder.
    beneficiary: address,
    /// Released to the hauler on accept.
    cargo: Option<Balance>,
    /// What `cargo` held when drafted; kept after accept for outcome records.
    cargo_spec: Spec,
    reward: balance::Balance<T>,
    /// Empty until accepted.
    collateral: balance::Balance<T>,
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
/// it must `publish` it; extensions can only be attached in between. The cap
/// is made with the draft, so terms that pay the cap holder know its address.
public struct Draft<phantom T> {
    agreement: HaulingAgreement<T>,
    cap: ListerCap,
}

/// Right to cancel an open agreement and, when its terms pay the cap holder,
/// to collect its proceeds. Has `store` so a DAO or other wrapper can custody
/// it. `cancel` consumes it, and so does `collect`; otherwise `delete_cap`.
/// With a beneficiary address, transferring the cap moves only the right to
/// cancel: a listing the config admin closes with `close_lapsed` still refunds
/// the lister, so a new holder should cancel a lapsed listing promptly.
public struct ListerCap has key, store {
    id: UID,
    agreement_id: ID,
    /// The agreement's payouts come here as `Proceeds`.
    receives_proceeds: bool,
}

/// The lister's side of an agreement whose terms pay the cap holder, sent to
/// its `ListerCap` when the agreement ends by `deliver`, `default`, `forfeit`
/// or `close_lapsed`. Only this module creates one, and only `collect` with
/// that cap opens it.
public struct Proceeds<phantom T> has key {
    id: UID,
    agreement_id: ID,
    /// The delivered `want`, or the cargo when the listing lapsed. `none` on
    /// default or forfeit, and for a lapsed listing with empty cargo.
    items: Option<Balance>,
    /// Reward and collateral on default or forfeit, the reward when the listing
    /// lapsed, and nothing on delivery.
    coins: balance::Balance<T>,
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
    /// Who `lister` drafted for. The wrapper that set it chose it, so an
    /// observer must ignore entities from wrappers it does not trust.
    on_behalf_of: Option<Entity>,
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
// When the terms pay the cap holder, the beneficiary is the cap's address and
// the lister's side arrives there as one `Proceeds`. `currency` is the coin
// type of every reward, collateral and delivery fee amount in the event.

public struct AgreementPosted has copy, drop {
    agreement_id: ID,
    /// Sender of `draft`; may differ from `beneficiary` (e.g. a DAO listing
    /// for its treasury).
    lister: address,
    /// Who `lister` drafts for, as the wrapper in `kind` vouches, if any.
    on_behalf_of: Option<Entity>,
    cap_id: ID,
    beneficiary: address,
    /// `beneficiary` is the cap's address, and the lister's side of the
    /// payouts arrives there as `Proceeds`.
    pays_cap_holder: bool,
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
/// agreement: `cargo` and `reward` went to `refunded_to`, which is `lister`,
/// or the cap's address when the terms pay the cap holder. `closed_by` sent
/// the transaction.
public struct AgreementLapsed has copy, drop {
    agreement_id: ID,
    lister: address,
    refunded_to: address,
    closed_by: address,
    cargo: Spec,
    currency: TypeName,
    reward: u64,
}

// === Drafting ===

/// Start an agreement escrowing `cargo` and `reward`, paid in coin type `T`,
/// which `config` must approve, on `terms` (see `terms`). The accept window
/// starts now: someone must accept before `now + terms.accept_ms()`. `want`
/// must name a different collection or asset than `cargo`, so handing the
/// cargo back can never count as delivery.
/// `post_fee` must be exactly `config`'s posting fee in its coin type `F` (an
/// empty coin of any type when there is none); it goes to the treasury now and
/// is not refunded. The agreement fixes `config`'s delivery rate and treasury.
/// Attach extensions, then `publish`.
public fun draft<T, F>(
    cargo: Balance,
    reward: Coin<T>,
    terms: Terms,
    config: &Config,
    post_fee: Coin<F>,
    clock: &Clock,
    ctx: &mut TxContext,
): Draft<T> {
    let now = clock.timestamp_ms();
    let cargo_spec = spec::of(&cargo);
    terms.assert_fits(&cargo_spec);
    config.assert_approved<T>();
    config.collect_post_fee(post_fee);
    let id = object::new(ctx);
    let cap = ListerCap {
        id: object::new(ctx),
        agreement_id: id.to_inner(),
        receives_proceeds: terms.pays_cap_holder(),
    };
    let beneficiary = terms.beneficiary().destroy_with_default(object::id(&cap).to_address());
    Draft {
        agreement: HaulingAgreement {
            id,
            lister: ctx.sender(),
            on_behalf_of: option::none(),
            terms,
            accept_by_ms: now + terms.accept_ms(),
            beneficiary,
            cargo_spec,
            cargo: option::some(cargo),
            reward: reward.into_balance(),
            collateral: balance::zero(),
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
        cap,
    }
}

/// Require accepting transactions to satisfy `requirement`, after any added
/// before it.
public fun require_to_accept<T>(draft: &mut Draft<T>, requirement: Requirement) {
    draft.agreement.accept_requirements.push_back(requirement);
}

/// Like `require_to_accept`, and also trust this requirement's rule to record
/// the hauler's identity. An agreement has at most one identity rule, and an
/// accept cannot complete unless it records an identity, exactly once. Don't
/// also add the same rule with `require_to_accept`, and name only a rule that
/// calls `set_identity`: either makes every accept abort.
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

/// Record that the lister drafts for `entity_id`, as wrapper `W` vouches. Only
/// `W`'s module can call this, and it must check that the signer of `draft`
/// speaks for `entity_id`, for example that a governance ticket came from that
/// DAO. `AgreementPosted` and outcome records show it, so indexers and
/// observers can credit the entity rather than the signer. It moves no
/// payout: terms that pay the cap holder do that.
public fun set_on_behalf_of<T, W>(draft: &mut Draft<T>, _: Permit<W>, entity_id: ID) {
    assert!(draft.agreement.on_behalf_of.is_none(), EAlreadyBound);
    draft.agreement.on_behalf_of.fill(Entity {
        kind: type_name::with_original_ids<W>(),
        id: entity_id,
    });
}

/// Share the agreement and return its cap. Its terms and extensions are fixed
/// from here.
public fun publish<T>(draft: Draft<T>): ListerCap {
    let Draft { agreement, cap } = draft;
    event::emit(AgreementPosted {
        agreement_id: object::id(&agreement),
        lister: agreement.lister,
        on_behalf_of: agreement.on_behalf_of,
        cap_id: object::id(&cap),
        beneficiary: agreement.beneficiary,
        pays_cap_holder: agreement.terms.pays_cap_holder(),
        cargo: agreement.cargo_spec,
        want: agreement.terms.want(),
        currency: type_name::with_original_ids<T>(),
        reward: agreement.reward.value(),
        collateral: agreement.terms.collateral(),
        accept_by_ms: agreement.accept_by_ms,
        haul_ms: agreement.terms.haul_ms(),
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
    terms: Terms,
    config: &Config,
    post_fee: Coin<F>,
    clock: &Clock,
    ctx: &mut TxContext,
): ListerCap {
    draft(cargo, reward, terms, config, post_fee, clock, ctx).publish()
}

// === Accepting ===

/// Start accepting. Returns the request every accept requirement must be
/// satisfied on, in order, before `finish_accept`.
public fun begin_accept<T>(self: &HaulingAgreement<T>, clock: &Clock, ctx: &TxContext): Request {
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
    self: &mut HaulingAgreement<T>,
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
    assert!(collateral.value() == self.terms.collateral(), EWrongCollateral);
    self.collateral.join(collateral.into_balance());
    self.hauler.fill(hauler);
    self.hauler_identity = hauler_identity;
    self.deadline_ms = now + self.terms.haul_ms();
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
    self: &mut HaulingAgreement<T>,
    collateral: Coin<T>,
    clock: &Clock,
    ctx: &mut TxContext,
): Balance {
    let request = self.begin_accept(clock, ctx);
    self.finish_accept(request, collateral, clock)
}

// === Delivering and defaulting ===

/// Hand in exactly the wanted balance before the deadline. Permissionless:
/// recipients are fixed, so it does not matter who submits. The wanted balance
/// goes to the beneficiary, or as `Proceeds` to the cap when the terms pay the
/// cap holder. The delivery fee, `reward * delivery_fee_bps / 10,000` rounded
/// down, goes to the treasury and the rest of the reward to the hauler.
public fun deliver<T>(
    self: HaulingAgreement<T>,
    delivered: Balance,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(self.hauler.is_some(), ENotAccepted);
    assert!(clock.timestamp_ms() < self.deadline_ms, ETooLate);
    let want = self.terms.want();
    want.assert_matches(&delivered);
    self.record(Outcome::Delivered, clock, ctx);
    let (agreement_id, lister) = (object::id(&self), self.lister);
    let hauler_identity = self.hauler_identity;
    let (fee_bps, treasury) = (self.delivery_fee_bps, self.treasury);
    let to_cap = self.terms.pays_cap_holder();
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
    if (to_cap) {
        send_proceeds<T>(agreement_id, option::some(delivered), balance::zero(), beneficiary, ctx)
    } else transfer::public_transfer(delivered, beneficiary);
    pay(reward, hauler, ctx);
    pay(collateral, hauler, ctx);
}

/// After the deadline, send reward and collateral to the beneficiary, or as
/// `Proceeds` to the cap when the terms pay the cap holder. Permissionless, so
/// funds never wait on a party who has walked away. The hauler keeps whatever
/// cargo they still hold.
public fun default<T>(self: HaulingAgreement<T>, clock: &Clock, ctx: &mut TxContext) {
    assert!(self.hauler.is_some(), ENotAccepted);
    assert!(clock.timestamp_ms() >= self.deadline_ms, ETooEarly);
    pay_default(self, false, clock, ctx);
}

/// The hauler gives up before the deadline: reward and collateral go to the
/// beneficiary now instead of after it. Same payout as `default`; the hauler
/// keeps whatever cargo they still hold. Once the deadline passes only
/// `default` ends the agreement, so a hauler who missed it cannot have the
/// failure recorded as a forfeit.
public fun forfeit<T>(self: HaulingAgreement<T>, clock: &Clock, ctx: &mut TxContext) {
    assert!(self.hauler.is_some(), ENotAccepted);
    assert!(*self.hauler.borrow() == ctx.sender(), ENotHauler);
    assert!(clock.timestamp_ms() < self.deadline_ms, ETooLate);
    pay_default(self, true, clock, ctx);
}

/// Delete an open agreement, returning `(cargo, reward)` to the cap holder.
/// Allowed before or after `accept_by_ms`, whoever the terms pay.
public fun cancel<T>(
    self: HaulingAgreement<T>,
    cap: ListerCap,
    clock: &Clock,
    ctx: &mut TxContext,
): (Balance, Coin<T>) {
    let ListerCap { id: cap_id, agreement_id, .. } = cap;
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
/// cargo and reward to the lister, the address that signed `draft`, or as
/// `Proceeds` to the cap when the terms pay the cap holder. Only the config's
/// `AdminCap` holder can call it, so a listing whose `ListerCap` was lost or
/// burned still ends. The escrow never goes to the caller. With a beneficiary
/// address it goes to the lister even when someone else holds the cap, so a
/// wrapper that drafts through another signer should use terms that pay the
/// cap holder. A holder who is not the lister can still `cancel` after
/// `accept_by_ms`, and whichever transaction lands first decides who gets the
/// escrow, so the admin should close only listings lapsed long enough that a
/// holder would have cancelled.
public fun close_lapsed<T>(
    self: HaulingAgreement<T>,
    _: &AdminCap,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(self.hauler.is_none(), ENotOpen);
    assert!(clock.timestamp_ms() >= self.accept_by_ms, ENotLapsed);
    self.record(Outcome::Lapsed, clock, ctx);
    let (agreement_id, lister) = (object::id(&self), self.lister);
    let to_cap = self.terms.pays_cap_holder();
    let refunded_to = if (to_cap) self.beneficiary else lister;
    let (cargo, reward) = close_open(self);
    event::emit(AgreementLapsed {
        agreement_id,
        lister,
        refunded_to,
        closed_by: ctx.sender(),
        cargo: spec::of(&cargo),
        currency: type_name::with_original_ids<T>(),
        reward: reward.value(),
    });
    if (to_cap) send_proceeds(agreement_id, non_empty(cargo), reward, refunded_to, ctx)
    else {
        payout::pay(cargo, lister);
        pay(reward, lister, ctx);
    }
}

/// Open the `Proceeds` sent to `cap` and delete both, returning the items, if
/// any, and the coins. Only an agreement whose terms pay the cap holder sends
/// proceeds, exactly once, when it ends by `deliver`, `default`, `forfeit` or
/// `close_lapsed`; `cancel` returns its escrow directly instead.
public fun collect<T>(
    mut cap: ListerCap,
    proceeds: Receiving<Proceeds<T>>,
    ctx: &mut TxContext,
): (Option<Balance>, Coin<T>) {
    let Proceeds { id, items, coins, .. } = transfer::receive(&mut cap.id, proceeds);
    id.delete();
    let ListerCap { id, .. } = cap;
    id.delete();
    (items, coin::from_balance(coins, ctx))
}

/// Delete a `ListerCap`, reclaiming its storage. Meant for after the agreement
/// ended by `deliver`, `default`, `forfeit` or `close_lapsed`. Deleting it
/// while the agreement is still open gives up the right to cancel, leaving
/// `close_lapsed` as the only way to end it. Aborts for a cap that receives
/// its agreement's proceeds, which must be collected with it instead.
public fun delete_cap(cap: ListerCap) {
    let ListerCap { id, receives_proceeds, .. } = cap;
    assert!(!receives_proceeds, ECapReceivesProceeds);
    id.delete();
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

public fun lister<T>(self: &HaulingAgreement<T>): address { self.lister }

/// Who the lister drafted for, as a wrapper vouched with `set_on_behalf_of`.
public fun on_behalf_of<T>(self: &HaulingAgreement<T>): Option<Entity> { self.on_behalf_of }

/// The terms the agreement was drafted on. Their windows are relative, so they
/// can be posted again, with a fresh accept window, after a cancel.
public fun terms<T>(self: &HaulingAgreement<T>): Terms { self.terms }

/// Receives the lister's side of the payouts: the terms' beneficiary, or the
/// `ListerCap`'s address when they pay the cap holder.
public fun beneficiary<T>(self: &HaulingAgreement<T>): address { self.beneficiary }

/// The lister's side of the payouts goes to the `ListerCap` as `Proceeds`.
public fun pays_cap_holder<T>(self: &HaulingAgreement<T>): bool {
    self.terms.pays_cap_holder()
}

public fun cargo<T>(self: &HaulingAgreement<T>): &Option<Balance> { &self.cargo }

/// What the cargo held when drafted, before or after it is released.
public fun cargo_spec<T>(self: &HaulingAgreement<T>): Spec { self.cargo_spec }

/// The coin type the agreement is paid in.
public fun currency<T>(_: &HaulingAgreement<T>): TypeName { type_name::with_original_ids<T>() }

/// The escrowed reward, before any delivery fee.
public fun reward<T>(self: &HaulingAgreement<T>): u64 { self.reward.value() }

public fun want<T>(self: &HaulingAgreement<T>): Spec { self.terms.want() }

/// The collateral a hauler must lock.
public fun collateral_amount<T>(self: &HaulingAgreement<T>): u64 { self.terms.collateral() }

/// The collateral locked: 0 while open.
public fun collateral_locked<T>(self: &HaulingAgreement<T>): u64 { self.collateral.value() }

/// The end of the accept window, exclusive: drafting time plus `accept_ms`.
public fun accept_by_ms<T>(self: &HaulingAgreement<T>): u64 { self.accept_by_ms }

public fun haul_ms<T>(self: &HaulingAgreement<T>): u64 { self.terms.haul_ms() }

public fun posted_at_ms<T>(self: &HaulingAgreement<T>): u64 { self.posted_at_ms }

public fun accept_requirements<T>(self: &HaulingAgreement<T>): vector<Requirement> {
    self.accept_requirements
}

public fun identity_rule<T>(self: &HaulingAgreement<T>): Option<TypeName> { self.identity_rule }

public fun observer<T>(self: &HaulingAgreement<T>): Option<Binding> { self.observer }

public fun hauler<T>(self: &HaulingAgreement<T>): Option<address> { self.hauler }

public fun hauler_identity<T>(self: &HaulingAgreement<T>): Option<ID> { self.hauler_identity }

public fun deadline_ms<T>(self: &HaulingAgreement<T>): u64 { self.deadline_ms }

/// The posting fee the lister paid, if any.
public fun post_fee<T>(self: &HaulingAgreement<T>): Option<PostFee> { self.post_fee }

public fun delivery_fee_bps<T>(self: &HaulingAgreement<T>): u16 { self.delivery_fee_bps }

/// Receives this agreement's delivery fee.
public fun treasury<T>(self: &HaulingAgreement<T>): address { self.treasury }

public fun is_open<T>(self: &HaulingAgreement<T>): bool { self.hauler.is_none() }

public fun cap_agreement_id(cap: &ListerCap): ID { cap.agreement_id }

/// The agreement's payouts come to this cap as `Proceeds`.
public fun cap_receives_proceeds(cap: &ListerCap): bool { cap.receives_proceeds }

public fun draft_agreement<T>(draft: &Draft<T>): &HaulingAgreement<T> { &draft.agreement }

/// The wrapper's marker type, whose module vouched for the entity.
public fun entity_kind(self: &Entity): TypeName { self.kind }

public fun entity_id(self: &Entity): ID { self.id }

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

/// Who the lister drafted for. Check `entity_kind` before trusting it.
public fun record_on_behalf_of(self: &OutcomeRecord): Option<Entity> { self.on_behalf_of }

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
fun record<T>(self: &HaulingAgreement<T>, outcome: Outcome, clock: &Clock, ctx: &mut TxContext) {
    if (self.observer.is_none()) return;
    let observer = *self.observer.borrow();
    let record = OutcomeRecord {
        id: object::new(ctx),
        agreement_id: object::id(self),
        observer,
        outcome,
        lister: self.lister,
        on_behalf_of: self.on_behalf_of,
        beneficiary: self.beneficiary,
        hauler: self.hauler,
        hauler_identity: self.hauler_identity,
        identity_rule: self.identity_rule,
        cargo: self.cargo_spec,
        want: self.terms.want(),
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
    self: HaulingAgreement<T>,
    forfeited: bool,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    self.record(Outcome::Defaulted { forfeited }, clock, ctx);
    let (agreement_id, lister) = (object::id(&self), self.lister);
    let hauler_identity = self.hauler_identity;
    let to_cap = self.terms.pays_cap_holder();
    let (beneficiary, hauler, mut reward, collateral) = close(self);
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
    if (to_cap) {
        reward.join(collateral);
        send_proceeds(agreement_id, option::none(), reward, beneficiary, ctx)
    } else {
        pay(reward, beneficiary, ctx);
        pay(collateral, beneficiary, ctx);
    }
}

fun close<T>(
    self: HaulingAgreement<T>,
): (address, address, balance::Balance<T>, balance::Balance<T>) {
    let HaulingAgreement { id, beneficiary, cargo, reward, collateral, hauler, .. } = self;
    id.delete();
    cargo.destroy_none();
    (beneficiary, hauler.destroy_some(), reward, collateral)
}

/// Delete an open agreement, returning its `(cargo, reward)`.
fun close_open<T>(self: HaulingAgreement<T>): (Balance, balance::Balance<T>) {
    let HaulingAgreement { id, mut cargo, reward, collateral, hauler, .. } = self;
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

/// Send the lister's side to the agreement's cap at `cap` as one `Proceeds`,
/// even an empty one: the cap holder needs it to `collect` and close the cap.
fun send_proceeds<T>(
    agreement_id: ID,
    items: Option<Balance>,
    coins: balance::Balance<T>,
    cap: address,
    ctx: &mut TxContext,
) {
    transfer::transfer(Proceeds { id: object::new(ctx), agreement_id, items, coins }, cap);
}

/// `some(balance)`, or `none` once an empty `balance` is destroyed.
fun non_empty(balance: Balance): Option<Balance> {
    if (multicoin::value(&balance) == 0) {
        multicoin::destroy_zero(balance);
        option::none()
    } else option::some(balance)
}

// === Test helpers ===

#[test_only]
public fun posted_event_for_testing(
    agreement_id: ID, lister: address, on_behalf_of: Option<Entity>, cap_id: ID,
    beneficiary: address, pays_cap_holder: bool, cargo: Spec, want: Spec, currency: TypeName,
    reward: u64, collateral: u64, accept_by_ms: u64, haul_ms: u64,
    accept_requirements: vector<Requirement>, identity_rule: Option<TypeName>,
    observer: Option<Binding>, post_fee: Option<PostFee>, delivery_fee_bps: u16,
    treasury: address,
): AgreementPosted {
    AgreementPosted {
        agreement_id, lister, on_behalf_of, cap_id, beneficiary, pays_cap_holder, cargo, want,
        currency, reward, collateral, accept_by_ms, haul_ms, accept_requirements, identity_rule,
        observer, post_fee, delivery_fee_bps, treasury,
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
    agreement_id: ID, lister: address, refunded_to: address, closed_by: address, cargo: Spec,
    currency: TypeName, reward: u64,
): AgreementLapsed {
    AgreementLapsed { agreement_id, lister, refunded_to, closed_by, cargo, currency, reward }
}

#[test_only]
public fun new_binding_for_testing<O>(instance: ID, fee: Option<Spec>): Binding {
    new_binding<O>(instance, fee)
}

#[test_only]
public fun new_entity_for_testing<W>(id: ID): Entity {
    Entity { kind: type_name::with_original_ids<W>(), id }
}
