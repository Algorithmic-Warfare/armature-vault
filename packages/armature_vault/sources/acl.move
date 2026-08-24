/// Standalone ACL primitives for the armature-vault permission model.
///
/// `Principal` is the caller-identity abstraction shared across all vault modules.
/// Each vault module defines its own `Role` type for its specific permissions.
///
/// `Principal` is a kind-tagged struct rather than an enum: Sui's compatible-
/// upgrade rules freeze an enum's variant set forever (the bytecode verifier
/// rejects any variant addition), but a `u8` tag is data. Adding a principal
/// kind mid-cycle is therefore a compatible upgrade — one new constructor plus
/// one new arm in `satisfies`, no layout change, no republish. Kinds without a
/// constructor are unrepresentable (fields are private; only this module can
/// construct a value), and `satisfies` fails closed on any tag it does not
/// recognize.
///
/// Kind numbering is part of the public contract (clients BCS-decode stored
/// principals and events): player = 0, ou = 1, machine = 2. Never renumber.
module armature_vault::acl {
    use armature::dao::DAO;

    // === Kinds ===

    /// Satisfied by a single wallet address (a human player's wallet).
    const KIND_PLAYER: u8 = 0;
    /// Satisfied by any board member of the DAO/OU with this id.
    const KIND_OU: u8 = 1;
    /// Satisfied by a single wallet address held by an automated service (bot,
    /// backend worker). The trust model is identical to a player key — pure
    /// key possession — the distinct kind exists so contracts and indexers can
    /// apply machine-specific policy where a module wants it, and so UIs can
    /// tell automation apart from humans on-chain. (The receipt vault's Edit
    /// role excludes machines only the way it excludes every bare key: Edit is
    /// Ou-only.)
    const KIND_MACHINE: u8 = 2;

    // === Principals ===

    public struct Principal has copy, drop, store {
        kind: u8,
        /// Wallet address for player/machine kinds; DAO object id for ou.
        id: address,
        /// Reserved for future kinds that need more than a bare identity.
        /// Every current kind leaves it empty. `data` participates in
        /// `Principal` equality (grant dedupe / revoke matching), so any
        /// future kind that uses it must define a canonical encoding.
        data: vector<u8>,
    }

    /// A principal satisfied by a single wallet address.
    public fun player(addr: address): Principal {
        Principal { kind: KIND_PLAYER, id: addr, data: vector[] }
    }

    /// A principal satisfied by any board member of the DAO/OU with this id.
    public fun ou(dao_id: ID): Principal {
        Principal { kind: KIND_OU, id: dao_id.to_address(), data: vector[] }
    }

    /// A principal satisfied by a single machine-held wallet address.
    public fun machine(addr: address): Principal {
        Principal { kind: KIND_MACHINE, id: addr, data: vector[] }
    }

    // === Accessors ===

    public fun kind(principal: &Principal): u8 { principal.kind }

    public fun id(principal: &Principal): address { principal.id }

    public fun is_player(principal: &Principal): bool { principal.kind == KIND_PLAYER }

    public fun is_ou(principal: &Principal): bool { principal.kind == KIND_OU }

    public fun is_machine(principal: &Principal): bool { principal.kind == KIND_MACHINE }

    // === Authorization ===

    /// True if `sender` satisfies `principal` given the `&DAO` the caller is
    /// acting as. Player and machine principals are key-possession checks (the
    /// DAO is irrelevant); an ou principal requires the passed DAO to be that
    /// OU and `sender` to be on its board. Unrecognized kinds — impossible
    /// today, reachable only if a future upgrade ships a constructor without a
    /// matching arm here — never satisfy.
    public(package) fun satisfies(principal: &Principal, dao: &DAO, sender: address): bool {
        if (principal.kind == KIND_PLAYER || principal.kind == KIND_MACHINE) {
            principal.id == sender
        } else if (principal.kind == KIND_OU) {
            dao.id().to_address() == principal.id && dao.is_governance_member(sender)
        } else {
            false
        }
    }
}
