/// Standalone ACL primitives for the armature-vault permission model.
///
/// `Principal` is the caller-identity abstraction shared across all vault modules.
/// Each vault module defines its own `Role` type for its specific permissions.
module armature_vault::acl {
    use armature::dao::DAO;

    // === Principals ===

    // BCS encodes enums as a ULEB128 variant index — indexers decode stored
    // event bytes by position, so variant order is load-bearing: append only.
    public enum Principal has copy, drop, store {
        Player { addr: address },
        Ou { dao_id: ID },
        Machine { addr: address },
    }

    /// A principal satisfied by a single wallet address.
    public fun player(addr: address): Principal {
        Principal::Player { addr }
    }

    /// A principal satisfied by any board member of the DAO/OU with this id.
    public fun ou(dao_id: ID): Principal {
        Principal::Ou { dao_id }
    }

    /// A principal satisfied by a single machine-held key's address — a
    /// server-side keypair rather than a human wallet. Same authorization rule
    /// as `Player`; the separate variant types the identity so indexers and
    /// UIs can distinguish machine access from human access.
    public fun machine(addr: address): Principal {
        Principal::Machine { addr }
    }

    // === Authorization ===

    /// True if `sender` satisfies `principal` given the `&DAO` the caller is acting
    /// as. For `Player` and `Machine` principals the DAO is irrelevant; for an `Ou`
    /// principal the passed DAO must be that OU and `sender` must be on its board.
    public(package) fun satisfies(principal: &Principal, dao: &DAO, sender: address): bool {
        match (principal) {
            Principal::Player { addr } => *addr == sender,
            Principal::Ou { dao_id } => dao.id() == *dao_id && dao.is_governance_member(sender),
            Principal::Machine { addr } => *addr == sender,
        }
    }
}
