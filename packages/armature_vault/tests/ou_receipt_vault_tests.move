/// Tests for `ou_receipt_vault` — the dynamic multi-principal OU-gated
/// receipt vault.
///
/// Scenarios mirror the motivating example: a shared storage where AWAR members
/// and WOLF members (two OUs) plus Protodroid (a bare player) can deposit and
/// withdraw, while AWAR officers (a higher OU) hold the Edit role and can remove
/// a principal who goes rogue. Plus the OU-migration path and the last-editor
/// brick guard.
///
/// Vaults are built via `new_for_testing` to skip the heavy world StorageUnit
/// anchor — the ACL paths under test never reference the StorageUnit.
#[test_only]
module armature_vault::ou_receipt_vault_tests {
    use armature::{ou::{Self, OU}, governance, proposal, remove_member::RemoveMember};
    use armature_vault::{
        acl::{Self as acl, Principal},
        ou_receipt_vault::{Self as vault, OuReceiptVault, Role}
    };
    use multicoin::multicoin::{Self, Collection, CollectionCap, Balance};
    use std::string;
    use sui::{test_scenario as ts, vec_map};

    // AWAR members
    const AWAR_M1: address = @0xA1;
    const AWAR_M2: address = @0xA2;
    // WOLF members
    const WOLF_M1: address = @0xB1;
    // Protodroid — bare player principal
    const PROTO: address = @0xC1;
    // AWAR officer — holds Edit
    const AWAR_OFFICER: address = @0xD1;
    // Service/bot key — Machine principal
    const BOT: address = @0xF1;
    // Nobody
    const OUTSIDER: address = @0x0E;

    const ASSET: u64 = 7;

    // === Helpers ===

    fun make_ou(scenario: &mut ts::Scenario, creator: address, members: vector<address>): ID {
        ts::next_tx(scenario, creator);
        let init = governance::init_board(members);
        ou::create(
            &init,
            string::utf8(b"OU"),
            string::utf8(b"https://example.com/i.png"),
            scenario.ctx(),
        )
    }

    /// Remove `member` from the OU's board as an executed RemoveMember would.
    fun remove_board_member(scenario: &mut ts::Scenario, ou_id: ID, member: address) {
        ts::next_tx(scenario, member);
        let mut org = ts::take_shared_by_id<OU>(scenario, ou_id);
        let req = proposal::new_execution_request_for_testing<RemoveMember>(
            ou_id,
            object::id_from_address(@0x9999),
        );
        org.remove_board_member_governance(member, &req);
        proposal::consume_execution_request_for_testing(req);
        ts::return_shared(org);
    }

    fun make_collection(scenario: &mut ts::Scenario, owner: address): ID {
        ts::next_tx(scenario, owner);
        let (collection, cap) = multicoin::new_collection(scenario.ctx());
        let cid = object::id(&collection);
        transfer::public_share_object(collection);
        transfer::public_transfer(cap, owner);
        cid
    }

    fun mint(
        scenario: &mut ts::Scenario,
        owner: address,
        collection_id: ID,
        asset_id: u64,
        amount: u64,
    ): Balance {
        ts::next_tx(scenario, owner);
        let mut collection = ts::take_shared_by_id<Collection>(scenario, collection_id);
        let cap = ts::take_from_sender<CollectionCap>(scenario);
        let bal = multicoin::mint_balance(&cap, &mut collection, asset_id, amount, scenario.ctx());
        ts::return_to_sender(scenario, cap);
        ts::return_shared(collection);
        bal
    }

    /// Build the example ACL:
    ///   deposit/withdraw: [ou(awar_members), ou(wolf_members), player(proto)]
    ///   edit:             [ou(awar_officers)]
    fun example_acl(
        awar_members: ID,
        wolf_members: ID,
        awar_officers: ID,
    ): vec_map::VecMap<Role, vector<Principal>> {
        let use_perms = vector[acl::ou(awar_members), acl::ou(wolf_members), acl::player(PROTO)];
        let mut acl_map = vec_map::empty<Role, vector<Principal>>();
        acl_map.insert(vault::role_deposit(), use_perms);
        acl_map.insert(vault::role_withdraw(), use_perms);
        acl_map.insert(vault::role_edit(), vector[acl::ou(awar_officers)]);
        acl_map
    }

    // === Tests ===

    /// AWAR member deposits; WOLF member deposits; Protodroid (player) withdraws.
    #[test]
    fun multi_principal_deposit_withdraw() {
        let mut scenario = ts::begin(AWAR_M1);

        let awar = make_ou(&mut scenario, AWAR_M1, vector[AWAR_M1]);
        let wolf = make_ou(&mut scenario, WOLF_M1, vector[WOLF_M1]);
        let officers = make_ou(&mut scenario, AWAR_OFFICER, vector[AWAR_OFFICER]);
        let collection_id = make_collection(&mut scenario, AWAR_M1);

        ts::next_tx(&mut scenario, AWAR_M1);
        let v = vault::new_for_testing(
            object::id_from_address(@0x5501),
            collection_id,
            example_acl(awar, wolf, officers),
            scenario.ctx(),
        );
        vault::share_for_testing(v);

        // AWAR member deposits 100 (acting as the AWAR OU).
        let r1 = mint(&mut scenario, AWAR_M1, collection_id, ASSET, 100);
        ts::next_tx(&mut scenario, AWAR_M1);
        {
            let mut v = ts::take_shared<OuReceiptVault>(&scenario);
            let awar_ou = ts::take_shared_by_id<OU>(&scenario, awar);
            vault::deposit_receipt(&mut v, &awar_ou, r1, scenario.ctx());
            ts::return_shared(awar_ou);
            ts::return_shared(v);
        };

        // WOLF member deposits 50 (acting as the WOLF OU). The receipt is minted by
        // the collection owner (AWAR_M1 holds the CollectionCap) and handed to WOLF.
        let r2 = mint(&mut scenario, AWAR_M1, collection_id, ASSET, 50);
        ts::next_tx(&mut scenario, WOLF_M1);
        {
            let mut v = ts::take_shared<OuReceiptVault>(&scenario);
            let wolf_ou = ts::take_shared_by_id<OU>(&scenario, wolf);
            vault::deposit_receipt(&mut v, &wolf_ou, r2, scenario.ctx());
            assert!(vault::vault_balance(&v, ASSET) == 150, 0);
            ts::return_shared(wolf_ou);
            ts::return_shared(v);
        };

        // Protodroid (bare player) withdraws 60 — passes any OU ref (uses AWAR's).
        ts::next_tx(&mut scenario, PROTO);
        {
            let mut v = ts::take_shared<OuReceiptVault>(&scenario);
            let any_ou = ts::take_shared_by_id<OU>(&scenario, awar);
            let out = vault::withdraw_receipt(&mut v, &any_ou, ASSET, 60, scenario.ctx());
            assert!(out.value() == 60, 1);
            assert!(vault::vault_balance(&v, ASSET) == 90, 2);
            transfer::public_transfer(out, PROTO);
            ts::return_shared(any_ou);
            ts::return_shared(v);
        };

        ts::end(scenario);
    }

    /// An outsider (no principal) cannot deposit.
    #[test]
    #[expected_failure(abort_code = vault::ENotAuthorized)]
    fun deposit_rejected_for_outsider() {
        let mut scenario = ts::begin(AWAR_M1);
        let awar = make_ou(&mut scenario, AWAR_M1, vector[AWAR_M1]);
        let wolf = make_ou(&mut scenario, WOLF_M1, vector[WOLF_M1]);
        let officers = make_ou(&mut scenario, AWAR_OFFICER, vector[AWAR_OFFICER]);
        let collection_id = make_collection(&mut scenario, AWAR_M1);

        ts::next_tx(&mut scenario, AWAR_M1);
        let v = vault::new_for_testing(
            object::id_from_address(@0x5501),
            collection_id,
            example_acl(awar, wolf, officers),
            scenario.ctx(),
        );
        vault::share_for_testing(v);

        let r = mint(&mut scenario, AWAR_M1, collection_id, ASSET, 10);
        // OUTSIDER tries to deposit, passing AWAR's OU (they aren't a member).
        ts::next_tx(&mut scenario, OUTSIDER);
        let mut v = ts::take_shared<OuReceiptVault>(&scenario);
        let awar_ou = ts::take_shared_by_id<OU>(&scenario, awar);
        vault::deposit_receipt(&mut v, &awar_ou, r, scenario.ctx());

        abort
    }

    /// AWAR officers (Edit) revoke Protodroid's withdraw perm; he can no longer withdraw.
    #[test]
    #[expected_failure(abort_code = vault::ENotAuthorized)]
    fun officers_revoke_rogue_player() {
        let mut scenario = ts::begin(AWAR_M1);
        let awar = make_ou(&mut scenario, AWAR_M1, vector[AWAR_M1]);
        let wolf = make_ou(&mut scenario, WOLF_M1, vector[WOLF_M1]);
        let officers = make_ou(&mut scenario, AWAR_OFFICER, vector[AWAR_OFFICER]);
        let collection_id = make_collection(&mut scenario, AWAR_M1);

        ts::next_tx(&mut scenario, AWAR_M1);
        let v = vault::new_for_testing(
            object::id_from_address(@0x5501),
            collection_id,
            example_acl(awar, wolf, officers),
            scenario.ctx(),
        );
        vault::share_for_testing(v);

        // Seed some balance via AWAR member.
        let r = mint(&mut scenario, AWAR_M1, collection_id, ASSET, 100);
        ts::next_tx(&mut scenario, AWAR_M1);
        {
            let mut v = ts::take_shared<OuReceiptVault>(&scenario);
            let awar_ou = ts::take_shared_by_id<OU>(&scenario, awar);
            vault::deposit_receipt(&mut v, &awar_ou, r, scenario.ctx());
            ts::return_shared(awar_ou);
            ts::return_shared(v);
        };

        // Officer revokes Protodroid from both deposit and withdraw (batch).
        ts::next_tx(&mut scenario, AWAR_OFFICER);
        {
            let mut v = ts::take_shared<OuReceiptVault>(&scenario);
            let officers_ou = ts::take_shared_by_id<OU>(&scenario, officers);
            vault::revoke(
                &mut v,
                &officers_ou,
                vector[vault::role_deposit(), vault::role_withdraw()],
                vector[acl::player(PROTO), acl::player(PROTO)],
                scenario.ctx(),
            );
            ts::return_shared(officers_ou);
            ts::return_shared(v);
        };

        // Protodroid now tries to withdraw — must abort ENotAuthorized.
        ts::next_tx(&mut scenario, PROTO);
        let mut v = ts::take_shared<OuReceiptVault>(&scenario);
        let awar_ou = ts::take_shared_by_id<OU>(&scenario, awar);
        let out = vault::withdraw_receipt(&mut v, &awar_ou, ASSET, 10, scenario.ctx());
        transfer::public_transfer(out, PROTO);

        abort
    }

    /// A non-editor cannot administer the ACL.
    #[test]
    #[expected_failure(abort_code = vault::ENotAuthorized)]
    fun non_editor_cannot_grant() {
        let mut scenario = ts::begin(AWAR_M1);
        let awar = make_ou(&mut scenario, AWAR_M1, vector[AWAR_M1]);
        let wolf = make_ou(&mut scenario, WOLF_M1, vector[WOLF_M1]);
        let officers = make_ou(&mut scenario, AWAR_OFFICER, vector[AWAR_OFFICER]);
        let collection_id = make_collection(&mut scenario, AWAR_M1);

        ts::next_tx(&mut scenario, AWAR_M1);
        let v = vault::new_for_testing(
            object::id_from_address(@0x5501),
            collection_id,
            example_acl(awar, wolf, officers),
            scenario.ctx(),
        );
        vault::share_for_testing(v);

        // AWAR member (deposit/withdraw, NOT edit) tries to grant — must abort.
        ts::next_tx(&mut scenario, AWAR_M1);
        let mut v = ts::take_shared<OuReceiptVault>(&scenario);
        let awar_ou = ts::take_shared_by_id<OU>(&scenario, awar);
        vault::grant(
            &mut v,
            &awar_ou,
            vector[vault::role_deposit()],
            vector[acl::player(OUTSIDER)],
            scenario.ctx(),
        );

        abort
    }

    /// Migration path: a new OU is granted Edit (coexisting with the old editor),
    /// then the old editor is revoked. The new OU can administer; the property we
    /// assert is that the new OU's Edit grant takes effect and the old one is gone.
    #[test]
    fun migration_grant_new_editor_then_revoke_old() {
        let mut scenario = ts::begin(AWAR_M1);
        let awar = make_ou(&mut scenario, AWAR_M1, vector[AWAR_M1]);
        let wolf = make_ou(&mut scenario, WOLF_M1, vector[WOLF_M1]);
        let officers = make_ou(&mut scenario, AWAR_OFFICER, vector[AWAR_OFFICER]);
        let collection_id = make_collection(&mut scenario, AWAR_M1);

        ts::next_tx(&mut scenario, AWAR_M1);
        let v = vault::new_for_testing(
            object::id_from_address(@0x5501),
            collection_id,
            example_acl(awar, wolf, officers),
            scenario.ctx(),
        );
        vault::share_for_testing(v);

        // The "migrated" officers OU (new id, same officer on board for the test).
        let new_officers = make_ou(&mut scenario, AWAR_OFFICER, vector[AWAR_OFFICER]);

        // Old officers grant Edit to the new officers OU (both editors coexist).
        // grant_edit_ou checks the new OU is real via its &OU witness.
        ts::next_tx(&mut scenario, AWAR_OFFICER);
        {
            let mut v = ts::take_shared<OuReceiptVault>(&scenario);
            let officers_ou = ts::take_shared_by_id<OU>(&scenario, officers);
            let new_officers_ou = ts::take_shared_by_id<OU>(&scenario, new_officers);
            vault::grant_edit_ou(&mut v, &officers_ou, &new_officers_ou, scenario.ctx());
            assert!(vault::principals(&v, vault::role_edit()).length() == 2, 0);
            ts::return_shared(new_officers_ou);
            ts::return_shared(officers_ou);
            ts::return_shared(v);
        };

        // New officers OU now revokes the old Edit principal (valid editor itself).
        ts::next_tx(&mut scenario, AWAR_OFFICER);
        {
            let mut v = ts::take_shared<OuReceiptVault>(&scenario);
            let new_officers_ou = ts::take_shared_by_id<OU>(&scenario, new_officers);
            vault::revoke(
                &mut v,
                &new_officers_ou,
                vector[vault::role_edit()],
                vector[acl::ou(officers)],
                scenario.ctx(),
            );
            assert!(vault::principals(&v, vault::role_edit()).length() == 1, 1);
            ts::return_shared(new_officers_ou);
            ts::return_shared(v);
        };

        ts::end(scenario);
    }

    /// The last Edit principal cannot be revoked (brick guard).
    #[test]
    #[expected_failure(abort_code = vault::ELastEditor)]
    fun cannot_revoke_last_editor() {
        let mut scenario = ts::begin(AWAR_M1);
        let awar = make_ou(&mut scenario, AWAR_M1, vector[AWAR_M1]);
        let wolf = make_ou(&mut scenario, WOLF_M1, vector[WOLF_M1]);
        let officers = make_ou(&mut scenario, AWAR_OFFICER, vector[AWAR_OFFICER]);
        let collection_id = make_collection(&mut scenario, AWAR_M1);

        ts::next_tx(&mut scenario, AWAR_M1);
        let v = vault::new_for_testing(
            object::id_from_address(@0x5501),
            collection_id,
            example_acl(awar, wolf, officers),
            scenario.ctx(),
        );
        vault::share_for_testing(v);

        // Officers try to revoke themselves — the only Edit principal — must abort.
        ts::next_tx(&mut scenario, AWAR_OFFICER);
        let mut v = ts::take_shared<OuReceiptVault>(&scenario);
        let officers_ou = ts::take_shared_by_id<OU>(&scenario, officers);
        vault::revoke(
            &mut v,
            &officers_ou,
            vector[vault::role_edit()],
            vector[acl::ou(officers)],
            scenario.ctx(),
        );

        abort
    }

    // =============================================================================
    // === Regression tests for issue #1 fixes (F2/F3/F4/F5 + H1/M3/M4/L1/L2/I1)
    // === Each test was originally written against unfixed code as part of the
    // === adversarial review in
    // === https://github.com/Algorithmic-Warfare/armature-vault/issues/1#issuecomment-4690910572
    // === then flipped here to verify the fix shipped in PR #2.
    // =============================================================================

    // --- H1/M3 (superseded): Edit accepts any principal kind

    /// Roles are not tied to principal kinds: `grant` adds Player, Machine, and Ou
    /// principals to Edit alike. An Ou id need not be backed by a live OU here —
    /// `grant_edit_ou` is the witness-checked path for that.
    #[test]
    fun grant_accepts_any_principal_for_edit_role() {
        let mut scenario = ts::begin(AWAR_M1);
        let awar = make_ou(&mut scenario, AWAR_M1, vector[AWAR_M1]);
        let wolf = make_ou(&mut scenario, WOLF_M1, vector[WOLF_M1]);
        let officers = make_ou(&mut scenario, AWAR_OFFICER, vector[AWAR_OFFICER]);
        let collection_id = make_collection(&mut scenario, AWAR_M1);

        ts::next_tx(&mut scenario, AWAR_M1);
        let v = vault::new_for_testing(
            object::id_from_address(@0x5501),
            collection_id,
            example_acl(awar, wolf, officers),
            scenario.ctx(),
        );
        vault::share_for_testing(v);

        let unbacked = object::id_from_address(@0xDEADBEEF);
        ts::next_tx(&mut scenario, AWAR_OFFICER);
        {
            let mut v = ts::take_shared<OuReceiptVault>(&scenario);
            let officers_ou = ts::take_shared_by_id<OU>(&scenario, officers);
            vault::grant(
                &mut v,
                &officers_ou,
                vector[vault::role_edit(), vault::role_edit(), vault::role_edit()],
                vector[acl::player(AWAR_OFFICER), acl::machine(BOT), acl::ou(unbacked)],
                scenario.ctx(),
            );
            let edits = vault::principals(&v, vault::role_edit());
            assert!(edits.length() == 4, 0);
            assert!(edits.contains(&acl::player(AWAR_OFFICER)), 1);
            assert!(edits.contains(&acl::machine(BOT)), 2);
            assert!(edits.contains(&acl::ou(unbacked)), 3);
            ts::return_shared(officers_ou);
            ts::return_shared(v);
        };
        ts::end(scenario);
    }

    /// A Machine granted Edit administers the vault on its own key, passing any OU
    /// ref: it grants a role and revokes the officers OU it was granted by.
    #[test]
    fun machine_granted_edit_administers_vault() {
        let mut scenario = ts::begin(AWAR_M1);
        let awar = make_ou(&mut scenario, AWAR_M1, vector[AWAR_M1]);
        let wolf = make_ou(&mut scenario, WOLF_M1, vector[WOLF_M1]);
        let officers = make_ou(&mut scenario, AWAR_OFFICER, vector[AWAR_OFFICER]);
        let collection_id = make_collection(&mut scenario, AWAR_M1);

        ts::next_tx(&mut scenario, AWAR_M1);
        let v = vault::new_for_testing(
            object::id_from_address(@0x5501),
            collection_id,
            example_acl(awar, wolf, officers),
            scenario.ctx(),
        );
        vault::share_for_testing(v);

        ts::next_tx(&mut scenario, AWAR_OFFICER);
        {
            let mut v = ts::take_shared<OuReceiptVault>(&scenario);
            let officers_ou = ts::take_shared_by_id<OU>(&scenario, officers);
            vault::grant(
                &mut v,
                &officers_ou,
                vector[vault::role_edit()],
                vector[acl::machine(BOT)],
                scenario.ctx(),
            );
            ts::return_shared(officers_ou);
            ts::return_shared(v);
        };

        ts::next_tx(&mut scenario, BOT);
        {
            let mut v = ts::take_shared<OuReceiptVault>(&scenario);
            let any_ou = ts::take_shared_by_id<OU>(&scenario, awar);
            vault::grant(
                &mut v,
                &any_ou,
                vector[vault::role_deposit()],
                vector[acl::player(OUTSIDER)],
                scenario.ctx(),
            );
            vault::revoke(
                &mut v,
                &any_ou,
                vector[vault::role_edit()],
                vector[acl::ou(officers)],
                scenario.ctx(),
            );
            assert!(vault::principals(&v, vault::role_deposit()).contains(&acl::player(OUTSIDER)), 0);
            assert!(vault::principals(&v, vault::role_edit()) == vector[acl::machine(BOT)], 1);
            ts::return_shared(any_ou);
            ts::return_shared(v);
        };
        ts::end(scenario);
    }

    /// Officers grant a Machine key Deposit + Withdraw; the bot deposits and
    /// withdraws as its own address, passing any OU ref.
    #[test]
    fun machine_granted_deposit_withdraw() {
        let mut scenario = ts::begin(AWAR_M1);
        let awar = make_ou(&mut scenario, AWAR_M1, vector[AWAR_M1]);
        let wolf = make_ou(&mut scenario, WOLF_M1, vector[WOLF_M1]);
        let officers = make_ou(&mut scenario, AWAR_OFFICER, vector[AWAR_OFFICER]);
        let collection_id = make_collection(&mut scenario, AWAR_M1);

        ts::next_tx(&mut scenario, AWAR_M1);
        let v = vault::new_for_testing(
            object::id_from_address(@0x5501),
            collection_id,
            example_acl(awar, wolf, officers),
            scenario.ctx(),
        );
        vault::share_for_testing(v);

        ts::next_tx(&mut scenario, AWAR_OFFICER);
        {
            let mut v = ts::take_shared<OuReceiptVault>(&scenario);
            let officers_ou = ts::take_shared_by_id<OU>(&scenario, officers);
            vault::grant(
                &mut v,
                &officers_ou,
                vector[vault::role_deposit(), vault::role_withdraw()],
                vector[acl::machine(BOT), acl::machine(BOT)],
                scenario.ctx(),
            );
            ts::return_shared(officers_ou);
            ts::return_shared(v);
        };

        let r = mint(&mut scenario, AWAR_M1, collection_id, ASSET, 40);
        ts::next_tx(&mut scenario, BOT);
        {
            let mut v = ts::take_shared<OuReceiptVault>(&scenario);
            let any_ou = ts::take_shared_by_id<OU>(&scenario, awar);
            vault::deposit_receipt(&mut v, &any_ou, r, scenario.ctx());
            let out = vault::withdraw_receipt(&mut v, &any_ou, ASSET, 15, scenario.ctx());
            assert!(out.value() == 15, 0);
            assert!(vault::vault_balance(&v, ASSET) == 25, 1);
            transfer::public_transfer(out, BOT);
            ts::return_shared(any_ou);
            ts::return_shared(v);
        };

        ts::end(scenario);
    }

    /// Revoking a Machine's Withdraw locks the bot out.
    #[test]
    #[expected_failure(abort_code = vault::ENotAuthorized)]
    fun revoked_machine_cannot_withdraw() {
        let mut scenario = ts::begin(AWAR_M1);
        let awar = make_ou(&mut scenario, AWAR_M1, vector[AWAR_M1]);
        let wolf = make_ou(&mut scenario, WOLF_M1, vector[WOLF_M1]);
        let officers = make_ou(&mut scenario, AWAR_OFFICER, vector[AWAR_OFFICER]);
        let collection_id = make_collection(&mut scenario, AWAR_M1);

        ts::next_tx(&mut scenario, AWAR_M1);
        let v = vault::new_for_testing(
            object::id_from_address(@0x5501),
            collection_id,
            example_acl(awar, wolf, officers),
            scenario.ctx(),
        );
        vault::share_for_testing(v);

        let r = mint(&mut scenario, AWAR_M1, collection_id, ASSET, 40);
        ts::next_tx(&mut scenario, AWAR_M1);
        {
            let mut v = ts::take_shared<OuReceiptVault>(&scenario);
            let awar_ou = ts::take_shared_by_id<OU>(&scenario, awar);
            vault::deposit_receipt(&mut v, &awar_ou, r, scenario.ctx());
            ts::return_shared(awar_ou);
            ts::return_shared(v);
        };

        ts::next_tx(&mut scenario, AWAR_OFFICER);
        {
            let mut v = ts::take_shared<OuReceiptVault>(&scenario);
            let officers_ou = ts::take_shared_by_id<OU>(&scenario, officers);
            vault::grant(
                &mut v,
                &officers_ou,
                vector[vault::role_withdraw()],
                vector[acl::machine(BOT)],
                scenario.ctx(),
            );
            vault::revoke(
                &mut v,
                &officers_ou,
                vector[vault::role_withdraw()],
                vector[acl::machine(BOT)],
                scenario.ctx(),
            );
            ts::return_shared(officers_ou);
            ts::return_shared(v);
        };

        ts::next_tx(&mut scenario, BOT);
        let mut v = ts::take_shared<OuReceiptVault>(&scenario);
        let any_ou = ts::take_shared_by_id<OU>(&scenario, awar);
        let _out = vault::withdraw_receipt(&mut v, &any_ou, ASSET, 1, scenario.ctx());

        abort
    }

    /// grant_edit_ou succeeds with a real &OU witness and emits an event.
    #[test]
    fun grant_edit_ou_happy_path() {
        let mut scenario = ts::begin(AWAR_M1);
        let awar = make_ou(&mut scenario, AWAR_M1, vector[AWAR_M1]);
        let wolf = make_ou(&mut scenario, WOLF_M1, vector[WOLF_M1]);
        let officers = make_ou(&mut scenario, AWAR_OFFICER, vector[AWAR_OFFICER]);
        let collection_id = make_collection(&mut scenario, AWAR_M1);
        let new_officers = make_ou(&mut scenario, AWAR_OFFICER, vector[AWAR_OFFICER]);

        ts::next_tx(&mut scenario, AWAR_M1);
        let v = vault::new_for_testing(
            object::id_from_address(@0x5501),
            collection_id,
            example_acl(awar, wolf, officers),
            scenario.ctx(),
        );
        vault::share_for_testing(v);

        ts::next_tx(&mut scenario, AWAR_OFFICER);
        {
            let mut v = ts::take_shared<OuReceiptVault>(&scenario);
            let officers_ou = ts::take_shared_by_id<OU>(&scenario, officers);
            let new_officers_ou = ts::take_shared_by_id<OU>(&scenario, new_officers);
            vault::grant_edit_ou(&mut v, &officers_ou, &new_officers_ou, scenario.ctx());
            let edits = vault::principals(&v, vault::role_edit());
            assert!(edits.length() == 2, 0);
            assert!(edits.contains(&acl::ou(new_officers)), 1);
            ts::return_shared(new_officers_ou);
            ts::return_shared(officers_ou);
            ts::return_shared(v);
        };
        ts::end(scenario);
    }

    // --- H1 brick-guard 2: caller must remain satisfied post-revoke

    /// Revoke aborts EEditorWouldLockSelf if the caller wouldn't pass assert_role(Edit)
    /// after the batch. Defends against the "grant unsatisfiable then revoke self"
    /// brick path now that Edit accepts any principal.
    #[test]
    #[expected_failure(abort_code = vault::EEditorWouldLockSelf)]
    fun revoke_aborts_if_caller_would_lock_themselves() {
        let mut scenario = ts::begin(AWAR_M1);
        let awar = make_ou(&mut scenario, AWAR_M1, vector[AWAR_M1]);
        let wolf = make_ou(&mut scenario, WOLF_M1, vector[WOLF_M1]);
        let officers = make_ou(&mut scenario, AWAR_OFFICER, vector[AWAR_OFFICER]);
        let collection_id = make_collection(&mut scenario, AWAR_M1);
        // A second editor who is NOT a member of `officers`.
        let other = make_ou(&mut scenario, OUTSIDER, vector[OUTSIDER]);

        ts::next_tx(&mut scenario, AWAR_M1);
        let v = vault::new_for_testing(
            object::id_from_address(@0x5501),
            collection_id,
            example_acl(awar, wolf, officers),
            scenario.ctx(),
        );
        vault::share_for_testing(v);

        // First, validly add `other` as a second Edit principal (Edit list non-empty).
        ts::next_tx(&mut scenario, AWAR_OFFICER);
        {
            let mut v = ts::take_shared<OuReceiptVault>(&scenario);
            let officers_ou = ts::take_shared_by_id<OU>(&scenario, officers);
            let other_ou = ts::take_shared_by_id<OU>(&scenario, other);
            vault::grant_edit_ou(&mut v, &officers_ou, &other_ou, scenario.ctx());
            ts::return_shared(other_ou);
            ts::return_shared(officers_ou);
            ts::return_shared(v);
        };

        // Now AWAR_OFFICER tries to revoke `officers` (their own OU). The brick-guard 1
        // (length > 0) passes since `other` remains. But AWAR_OFFICER is NOT a member
        // of `other` — so the post-revoke caller-satisfies check fires.
        ts::next_tx(&mut scenario, AWAR_OFFICER);
        let mut v = ts::take_shared<OuReceiptVault>(&scenario);
        let officers_ou = ts::take_shared_by_id<OU>(&scenario, officers);
        vault::revoke(
            &mut v,
            &officers_ou,
            vector[vault::role_edit()],
            vector[acl::ou(officers)],
            scenario.ctx(),
        );

        abort
    }

    // --- F2 + L1: events emitted only after brick-guards, and only on real changes

    /// Original L1: phantom events on no-op grant/revoke. Post-fix: zero events
    /// when the operation is a no-op, and the state is unchanged.
    #[test]
    fun no_op_grant_and_revoke_emit_no_events() {
        let mut scenario = ts::begin(AWAR_M1);
        let awar = make_ou(&mut scenario, AWAR_M1, vector[AWAR_M1]);
        let wolf = make_ou(&mut scenario, WOLF_M1, vector[WOLF_M1]);
        let officers = make_ou(&mut scenario, AWAR_OFFICER, vector[AWAR_OFFICER]);
        let collection_id = make_collection(&mut scenario, AWAR_M1);

        ts::next_tx(&mut scenario, AWAR_M1);
        let v = vault::new_for_testing(
            object::id_from_address(@0x5501),
            collection_id,
            example_acl(awar, wolf, officers),
            scenario.ctx(),
        );
        vault::share_for_testing(v);

        ts::next_tx(&mut scenario, AWAR_OFFICER);
        let deposit_len_before = {
            let v = ts::take_shared<OuReceiptVault>(&scenario);
            let n = vault::principals(&v, vault::role_deposit()).length();
            ts::return_shared(v);
            n
        };

        // (1) Duplicate grant: PROTO already has deposit.
        ts::next_tx(&mut scenario, AWAR_OFFICER);
        {
            let mut v = ts::take_shared<OuReceiptVault>(&scenario);
            let officers_ou = ts::take_shared_by_id<OU>(&scenario, officers);
            vault::grant(
                &mut v,
                &officers_ou,
                vector[vault::role_deposit()],
                vector[acl::player(PROTO)],
                scenario.ctx(),
            );
            ts::return_shared(officers_ou);
            ts::return_shared(v);
        };
        let regrant_effects = ts::next_tx(&mut scenario, AWAR_OFFICER);
        assert!(ts::num_user_events(&regrant_effects) == 0, 100);
        {
            let v = ts::take_shared<OuReceiptVault>(&scenario);
            assert!(
                vault::principals(&v, vault::role_deposit()).length() == deposit_len_before,
                101,
            );
            ts::return_shared(v);
        };

        // (2) Revoke of non-member: OUTSIDER never had deposit.
        ts::next_tx(&mut scenario, AWAR_OFFICER);
        {
            let mut v = ts::take_shared<OuReceiptVault>(&scenario);
            let officers_ou = ts::take_shared_by_id<OU>(&scenario, officers);
            vault::revoke(
                &mut v,
                &officers_ou,
                vector[vault::role_deposit()],
                vector[acl::player(OUTSIDER)],
                scenario.ctx(),
            );
            ts::return_shared(officers_ou);
            ts::return_shared(v);
        };
        let rerevoke_effects = ts::next_tx(&mut scenario, AWAR_OFFICER);
        assert!(ts::num_user_events(&rerevoke_effects) == 0, 200);

        ts::end(scenario);
    }

    // --- M4 + L2: zero-value deposit is rejected

    #[test]
    #[expected_failure(abort_code = vault::EZeroAmount)]
    fun zero_value_deposit_rejected() {
        let mut scenario = ts::begin(AWAR_M1);
        let awar = make_ou(&mut scenario, AWAR_M1, vector[AWAR_M1]);
        let wolf = make_ou(&mut scenario, WOLF_M1, vector[WOLF_M1]);
        let officers = make_ou(&mut scenario, AWAR_OFFICER, vector[AWAR_OFFICER]);
        let collection_id = make_collection(&mut scenario, AWAR_M1);

        ts::next_tx(&mut scenario, AWAR_M1);
        let v = vault::new_for_testing(
            object::id_from_address(@0x5501),
            collection_id,
            example_acl(awar, wolf, officers),
            scenario.ctx(),
        );
        vault::share_for_testing(v);

        ts::next_tx(&mut scenario, AWAR_M1);
        let zero_receipt = multicoin::zero(collection_id, ASSET, scenario.ctx());

        ts::next_tx(&mut scenario, AWAR_M1);
        let mut v = ts::take_shared<OuReceiptVault>(&scenario);
        let awar_ou = ts::take_shared_by_id<OU>(&scenario, awar);
        vault::deposit_receipt(&mut v, &awar_ou, zero_receipt, scenario.ctx());

        abort
    }

    // --- F3: zero-amount withdraw is rejected

    #[test]
    #[expected_failure(abort_code = vault::EZeroAmount)]
    fun zero_amount_withdraw_rejected() {
        let mut scenario = ts::begin(AWAR_M1);
        let awar = make_ou(&mut scenario, AWAR_M1, vector[AWAR_M1]);
        let wolf = make_ou(&mut scenario, WOLF_M1, vector[WOLF_M1]);
        let officers = make_ou(&mut scenario, AWAR_OFFICER, vector[AWAR_OFFICER]);
        let collection_id = make_collection(&mut scenario, AWAR_M1);

        ts::next_tx(&mut scenario, AWAR_M1);
        let v = vault::new_for_testing(
            object::id_from_address(@0x5501),
            collection_id,
            example_acl(awar, wolf, officers),
            scenario.ctx(),
        );
        vault::share_for_testing(v);

        let r = mint(&mut scenario, AWAR_M1, collection_id, ASSET, 10);
        ts::next_tx(&mut scenario, AWAR_M1);
        {
            let mut v = ts::take_shared<OuReceiptVault>(&scenario);
            let awar_ou = ts::take_shared_by_id<OU>(&scenario, awar);
            vault::deposit_receipt(&mut v, &awar_ou, r, scenario.ctx());
            ts::return_shared(awar_ou);
            ts::return_shared(v);
        };

        ts::next_tx(&mut scenario, PROTO);
        let mut v = ts::take_shared<OuReceiptVault>(&scenario);
        let any_ou = ts::take_shared_by_id<OU>(&scenario, awar);
        let out = vault::withdraw_receipt(&mut v, &any_ou, ASSET, 0, scenario.ctx());
        transfer::public_transfer(out, PROTO);

        abort
    }

    // --- F5: length mismatch returns EInvalidArguments, not ENotAuthorized

    #[test]
    #[expected_failure(abort_code = vault::EInvalidArguments)]
    fun grant_length_mismatch_returns_invalid_arguments() {
        let mut scenario = ts::begin(AWAR_M1);
        let awar = make_ou(&mut scenario, AWAR_M1, vector[AWAR_M1]);
        let wolf = make_ou(&mut scenario, WOLF_M1, vector[WOLF_M1]);
        let officers = make_ou(&mut scenario, AWAR_OFFICER, vector[AWAR_OFFICER]);
        let collection_id = make_collection(&mut scenario, AWAR_M1);

        ts::next_tx(&mut scenario, AWAR_M1);
        let v = vault::new_for_testing(
            object::id_from_address(@0x5501),
            collection_id,
            example_acl(awar, wolf, officers),
            scenario.ctx(),
        );
        vault::share_for_testing(v);

        ts::next_tx(&mut scenario, AWAR_OFFICER);
        let mut v = ts::take_shared<OuReceiptVault>(&scenario);
        let officers_ou = ts::take_shared_by_id<OU>(&scenario, officers);
        vault::grant(
            &mut v,
            &officers_ou,
            vector[vault::role_deposit(), vault::role_withdraw()],
            vector[acl::player(OUTSIDER)],
            scenario.ctx(),
        );

        abort
    }

    // --- F4: registry key is updatable after OU migration

    #[test]
    fun update_registry_key_remaps_vault_after_migration() {
        let mut scenario = ts::begin(AWAR_M1);
        let awar = make_ou(&mut scenario, AWAR_M1, vector[AWAR_M1]);
        let wolf = make_ou(&mut scenario, WOLF_M1, vector[WOLF_M1]);
        let officers = make_ou(&mut scenario, AWAR_OFFICER, vector[AWAR_OFFICER]);
        let new_officers = make_ou(&mut scenario, AWAR_OFFICER, vector[AWAR_OFFICER]);
        let collection_id = make_collection(&mut scenario, AWAR_M1);
        let ssu_id = object::id_from_address(@0x5501);

        // Stand up the registry so update_registry_key has a real entry to remap.
        ts::next_tx(&mut scenario, AWAR_M1);
        vault::init_for_testing(scenario.ctx());

        // Construct a vault by hand and register its key under the OLD editor OU.
        ts::next_tx(&mut scenario, AWAR_M1);
        let v = vault::new_for_testing(
            ssu_id,
            collection_id,
            example_acl(awar, wolf, officers),
            scenario.ctx(),
        );
        let v_id = object::id(&v);
        vault::share_for_testing(v);

        ts::next_tx(&mut scenario, AWAR_M1);
        {
            let mut reg = ts::take_shared<vault::OuReceiptVaultRegistry>(&scenario);
            let mut v = ts::take_shared<OuReceiptVault>(&scenario);
            vault::register_for_testing(&mut reg, ssu_id, officers, v_id);
            // M2: tell the vault which registry slot it lives under.
            vault::set_registrant_ou_id_for_testing(&mut v, officers);
            // Lookup under the old key works.
            assert!(vault::lookup(&reg, ssu_id, officers).is_some(), 0);
            assert!(vault::lookup(&reg, ssu_id, new_officers).is_none(), 1);
            ts::return_shared(v);
            ts::return_shared(reg);
        };

        // Editor re-keys the registry entry to point at the migrated OU.
        ts::next_tx(&mut scenario, AWAR_OFFICER);
        {
            let mut reg = ts::take_shared<vault::OuReceiptVaultRegistry>(&scenario);
            let mut v = ts::take_shared<OuReceiptVault>(&scenario);
            let officers_ou = ts::take_shared_by_id<OU>(&scenario, officers);
            let new_officers_ou = ts::take_shared_by_id<OU>(&scenario, new_officers);
            vault::update_registry_key(
                &mut reg,
                &mut v,
                &officers_ou,
                &new_officers_ou,
                scenario.ctx(),
            );
            // New key resolves; old key no longer.
            assert!(vault::lookup(&reg, ssu_id, new_officers).is_some(), 2);
            assert!(vault::lookup(&reg, ssu_id, officers).is_none(), 3);
            ts::return_shared(new_officers_ou);
            ts::return_shared(officers_ou);
            ts::return_shared(v);
            ts::return_shared(reg);
        };

        ts::end(scenario);
    }

    /// F4 cross-vault safety (per PR #2 review): update_registry_key aborts if the
    /// registry entry at old_key points at a *different* vault than the one passed.
    /// Prevents a caller with Edit on vault B (and editor_ou listed on vault B's
    /// ACL) from silently remapping vault A's registry entry.
    #[test]
    #[expected_failure(abort_code = vault::EInvalidArguments)]
    fun update_registry_key_rejects_cross_vault_remap() {
        let mut scenario = ts::begin(AWAR_M1);
        let awar = make_ou(&mut scenario, AWAR_M1, vector[AWAR_M1]);
        let wolf = make_ou(&mut scenario, WOLF_M1, vector[WOLF_M1]);
        let officers = make_ou(&mut scenario, AWAR_OFFICER, vector[AWAR_OFFICER]);
        let new_officers = make_ou(&mut scenario, AWAR_OFFICER, vector[AWAR_OFFICER]);
        let collection_id = make_collection(&mut scenario, AWAR_M1);
        let ssu_id = object::id_from_address(@0x5501);

        ts::next_tx(&mut scenario, AWAR_M1);
        vault::init_for_testing(scenario.ctx());

        // Vault A is the real registry occupant of (ssu_id, officers).
        ts::next_tx(&mut scenario, AWAR_M1);
        let v_a = vault::new_for_testing(
            ssu_id,
            collection_id,
            example_acl(awar, wolf, officers),
            scenario.ctx(),
        );
        let v_a_id = object::id(&v_a);
        vault::share_for_testing(v_a);

        // Vault B is a separate vault on which the officer also holds Edit.
        ts::next_tx(&mut scenario, AWAR_M1);
        let v_b = vault::new_for_testing(
            object::id_from_address(@0x5502),
            collection_id,
            example_acl(awar, wolf, officers),
            scenario.ctx(),
        );
        vault::share_for_testing(v_b);

        ts::next_tx(&mut scenario, AWAR_M1);
        {
            let mut reg = ts::take_shared<vault::OuReceiptVaultRegistry>(&scenario);
            // Only register vault A under (ssu_id, officers). Vault B is unrelated to
            // this slot but the attacker tries to remap it.
            vault::register_for_testing(&mut reg, ssu_id, officers, v_a_id);
            ts::return_shared(reg);
        };

        // Attacker holds Edit on vault B and passes vault B (not vault A) to
        // update_registry_key — pre-fix this would silently remap vault A's slot.
        ts::next_tx(&mut scenario, AWAR_OFFICER);
        let mut reg = ts::take_shared<vault::OuReceiptVaultRegistry>(&scenario);
        // Both vaults are shared; disambiguate by taking vault B by id.
        // We don't actually need the v_b id earlier — take_shared returns the second
        // one if we already took the first; instead just take by id here.
        let mut v_b = ts::take_shared<OuReceiptVault>(&scenario);
        let officers_ou = ts::take_shared_by_id<OU>(&scenario, officers);
        let new_officers_ou = ts::take_shared_by_id<OU>(&scenario, new_officers);
        vault::update_registry_key(
            &mut reg,
            &mut v_b,
            &officers_ou,
            &new_officers_ou,
            scenario.ctx(),
        );

        abort
    }

    // --- I1: initialize_ou_vault emits AclGrantedEvent for the seeded Edit principal

    // I1 is verified by inspection of the source — initialize_ou_vault now emits
    // AclGrantedEvent for every principal in deposit_principals, withdraw_principals,
    // and edit_principals alongside VaultInitializedEvent. The initialize path
    // requires a real world::StorageUnit which the existing test harness intentionally
    // bypasses (see new_for_testing's doc-comment), so this fix is not exercisable
    // as a Move #[test] here. The follow-up issue tracking M1/M2/F1 should add an
    // SSU-bootstrap helper. An EEmptyEditPrincipals guard at the top of
    // initialize_ou_vault ensures at least one Edit principal is always provided.

    // =============================================================================
    // === M2: vault teardown + DOF-emptiness tracking (#5)
    // =============================================================================

    /// M2 happy path: deinitialize an empty vault frees the registry slot and
    /// bricks the ACL so subsequent admin calls fail.
    #[test]
    fun deinitialize_empty_vault_frees_registry_slot_and_bricks_acl() {
        let mut scenario = ts::begin(AWAR_M1);
        let awar = make_ou(&mut scenario, AWAR_M1, vector[AWAR_M1]);
        let wolf = make_ou(&mut scenario, WOLF_M1, vector[WOLF_M1]);
        let officers = make_ou(&mut scenario, AWAR_OFFICER, vector[AWAR_OFFICER]);
        let collection_id = make_collection(&mut scenario, AWAR_M1);
        let ssu_id = object::id_from_address(@0x5501);

        ts::next_tx(&mut scenario, AWAR_M1);
        vault::init_for_testing(scenario.ctx());

        ts::next_tx(&mut scenario, AWAR_M1);
        let v = vault::new_for_testing(
            ssu_id,
            collection_id,
            example_acl(awar, wolf, officers),
            scenario.ctx(),
        );
        let v_id = object::id(&v);
        vault::share_for_testing(v);

        ts::next_tx(&mut scenario, AWAR_M1);
        {
            let mut reg = ts::take_shared<vault::OuReceiptVaultRegistry>(&scenario);
            let mut v = ts::take_shared<OuReceiptVault>(&scenario);
            vault::register_for_testing(&mut reg, ssu_id, officers, v_id);
            vault::set_registrant_ou_id_for_testing(&mut v, officers);
            ts::return_shared(v);
            ts::return_shared(reg);
        };

        // Editor deinitializes the empty vault.
        ts::next_tx(&mut scenario, AWAR_OFFICER);
        {
            let mut reg = ts::take_shared<vault::OuReceiptVaultRegistry>(&scenario);
            let mut v = ts::take_shared<OuReceiptVault>(&scenario);
            let officers_ou = ts::take_shared_by_id<OU>(&scenario, officers);
            vault::deinitialize_ou_vault(&mut reg, &mut v, &officers_ou, scenario.ctx());

            // Registry slot freed: lookup returns none.
            assert!(vault::lookup(&reg, ssu_id, officers).is_none(), 0);
            // ACL fully wiped — every role is now absent.
            assert!(vault::principals(&v, vault::role_edit()).is_empty(), 1);
            assert!(vault::principals(&v, vault::role_deposit()).is_empty(), 2);
            assert!(vault::principals(&v, vault::role_withdraw()).is_empty(), 3);

            ts::return_shared(officers_ou);
            ts::return_shared(v);
            ts::return_shared(reg);
        };

        ts::end(scenario);
    }

    /// M2: after deinit, no caller can satisfy any role — including the original
    /// editor. Demonstrates the brick is total.
    #[test]
    #[expected_failure(abort_code = vault::ENotAuthorized)]
    fun deinitialized_vault_rejects_grant() {
        let mut scenario = ts::begin(AWAR_M1);
        let awar = make_ou(&mut scenario, AWAR_M1, vector[AWAR_M1]);
        let wolf = make_ou(&mut scenario, WOLF_M1, vector[WOLF_M1]);
        let officers = make_ou(&mut scenario, AWAR_OFFICER, vector[AWAR_OFFICER]);
        let collection_id = make_collection(&mut scenario, AWAR_M1);
        let ssu_id = object::id_from_address(@0x5501);

        ts::next_tx(&mut scenario, AWAR_M1);
        vault::init_for_testing(scenario.ctx());

        ts::next_tx(&mut scenario, AWAR_M1);
        let v = vault::new_for_testing(
            ssu_id,
            collection_id,
            example_acl(awar, wolf, officers),
            scenario.ctx(),
        );
        let v_id = object::id(&v);
        vault::share_for_testing(v);

        ts::next_tx(&mut scenario, AWAR_M1);
        {
            let mut reg = ts::take_shared<vault::OuReceiptVaultRegistry>(&scenario);
            let mut v = ts::take_shared<OuReceiptVault>(&scenario);
            vault::register_for_testing(&mut reg, ssu_id, officers, v_id);
            vault::set_registrant_ou_id_for_testing(&mut v, officers);
            ts::return_shared(v);
            ts::return_shared(reg);
        };

        ts::next_tx(&mut scenario, AWAR_OFFICER);
        {
            let mut reg = ts::take_shared<vault::OuReceiptVaultRegistry>(&scenario);
            let mut v = ts::take_shared<OuReceiptVault>(&scenario);
            let officers_ou = ts::take_shared_by_id<OU>(&scenario, officers);
            vault::deinitialize_ou_vault(&mut reg, &mut v, &officers_ou, scenario.ctx());
            ts::return_shared(officers_ou);
            ts::return_shared(v);
            ts::return_shared(reg);
        };

        // Even the original editor can no longer administer the orphan vault.
        ts::next_tx(&mut scenario, AWAR_OFFICER);
        let mut v = ts::take_shared<OuReceiptVault>(&scenario);
        let officers_ou = ts::take_shared_by_id<OU>(&scenario, officers);
        vault::grant(
            &mut v,
            &officers_ou,
            vector[vault::role_deposit()],
            vector[acl::player(OUTSIDER)],
            scenario.ctx(),
        );

        abort
    }

    /// M2: registry slot is reusable after deinit — a fresh registration under the
    /// same (ssu_id, editor_ou_id) key succeeds.
    #[test]
    fun registry_slot_reusable_after_deinit() {
        let mut scenario = ts::begin(AWAR_M1);
        let awar = make_ou(&mut scenario, AWAR_M1, vector[AWAR_M1]);
        let wolf = make_ou(&mut scenario, WOLF_M1, vector[WOLF_M1]);
        let officers = make_ou(&mut scenario, AWAR_OFFICER, vector[AWAR_OFFICER]);
        let collection_id = make_collection(&mut scenario, AWAR_M1);
        let ssu_id = object::id_from_address(@0x5501);

        ts::next_tx(&mut scenario, AWAR_M1);
        vault::init_for_testing(scenario.ctx());

        // Stand up + register vault A.
        ts::next_tx(&mut scenario, AWAR_M1);
        let v_a = vault::new_for_testing(
            ssu_id,
            collection_id,
            example_acl(awar, wolf, officers),
            scenario.ctx(),
        );
        let v_a_id = object::id(&v_a);
        vault::share_for_testing(v_a);

        ts::next_tx(&mut scenario, AWAR_M1);
        {
            let mut reg = ts::take_shared<vault::OuReceiptVaultRegistry>(&scenario);
            let mut v = ts::take_shared<OuReceiptVault>(&scenario);
            vault::register_for_testing(&mut reg, ssu_id, officers, v_a_id);
            vault::set_registrant_ou_id_for_testing(&mut v, officers);
            ts::return_shared(v);
            ts::return_shared(reg);
        };

        // Deinit vault A.
        ts::next_tx(&mut scenario, AWAR_OFFICER);
        {
            let mut reg = ts::take_shared<vault::OuReceiptVaultRegistry>(&scenario);
            let mut v = ts::take_shared<OuReceiptVault>(&scenario);
            let officers_ou = ts::take_shared_by_id<OU>(&scenario, officers);
            vault::deinitialize_ou_vault(&mut reg, &mut v, &officers_ou, scenario.ctx());
            ts::return_shared(officers_ou);
            ts::return_shared(v);
            ts::return_shared(reg);
        };

        // Re-register a fresh vault B under the same key — must succeed.
        ts::next_tx(&mut scenario, AWAR_M1);
        let v_b = vault::new_for_testing(
            ssu_id,
            collection_id,
            example_acl(awar, wolf, officers),
            scenario.ctx(),
        );
        let v_b_id = object::id(&v_b);
        vault::share_for_testing(v_b);

        ts::next_tx(&mut scenario, AWAR_M1);
        {
            let mut reg = ts::take_shared<vault::OuReceiptVaultRegistry>(&scenario);
            vault::register_for_testing(&mut reg, ssu_id, officers, v_b_id);
            let looked_up = vault::lookup(&reg, ssu_id, officers);
            assert!(looked_up.is_some(), 0);
            assert!(*looked_up.borrow() == v_b_id, 1);
            ts::return_shared(reg);
        };

        ts::end(scenario);
    }

    /// M2: deinit aborts EVaultNonEmpty if any asset_id has a live balance.
    #[test]
    #[expected_failure(abort_code = vault::EVaultNonEmpty)]
    fun deinit_rejected_on_non_empty_vault() {
        let mut scenario = ts::begin(AWAR_M1);
        let awar = make_ou(&mut scenario, AWAR_M1, vector[AWAR_M1]);
        let wolf = make_ou(&mut scenario, WOLF_M1, vector[WOLF_M1]);
        let officers = make_ou(&mut scenario, AWAR_OFFICER, vector[AWAR_OFFICER]);
        let collection_id = make_collection(&mut scenario, AWAR_M1);
        let ssu_id = object::id_from_address(@0x5501);

        ts::next_tx(&mut scenario, AWAR_M1);
        vault::init_for_testing(scenario.ctx());

        ts::next_tx(&mut scenario, AWAR_M1);
        let v = vault::new_for_testing(
            ssu_id,
            collection_id,
            example_acl(awar, wolf, officers),
            scenario.ctx(),
        );
        let v_id = object::id(&v);
        vault::share_for_testing(v);

        ts::next_tx(&mut scenario, AWAR_M1);
        {
            let mut reg = ts::take_shared<vault::OuReceiptVaultRegistry>(&scenario);
            let mut v = ts::take_shared<OuReceiptVault>(&scenario);
            vault::register_for_testing(&mut reg, ssu_id, officers, v_id);
            vault::set_registrant_ou_id_for_testing(&mut v, officers);
            ts::return_shared(v);
            ts::return_shared(reg);
        };

        // Deposit a real balance so the vault is non-empty.
        let r = mint(&mut scenario, AWAR_M1, collection_id, ASSET, 100);
        ts::next_tx(&mut scenario, AWAR_M1);
        {
            let mut v = ts::take_shared<OuReceiptVault>(&scenario);
            let awar_ou = ts::take_shared_by_id<OU>(&scenario, awar);
            vault::deposit_receipt(&mut v, &awar_ou, r, scenario.ctx());
            assert!(vault::vault_balance(&v, ASSET) == 100, 0);
            ts::return_shared(awar_ou);
            ts::return_shared(v);
        };

        // Try to deinit — must abort EVaultNonEmpty.
        ts::next_tx(&mut scenario, AWAR_OFFICER);
        let mut reg = ts::take_shared<vault::OuReceiptVaultRegistry>(&scenario);
        let mut v = ts::take_shared<OuReceiptVault>(&scenario);
        let officers_ou = ts::take_shared_by_id<OU>(&scenario, officers);
        vault::deinitialize_ou_vault(&mut reg, &mut v, &officers_ou, scenario.ctx());

        abort
    }

    /// M2: deinit is Edit-gated — a non-editor cannot deinit even an empty vault.
    #[test]
    #[expected_failure(abort_code = vault::ENotAuthorized)]
    fun deinit_rejected_for_non_editor() {
        let mut scenario = ts::begin(AWAR_M1);
        let awar = make_ou(&mut scenario, AWAR_M1, vector[AWAR_M1]);
        let wolf = make_ou(&mut scenario, WOLF_M1, vector[WOLF_M1]);
        let officers = make_ou(&mut scenario, AWAR_OFFICER, vector[AWAR_OFFICER]);
        let collection_id = make_collection(&mut scenario, AWAR_M1);
        let ssu_id = object::id_from_address(@0x5501);

        ts::next_tx(&mut scenario, AWAR_M1);
        vault::init_for_testing(scenario.ctx());

        ts::next_tx(&mut scenario, AWAR_M1);
        let v = vault::new_for_testing(
            ssu_id,
            collection_id,
            example_acl(awar, wolf, officers),
            scenario.ctx(),
        );
        let v_id = object::id(&v);
        vault::share_for_testing(v);

        ts::next_tx(&mut scenario, AWAR_M1);
        {
            let mut reg = ts::take_shared<vault::OuReceiptVaultRegistry>(&scenario);
            let mut v = ts::take_shared<OuReceiptVault>(&scenario);
            vault::register_for_testing(&mut reg, ssu_id, officers, v_id);
            vault::set_registrant_ou_id_for_testing(&mut v, officers);
            ts::return_shared(v);
            ts::return_shared(reg);
        };

        // AWAR_M1 holds Deposit/Withdraw, NOT Edit. Try to deinit with AWAR OU.
        ts::next_tx(&mut scenario, AWAR_M1);
        let mut reg = ts::take_shared<vault::OuReceiptVaultRegistry>(&scenario);
        let mut v = ts::take_shared<OuReceiptVault>(&scenario);
        let awar_ou = ts::take_shared_by_id<OU>(&scenario, awar);
        vault::deinitialize_ou_vault(&mut reg, &mut v, &awar_ou, scenario.ctx());

        abort
    }

    /// M2 counter: deposit + full-drain returns non_empty_assets to zero, enabling
    /// deinit after a complete drawdown.
    #[test]
    fun deinit_succeeds_after_full_drawdown() {
        let mut scenario = ts::begin(AWAR_M1);
        let awar = make_ou(&mut scenario, AWAR_M1, vector[AWAR_M1]);
        let wolf = make_ou(&mut scenario, WOLF_M1, vector[WOLF_M1]);
        let officers = make_ou(&mut scenario, AWAR_OFFICER, vector[AWAR_OFFICER]);
        let collection_id = make_collection(&mut scenario, AWAR_M1);
        let ssu_id = object::id_from_address(@0x5501);

        ts::next_tx(&mut scenario, AWAR_M1);
        vault::init_for_testing(scenario.ctx());

        ts::next_tx(&mut scenario, AWAR_M1);
        let v = vault::new_for_testing(
            ssu_id,
            collection_id,
            example_acl(awar, wolf, officers),
            scenario.ctx(),
        );
        let v_id = object::id(&v);
        vault::share_for_testing(v);

        ts::next_tx(&mut scenario, AWAR_M1);
        {
            let mut reg = ts::take_shared<vault::OuReceiptVaultRegistry>(&scenario);
            let mut v = ts::take_shared<OuReceiptVault>(&scenario);
            vault::register_for_testing(&mut reg, ssu_id, officers, v_id);
            vault::set_registrant_ou_id_for_testing(&mut v, officers);
            ts::return_shared(v);
            ts::return_shared(reg);
        };

        // Deposit 100 of ASSET.
        let r = mint(&mut scenario, AWAR_M1, collection_id, ASSET, 100);
        ts::next_tx(&mut scenario, AWAR_M1);
        {
            let mut v = ts::take_shared<OuReceiptVault>(&scenario);
            let awar_ou = ts::take_shared_by_id<OU>(&scenario, awar);
            vault::deposit_receipt(&mut v, &awar_ou, r, scenario.ctx());
            ts::return_shared(awar_ou);
            ts::return_shared(v);
        };

        // Withdraw all 100 — drives the cleanup branch + counter decrement.
        ts::next_tx(&mut scenario, PROTO);
        {
            let mut v = ts::take_shared<OuReceiptVault>(&scenario);
            let any_ou = ts::take_shared_by_id<OU>(&scenario, awar);
            let out = vault::withdraw_receipt(&mut v, &any_ou, ASSET, 100, scenario.ctx());
            assert!(out.value() == 100, 0);
            assert!(vault::vault_balance(&v, ASSET) == 0, 1);
            transfer::public_transfer(out, PROTO);
            ts::return_shared(any_ou);
            ts::return_shared(v);
        };

        // Now empty: deinit succeeds.
        ts::next_tx(&mut scenario, AWAR_OFFICER);
        {
            let mut reg = ts::take_shared<vault::OuReceiptVaultRegistry>(&scenario);
            let mut v = ts::take_shared<OuReceiptVault>(&scenario);
            let officers_ou = ts::take_shared_by_id<OU>(&scenario, officers);
            vault::deinitialize_ou_vault(&mut reg, &mut v, &officers_ou, scenario.ctx());
            assert!(vault::lookup(&reg, ssu_id, officers).is_none(), 0);
            ts::return_shared(officers_ou);
            ts::return_shared(v);
            ts::return_shared(reg);
        };

        ts::end(scenario);
    }

    /// M2: after `update_registry_key`, deinit uses the *new* registry slot (the
    /// vault's `registry_key_ou_id` tracks the migration).
    #[test]
    fun deinit_uses_current_registry_key_after_migration() {
        let mut scenario = ts::begin(AWAR_M1);
        let awar = make_ou(&mut scenario, AWAR_M1, vector[AWAR_M1]);
        let wolf = make_ou(&mut scenario, WOLF_M1, vector[WOLF_M1]);
        let officers = make_ou(&mut scenario, AWAR_OFFICER, vector[AWAR_OFFICER]);
        let new_officers = make_ou(&mut scenario, AWAR_OFFICER, vector[AWAR_OFFICER]);
        let collection_id = make_collection(&mut scenario, AWAR_M1);
        let ssu_id = object::id_from_address(@0x5501);

        ts::next_tx(&mut scenario, AWAR_M1);
        vault::init_for_testing(scenario.ctx());

        ts::next_tx(&mut scenario, AWAR_M1);
        let v = vault::new_for_testing(
            ssu_id,
            collection_id,
            example_acl(awar, wolf, officers),
            scenario.ctx(),
        );
        let v_id = object::id(&v);
        vault::share_for_testing(v);

        ts::next_tx(&mut scenario, AWAR_M1);
        {
            let mut reg = ts::take_shared<vault::OuReceiptVaultRegistry>(&scenario);
            let mut v = ts::take_shared<OuReceiptVault>(&scenario);
            vault::register_for_testing(&mut reg, ssu_id, officers, v_id);
            vault::set_registrant_ou_id_for_testing(&mut v, officers);
            ts::return_shared(v);
            ts::return_shared(reg);
        };

        // First: grant new_officers Edit, then migrate the registry key to new_officers.
        ts::next_tx(&mut scenario, AWAR_OFFICER);
        {
            let mut reg = ts::take_shared<vault::OuReceiptVaultRegistry>(&scenario);
            let mut v = ts::take_shared<OuReceiptVault>(&scenario);
            let officers_ou = ts::take_shared_by_id<OU>(&scenario, officers);
            let new_officers_ou = ts::take_shared_by_id<OU>(&scenario, new_officers);
            vault::grant_edit_ou(&mut v, &officers_ou, &new_officers_ou, scenario.ctx());
            vault::update_registry_key(
                &mut reg,
                &mut v,
                &officers_ou,
                &new_officers_ou,
                scenario.ctx(),
            );
            assert!(vault::lookup(&reg, ssu_id, new_officers).is_some(), 0);
            assert!(vault::lookup(&reg, ssu_id, officers).is_none(), 1);
            ts::return_shared(new_officers_ou);
            ts::return_shared(officers_ou);
            ts::return_shared(v);
            ts::return_shared(reg);
        };

        // Now deinit with new_officers (the *current* editor) — must locate the
        // new key and free it.
        ts::next_tx(&mut scenario, AWAR_OFFICER);
        {
            let mut reg = ts::take_shared<vault::OuReceiptVaultRegistry>(&scenario);
            let mut v = ts::take_shared<OuReceiptVault>(&scenario);
            let new_officers_ou = ts::take_shared_by_id<OU>(&scenario, new_officers);
            vault::deinitialize_ou_vault(&mut reg, &mut v, &new_officers_ou, scenario.ctx());
            assert!(vault::lookup(&reg, ssu_id, new_officers).is_none(), 2);
            // ACL is fully wiped — every role becomes empty/absent.
            assert!(vault::principals(&v, vault::role_edit()).is_empty(), 3);
            assert!(vault::principals(&v, vault::role_deposit()).is_empty(), 4);
            assert!(vault::principals(&v, vault::role_withdraw()).is_empty(), 5);
            ts::return_shared(new_officers_ou);
            ts::return_shared(v);
            ts::return_shared(reg);
        };

        ts::end(scenario);
    }

    /// A member removed from an OU's board no longer satisfies that OU's
    /// principal: AWAR_M2 deposits while on the board, then is removed and
    /// the next deposit aborts.
    #[test]
    #[expected_failure(abort_code = vault::ENotAuthorized)]
    fun removed_board_member_loses_ou_access() {
        let mut scenario = ts::begin(AWAR_M1);
        let awar = make_ou(&mut scenario, AWAR_M1, vector[AWAR_M1, AWAR_M2]);
        let wolf = make_ou(&mut scenario, WOLF_M1, vector[WOLF_M1]);
        let officers = make_ou(&mut scenario, AWAR_OFFICER, vector[AWAR_OFFICER]);
        let collection_id = make_collection(&mut scenario, AWAR_M1);

        ts::next_tx(&mut scenario, AWAR_M1);
        let v = vault::new_for_testing(
            object::id_from_address(@0x5501),
            collection_id,
            example_acl(awar, wolf, officers),
            scenario.ctx(),
        );
        vault::share_for_testing(v);

        let r1 = mint(&mut scenario, AWAR_M1, collection_id, ASSET, 10);
        ts::next_tx(&mut scenario, AWAR_M2);
        {
            let mut v = ts::take_shared<OuReceiptVault>(&scenario);
            let awar_ou = ts::take_shared_by_id<OU>(&scenario, awar);
            vault::deposit_receipt(&mut v, &awar_ou, r1, scenario.ctx());
            ts::return_shared(awar_ou);
            ts::return_shared(v);
        };

        remove_board_member(&mut scenario, awar, AWAR_M2);

        let r2 = mint(&mut scenario, AWAR_M1, collection_id, ASSET, 10);
        ts::next_tx(&mut scenario, AWAR_M2);
        let mut v = ts::take_shared<OuReceiptVault>(&scenario);
        let awar_ou = ts::take_shared_by_id<OU>(&scenario, awar);
        vault::deposit_receipt(&mut v, &awar_ou, r2, scenario.ctx());

        abort
    }
}
