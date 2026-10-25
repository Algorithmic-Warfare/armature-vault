/// The terms of a hauling agreement as one value: what counts as delivery,
/// the collateral a hauler locks, the accept and haul windows, and who receives
/// the lister's side of the payouts.
///
/// `Terms` has `store`, so a wrapper can keep them in its own objects, such as
/// a governance payload that posts an agreement when it executes, and pass them
/// to `hauling::draft` as they are. Both windows are relative: the accept
/// window starts when the agreement is drafted and the haul window when it is
/// accepted. So terms never expire while stored, and an agreement's terms, from
/// `hauling::terms`, can be posted again after it is cancelled, even once it
/// has lapsed.
///
/// The constructors check everything that doesn't depend on the cargo.
/// `hauling::draft` checks the rest: that `want` names something other than
/// the cargo.
///
/// Who receives the lister's side:
///
/// - `new` names a beneficiary address. The delivered `want` goes there, and so
///   do the reward and collateral on default or forfeit.
/// - `new_for_cap_holder` sends those payouts to the agreement's `ListerCap`
///   instead, with the cargo and reward of a lapsed listing, as one
///   `hauling::Proceeds` that the cap's holder opens with `hauling::collect`.
///   Payouts then follow the cap, so a wallet, a DAO or any other wrapper that
///   holds it receives them without a receiving address of its own.
module hauling_agreements::terms;

use agreements::spec::Spec;

// === Errors ===

#[error(code = 0)]
const EInvalidTerms: vector<u8> = b"Agreement terms are invalid";

// === Constants ===

/// Longest accept window and haul window: 30 days. Also keeps every derived
/// timestamp from overflowing.
const MAX_DURATION_MS: u64 = 30 * 24 * 60 * 60 * 1000;

// === Structs ===

public struct Terms has store, copy, drop {
    /// Exactly what counts as delivery.
    want: Spec,
    /// What a hauler must lock, in the agreement's coin type.
    collateral: u64,
    /// The accept window, measured from drafting.
    accept_ms: u64,
    /// The delivery window, measured from accept.
    haul_ms: u64,
    /// Receives the lister's side of the payouts. `none` sends them to the
    /// agreement's `ListerCap`.
    beneficiary: Option<address>,
}

// === Constructors ===

/// Terms whose payouts go to `beneficiary`. `want` and `collateral` must be
/// more than 0, and `accept_ms` and `haul_ms` between 1 and `max_duration_ms`.
public fun new(
    want: Spec,
    collateral: u64,
    accept_ms: u64,
    haul_ms: u64,
    beneficiary: address,
): Terms {
    build(want, collateral, accept_ms, haul_ms, option::some(beneficiary))
}

/// Terms whose payouts go to the agreement's `ListerCap`, as one
/// `hauling::Proceeds` for whoever holds the cap. Same checks as `new`.
public fun new_for_cap_holder(
    want: Spec,
    collateral: u64,
    accept_ms: u64,
    haul_ms: u64,
): Terms {
    build(want, collateral, accept_ms, haul_ms, option::none())
}

// === Views ===

public fun want(self: &Terms): Spec { self.want }

public fun collateral(self: &Terms): u64 { self.collateral }

public fun accept_ms(self: &Terms): u64 { self.accept_ms }

public fun haul_ms(self: &Terms): u64 { self.haul_ms }

/// The beneficiary address, or `none` when payouts go to the cap holder.
public fun beneficiary(self: &Terms): Option<address> { self.beneficiary }

public fun pays_cap_holder(self: &Terms): bool { self.beneficiary.is_none() }

/// The longest accept or haul window an agreement may have: 30 days.
public fun max_duration_ms(): u64 { MAX_DURATION_MS }

// === Package Functions ===

/// Abort unless the terms fit `cargo`: `want` must name a different collection
/// or asset than the cargo, so handing the cargo back can never count as
/// delivery.
public(package) fun assert_fits(self: &Terms, cargo: &Spec) {
    assert!(
        self.want.collection() != cargo.collection() || self.want.asset_id() != cargo.asset_id(),
        EInvalidTerms,
    );
}

// === Internal ===

fun build(
    want: Spec,
    collateral: u64,
    accept_ms: u64,
    haul_ms: u64,
    beneficiary: Option<address>,
): Terms {
    assert!(want.qty() > 0 && collateral > 0, EInvalidTerms);
    assert!(accept_ms > 0 && accept_ms <= MAX_DURATION_MS, EInvalidTerms);
    assert!(haul_ms > 0 && haul_ms <= MAX_DURATION_MS, EInvalidTerms);
    Terms { want, collateral, accept_ms, haul_ms, beneficiary }
}
