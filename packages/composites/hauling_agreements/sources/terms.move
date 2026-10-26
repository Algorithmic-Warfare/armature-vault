/// The terms of a hauling agreement as one value: what counts as delivery,
/// the collateral a hauler locks, the accept and haul windows, and who receives
/// the lister's side of the payouts.
///
/// Delivery is a list of items, `want`: one or more exact quantities, each of
/// a different collection and asset, at most `max_items` of them. A delivery
/// hands in one balance per entry, in `want`'s order.
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
/// `hauling::draft` checks the rest: that no entry of `want` names an item the
/// cargo holds.
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
module hauling_agreements::terms {
    use agreements::spec::{Self, Spec};

    // === Errors ===

    #[error(code = 0)]
    const EInvalidTerms: vector<u8> = b"Agreement terms are invalid";

    // === Constants ===

    /// Longest accept window and haul window: 30 days. Also keeps every derived
    /// timestamp from overflowing.
    const MAX_DURATION_MS: u64 = 30 * 24 * 60 * 60 * 1000;

    /// Most items an agreement's `want`, or its cargo, may list.
    const MAX_ITEMS: u64 = 32;

    // === Structs ===

    public struct Terms has copy, drop, store {
        /// Exactly what counts as delivery, one entry per item.
        want: vector<Spec>,
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

    /// Terms whose payouts go to `beneficiary`. `want` must list between 1 and
    /// `max_items` entries, each of a different collection and asset and each
    /// more than 0. `collateral` must be more than 0, and `accept_ms` and
    /// `haul_ms` between 1 and `max_duration_ms`.
    public fun new(
        want: vector<Spec>,
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
        want: vector<Spec>,
        collateral: u64,
        accept_ms: u64,
        haul_ms: u64,
    ): Terms {
        build(want, collateral, accept_ms, haul_ms, option::none())
    }

    // === Views ===

    public fun want(self: &Terms): vector<Spec> { self.want }

    public fun collateral(self: &Terms): u64 { self.collateral }

    public fun accept_ms(self: &Terms): u64 { self.accept_ms }

    public fun haul_ms(self: &Terms): u64 { self.haul_ms }

    /// The beneficiary address, or `none` when payouts go to the cap holder.
    public fun beneficiary(self: &Terms): Option<address> { self.beneficiary }

    public fun pays_cap_holder(self: &Terms): bool { self.beneficiary.is_none() }

    /// The longest accept or haul window an agreement may have: 30 days.
    public fun max_duration_ms(): u64 { MAX_DURATION_MS }

    /// The most entries `want`, or an agreement's cargo, may list.
    public fun max_items(): u64 { MAX_ITEMS }

    // === Package Functions ===

    /// Abort unless the terms fit `cargo`: no entry of `want` may name a
    /// collection and asset the cargo holds, so handing any of the cargo back
    /// can never count as delivery.
    public(package) fun assert_fits(self: &Terms, cargo: &vector<Spec>) {
        assert!(!spec::any_shared(&self.want, cargo), EInvalidTerms);
    }

    // === Internal ===

    fun build(
        want: vector<Spec>,
        collateral: u64,
        accept_ms: u64,
        haul_ms: u64,
        beneficiary: Option<address>,
    ): Terms {
        assert!(!want.is_empty() && want.length() <= MAX_ITEMS, EInvalidTerms);
        assert!(want.all!(|item| item.qty() > 0) && spec::all_distinct(&want), EInvalidTerms);
        assert!(collateral > 0, EInvalidTerms);
        assert!(accept_ms > 0 && accept_ms <= MAX_DURATION_MS, EInvalidTerms);
        assert!(haul_ms > 0 && haul_ms <= MAX_DURATION_MS, EInvalidTerms);
        Terms { want, collateral, accept_ms, haul_ms, beneficiary }
    }
}
