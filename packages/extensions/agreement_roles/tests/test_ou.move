/// OU fixtures for the claim tests: create an OU and change its
/// board as an executed proposal would.
#[test_only]
module agreement_roles::test_ou {
    use armature::{
        add_member::AddMember,
        governance,
        ou::{Self, OU},
        proposal,
        remove_member::RemoveMember
    };
    use std::string;
    use sui::test_scenario::{Self as ts, Scenario};

    /// Create and share an OU whose board is `members`.
    public fun make(scenario: &mut Scenario, creator: address, members: vector<address>): ID {
        scenario.next_tx(creator);
        ou::create(
            &governance::init_board(members),
            string::utf8(b"OU"),
            string::utf8(b"https://example.com/ou.json"),
            scenario.ctx(),
        )
    }

    /// Add `member` to the OU's board as an executed AddMember would.
    public fun add_board_member(scenario: &mut Scenario, ou_id: ID, member: address) {
        scenario.next_tx(member);
        let mut org = scenario.take_shared_by_id<OU>(ou_id);
        let req = proposal::new_execution_request_for_testing<AddMember>(
            ou_id,
            object::id_from_address(@0x9998),
        );
        org.add_board_member_governance(member, &req);
        proposal::consume_execution_request_for_testing(req);
        ts::return_shared(org);
    }

    /// Remove `member` from the OU's board as an executed RemoveMember would.
    public fun remove_board_member(scenario: &mut Scenario, ou_id: ID, member: address) {
        scenario.next_tx(member);
        let mut org = scenario.take_shared_by_id<OU>(ou_id);
        let req = proposal::new_execution_request_for_testing<RemoveMember>(
            ou_id,
            object::id_from_address(@0x9999),
        );
        org.remove_board_member_governance(member, &req);
        proposal::consume_execution_request_for_testing(req);
        ts::return_shared(org);
    }
}
