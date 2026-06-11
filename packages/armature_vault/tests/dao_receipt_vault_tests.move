/// Tests for `dao_receipt_vault` — the dynamic multi-principal DAO/OU-gated
/// receipt vault.
///
/// Scenarios mirror the motivating example: a shared storage where AWAR members
/// and WOLF members (two OUs) plus Protodroid (a bare player) can deposit and
/// withdraw, while AWAR officers (a higher OU) hold the Edit role and can remove
/// a principal who goes rogue. Plus the DAO-migration path and the last-editor
/// brick guard.
///
/// Vaults are built via `new_for_testing` to skip the heavy world StorageUnit
/// anchor — the ACL paths under test never reference the StorageUnit.
#[test_only]
module armature_vault::dao_receipt_vault_tests;

use armature::dao::{Self, DAO};
use armature::governance;
use armature_vault::dao_receipt_vault::{Self as vault, DaoReceiptVault, Role, Principal};
use multicoin::multicoin::{Self, Collection, CollectionCap, Balance};
use std::string;
use sui::test_scenario as ts;
use sui::vec_map;

// AWAR members
const AWAR_M1: address = @0xA1;
// WOLF members
const WOLF_M1: address = @0xB1;
// Protodroid — bare player principal
const PROTO: address = @0xC1;
// AWAR officer — holds Edit
const AWAR_OFFICER: address = @0xD1;
// Nobody
const OUTSIDER: address = @0x0E;

const ASSET: u64 = 7;

// === Helpers ===

fun make_dao(scenario: &mut ts::Scenario, creator: address, members: vector<address>): ID {
    ts::next_tx(scenario, creator);
    let init = governance::init_board(members);
    dao::create(
        &init,
        string::utf8(b"OU"),
        string::utf8(b"ou"),
        string::utf8(b"https://example.com/i.png"),
        scenario.ctx(),
    )
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
    let use_perms = vector[vault::ou(awar_members), vault::ou(wolf_members), vault::player(PROTO)];
    let mut acl = vec_map::empty<Role, vector<Principal>>();
    acl.insert(vault::role_deposit(), use_perms);
    acl.insert(vault::role_withdraw(), use_perms);
    acl.insert(vault::role_edit(), vector[vault::ou(awar_officers)]);
    acl
}

// === Tests ===

/// AWAR member deposits; WOLF member deposits; Protodroid (player) withdraws.
#[test]
fun multi_principal_deposit_withdraw() {
    let mut scenario = ts::begin(AWAR_M1);

    let awar = make_dao(&mut scenario, AWAR_M1, vector[AWAR_M1]);
    let wolf = make_dao(&mut scenario, WOLF_M1, vector[WOLF_M1]);
    let officers = make_dao(&mut scenario, AWAR_OFFICER, vector[AWAR_OFFICER]);
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
        let mut v = ts::take_shared<DaoReceiptVault>(&scenario);
        let awar_dao = ts::take_shared_by_id<DAO>(&scenario, awar);
        vault::deposit_receipt(&mut v, &awar_dao, r1, scenario.ctx());
        ts::return_shared(awar_dao);
        ts::return_shared(v);
    };

    // WOLF member deposits 50 (acting as the WOLF OU). The receipt is minted by
    // the collection owner (AWAR_M1 holds the CollectionCap) and handed to WOLF.
    let r2 = mint(&mut scenario, AWAR_M1, collection_id, ASSET, 50);
    ts::next_tx(&mut scenario, WOLF_M1);
    {
        let mut v = ts::take_shared<DaoReceiptVault>(&scenario);
        let wolf_dao = ts::take_shared_by_id<DAO>(&scenario, wolf);
        vault::deposit_receipt(&mut v, &wolf_dao, r2, scenario.ctx());
        assert!(vault::vault_balance(&v, ASSET) == 150, 0);
        ts::return_shared(wolf_dao);
        ts::return_shared(v);
    };

    // Protodroid (bare player) withdraws 60 — passes any DAO ref (uses AWAR's).
    ts::next_tx(&mut scenario, PROTO);
    {
        let mut v = ts::take_shared<DaoReceiptVault>(&scenario);
        let any_dao = ts::take_shared_by_id<DAO>(&scenario, awar);
        let out = vault::withdraw_receipt(&mut v, &any_dao, ASSET, 60, scenario.ctx());
        assert!(out.value() == 60, 1);
        assert!(vault::vault_balance(&v, ASSET) == 90, 2);
        transfer::public_transfer(out, PROTO);
        ts::return_shared(any_dao);
        ts::return_shared(v);
    };

    ts::end(scenario);
}

/// An outsider (no principal) cannot deposit.
#[test]
#[expected_failure(abort_code = vault::ENotAuthorized)]
fun deposit_rejected_for_outsider() {
    let mut scenario = ts::begin(AWAR_M1);
    let awar = make_dao(&mut scenario, AWAR_M1, vector[AWAR_M1]);
    let wolf = make_dao(&mut scenario, WOLF_M1, vector[WOLF_M1]);
    let officers = make_dao(&mut scenario, AWAR_OFFICER, vector[AWAR_OFFICER]);
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
    // OUTSIDER tries to deposit, passing AWAR's DAO (they aren't a member).
    ts::next_tx(&mut scenario, OUTSIDER);
    let mut v = ts::take_shared<DaoReceiptVault>(&scenario);
    let awar_dao = ts::take_shared_by_id<DAO>(&scenario, awar);
    vault::deposit_receipt(&mut v, &awar_dao, r, scenario.ctx());

    abort
}

/// AWAR officers (Edit) revoke Protodroid's withdraw perm; he can no longer withdraw.
#[test]
#[expected_failure(abort_code = vault::ENotAuthorized)]
fun officers_revoke_rogue_player() {
    let mut scenario = ts::begin(AWAR_M1);
    let awar = make_dao(&mut scenario, AWAR_M1, vector[AWAR_M1]);
    let wolf = make_dao(&mut scenario, WOLF_M1, vector[WOLF_M1]);
    let officers = make_dao(&mut scenario, AWAR_OFFICER, vector[AWAR_OFFICER]);
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
        let mut v = ts::take_shared<DaoReceiptVault>(&scenario);
        let awar_dao = ts::take_shared_by_id<DAO>(&scenario, awar);
        vault::deposit_receipt(&mut v, &awar_dao, r, scenario.ctx());
        ts::return_shared(awar_dao);
        ts::return_shared(v);
    };

    // Officer revokes Protodroid from both deposit and withdraw (batch).
    ts::next_tx(&mut scenario, AWAR_OFFICER);
    {
        let mut v = ts::take_shared<DaoReceiptVault>(&scenario);
        let officers_dao = ts::take_shared_by_id<DAO>(&scenario, officers);
        vault::revoke(
            &mut v,
            &officers_dao,
            vector[vault::role_deposit(), vault::role_withdraw()],
            vector[vault::player(PROTO), vault::player(PROTO)],
            scenario.ctx(),
        );
        ts::return_shared(officers_dao);
        ts::return_shared(v);
    };

    // Protodroid now tries to withdraw — must abort ENotAuthorized.
    ts::next_tx(&mut scenario, PROTO);
    let mut v = ts::take_shared<DaoReceiptVault>(&scenario);
    let awar_dao = ts::take_shared_by_id<DAO>(&scenario, awar);
    let out = vault::withdraw_receipt(&mut v, &awar_dao, ASSET, 10, scenario.ctx());
    transfer::public_transfer(out, PROTO);

    abort
}

/// A non-editor cannot administer the ACL.
#[test]
#[expected_failure(abort_code = vault::ENotAuthorized)]
fun non_editor_cannot_grant() {
    let mut scenario = ts::begin(AWAR_M1);
    let awar = make_dao(&mut scenario, AWAR_M1, vector[AWAR_M1]);
    let wolf = make_dao(&mut scenario, WOLF_M1, vector[WOLF_M1]);
    let officers = make_dao(&mut scenario, AWAR_OFFICER, vector[AWAR_OFFICER]);
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
    let mut v = ts::take_shared<DaoReceiptVault>(&scenario);
    let awar_dao = ts::take_shared_by_id<DAO>(&scenario, awar);
    vault::grant(
        &mut v,
        &awar_dao,
        vector[vault::role_deposit()],
        vector[vault::player(OUTSIDER)],
        scenario.ctx(),
    );

    abort
}

/// Migration path: a new DAO is granted Edit (coexisting with the old editor),
/// then the old editor is revoked. The new DAO can administer; the property we
/// assert is that the new OU's Edit grant takes effect and the old one is gone.
#[test]
fun migration_grant_new_editor_then_revoke_old() {
    let mut scenario = ts::begin(AWAR_M1);
    let awar = make_dao(&mut scenario, AWAR_M1, vector[AWAR_M1]);
    let wolf = make_dao(&mut scenario, WOLF_M1, vector[WOLF_M1]);
    let officers = make_dao(&mut scenario, AWAR_OFFICER, vector[AWAR_OFFICER]);
    let collection_id = make_collection(&mut scenario, AWAR_M1);

    ts::next_tx(&mut scenario, AWAR_M1);
    let v = vault::new_for_testing(
        object::id_from_address(@0x5501),
        collection_id,
        example_acl(awar, wolf, officers),
        scenario.ctx(),
    );
    vault::share_for_testing(v);

    // The "migrated" officers DAO (new id, same officer on board for the test).
    let new_officers = make_dao(&mut scenario, AWAR_OFFICER, vector[AWAR_OFFICER]);

    // Old officers grant Edit to the new officers OU (both editors coexist).
    ts::next_tx(&mut scenario, AWAR_OFFICER);
    {
        let mut v = ts::take_shared<DaoReceiptVault>(&scenario);
        let officers_dao = ts::take_shared_by_id<DAO>(&scenario, officers);
        vault::grant(
            &mut v,
            &officers_dao,
            vector[vault::role_edit()],
            vector[vault::ou(new_officers)],
            scenario.ctx(),
        );
        assert!(vault::principals(&v, vault::role_edit()).length() == 2, 0);
        ts::return_shared(officers_dao);
        ts::return_shared(v);
    };

    // New officers DAO now revokes the old Edit principal (valid editor itself).
    ts::next_tx(&mut scenario, AWAR_OFFICER);
    {
        let mut v = ts::take_shared<DaoReceiptVault>(&scenario);
        let new_officers_dao = ts::take_shared_by_id<DAO>(&scenario, new_officers);
        vault::revoke(
            &mut v,
            &new_officers_dao,
            vector[vault::role_edit()],
            vector[vault::ou(officers)],
            scenario.ctx(),
        );
        assert!(vault::principals(&v, vault::role_edit()).length() == 1, 1);
        ts::return_shared(new_officers_dao);
        ts::return_shared(v);
    };

    ts::end(scenario);
}

/// The last Edit principal cannot be revoked (brick guard).
#[test]
#[expected_failure(abort_code = vault::ELastEditor)]
fun cannot_revoke_last_editor() {
    let mut scenario = ts::begin(AWAR_M1);
    let awar = make_dao(&mut scenario, AWAR_M1, vector[AWAR_M1]);
    let wolf = make_dao(&mut scenario, WOLF_M1, vector[WOLF_M1]);
    let officers = make_dao(&mut scenario, AWAR_OFFICER, vector[AWAR_OFFICER]);
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
    let mut v = ts::take_shared<DaoReceiptVault>(&scenario);
    let officers_dao = ts::take_shared_by_id<DAO>(&scenario, officers);
    vault::revoke(
        &mut v,
        &officers_dao,
        vector[vault::role_edit()],
        vector[vault::ou(officers)],
        scenario.ctx(),
    );

    abort
}
