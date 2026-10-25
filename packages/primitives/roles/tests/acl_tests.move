#[test_only]
module roles::acl_tests {
    use armature::{governance, ou::{Self, OU}, proposal, remove_member::RemoveMember};
    use roles::acl;
    use std::string;
    use std::unit_test::assert_eq;
    use sui::bcs;
    use sui::test_scenario::{Self as ts, Scenario};

    const MEMBER: address = @0xA1;
    const OTHER_MEMBER: address = @0xB1;
    const PLAYER: address = @0xC1;
    const BOT: address = @0xF1;
    const OUTSIDER: address = @0x0E;

    fun make_ou(scenario: &mut Scenario, creator: address, members: vector<address>): ID {
        scenario.next_tx(creator);
        ou::create(
            &governance::init_board(members),
            string::utf8(b"OU"),
            string::utf8(b"https://example.com/ou.json"),
            scenario.ctx(),
        )
    }

    #[test]
    fun player_and_machine_match_their_address_only() {
        let mut scenario = ts::begin(MEMBER);
        let ou_id = make_ou(&mut scenario, MEMBER, vector[MEMBER]);
        scenario.next_tx(MEMBER);
        let org = scenario.take_shared_by_id<OU>(ou_id);
        let player = acl::player(PLAYER);
        let bot = acl::machine(BOT);
        assert!(player.satisfies(&org, PLAYER));
        assert!(!player.satisfies(&org, OUTSIDER));
        assert!(bot.satisfies(&org, BOT));
        assert!(player.satisfies_directly(PLAYER));
        assert!(bot.satisfies_directly(BOT));
        assert!(!bot.satisfies_directly(PLAYER));
        ts::return_shared(org);
        scenario.end();
    }

    #[test]
    fun ou_principal_needs_that_ou_and_a_board_member() {
        let mut scenario = ts::begin(MEMBER);
        let ou_id = make_ou(&mut scenario, MEMBER, vector[MEMBER]);
        let other_id = make_ou(&mut scenario, OTHER_MEMBER, vector[OTHER_MEMBER]);
        scenario.next_tx(MEMBER);
        let org = scenario.take_shared_by_id<OU>(ou_id);
        let other = scenario.take_shared_by_id<OU>(other_id);
        let principal = acl::ou(ou_id);
        assert!(principal.satisfies(&org, MEMBER));
        assert!(!principal.satisfies(&org, OUTSIDER));
        // A board member of another OU, acting as that OU, does not qualify.
        assert!(!principal.satisfies(&other, OTHER_MEMBER));
        // Nor does a real member who passes the wrong OU.
        assert!(!principal.satisfies(&other, MEMBER));
        // Without an OU to check, an Ou principal is never satisfied.
        assert!(!principal.satisfies_directly(MEMBER));
        ts::return_shared(other);
        ts::return_shared(org);
        scenario.end();
    }

    #[test]
    fun removed_board_member_no_longer_satisfies() {
        let mut scenario = ts::begin(MEMBER);
        let ou_id = make_ou(&mut scenario, MEMBER, vector[MEMBER, OTHER_MEMBER]);
        scenario.next_tx(MEMBER);
        let mut org = scenario.take_shared_by_id<OU>(ou_id);
        let principal = acl::ou(ou_id);
        assert!(principal.satisfies(&org, OTHER_MEMBER));
        let req = proposal::new_execution_request_for_testing<RemoveMember>(
            ou_id,
            object::id_from_address(@0x9999),
        );
        org.remove_board_member_governance(OTHER_MEMBER, &req);
        proposal::consume_execution_request_for_testing(req);
        assert!(!principal.satisfies(&org, OTHER_MEMBER));
        assert!(principal.satisfies(&org, MEMBER));
        ts::return_shared(org);
        scenario.end();
    }

    #[test]
    fun peel_principal_reads_what_bcs_wrote() {
        let principals = vector[
            acl::player(PLAYER),
            acl::ou(object::id_from_address(@0x0B)),
            acl::machine(BOT),
        ];
        let mut bytes = bcs::new(bcs::to_bytes(&principals));
        assert_eq!(bytes.peel_vec_length(), 3);
        assert_eq!(acl::peel_principal(&mut bytes), principals[0]);
        assert_eq!(acl::peel_principal(&mut bytes), principals[1]);
        assert_eq!(acl::peel_principal(&mut bytes), principals[2]);
        assert_eq!(bytes.into_remainder_bytes(), vector[]);
    }

    #[test, expected_failure(abort_code = acl::EUnknownPrincipal)]
    fun peel_principal_rejects_an_unknown_variant() {
        let mut bytes = bcs::new(vector[3]);
        acl::peel_principal(&mut bytes);
    }
}
