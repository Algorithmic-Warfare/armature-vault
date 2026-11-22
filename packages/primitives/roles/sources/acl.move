/// Standalone ACL primitives for role-gated packages in this repo.
///
/// `Principal` is the caller-identity abstraction. Each consuming package
/// defines its own `Role` type and maps each role to a list of principals; a
/// caller holds a role if they satisfy any principal listed for it.
///
/// `agreement_roles`' claim gate and every `armature_vault` role check use it.
/// It replaced the copy the vault shipped as `armature_vault::acl` through
/// Cycle 7, adding a public `satisfies`, `satisfies_directly` and
/// `peel_principal`.
module roles::acl {
    use armature::ou::OU;
    use sui::bcs::BCS;

    // === Errors ===

    #[error(code = 0)]
    const EUnknownPrincipal: vector<u8> = b"BCS does not encode a known Principal variant";

    // === Principals ===

    public enum Principal has copy, drop, store {
        Player { addr: address },
        Ou { ou_id: ID },
        Machine { addr: address },
    }

    /// A principal satisfied by a single wallet address.
    public fun player(addr: address): Principal {
        Principal::Player { addr }
    }

    /// A principal satisfied by any board member of the OU with this id.
    public fun ou(ou_id: ID): Principal {
        Principal::Ou { ou_id }
    }

    /// A principal satisfied by a single machine address — a service or bot key,
    /// not tied to an on-chain Player. Checked exactly like `Player`.
    public fun machine(addr: address): Principal {
        Principal::Machine { addr }
    }

    /// The OU id of an `Ou` principal; none for `Player` and `Machine`. For
    /// consumers that treat OU principals specially (armature_vault's anchor).
    public fun ou_id(principal: &Principal): Option<ID> {
        match (principal) {
            Principal::Ou { ou_id } => option::some(*ou_id),
            _ => option::none(),
        }
    }

    // === Authorization ===

    /// True if `sender` satisfies `principal` given the `&OU` the caller is acting
    /// as. For a `Player` or `Machine` principal the OU is irrelevant; for an `Ou` principal the
    /// passed OU must be that OU and `sender` must be a current board member.
    public fun satisfies(principal: &Principal, org: &OU, sender: address): bool {
        match (principal) {
            Principal::Player { addr } => *addr == sender,
            Principal::Ou { ou_id } => org.id() == *ou_id && org.is_governance_member(sender),
            Principal::Machine { addr } => *addr == sender,
        }
    }

    /// True if `sender` satisfies a `Player` or `Machine` principal. Always false
    /// for an `Ou` principal, which needs the OU to check. For callers that hold
    /// a role directly and have no OU to act as.
    public fun satisfies_directly(principal: &Principal, sender: address): bool {
        match (principal) {
            Principal::Player { addr } => *addr == sender,
            Principal::Ou { .. } => false,
            Principal::Machine { addr } => *addr == sender,
        }
    }

    // === Decoding ===

    /// Read one `Principal` from BCS, as `bcs::to_bytes` wrote it. For packages
    /// that store principals inside a BCS-encoded config, such as a requirement.
    /// Kept beside the enum so the variant tags stay in step with it.
    public fun peel_principal(bcs: &mut BCS): Principal {
        let tag = bcs.peel_enum_tag();
        if (tag == 0) Principal::Player { addr: bcs.peel_address() }
        else if (tag == 1) Principal::Ou { ou_id: object::id_from_address(bcs.peel_address()) }
        else if (tag == 2) Principal::Machine { addr: bcs.peel_address() }
        else abort EUnknownPrincipal
    }
}
