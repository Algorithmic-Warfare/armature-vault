/// An exact multicoin amount: `qty` of `asset_id` in `collection`.
///
/// Agreements use a `Spec` to name what a party must hand over, such as the
/// delivery a beneficiary wants or the collateral a hauler locks, and to record
/// what moved in events and outcome records.
module agreements::spec {
    use multicoin::multicoin::{Self, Balance};

    // === Errors ===

    #[error(code = 0)]
    const EWrongAsset: vector<u8> = b"Balance collection or asset does not match";
    #[error(code = 1)]
    const EWrongAmount: vector<u8> = b"Balance amount does not match";

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

    // === View Functions ===

    public fun collection(self: &Spec): ID { self.collection }

    public fun asset_id(self: &Spec): u64 { self.asset_id }

    public fun qty(self: &Spec): u64 { self.qty }
}
