/// Standalone ACL primitives for the armature-vault permission model.
///
/// `Principal` is the caller-identity abstraction shared across all vault modules.
/// Each vault module defines its own `Role` type for its specific permissions.
module armature_vault::acl {
    use armature::dao::DAO;

    // === Principals ===

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
}
