#[test_only]
module agreements::payout_tests;

use agreements::payout;
use multicoin::multicoin::{Self, Balance};
use std::unit_test::assert_eq;
use sui::test_scenario::{Self as ts, Scenario};

const PAYER: address = @0xF;
const A: address = @0xA;
const B: address = @0xB;
const C: address = @0xC;
const D: address = @0xD;
const E: address = @0xE;

const ASSET: u64 = 0;

fun coll(): ID { object::id_from_address(@0x70) }

/// Pay `total` by `shares` to `recipients` in one transaction, then return
/// what each recipient received.
fun pay(total: u64, shares: vector<u16>, recipients: vector<address>): vector<u64> {
    let mut sc = ts::begin(PAYER);
    let balance = multicoin::create_balance_for_testing(coll(), ASSET, total, sc.ctx());
    payout::pay_by_bps(balance, shares, recipients, sc.ctx());
    sc.next_tx(PAYER);
    let received = recipients.map_ref!(|r| received(&sc, *r));
    sc.end();
    received
}

/// Total received by `owner`. Every balance it holds must be nonzero.
fun received(sc: &Scenario, owner: address): u64 {
    let mut total = 0;
    ts::ids_for_address<Balance>(owner).do!(|id| {
        let b = sc.take_from_address_by_id<Balance>(owner, id);
        assert!(multicoin::value(&b) > 0);
        total = total + multicoin::value(&b);
        ts::return_to_address(owner, b);
    });
    total
}

fun pieces(owner: address): u64 { ts::ids_for_address<Balance>(owner).length() }

// === Exact and rounded splits ===

#[test]
fun even_split_is_exact() {
    assert_eq!(pay(1_000, vector[5_000, 3_000, 2_000], vector[A, B, C]), vector[500, 300, 200]);
}

#[test]
fun one_recipient_gets_everything() {
    assert_eq!(pay(77, vector[10_000], vector[A]), vector[77]);
}

/// One unit split 99.99% / 0.01% goes to the 99.99% share, not the last one.
#[test]
fun single_unit_goes_to_the_largest_share() {
    assert_eq!(pay(1, vector[9_999, 0, 1], vector[A, B, C]), vector[1, 0, 0]);
}

/// Three units split in thirds: one each.
#[test]
fun thirds_of_three_are_one_each() {
    assert_eq!(pay(3, vector[3_333, 3_333, 3_334], vector[A, B, C]), vector[1, 1, 1]);
}

/// Equal remainders go to the earlier recipient.
#[test]
fun ties_go_to_the_earlier_recipient() {
    assert_eq!(pay(1, vector[0, 5_000, 5_000], vector[A, B, C]), vector[0, 1, 0]);
    assert_eq!(pay(2, vector[3_334, 3_333, 3_333], vector[A, B, C]), vector[1, 1, 0]);
}

/// A zero share is never paid, even when it is the last recipient.
#[test]
fun zero_shares_are_not_paid() {
    let mut sc = ts::begin(PAYER);
    let balance = multicoin::create_balance_for_testing(coll(), ASSET, 5, sc.ctx());
    payout::pay_by_bps(balance, vector[5_000, 5_000, 0], vector[A, B, C], sc.ctx());
    sc.next_tx(PAYER);
    assert_eq!(received(&sc, A), 3);
    assert_eq!(received(&sc, B), 2);
    assert_eq!(pieces(C), 0);
    sc.end();
}

/// An empty balance pays nobody.
#[test]
fun empty_balance_pays_nobody() {
    let mut sc = ts::begin(PAYER);
    let balance = multicoin::create_balance_for_testing(coll(), ASSET, 0, sc.ctx());
    payout::pay_by_bps(balance, vector[5_000, 5_000], vector[A, B], sc.ctx());
    sc.next_tx(PAYER);
    assert_eq!(pieces(A), 0);
    assert_eq!(pieces(B), 0);
    sc.end();
}

/// The same address listed twice receives both shares.
#[test]
fun repeated_recipient_receives_both_shares() {
    let mut sc = ts::begin(PAYER);
    let balance = multicoin::create_balance_for_testing(coll(), ASSET, 10, sc.ctx());
    payout::pay_by_bps(balance, vector[3_000, 7_000], vector[A, A], sc.ctx());
    sc.next_tx(PAYER);
    assert_eq!(received(&sc, A), 10);
    assert_eq!(pieces(A), 2);
    sc.end();
}

#[test]
fun five_recipients() {
    assert_eq!(
        pay(7, vector[2_000, 2_000, 2_000, 2_000, 2_000], vector[A, B, C, D, E]),
        vector[2, 2, 1, 1, 1],
    );
}

/// The largest possible balance does not overflow.
#[test]
fun max_balance_does_not_overflow() {
    let max = 18_446_744_073_709_551_615;
    let paid = pay(max, vector[3_333, 3_333, 3_334], vector[A, B, C]);
    assert_eq!(paid[0] + paid[1] + paid[2], max);
}

/// For every total up to 200, the payout adds up and nobody is more than one
/// unit away from their exact share.
#[test]
fun payouts_add_up_and_stay_within_one_unit() {
    let shares = vector[1, 3_333, 6_666];
    let mut total = 0;
    while (total <= 200) {
        let paid = pay(total, shares, vector[A, B, C]);
        assert_eq!(paid[0] + paid[1] + paid[2], total);
        let mut i = 0;
        while (i < 3) {
            let exact_floor = total * (shares[i] as u64) / 10_000;
            assert!(paid[i] == exact_floor || paid[i] == exact_floor + 1);
            i = i + 1;
        };
        total = total + 1;
    };
}

// === Invalid shares ===

#[test, expected_failure(abort_code = payout::EInvalidShares)]
fun shares_must_sum_to_10_000() {
    pay(10, vector[5_000, 4_999], vector[A, B]);
}

#[test, expected_failure(abort_code = payout::EInvalidShares)]
fun shares_cannot_exceed_10_000() {
    pay(10, vector[5_000, 5_001], vector[A, B]);
}

#[test, expected_failure(abort_code = payout::EInvalidShares)]
fun one_share_per_recipient() {
    pay(10, vector[10_000], vector[A, B]);
}

#[test, expected_failure(abort_code = payout::EInvalidShares)]
fun at_least_one_recipient() {
    pay(10, vector[], vector[]);
}

#[test]
fun bps_is_10_000() {
    assert_eq!(payout::bps(), 10_000);
}
