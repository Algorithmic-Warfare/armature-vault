#[test_only]
module agreements::spec_tests;

use agreements::requirement;
use agreements::spec;
use multicoin::multicoin::{Self, Balance};
use std::type_name;
use std::unit_test::assert_eq;
use sui::bcs;
use sui::test_scenario::{Self as ts, Scenario};

const ALICE: address = @0xA;

fun coll(): ID { object::id_from_address(@0xC0) }

fun other_coll(): ID { object::id_from_address(@0xC1) }

fun mint(collection: ID, asset_id: u64, qty: u64, sc: &mut Scenario): Balance {
    multicoin::create_balance_for_testing(collection, asset_id, qty, sc.ctx())
}

// === Spec ===

#[test]
fun spec_reads_back_its_fields() {
    let s = spec::new(coll(), 7, 10);
    assert_eq!(s.collection(), coll());
    assert_eq!(s.asset_id(), 7);
    assert_eq!(s.qty(), 10);
}

#[test]
fun spec_of_describes_a_balance() {
    let mut sc = ts::begin(ALICE);
    let b = mint(coll(), 7, 10, &mut sc);
    assert_eq!(spec::of(&b), spec::new(coll(), 7, 10));
    spec::new(coll(), 7, 10).assert_matches(&b);
    transfer::public_transfer(b, ALICE);
    sc.end();
}

#[test, expected_failure(abort_code = spec::EWrongAsset)]
fun assert_matches_rejects_another_collection() {
    let mut sc = ts::begin(ALICE);
    let b = mint(other_coll(), 7, 10, &mut sc);
    spec::new(coll(), 7, 10).assert_matches(&b);
    abort
}

#[test, expected_failure(abort_code = spec::EWrongAsset)]
fun assert_matches_rejects_another_asset() {
    let mut sc = ts::begin(ALICE);
    let b = mint(coll(), 8, 10, &mut sc);
    spec::new(coll(), 7, 10).assert_matches(&b);
    abort
}

#[test, expected_failure(abort_code = spec::EWrongAmount)]
fun assert_matches_rejects_less() {
    let mut sc = ts::begin(ALICE);
    let b = mint(coll(), 7, 9, &mut sc);
    spec::new(coll(), 7, 10).assert_matches(&b);
    abort
}

#[test, expected_failure(abort_code = spec::EWrongAmount)]
fun assert_matches_rejects_more() {
    let mut sc = ts::begin(ALICE);
    let b = mint(coll(), 7, 11, &mut sc);
    spec::new(coll(), 7, 10).assert_matches(&b);
    abort
}

// === Requirement ===

public struct Config has drop {
    limit: u64,
    who: address,
}

public struct Other has drop {}

#[test]
fun requirement_records_its_type_and_config() {
    let r = requirement::from_config(Config { limit: 5, who: ALICE });
    assert!(r.is<Config>());
    assert!(!r.is<Other>());
    assert_eq!(r.type_name(), type_name::with_original_ids<Config>());
    let mut data = bcs::new(r.data());
    assert_eq!(data.peel_u64(), 5);
    assert_eq!(data.peel_address(), ALICE);
}

#[test]
fun requirements_with_equal_configs_are_equal() {
    assert_eq!(
        requirement::from_config(Config { limit: 5, who: ALICE }),
        requirement::from_config(Config { limit: 5, who: ALICE }),
    );
    assert!(
        requirement::from_config(Config { limit: 5, who: ALICE })
            != requirement::from_config(Config { limit: 6, who: ALICE }),
    );
}
