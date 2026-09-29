/// Tests for `ou_receipt_vault::initialize_ou_vault` against a real world
/// `StorageUnit` and warehouse_receipts `VaultConfig`.
///
/// The rest of the suite builds vaults with `new_for_testing`; this module pays
/// for the world bootstrap (character → network node → storage unit → vault
/// config) so the init path, its registry entry and the SSU binding check run
/// on real objects.
#[test_only]
module armature_vault::ou_receipt_vault_init_tests {
    use armature::{governance, ou::{Self, OU}};
    use armature_vault::{
        acl,
        ou_receipt_vault::{Self as vault, OuReceiptVault, OuReceiptVaultRegistry}
    };
    use std::string::utf8;
    use sui::test_scenario as ts;
    use warehouse_receipts::{receipt, vault::VaultConfig};
    use world::{
        access::{Self, AdminACL, OwnerCap},
        character::{Self, Character},
        network_node::{Self, NetworkNode},
        object_registry::{Self, ObjectRegistry},
        storage_unit::{Self, StorageUnit},
        world::{Self, GovernorCap}
    };

    const GOVERNOR: address = @0xA;
    // Sponsor for world objects.
    const ADMIN: address = @0xB;
    // Owns the character that owns the storage unit.
    const SSU_OWNER: address = @0xC;
    // Board member of the members OU (the registrant).
    const MEMBER: address = @0xD1;
    // Board member of the officers OU (holds Edit).
    const OFFICER: address = @0xE1;
    const OUTSIDER: address = @0xF1;

    const CHARACTER_ITEM_ID: u32 = 1000;
    const NWN_ITEM_ID: u64 = 5000;
    const NWN_TYPE_ID: u64 = 111000;
    const SSU_ITEM_ID: u64 = 90002;
    const SSU2_ITEM_ID: u64 = 90003;
    const SSU_TYPE_ID: u64 = 5555;
    const LOCATION_HASH: vector<u8> =
        x"7a8f3b2e9c4d1a6f5e8b2d9c3f7a1e5b7a8f3b2e9c4d1a6f5e8b2d9c3f7a1e5b";

    // === World bootstrap ===

    /// Objects shared by the bootstrap, by ID.
    public struct World has drop {
        character: ID,
        network_node: ID,
        storage_unit: ID,
        vault_config: ID,
    }

    fun setup_world(sc: &mut ts::Scenario): World {
        ts::next_tx(sc, GOVERNOR);
        world::init_for_testing(sc.ctx());
        access::init_for_testing(sc.ctx());
        object_registry::init_for_testing(sc.ctx());
        vault::init_for_testing(sc.ctx());

        ts::next_tx(sc, GOVERNOR);
        {
            let gov_cap = ts::take_from_sender<GovernorCap>(sc);
            let mut admin_acl = ts::take_shared<AdminACL>(sc);
            access::add_sponsor_to_acl(&mut admin_acl, &gov_cap, ADMIN);
            ts::return_to_sender(sc, gov_cap);
            ts::return_shared(admin_acl);
        };

        ts::next_tx(sc, ADMIN);
        let character_id = {
            let admin_acl = ts::take_shared<AdminACL>(sc);
            let mut registry = ts::take_shared<ObjectRegistry>(sc);
            let character = character::create_character(
                &mut registry,
                &admin_acl,
                CHARACTER_ITEM_ID,
                utf8(b"tenant"),
                100,
                SSU_OWNER,
                utf8(b"owner"),
                sc.ctx(),
            );
            let id = object::id(&character);
            character.share_character(&admin_acl, sc.ctx());
            ts::return_shared(registry);
            ts::return_shared(admin_acl);
            id
        };

        ts::next_tx(sc, ADMIN);
        let nwn_id = {
            let admin_acl = ts::take_shared<AdminACL>(sc);
            let mut registry = ts::take_shared<ObjectRegistry>(sc);
            let character = ts::take_shared_by_id<Character>(sc, character_id);
            let nwn = network_node::anchor(
                &mut registry,
                &character,
                &admin_acl,
                NWN_ITEM_ID,
                NWN_TYPE_ID,
                LOCATION_HASH,
                1000,
                3_600_000,
                100,
                sc.ctx(),
            );
            let id = object::id(&nwn);
            nwn.share_network_node(&admin_acl, sc.ctx());
            ts::return_shared(character);
            ts::return_shared(registry);
            ts::return_shared(admin_acl);
            id
        };

        let storage_unit_id = anchor_storage_unit(sc, character_id, nwn_id, SSU_ITEM_ID);

        // The SSU owner creates the warehouse_receipts VaultConfig for it.
        ts::next_tx(sc, SSU_OWNER);
        {
            let mut character = ts::take_shared_by_id<Character>(sc, character_id);
            let (owner_cap, receipt) = character.borrow_owner_cap<StorageUnit>(
                ts::most_recent_receiving_ticket<OwnerCap<StorageUnit>>(&character_id),
                sc.ctx(),
            );
            let storage_unit = ts::take_shared_by_id<StorageUnit>(sc, storage_unit_id);
            receipt::initialize_vault(&storage_unit, &owner_cap, sc.ctx());
            character.return_owner_cap(owner_cap, receipt);
            ts::return_shared(storage_unit);
            ts::return_shared(character);
        };

        ts::next_tx(sc, SSU_OWNER);
        let config = ts::take_shared<VaultConfig>(sc);
        let vault_config_id = object::id(&config);
        ts::return_shared(config);

        World {
            character: character_id,
            network_node: nwn_id,
            storage_unit: storage_unit_id,
            vault_config: vault_config_id,
        }
    }

    fun anchor_storage_unit(sc: &mut ts::Scenario, character_id: ID, nwn_id: ID, item_id: u64): ID {
        ts::next_tx(sc, ADMIN);
        let admin_acl = ts::take_shared<AdminACL>(sc);
        let mut registry = ts::take_shared<ObjectRegistry>(sc);
        let mut nwn = ts::take_shared_by_id<NetworkNode>(sc, nwn_id);
        let character = ts::take_shared_by_id<Character>(sc, character_id);
        let storage_unit = storage_unit::anchor(
            &mut registry,
            &mut nwn,
            &character,
            &admin_acl,
            item_id,
            SSU_TYPE_ID,
            100_000,
            LOCATION_HASH,
            sc.ctx(),
        );
        let id = object::id(&storage_unit);
        storage_unit.share_storage_unit(&admin_acl, sc.ctx());
        ts::return_shared(character);
        ts::return_shared(nwn);
        ts::return_shared(registry);
        ts::return_shared(admin_acl);
        id
    }

    fun make_ou(sc: &mut ts::Scenario, creator: address): ID {
        ts::next_tx(sc, creator);
        let init = governance::init_board(vector[creator]);
        ou::create(&init, utf8(b"OU"), utf8(b"https://example.com/i.png"), sc.ctx())
    }

    /// Call `initialize_ou_vault` as `caller` on `storage_unit_id` with the
    /// world's VaultConfig.
    fun initialize(
        sc: &mut ts::Scenario,
        w: &World,
        storage_unit_id: ID,
        caller: address,
        registrant: ID,
        deposit: vector<acl::Principal>,
        withdraw: vector<acl::Principal>,
        edit: vector<acl::Principal>,
    ) {
        ts::next_tx(sc, caller);
        let mut registry = ts::take_shared<OuReceiptVaultRegistry>(sc);
        let storage_unit = ts::take_shared_by_id<StorageUnit>(sc, storage_unit_id);
        let org = ts::take_shared_by_id<OU>(sc, registrant);
        let config = ts::take_shared_by_id<VaultConfig>(sc, w.vault_config);
        vault::initialize_ou_vault(
            &mut registry,
            &storage_unit,
            &org,
            &config,
            deposit,
            withdraw,
            edit,
            sc.ctx(),
        );
        ts::return_shared(config);
        ts::return_shared(org);
        ts::return_shared(storage_unit);
        ts::return_shared(registry);
    }

    // === Tests ===

    /// Init binds the vault to the SSU and its receipt collection, seeds the ACL
    /// from the caller's lists (leaving empty roles unset) and registers the
    /// vault under (SSU, registrant OU). Officers can then administer it and
    /// deinitialize it, which frees the registry slot.
    #[test]
    fun initialize_registers_and_seeds_acl() {
        let mut sc = ts::begin(GOVERNOR);
        let w = setup_world(&mut sc);
        let members = make_ou(&mut sc, MEMBER);
        let officers = make_ou(&mut sc, OFFICER);

        initialize(
            &mut sc,
            &w,
            w.storage_unit,
            MEMBER,
            members,
            vector[acl::ou(members)],
            vector[],
            vector[acl::ou(officers)],
        );

        ts::next_tx(&mut sc, OFFICER);
        let mut registry = ts::take_shared<OuReceiptVaultRegistry>(&sc);
        let mut v = ts::take_shared<OuReceiptVault>(&sc);
        let config = ts::take_shared_by_id<VaultConfig>(&sc, w.vault_config);
        let officers_ou = ts::take_shared_by_id<OU>(&sc, officers);

        assert!(vault::lookup(&registry, w.storage_unit, members) == option::some(object::id(&v)));
        assert!(vault::lookup(&registry, w.storage_unit, officers).is_none());
        assert!(vault::storage_unit_id(&v) == w.storage_unit);
        assert!(vault::collection_id(&v) == config.collection_id());
        assert!(vault::principals(&v, vault::role_deposit()) == vector[acl::ou(members)]);
        assert!(vault::principals(&v, vault::role_withdraw()) == vector[]);
        assert!(vault::principals(&v, vault::role_edit()) == vector[acl::ou(officers)]);

        // Revoking from the unset Withdraw role is a no-op.
        vault::revoke(
            &mut v,
            &officers_ou,
            vector[vault::role_withdraw()],
            vector[acl::player(OUTSIDER)],
            sc.ctx(),
        );
        assert!(vault::principals(&v, vault::role_withdraw()) == vector[]);

        // Granting into the unset Withdraw role creates it.
        vault::grant(
            &mut v,
            &officers_ou,
            vector[vault::role_withdraw()],
            vector[acl::ou(members)],
            sc.ctx(),
        );
        assert!(vault::principals(&v, vault::role_withdraw()) == vector[acl::ou(members)]);

        vault::deinitialize_ou_vault(&mut registry, &mut v, &officers_ou, sc.ctx());
        assert!(vault::lookup(&registry, w.storage_unit, members).is_none());
        assert!(vault::principals(&v, vault::role_edit()) == vector[]);

        ts::return_shared(officers_ou);
        ts::return_shared(config);
        ts::return_shared(v);
        ts::return_shared(registry);
        sc.end();
    }

    /// Every role list may be populated at init.
    #[test]
    fun initialize_seeds_every_role() {
        let mut sc = ts::begin(GOVERNOR);
        let w = setup_world(&mut sc);
        let members = make_ou(&mut sc, MEMBER);

        initialize(
            &mut sc,
            &w,
            w.storage_unit,
            MEMBER,
            members,
            vector[acl::ou(members)],
            vector[acl::player(SSU_OWNER)],
            vector[acl::ou(members)],
        );

        ts::next_tx(&mut sc, MEMBER);
        let v = ts::take_shared<OuReceiptVault>(&sc);
        assert!(vault::principals(&v, vault::role_deposit()) == vector[acl::ou(members)]);
        assert!(vault::principals(&v, vault::role_withdraw()) == vector[acl::player(SSU_OWNER)]);
        assert!(vault::principals(&v, vault::role_edit()) == vector[acl::ou(members)]);
        ts::return_shared(v);
        sc.end();
    }

    /// Only a board member of the registrant OU may initialize.
    #[test]
    #[expected_failure(abort_code = vault::ENotAuthorized)]
    fun initialize_by_non_member_aborts() {
        let mut sc = ts::begin(GOVERNOR);
        let w = setup_world(&mut sc);
        let members = make_ou(&mut sc, MEMBER);

        initialize(
            &mut sc,
            &w,
            w.storage_unit,
            OUTSIDER,
            members,
            vector[],
            vector[],
            vector[acl::ou(members)],
        );
        sc.end();
    }

    /// A vault with no Edit principal could never be administered.
    #[test]
    #[expected_failure(abort_code = vault::EEmptyEditPrincipals)]
    fun initialize_without_editors_aborts() {
        let mut sc = ts::begin(GOVERNOR);
        let w = setup_world(&mut sc);
        let members = make_ou(&mut sc, MEMBER);

        initialize(
            &mut sc,
            &w,
            w.storage_unit,
            MEMBER,
            members,
            vector[acl::ou(members)],
            vector[acl::ou(members)],
            vector[],
        );
        sc.end();
    }

    /// The VaultConfig must be the one bound to the passed StorageUnit.
    #[test]
    #[expected_failure(abort_code = vault::EStorageUnitMismatch)]
    fun initialize_with_other_ssu_config_aborts() {
        let mut sc = ts::begin(GOVERNOR);
        let w = setup_world(&mut sc);
        let members = make_ou(&mut sc, MEMBER);
        let other_ssu = anchor_storage_unit(&mut sc, w.character, w.network_node, SSU2_ITEM_ID);

        initialize(
            &mut sc,
            &w,
            other_ssu,
            MEMBER,
            members,
            vector[],
            vector[],
            vector[acl::ou(members)],
        );
        sc.end();
    }

    /// One vault per (SSU, registrant OU).
    #[test]
    #[expected_failure(abort_code = vault::EVaultAlreadyExists)]
    fun initialize_twice_aborts() {
        let mut sc = ts::begin(GOVERNOR);
        let w = setup_world(&mut sc);
        let members = make_ou(&mut sc, MEMBER);

        initialize(
            &mut sc,
            &w,
            w.storage_unit,
            MEMBER,
            members,
            vector[],
            vector[],
            vector[acl::ou(members)],
        );
        initialize(
            &mut sc,
            &w,
            w.storage_unit,
            MEMBER,
            members,
            vector[],
            vector[],
            vector[acl::ou(members)],
        );
        sc.end();
    }
}
