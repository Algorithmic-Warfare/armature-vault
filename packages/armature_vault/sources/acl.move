/// Standalone ACL primitives for the armature-vault permission model.
///
/// `Role` and `Principal` are the two axes of the access-control model used
/// across all vault modules in this package. A caller passes a role check if
/// they satisfy *any* principal listed for that role.
///
/// Extracted here so that future modules moved into this package (e.g. keyspace
/// encrypted-entry contracts) can share the same permission model without
/// depending on `dao_receipt_vault` directly.
module armature_vault::acl {
    use armature::dao::DAO;

    // === Roles ===

    public enum Role has copy, drop, store {
        Deposit,
        Withdraw,
        Edit,
    }

    public fun role_deposit(): Role { Role::Deposit }

    public fun role_withdraw(): Role { Role::Withdraw }

    public fun role_edit(): Role { Role::Edit }

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
