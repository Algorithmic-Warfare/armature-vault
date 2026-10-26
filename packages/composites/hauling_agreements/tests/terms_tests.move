/// `Terms`: what the constructors keep and check, and posting an agreement's
/// terms again. The check `hauling::draft` makes (want versus cargo) and the
/// constructor checks for `new` are in `hauling_tests`.
#[test_only]
module hauling_agreements::terms_tests {
    use agreements::spec::{Self, Spec};
    use hauling_agreements::{
        hauling::{HaulingAgreement, ListerCap},
        terms,
        test_config::{Self, TOKEN}
    };
    use multicoin::multicoin;
    use std::unit_test::assert_eq;
    use sui::{clock, test_scenario as ts};

    const LISTER: address = @0xA;
    const BENEFICIARY: address = @0xC;
    const OTHER: address = @0xD;

    const ITEM: u64 = 7;
    const CARGO_QTY: u64 = 10;
    const REWARD_QTY: u64 = 100;
    const COLLATERAL_QTY: u64 = 500;

    const START_MS: u64 = 1_000;
    const ACCEPT_MS: u64 = 4_000;
    // After the accept window of a listing posted at START_MS.
    const LAPSED_MS: u64 = 9_000;
    const HAUL_MS: u64 = 10_000;

    fun dst(): ID { object::id_from_address(@0xD5) }

    fun want(): vector<Spec> { vector[spec::new(dst(), ITEM, CARGO_QTY)] }

    /// `n` distinct items at the destination.
    fun items(n: u64): vector<Spec> { vector::tabulate!(n, |i| spec::new(dst(), ITEM + i, 1)) }

    #[test]
    fun new_keeps_every_field() {
        let t = terms::new(want(), COLLATERAL_QTY, ACCEPT_MS, HAUL_MS, BENEFICIARY);
        assert_eq!(t.want(), want());
        assert_eq!(t.collateral(), COLLATERAL_QTY);
        assert_eq!(t.accept_ms(), ACCEPT_MS);
        assert_eq!(t.haul_ms(), HAUL_MS);
        assert_eq!(t.beneficiary(), option::some(BENEFICIARY));
        assert!(!t.pays_cap_holder());
    }

    #[test]
    fun new_for_cap_holder_names_no_beneficiary() {
        let t = terms::new_for_cap_holder(want(), COLLATERAL_QTY, ACCEPT_MS, HAUL_MS);
        assert_eq!(t.want(), want());
        assert_eq!(t.collateral(), COLLATERAL_QTY);
        assert_eq!(t.accept_ms(), ACCEPT_MS);
        assert_eq!(t.haul_ms(), HAUL_MS);
        assert_eq!(t.beneficiary(), option::none());
        assert!(t.pays_cap_holder());
    }

    #[test]
    fun new_for_cap_holder_allows_windows_of_max_duration() {
        let max = terms::max_duration_ms();
        assert_eq!(max, 30 * 24 * 60 * 60 * 1000);
        terms::new_for_cap_holder(want(), COLLATERAL_QTY, max, max);
    }

    #[test, expected_failure(abort_code = terms::EInvalidTerms)]
    fun new_for_cap_holder_rejects_zero_accept_window() {
        terms::new_for_cap_holder(want(), COLLATERAL_QTY, 0, HAUL_MS);
    }

    #[test, expected_failure(abort_code = terms::EInvalidTerms)]
    fun new_for_cap_holder_rejects_accept_window_over_max() {
        terms::new_for_cap_holder(want(), COLLATERAL_QTY, terms::max_duration_ms() + 1, HAUL_MS);
    }

    #[test, expected_failure(abort_code = terms::EInvalidTerms)]
    fun new_for_cap_holder_rejects_zero_collateral() {
        terms::new_for_cap_holder(want(), 0, ACCEPT_MS, HAUL_MS);
    }

    #[test]
    fun want_keeps_several_items_in_order() {
        let mixed = vector[spec::new(dst(), ITEM + 1, 3), spec::new(dst(), ITEM, CARGO_QTY)];
        let t = terms::new(mixed, COLLATERAL_QTY, ACCEPT_MS, HAUL_MS, BENEFICIARY);
        assert_eq!(t.want(), mixed);
    }

    #[test]
    fun want_allows_max_items() {
        assert_eq!(terms::max_items(), 32);
        terms::new_for_cap_holder(items(terms::max_items()), COLLATERAL_QTY, ACCEPT_MS, HAUL_MS);
    }

    #[test, expected_failure(abort_code = terms::EInvalidTerms)]
    fun want_rejects_more_than_max_items() {
        terms::new_for_cap_holder(
            items(terms::max_items() + 1),
            COLLATERAL_QTY,
            ACCEPT_MS,
            HAUL_MS,
        );
    }

    #[test, expected_failure(abort_code = terms::EInvalidTerms)]
    fun want_rejects_no_items() {
        terms::new(vector[], COLLATERAL_QTY, ACCEPT_MS, HAUL_MS, BENEFICIARY);
    }

    #[test, expected_failure(abort_code = terms::EInvalidTerms)]
    fun want_rejects_a_zero_item_among_others() {
        terms::new(
            vector[spec::new(dst(), ITEM, CARGO_QTY), spec::new(dst(), ITEM + 1, 0)],
            COLLATERAL_QTY,
            ACCEPT_MS,
            HAUL_MS,
            BENEFICIARY,
        );
    }

    /// Each entry is a different item; the same item twice would be one entry.
    #[test, expected_failure(abort_code = terms::EInvalidTerms)]
    fun want_rejects_a_repeated_item() {
        terms::new(
            vector[spec::new(dst(), ITEM, CARGO_QTY), spec::new(dst(), ITEM, 1)],
            COLLATERAL_QTY,
            ACCEPT_MS,
            HAUL_MS,
            BENEFICIARY,
        );
    }

    #[test, expected_failure(abort_code = terms::EInvalidTerms)]
    fun new_for_cap_holder_rejects_haul_window_over_max() {
        terms::new_for_cap_holder(want(), COLLATERAL_QTY, ACCEPT_MS, terms::max_duration_ms() + 1);
    }

    /// An agreement returns the terms it was drafted on, and their windows are
    /// relative, so a listing nobody took can be cancelled after it lapses and
    /// posted again on the same terms, with a fresh accept window.
    #[test]
    fun lapsed_terms_post_again_with_a_fresh_window() {
        let mut scenario = ts::begin(LISTER);
        let mut clock = clock::create_for_testing(scenario.ctx());
        clock.set_for_testing(START_MS);
        let cargo = vector[
            multicoin::create_balance_for_testing(
                object::id_from_address(@0x51),
                ITEM,
                CARGO_QTY,
                scenario.ctx(),
            ),
        ];
        let reward = test_config::mint(REWARD_QTY, scenario.ctx());
        let posted = terms::new(want(), COLLATERAL_QTY, ACCEPT_MS, HAUL_MS, BENEFICIARY);
        let cap = test_config::post_with_terms(cargo, reward, posted, &clock, scenario.ctx());
        transfer::public_transfer(cap, LISTER);

        clock.set_for_testing(LAPSED_MS);
        scenario.next_tx(LISTER);
        let cap = scenario.take_from_sender<ListerCap>();
        let agreement = scenario.take_shared<HaulingAgreement<TOKEN>>();
        assert_eq!(agreement.accept_by_ms(), START_MS + ACCEPT_MS);
        let terms = agreement.terms();
        assert_eq!(terms, posted);
        let (cargo, reward) = agreement.cancel(cap, &clock, scenario.ctx());
        let cap = test_config::post_with_terms(cargo, reward, terms, &clock, scenario.ctx());
        let reposted_id = cap.cap_agreement_id();
        transfer::public_transfer(cap, LISTER);

        scenario.next_tx(OTHER);
        let reposted = scenario.take_shared_by_id<HaulingAgreement<TOKEN>>(reposted_id);
        assert_eq!(reposted.terms(), posted);
        assert_eq!(reposted.accept_by_ms(), LAPSED_MS + ACCEPT_MS);
        assert_eq!(reposted.reward(), REWARD_QTY);
        ts::return_shared(reposted);
        clock.destroy_for_testing();
        scenario.end();
    }
}
