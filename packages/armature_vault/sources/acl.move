/// Standalone ACL primitives for the armature-vault permission model.
///
/// `Principal` is the caller-identity abstraction shared across all vault modules.
/// Each vault module defines its own `Role` type for its specific permissions.
module armature_vault::acl {
    use armature::ou::OU;

    // === Principals ===

    public enum Principal has copy, drop, store {
        Player { addr: address },
        Ou { ou_id: ID },
    }

    /// A principal satisfied by a single wallet address.
    public fun player(addr: address): Principal {
        Principal::Player { addr }
    }

    /// A principal satisfied by any board member of the OU with this id.
    public fun ou(ou_id: ID): Principal {
        Principal::Ou { ou_id }
    }

    // === Authorization ===

    /// True if `sender` satisfies `principal` given the `&OU` the caller is acting
    /// as. For a `Player` principal the OU is irrelevant; for an `Ou` principal the
    /// passed OU must be that OU and `sender` must be a current board member.
    public(package) fun satisfies(principal: &Principal, org: &OU, sender: address): bool {
        match (principal) {
            Principal::Player { addr } => *addr == sender,
            Principal::Ou { ou_id } => org.id() == *ou_id && org.is_governance_member(sender),
        }
    }
}
