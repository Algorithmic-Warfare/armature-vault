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

    // === Principals (v2, upgradeable) ===
    //
    // Same abstraction as `Principal` — a caller identity that `satisfies` can
    // evaluate against a sender and a `&DAO` witness — re-expressed so it can
    // grow.  The kind is *data*, not a type variant, so adding a principal
    // kind is a new constant plus a `satisfies_v2` arm: a function-body change,
    // which Sui upgrades allow.  Nothing about the layout moves.
    //
    // Designed so a `PrincipalV2` should never be needed:
    //   - `id`   carries the 32-byte identity every kind so far needs
    //            (wallet address, OU id, machine address)
    //   - `data` is a BCS escape hatch for a future kind that needs more
    //            (an expiry, a type tag, a threshold set).  Empty for all
    //            current kinds, and part of equality — two principals match
    //            only if kind, id, and data all match.
    //
    // Kind tags are dense u8s.  `satisfies_v2` fails closed on unknown kinds,
    // so an off-chain reader that predates a kind denies rather than guesses.

    const KIND_PLAYER: u8 = 0;
    const KIND_OU: u8 = 1;
    const KIND_MACHINE: u8 = 2;

    public struct PrincipalV2 has copy, drop, store {
        kind: u8,
        id: address,
        data: vector<u8>,
    }

    /// A v2 principal satisfied by a single wallet address (`player:*`).
    public fun player_v2(addr: address): PrincipalV2 {
        PrincipalV2 { kind: KIND_PLAYER, id: addr, data: vector[] }
    }

    /// A v2 principal satisfied by any board member of this DAO/OU (`ou:*`).
    public fun ou_v2(dao_id: ID): PrincipalV2 {
        PrincipalV2 { kind: KIND_OU, id: dao_id.to_address(), data: vector[] }
    }

    /// A v2 principal satisfied by a machine key's address (`machine:*`) — a
    /// server-held keypair rather than a human wallet.  Authorization is the
    /// same address check as `player`; the distinct kind is what lets
    /// indexers, ACL UIs, and audits tell machine access from human access.
    public fun machine_v2(addr: address): PrincipalV2 {
        PrincipalV2 { kind: KIND_MACHINE, id: addr, data: vector[] }
    }

    /// Construct an arbitrary-kind principal.  Escape hatch for kinds added
    /// after this package version; `satisfies_v2` denies kinds it can't
    /// evaluate, so an unknown kind grants nothing until the logic ships.
    public fun principal_v2(kind: u8, id: address, data: vector<u8>): PrincipalV2 {
        PrincipalV2 { kind, id, data }
    }

    /// Lift a legacy `Principal` into its v2 equivalent.  Used to migrate
    /// existing grants; the result satisfies exactly the same senders.
    public fun to_v2(principal: &Principal): PrincipalV2 {
        match (principal) {
            Principal::Player { addr } => player_v2(*addr),
            Principal::Ou { dao_id } => ou_v2(*dao_id),
        }
    }

    /// v2 counterpart of `satisfies`.  Unknown kinds return false — an
    /// unrecognized principal must never authorize.
    public(package) fun satisfies_v2(principal: &PrincipalV2, dao: &DAO, sender: address): bool {
        if (principal.kind == KIND_PLAYER) {
            principal.id == sender
        } else if (principal.kind == KIND_OU) {
            dao.id().to_address() == principal.id && dao.is_governance_member(sender)
        } else if (principal.kind == KIND_MACHINE) {
            principal.id == sender
        } else {
            false
        }
    }

    // Kind tags, exposed as functions because Move constants aren't public.
    public fun kind_player(): u8 { KIND_PLAYER }
    public fun kind_ou(): u8 { KIND_OU }
    public fun kind_machine(): u8 { KIND_MACHINE }

    public fun v2_kind(principal: &PrincipalV2): u8 { principal.kind }
    public fun v2_id(principal: &PrincipalV2): address { principal.id }
    public fun v2_data(principal: &PrincipalV2): &vector<u8> { &principal.data }
}
