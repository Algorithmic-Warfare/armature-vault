#[test_only]
module armature_vault::acl_v2_tests {
    use armature_vault::{acl, acl_v2};

    const PLAYER: address = @0xB;
    const MACHINE: address = @0xC;
    const OU: address = @0xD;

    // ── Kinds ─────────────────────────────────────────────────────────────────

    #[test]
    fun test_kind_tags_and_accessors() {
        let p = acl_v2::player(PLAYER);
        assert!(acl_v2::kind(&p) == acl_v2::kind_player(), 0);
        assert!(acl_v2::id(&p) == PLAYER, 1);

        let m = acl_v2::machine(MACHINE);
        assert!(acl_v2::kind(&m) == acl_v2::kind_machine(), 2);
        assert!(acl_v2::id(&m) == MACHINE, 3);

        let o = acl_v2::ou(object::id_from_address(OU));
        assert!(acl_v2::kind(&o) == acl_v2::kind_ou(), 4);
        assert!(acl_v2::id(&o) == OU, 5);
    }

    // Kind is part of identity: the same address under two kinds is two
    // different principals, which is what keeps machine access distinguishable
    // from human access in an ACL.
    #[test]
    fun test_kind_is_part_of_identity() {
        assert!(acl_v2::player(PLAYER) != acl_v2::machine(PLAYER), 0);
        assert!(acl_v2::player(PLAYER) == acl_v2::player(PLAYER), 1);
    }

    // ── from_v1 ───────────────────────────────────────────────────────────────

    #[test]
    fun test_from_v1_lifts_both_legacy_variants() {
        let lifted_player = acl_v2::from_v1(&acl::player(PLAYER));
        assert!(lifted_player == acl_v2::player(PLAYER), 0);

        let ou_id = object::id_from_address(OU);
        let lifted_ou = acl_v2::from_v1(&acl::ou(ou_id));
        assert!(lifted_ou == acl_v2::ou(ou_id), 1);
    }

    // ── data payload convention ───────────────────────────────────────────────

    // Every current kind ships with an empty payload.
    #[test]
    fun test_current_kinds_have_no_payload() {
        assert!(!acl_v2::has_payload(&acl_v2::player(PLAYER)), 0);
        assert!(!acl_v2::has_payload(&acl_v2::machine(MACHINE)), 1);
        assert!(!acl_v2::has_payload(&acl_v2::ou(object::id_from_address(OU))), 2);
        assert!(acl_v2::data(&acl_v2::player(PLAYER)).is_empty(), 3);
    }

    // A payload round-trips through the [version, ...bcs] convention.
    #[test]
    fun test_payload_roundtrip() {
        let p = acl_v2::principal_with_payload(9, MACHINE, 3, vector[7, 8, 9]);

        assert!(acl_v2::kind(&p) == 9, 0);
        assert!(acl_v2::id(&p) == MACHINE, 1);
        assert!(acl_v2::has_payload(&p), 2);
        assert!(acl_v2::payload_version(&p) == 3, 3);
        assert!(acl_v2::payload(&p) == vector[7, 8, 9], 4);
        // Raw view keeps the version byte in front.
        assert!(acl_v2::data(&p) == vector[3, 7, 8, 9], 5);
    }

    // A payload may be a bare version tag with no body.
    #[test]
    fun test_version_only_payload() {
        let p = acl_v2::principal_with_payload(9, MACHINE, 1, vector[]);
        assert!(acl_v2::has_payload(&p), 0);
        assert!(acl_v2::payload_version(&p) == 1, 1);
        assert!(acl_v2::payload(&p).is_empty(), 2);
    }

    // Payloads are part of equality — two principals differing only in payload
    // are distinct grants.
    #[test]
    fun test_payload_participates_in_equality() {
        let a = acl_v2::principal_with_payload(9, MACHINE, 1, vector[1]);
        let b = acl_v2::principal_with_payload(9, MACHINE, 1, vector[2]);
        let c = acl_v2::principal_with_payload(9, MACHINE, 2, vector[1]);
        assert!(a != b, 0);
        assert!(a != c, 1);
        assert!(a == acl_v2::principal_with_payload(9, MACHINE, 1, vector[1]), 2);
    }

    #[test]
    #[expected_failure(abort_code = acl_v2::ENoPayload)]
    fun test_payload_version_aborts_without_payload() {
        acl_v2::payload_version(&acl_v2::player(PLAYER));
    }

    #[test]
    #[expected_failure(abort_code = acl_v2::ENoPayload)]
    fun test_payload_aborts_without_payload() {
        acl_v2::payload(&acl_v2::player(PLAYER));
    }
}
