/// A typed rule a lister attaches to an agreement action and a rule module
/// satisfies through a `Request`.
///
/// Adapted from world-contracts `core::requirement` without the component
/// targeting, which agreements do not need.
///
/// - `type_name` identifies which module may satisfy it: only the module that
///   defines the config type can produce the matching `Permit`.
/// - `data` is the BCS encoding of the rule's typed config.
module agreements::requirement {
    use std::{bcs, type_name::{Self, TypeName}};

    // === Structs ===

    public struct Requirement has copy, drop, store {
        type_name: TypeName,
        data: vector<u8>,
    }

    // === Public Functions ===

    /// Build a requirement from a typed config `c`. The type identity is recorded
    /// from `T`, so only the package that defines `T` can later satisfy it, while
    /// `data` carries the BCS-encoded configuration the rule enforces.
    public fun from_config<T: drop>(c: T): Requirement {
        Requirement {
            type_name: type_name::with_original_ids<T>(),
            data: bcs::to_bytes(&c),
        }
    }

    // === View Functions ===

    /// True when this requirement is satisfied by the module that defines `T`.
    public fun is<T>(r: &Requirement): bool {
        r.type_name == type_name::with_original_ids<T>()
    }

    public fun type_name(r: &Requirement): TypeName {
        r.type_name
    }

    public fun data(r: &Requirement): vector<u8> {
        r.data
    }
}
