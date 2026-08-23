/// Standalone ACL primitives for the armature-vault permission model.
///
/// `Principal` is the caller-identity abstraction shared across all vault modules.
/// Each vault module defines its own `Role` type for its specific permissions.
module armature_vault::acl {
    use armature::dao::DAO;

    // === Principals (v1, frozen) ===

    // Frozen by Sui upgrade compatibility: a published enum can never gain,
    // lose, or reorder variants (move-binary-format compatibility check), so
    // this enum can never learn a new principal kind.  `PrincipalV2` below is
    // its upgradeable successor; new code should use that.  This type stays
    // published and fully functional forever — existing grants keep working.
    public enum Principal has copy, drop, store {
        Player { addr: address },
        Ou { dao_id: ID },
    }

    /// A principal satisfied by a single wallet address.
    public fun player(addr: address): Principal {
        Principal::Player { addr }
    }

    /// A principal satisfied by any board member of the DAO/OU with this id.
    public fun ou(dao_id: ID): Principal {
        Principal::Ou { dao_id }
    }

    // === Authorization ===

    /// True if `sender` satisfies `principal` given the `&DAO` the caller is acting
    /// as. For a `Player` principal the DAO is irrelevant; for an `Ou` principal the
    /// passed DAO must be that OU and `sender` must be on its board.
    public(package) fun satisfies(principal: &Principal, dao: &DAO, sender: address): bool {
        match (principal) {
            Principal::Player { addr } => *addr == sender,
            Principal::Ou { dao_id } => dao.id() == *dao_id && dao.is_governance_member(sender),
        }
    }

    // === Interop with acl_v2 ===
    //
    // Enum variants can only be matched in their defining module, so these
    // accessors are how `acl_v2::from_v1` lifts a legacy principal without
    // this module needing to know anything about v2 kinds.

    /// True if this is an `Ou` principal (false for `Player`).
    public fun is_ou(principal: &Principal): bool {
        match (principal) {
            Principal::Player { .. } => false,
            Principal::Ou { .. } => true,
        }
    }

    /// The principal's identity as an address: the wallet for `Player`, the
    /// DAO/OU id for `Ou` (an `ID` has the same 32-byte representation).
    public fun identity(principal: &Principal): address {
        match (principal) {
            Principal::Player { addr } => *addr,
            Principal::Ou { dao_id } => dao_id.to_address(),
        }
    }
}
