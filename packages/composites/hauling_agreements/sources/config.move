/// Protocol configuration for hauling agreements: which coins may pay, and
/// the protocol fees. One shared `Config` is created at publish.
///
/// - **Approved currencies.** An agreement's reward, collateral and delivery
///   fee are all one coin type `T`, which must be approved when the agreement
///   is drafted. Revoking a currency stops new agreements in it; agreements
///   already drafted in it run to the end unchanged.
/// - **A posting fee**, a flat amount of one configured coin type, paid by the
///   lister to the treasury when drafting. It is not refunded on cancel.
///   `none` turns it off.
/// - **A delivery fee**, a share in bps of the reward, taken from the hauler's
///   reward when the agreement is delivered and sent to the treasury. Rounded
///   down. Nothing is taken on default, forfeit or cancel.
///
/// Each agreement copies the delivery rate and treasury when it is drafted, so
/// later changes to the config never alter accepted terms.
///
/// Only the `AdminCap` holder can change the config. The cap has `store`, so a
/// DAO can hold it. There is no public constructor, so every `&Config` an
/// agreement is drafted against is the one created at publish. The cap also
/// closes lapsed agreements (`hauling::close_lapsed`), whose escrow never goes
/// to the admin: it goes back to their lister, or as `Proceeds` to their
/// `ListerCap` when the terms pay the cap holder.
module hauling_agreements::config;

use agreements::payout;
use std::type_name::{Self, TypeName};
use sui::coin::Coin;
use sui::event;
use sui::vec_set::{Self, VecSet};

// === Errors ===

#[error(code = 0)]
const EInvalidBps: vector<u8> = b"Delivery fee must be at most 10,000 bps";
#[error(code = 1)]
const EUnexpectedFee: vector<u8> = b"No posting fee is set, so the fee coin must be empty";
#[error(code = 2)]
const EInvalidPostFee: vector<u8> = b"A posting fee must be more than 0";
#[error(code = 3)]
const ECurrencyNotApproved: vector<u8> = b"Coin type is not an approved currency";
#[error(code = 4)]
const ECurrencyAlreadyApproved: vector<u8> = b"Coin type is already an approved currency";
#[error(code = 5)]
const EWrongPostFeeCurrency: vector<u8> = b"Posting fee is paid in the wrong coin type";
#[error(code = 6)]
const EWrongPostFeeAmount: vector<u8> = b"Posting fee is not exactly the configured amount";

// === Structs ===

/// A flat fee of `amount` in coin type `currency`.
public struct PostFee has store, copy, drop {
    currency: TypeName,
    amount: u64,
}

public struct Config has key {
    id: UID,
    /// Coin types an agreement may be drafted in.
    currencies: VecSet<TypeName>,
    /// Paid by the lister when drafting; `none` for no posting fee.
    post_fee: Option<PostFee>,
    /// Taken from the reward on delivery.
    delivery_fee_bps: u16,
    /// Receives both fees.
    treasury: address,
}

/// Right to change the `Config`.
public struct AdminCap has key, store {
    id: UID,
}

// === Events ===

/// The whole config after an admin change.
public struct ConfigUpdated has copy, drop {
    config_id: ID,
    currencies: vector<TypeName>,
    post_fee: Option<PostFee>,
    delivery_fee_bps: u16,
    treasury: address,
}

// === Init ===

/// Share a config with no currencies, no fees and the publisher as treasury,
/// and give the publisher the admin cap.
fun init(ctx: &mut TxContext) {
    transfer::share_object(Config {
        id: object::new(ctx),
        currencies: vec_set::empty(),
        post_fee: option::none(),
        delivery_fee_bps: 0,
        treasury: ctx.sender(),
    });
    transfer::public_transfer(AdminCap { id: object::new(ctx) }, ctx.sender());
}

// === Admin ===

/// Allow agreements paid in coin type `T`.
public fun approve_currency<T>(_: &AdminCap, self: &mut Config) {
    let currency = type_name::with_original_ids<T>();
    assert!(!self.currencies.contains(&currency), ECurrencyAlreadyApproved);
    self.currencies.insert(currency);
    self.emit_updated();
}

/// Stop new agreements in coin type `T`. Existing ones are unaffected.
public fun revoke_currency<T>(_: &AdminCap, self: &mut Config) {
    let currency = type_name::with_original_ids<T>();
    assert!(self.currencies.contains(&currency), ECurrencyNotApproved);
    self.currencies.remove(&currency);
    self.emit_updated();
}

/// Charge `amount` of coin type `F` to post an agreement.
public fun set_post_fee<F>(_: &AdminCap, self: &mut Config, amount: u64) {
    assert!(amount > 0, EInvalidPostFee);
    self.post_fee = option::some(PostFee { currency: type_name::with_original_ids<F>(), amount });
    self.emit_updated();
}

/// Stop charging a posting fee.
public fun clear_post_fee(_: &AdminCap, self: &mut Config) {
    self.post_fee = option::none();
    self.emit_updated();
}

/// Set the delivery fee, at most 10,000 bps. Applies to agreements drafted
/// from now on.
public fun set_delivery_fee_bps(_: &AdminCap, self: &mut Config, bps: u16) {
    assert!((bps as u64) <= payout::bps(), EInvalidBps);
    self.delivery_fee_bps = bps;
    self.emit_updated();
}

/// Set the treasury. Applies to agreements drafted from now on.
public fun set_treasury(_: &AdminCap, self: &mut Config, treasury: address) {
    self.treasury = treasury;
    self.emit_updated();
}

// === Views ===

public fun is_approved<T>(self: &Config): bool {
    self.currencies.contains(&type_name::with_original_ids<T>())
}

public fun currencies(self: &Config): vector<TypeName> { *self.currencies.keys() }

public fun post_fee(self: &Config): Option<PostFee> { self.post_fee }

public fun delivery_fee_bps(self: &Config): u16 { self.delivery_fee_bps }

public fun treasury(self: &Config): address { self.treasury }

public fun post_fee_currency(self: &PostFee): TypeName { self.currency }

public fun post_fee_amount(self: &PostFee): u64 { self.amount }

/// The delivery fee on a reward of `amount`: `amount * bps / 10,000`, rounded
/// down.
public fun delivery_fee_on(amount: u64, bps: u16): u64 {
    ((amount as u128) * (bps as u128) / (payout::bps() as u128)) as u64
}

// === Package ===

public(package) fun assert_approved<T>(self: &Config) {
    assert!(self.is_approved<T>(), ECurrencyNotApproved);
}

/// Take the posting fee: exactly the configured amount and coin type to the
/// treasury, or an empty coin of any type when there is none.
public(package) fun collect_post_fee<F>(self: &Config, fee: Coin<F>) {
    if (self.post_fee.is_some()) {
        let post_fee = self.post_fee.borrow();
        assert!(type_name::with_original_ids<F>() == post_fee.currency, EWrongPostFeeCurrency);
        assert!(fee.value() == post_fee.amount, EWrongPostFeeAmount);
        transfer::public_transfer(fee, self.treasury);
    } else {
        assert!(fee.value() == 0, EUnexpectedFee);
        fee.destroy_zero();
    }
}

// === Internal ===

fun emit_updated(self: &Config) {
    event::emit(ConfigUpdated {
        config_id: object::id(self),
        currencies: *self.currencies.keys(),
        post_fee: self.post_fee,
        delivery_fee_bps: self.delivery_fee_bps,
        treasury: self.treasury,
    });
}

// === Test helpers ===

/// A config approving no currencies yet; approve with `approve_for_testing`.
#[test_only]
public fun new_for_testing(
    post_fee: Option<PostFee>,
    delivery_fee_bps: u16,
    treasury: address,
    ctx: &mut TxContext,
): Config {
    Config { id: object::new(ctx), currencies: vec_set::empty(), post_fee, delivery_fee_bps, treasury }
}

#[test_only]
public fun approve_for_testing<T>(self: &mut Config) {
    self.currencies.insert(type_name::with_original_ids<T>());
}

#[test_only]
public fun post_fee_for_testing<F>(amount: u64): PostFee {
    PostFee { currency: type_name::with_original_ids<F>(), amount }
}

#[test_only]
public fun share_for_testing(self: Config) {
    transfer::share_object(self);
}

#[test_only]
public fun destroy_for_testing(self: Config) {
    let Config { id, .. } = self;
    id.delete();
}

#[test_only]
public fun new_admin_cap_for_testing(ctx: &mut TxContext): AdminCap {
    AdminCap { id: object::new(ctx) }
}

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx);
}

#[test_only]
public fun updated_event_for_testing(
    config_id: ID,
    currencies: vector<TypeName>,
    post_fee: Option<PostFee>,
    delivery_fee_bps: u16,
    treasury: address,
): ConfigUpdated {
    ConfigUpdated { config_id, currencies, post_fee, delivery_fee_bps, treasury }
}
