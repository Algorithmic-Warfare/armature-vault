/// An exact multicoin amount: `qty` of `asset_id` in `collection`.
///
/// Agreements use a `Spec` to name what a party must hand over, such as the
/// delivery a beneficiary wants or the collateral a hauler locks, and to record
/// what moved in events and outcome records.
///
/// A `vector<Spec>` names several items at once, such as a mixed cargo. The
/// set functions (`of_each`, `assert_each_matches`, `all_distinct`,
/// `any_shared`) treat it as a list whose entries pair with balances one for
/// one, in order.
module agreements::spec {
    use multicoin::multicoin::{Self, Balance};

    // === Errors ===

    #[error(code = 0)]
    const EWrongAsset: vector<u8> = b"Balance collection or asset does not match";
    #[error(code = 1)]
    const EWrongAmount: vector<u8> = b"Balance amount does not match";
    #[error(code = 2)]
    const EWrongCount: vector<u8> = b"Balances do not pair one for one with the specs";

    // === Structs ===

    public struct Spec has copy, drop, store {
        collection: ID,
        asset_id: u64,
        qty: u64,
    }

    // === Public Functions ===

    public fun new(collection: ID, asset_id: u64, qty: u64): Spec {
        Spec { collection, asset_id, qty }
    }

    /// What `balance` holds.
    public fun of(balance: &Balance): Spec {
        Spec {
            collection: multicoin::collection_id(balance),
            asset_id: multicoin::asset_id(balance),
            qty: multicoin::value(balance),
        }
    }

    /// Abort unless `balance` is exactly `spec`: `EWrongAsset` for another
    /// collection or asset, `EWrongAmount` for another quantity.
    public fun assert_matches(spec: &Spec, balance: &Balance) {
        assert!(
            multicoin::collection_id(balance) == spec.collection
            && multicoin::asset_id(balance) == spec.asset_id,
            EWrongAsset,
        );
        assert!(multicoin::value(balance) == spec.qty, EWrongAmount);
    }

    /// Whether `a` and `b` name the same collection and asset, whatever their
    /// quantities.
    public fun same_asset(a: &Spec, b: &Spec): bool {
        a.collection == b.collection && a.asset_id == b.asset_id
    }

    // === Spec Sets ===

    /// What each of `balances` holds, in order.
    public fun of_each(balances: &vector<Balance>): vector<Spec> {
        balances.map_ref!(|balance| of(balance))
    }

    /// Abort unless `balances` are exactly `specs`, one for one in the same
    /// order: `EWrongCount` for a different number of balances, then as
    /// `assert_matches` for each pair.
    public fun assert_each_matches(specs: &vector<Spec>, balances: &vector<Balance>) {
        assert!(specs.length() == balances.length(), EWrongCount);
        specs.zip_do_ref!(balances, |spec, balance| spec.assert_matches(balance));
    }

    /// Whether no two of `specs` name the same collection and asset.
    public fun all_distinct(specs: &vector<Spec>): bool {
        let n = specs.length();
        let mut i = 0;
        while (i < n) {
            let mut j = i + 1;
            while (j < n) {
                if (same_asset(&specs[i], &specs[j])) return false;
                j = j + 1;
            };
            i = i + 1;
        };
        true
    }

    /// Whether some entry of `a` names the same collection and asset as some
    /// entry of `b`.
    public fun any_shared(a: &vector<Spec>, b: &vector<Spec>): bool {
        a.any!(|x| b.any!(|y| same_asset(x, y)))
    }

    // === View Functions ===

    public fun collection(self: &Spec): ID { self.collection }

    public fun asset_id(self: &Spec): u64 { self.asset_id }

    public fun qty(self: &Spec): u64 { self.qty }
}
