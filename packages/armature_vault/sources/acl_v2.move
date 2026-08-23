/// Upgradeable successor to `armature_vault::acl`.
///
/// `acl::Principal` is frozen forever: Sui's upgrade compatibility rejects any
/// change to a published enum's variant set, so that enum can never learn a new
/// principal kind.  `PrincipalV2` is the same abstraction — a caller identity
/// that `satisfies` evaluates against a sender and a `&DAO` witness — with the
/// kind carried as *data* instead of as a type variant.  Adding a principal
/// kind is then a new constant plus a `satisfies` arm: a function-body change,
/// which upgrades allow, with no layout change anywhere.
///
/// Designed so a `PrincipalV3` should never be needed:
///   - `id`   carries the 32-byte identity every kind so far needs
///            (wallet address, OU id, machine address)
///   - `data` is a BCS escape hatch for a future kind that needs more (an
///            expiry, a type tag, a threshold set).  Empty for all current
///            kinds, and part of equality — two principals match only if kind,
///            id, and data all match.
///
/// ## `data` layout convention
///
/// `data` is either **empty** — no payload, which is how every kind ships
/// today — or **`[payload_version, ...bcs]`**: a single leading version byte
/// followed by that kind's BCS-encoded payload.  Use `principal_with_payload`
/// to build one and `has_payload` / `payload_version` / `payload` to read it,
/// rather than indexing `data` directly.
///
/// The version space is **per kind**: kind 7's payload v1 has nothing to do
/// with kind 9's payload v1.  Reserving the byte now costs nothing (no kind
/// uses `data` yet) and means a kind can later change its payload shape
/// without the ambiguity of guessing at raw bytes — the same
/// read-all-known-versions, fail-closed-on-unknown discipline the ACL store
/// uses for its own schema.
///
/// `satisfies` fails closed on unknown kinds, and a kind that expects a
/// payload should likewise deny when the payload is absent or carries a
/// version it does not understand.
module armature_vault::acl_v2 {
    use armature::dao::DAO;
    use armature_vault::acl::{Self as acl, Principal};

    // === Errors ===

    /// A payload accessor was called on a principal whose `data` is empty.
    const ENoPayload: u64 = 0;

    // === Kinds ===

    const KIND_PLAYER: u8 = 0;
    const KIND_OU: u8 = 1;
    const KIND_MACHINE: u8 = 2;

    // Kind tags, exposed as functions because Move constants aren't public.
    public fun kind_player(): u8 { KIND_PLAYER }
    public fun kind_ou(): u8 { KIND_OU }
    public fun kind_machine(): u8 { KIND_MACHINE }

    // === Principal ===

    public struct PrincipalV2 has copy, drop, store {
        kind: u8,
        id: address,
        data: vector<u8>,
    }

    /// A principal satisfied by a single wallet address (`player:*`).
    public fun player(addr: address): PrincipalV2 {
        PrincipalV2 { kind: KIND_PLAYER, id: addr, data: vector[] }
    }

    /// A principal satisfied by any board member of this DAO/OU (`ou:*`).
    public fun ou(dao_id: ID): PrincipalV2 {
        PrincipalV2 { kind: KIND_OU, id: dao_id.to_address(), data: vector[] }
    }

    /// A principal satisfied by a machine key's address (`machine:*`) — a
    /// server-held keypair rather than a human wallet.  Authorization is the
    /// same address check as `player`; the distinct kind is what lets indexers,
    /// ACL UIs, and audits tell machine access from human access.
    public fun machine(addr: address): PrincipalV2 {
        PrincipalV2 { kind: KIND_MACHINE, id: addr, data: vector[] }
    }

    /// Construct an arbitrary-kind principal.  Escape hatch for kinds added
    /// after this package version; `satisfies` denies kinds it cannot evaluate,
    /// so an unknown kind grants nothing until the logic ships.
    ///
    /// `data` must be empty or follow the `[payload_version, ...bcs]`
    /// convention — prefer `principal_with_payload`, which enforces it.
    public fun principal(kind: u8, id: address, data: vector<u8>): PrincipalV2 {
        PrincipalV2 { kind, id, data }
    }

    /// Construct a principal carrying a versioned payload: `data` becomes
    /// `payload_version` followed by `payload`.  See the `data` layout
    /// convention in the module doc.
    public fun principal_with_payload(
        kind: u8,
        id: address,
        payload_version: u8,
        payload: vector<u8>,
    ): PrincipalV2 {
        let mut data = vector[payload_version];
        data.append(payload);
        PrincipalV2 { kind, id, data }
    }

    /// Lift a legacy `acl::Principal` into its v2 equivalent.  Used to migrate
    /// existing grants; the result satisfies exactly the same senders.
    public fun from_v1(legacy: &Principal): PrincipalV2 {
        let kind = if (acl::is_ou(legacy)) { KIND_OU } else { KIND_PLAYER };
        PrincipalV2 { kind, id: acl::identity(legacy), data: vector[] }
    }

    // === Authorization ===

    /// True if `sender` satisfies `principal` given the `&DAO` the caller is
    /// acting as.  For `player` and `machine` the DAO is irrelevant; for `ou`
    /// the passed DAO must be that OU and `sender` must be on its board.
    /// Unknown kinds return false — an unrecognized principal must never
    /// authorize.
    public(package) fun satisfies(principal: &PrincipalV2, dao: &DAO, sender: address): bool {
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

    // === Accessors ===

    public fun kind(principal: &PrincipalV2): u8 { principal.kind }
    public fun id(principal: &PrincipalV2): address { principal.id }

    /// The raw `data` bytes, version byte included.  Prefer the payload
    /// accessors below unless you are deliberately reading the raw encoding.
    public fun data(principal: &PrincipalV2): &vector<u8> { &principal.data }

    /// True when this principal carries a payload.  A kind that expects one
    /// should check this and deny when it is false.
    public fun has_payload(principal: &PrincipalV2): bool {
        !principal.data.is_empty()
    }

    /// The payload's leading version byte.  Aborts if there is no payload —
    /// guard with `has_payload`.
    public fun payload_version(principal: &PrincipalV2): u8 {
        assert!(!principal.data.is_empty(), ENoPayload);
        principal.data[0]
    }

    /// The payload bytes after the version byte (empty when the payload is
    /// just a version tag).  Aborts if there is no payload.
    public fun payload(principal: &PrincipalV2): vector<u8> {
        assert!(!principal.data.is_empty(), ENoPayload);
        let n = principal.data.length();
        let mut out = vector[];
        let mut i = 1;
        while (i < n) {
            out.push_back(principal.data[i]);
            i = i + 1;
        };
        out
    }
}
