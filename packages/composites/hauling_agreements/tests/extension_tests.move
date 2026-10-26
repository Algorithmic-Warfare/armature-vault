#[test_only]
module hauling_agreements::extension_tests {
    use agreements::payout;
    use agreements::{request, spec::{Self, Spec}};
    use hauling_agreements::{
        config,
        hauling::{
            Self,
            AcceptAction,
            HaulingAgreement,
            Draft,
            ListerCap,
            OutcomeRecord,
            AgreementPosted,
            AgreementAccepted
        },
        test_config::{Self, TOKEN},
        test_extensions::{Self as ext, Ledger, Character, Desk}
    };
    use multicoin::multicoin::{Self, Balance};
    use std::{type_name, unit_test::assert_eq};
    use sui::{clock::{Self, Clock}, event, test_scenario::{Self as ts, Scenario}};

    const LISTER: address = @0xA;
    const HAULER: address = @0xB;
    const BENEFICIARY: address = @0xC;
    const OTHER: address = @0xD;
    const TREASURY: address = @0xF;

    const ITEM: u64 = 7;
    const CARGO_QTY: u64 = 10;
    // Reward and collateral, in TOKEN.
    const REWARD_QTY: u64 = 100;
    const COLLATERAL_QTY: u64 = 500;
    // The observer's fee, a multicoin balance.
    const FEE_ASSET: u64 = 0;
    const FEE_QTY: u64 = 3;

    const START_MS: u64 = 1_000;
    const ACCEPT_BY_MS: u64 = 5_000;
    const ACCEPT_MS: u64 = 4_000; // ACCEPT_BY_MS - START_MS, posting at START_MS
    const HAUL_MS: u64 = 10_000;
    const ACCEPT_AT_MS: u64 = 2_000;
    const DEADLINE_MS: u64 = 12_000; // ACCEPT_AT_MS + HAUL_MS

    // === Fixtures ===

    fun src(): ID { object::id_from_address(@0x51) }

    fun dst(): ID { object::id_from_address(@0xD5) }

    fun fee_collection(): ID { object::id_from_address(@0x70) }

    fun character_id(): ID { object::id_from_address(@0xC4A) }

    /// The entity the `Desk` wrapper drafts for, such as a DAO.
    fun entity_id(): ID { object::id_from_address(@0xDA0) }

    fun mint(collection: ID, asset_id: u64, qty: u64, scenario: &mut Scenario): Balance {
        multicoin::create_balance_for_testing(collection, asset_id, qty, scenario.ctx())
    }

    fun want(): vector<Spec> { vector[spec::new(dst(), ITEM, CARGO_QTY)] }

    fun cargo_spec(): vector<Spec> { vector[spec::new(src(), ITEM, CARGO_QTY)] }

    fun fee_spec(): Spec { spec::new(fee_collection(), FEE_ASSET, FEE_QTY) }

    fun setup(): (Scenario, Clock) {
        let mut scenario = ts::begin(LISTER);
        let mut clock = clock::create_for_testing(scenario.ctx());
        clock.set_for_testing(START_MS);
        (scenario, clock)
    }

    fun finish(scenario: Scenario, clock: Clock) {
        clock.destroy_for_testing();
        scenario.end();
    }

    fun create_ledger(scenario: &mut Scenario): ID {
        scenario.next_tx(OTHER);
        ext::new_ledger(TREASURY, scenario.ctx())
    }

    /// Start a new LISTER transaction drafting the standard agreement.
    fun new_draft(scenario: &mut Scenario, clock: &Clock): Draft<TOKEN> {
        scenario.next_tx(LISTER);
        let cargo = vector[mint(src(), ITEM, CARGO_QTY, scenario)];
        let reward = test_config::mint(REWARD_QTY, scenario.ctx());
        test_config::draft(
            cargo,
            reward,
            want(),
            COLLATERAL_QTY,
            ACCEPT_MS,
            HAUL_MS,
            BENEFICIARY,
            clock,
            scenario.ctx(),
        )
    }

    /// Publish in the current transaction; LISTER keeps the cap.
    fun publish(draft: Draft<TOKEN>): (ID, ID) {
        let cap = draft.publish();
        let (agreement_id, cap_id) = (cap.cap_agreement_id(), object::id(&cap));
        transfer::public_transfer(cap, LISTER);
        (agreement_id, cap_id)
    }

    fun bind_ledger(draft: &mut Draft<TOKEN>, ledger_id: ID, scenario: &mut Scenario) {
        let ledger = scenario.take_shared_by_id<Ledger>(ledger_id);
        let fee = mint(fee_collection(), FEE_ASSET, FEE_QTY, scenario);
        ext::bind_ledger(&ledger, draft, fee);
        ts::return_shared(ledger);
    }

    /// HAULER accepts an agreement with no accept requirements at ACCEPT_AT_MS.
    fun accept_plain(scenario: &mut Scenario, clock: &mut Clock) {
        clock.set_for_testing(ACCEPT_AT_MS);
        scenario.next_tx(HAULER);
        let collateral = test_config::mint(COLLATERAL_QTY, scenario.ctx());
        let mut agreement = scenario.take_shared<HaulingAgreement<TOKEN>>();
        let cargo = agreement.accept(collateral, clock, scenario.ctx());
        payout::pay_all(cargo, HAULER);
        ts::return_shared(agreement);
    }

    /// HAULER accepts an agreement whose only requirement is the character rule.
    fun accept_as_character(scenario: &mut Scenario, clock: &mut Clock) {
        clock.set_for_testing(ACCEPT_AT_MS);
        scenario.next_tx(HAULER);
        let mut agreement = scenario.take_shared<HaulingAgreement<TOKEN>>();
        let mut req = agreement.begin_accept(clock, scenario.ctx());
        ext::satisfy_character(&mut req, character_id());
        let collateral = test_config::mint(COLLATERAL_QTY, scenario.ctx());
        let cargo = agreement.finish_accept(req, collateral, clock);
        payout::pay_all(cargo, HAULER);
        ts::return_shared(agreement);
    }

    /// Anyone delivers at DEADLINE_MS - 1.
    fun deliver(scenario: &mut Scenario, clock: &mut Clock) {
        clock.set_for_testing(DEADLINE_MS - 1);
        scenario.next_tx(OTHER);
        let delivered = vector[mint(dst(), ITEM, CARGO_QTY, scenario)];
        let agreement = scenario.take_shared<HaulingAgreement<TOKEN>>();
        agreement.deliver(delivered, clock, scenario.ctx());
    }

    fun ingest(ledger_id: ID, scenario: &mut Scenario) {
        scenario.next_tx(OTHER);
        let mut ledger = scenario.take_shared_by_id<Ledger>(ledger_id);
        let ticket = ts::most_recent_receiving_ticket<OutcomeRecord>(&ledger_id);
        ext::ingest(&mut ledger, ticket);
        ts::return_shared(ledger);
    }

    /// Total of `(collection, asset_id)` balances owned by `owner`.
    fun owned(scenario: &Scenario, owner: address, collection: ID, asset_id: u64): u64 {
        let mut total = 0;
        ts::ids_for_address<Balance>(owner).do!(|id| {
            let balance = scenario.take_from_address_by_id<Balance>(owner, id);
            if (
                multicoin::collection_id(&balance) == collection
            && multicoin::asset_id(&balance) == asset_id
            ) {
                total = total + multicoin::value(&balance);
            };
            ts::return_to_address(owner, balance);
        });
        total
    }

    // === Posting ===

    #[test]
    fun posted_event_lists_every_extension() {
        let (mut scenario, clock) = setup();
        let ledger_id = create_ledger(&mut scenario);
        let mut d = new_draft(&mut scenario, &clock);
        d.require_to_accept(ext::allowlist(vector[HAULER]));
        d.require_identity_to_accept(ext::character());
        bind_ledger(&mut d, ledger_id, &mut scenario);
        let (agreement_id, cap_id) = publish(d);

        assert_eq!(
            event::events_by_type<AgreementPosted>(),
            vector[
                hauling::posted_event_for_testing(
                    agreement_id,
                    LISTER,
                    option::none(),
                    cap_id,
                    BENEFICIARY,
                    false,
                    cargo_spec(),
                    want(),
                    test_config::token(),
                    REWARD_QTY,
                    COLLATERAL_QTY,
                    START_MS,
                    ACCEPT_BY_MS,
                    HAUL_MS,
                    vector[ext::allowlist(vector[HAULER]), ext::character()],
                    option::some(type_name::with_original_ids<Character>()),
                    option::some(
                        hauling::new_binding_for_testing<Ledger>(
                            ledger_id,
                            option::some(fee_spec()),
                        ),
                    ),
                    option::none(),
                    0,
                    test_config::treasury(),
                ),
            ],
        );
        // The ledger collected its own fee; the agreement only records it.
        scenario.next_tx(OTHER);
        assert_eq!(owned(&scenario, TREASURY, fee_collection(), FEE_ASSET), FEE_QTY);
        finish(scenario, clock);
    }

    #[test, expected_failure(abort_code = hauling::EIdentityRuleSet)]
    fun draft_rejects_second_identity_rule() {
        let (mut scenario, clock) = setup();
        let mut d = new_draft(&mut scenario, &clock);
        d.require_identity_to_accept(ext::character());
        d.require_identity_to_accept(ext::allowlist(vector[HAULER]));
        publish(d);
        finish(scenario, clock);
    }

    #[test, expected_failure(abort_code = hauling::EAlreadyBound)]
    fun draft_rejects_second_observer() {
        let (mut scenario, clock) = setup();
        let ledger_id = create_ledger(&mut scenario);
        let mut d = new_draft(&mut scenario, &clock);
        let ledger = scenario.take_shared_by_id<Ledger>(ledger_id);
        ext::bind_ledger(
            &ledger,
            &mut d,
            mint(fee_collection(), FEE_ASSET, FEE_QTY, &mut scenario),
        );
        ext::bind_ledger(
            &ledger,
            &mut d,
            mint(fee_collection(), FEE_ASSET, FEE_QTY, &mut scenario),
        );
        ts::return_shared(ledger);
        publish(d);
        finish(scenario, clock);
    }

    // === On behalf of ===

    /// A wrapper's entity is shown in `AgreementPosted` and every outcome record,
    /// while the signer stays the lister.
    #[test]
    fun on_behalf_of_credits_the_entity_in_the_event_and_record() {
        let (mut scenario, clock) = setup();
        let ledger_id = create_ledger(&mut scenario);
        let mut d = new_draft(&mut scenario, &clock);
        ext::draft_for_desk(&mut d, entity_id());
        bind_ledger(&mut d, ledger_id, &mut scenario);
        let entity = hauling::new_entity_for_testing<Desk>(entity_id());
        assert_eq!(entity.entity_kind(), type_name::with_original_ids<Desk>());
        assert_eq!(entity.entity_id(), entity_id());
        assert_eq!(d.draft_agreement().on_behalf_of(), option::some(entity));
        let (agreement_id, cap_id) = publish(d);
        assert_eq!(
            event::events_by_type<AgreementPosted>(),
            vector[
                hauling::posted_event_for_testing(
                    agreement_id,
                    LISTER,
                    option::some(entity),
                    cap_id,
                    BENEFICIARY,
                    false,
                    cargo_spec(),
                    want(),
                    test_config::token(),
                    REWARD_QTY,
                    COLLATERAL_QTY,
                    START_MS,
                    ACCEPT_BY_MS,
                    HAUL_MS,
                    vector[],
                    option::none(),
                    option::some(
                        hauling::new_binding_for_testing<Ledger>(
                            ledger_id,
                            option::some(fee_spec()),
                        ),
                    ),
                    option::none(),
                    0,
                    test_config::treasury(),
                ),
            ],
        );

        scenario.next_tx(LISTER);
        let cap = scenario.take_from_sender<ListerCap>();
        let agreement = scenario.take_shared<HaulingAgreement<TOKEN>>();
        assert_eq!(agreement.on_behalf_of(), option::some(entity));
        let (cargo, reward) = agreement.cancel(cap, &clock, scenario.ctx());
        payout::pay_all(cargo, LISTER);
        transfer::public_transfer(reward, LISTER);

        scenario.next_tx(OTHER);
        let mut ledger = scenario.take_shared_by_id<Ledger>(ledger_id);
        let ticket = ts::most_recent_receiving_ticket<OutcomeRecord>(&ledger_id);
        let record = ext::take_record(&mut ledger, ticket);
        assert_eq!(record.record_on_behalf_of(), option::some(entity));
        assert_eq!(record.record_lister(), LISTER);
        record.delete_outcome();
        ts::return_shared(ledger);
        finish(scenario, clock);
    }

    #[test, expected_failure(abort_code = hauling::EAlreadyBound)]
    fun draft_rejects_second_on_behalf_of() {
        let (mut scenario, clock) = setup();
        let mut d = new_draft(&mut scenario, &clock);
        ext::draft_for_desk(&mut d, entity_id());
        ext::draft_for_desk(&mut d, object::id_from_address(@0xDA1));
        publish(d);
        finish(scenario, clock);
    }

    // === Accept requirements ===

    #[test]
    fun accept_resolves_rules_in_order_and_records_identity() {
        let (mut scenario, mut clock) = setup();
        let mut d = new_draft(&mut scenario, &clock);
        d.require_to_accept(ext::allowlist(vector[HAULER]));
        d.require_identity_to_accept(ext::character());
        let (agreement_id, _) = publish(d);

        clock.set_for_testing(ACCEPT_AT_MS);
        scenario.next_tx(HAULER);
        let mut agreement = scenario.take_shared<HaulingAgreement<TOKEN>>();
        let mut req = agreement.begin_accept(&clock, scenario.ctx());
        assert!(req.is_action<AcceptAction>());
        assert_eq!(req.actor(), HAULER);
        ext::satisfy_allowlist(&mut req);
        ext::satisfy_character(&mut req, character_id());
        let collateral = test_config::mint(COLLATERAL_QTY, scenario.ctx());
        let cargo = agreement.finish_accept(req, collateral, &clock);
        assert_eq!(spec::of_each(&cargo), vector[spec::new(src(), ITEM, CARGO_QTY)]);
        assert_eq!(agreement.hauler(), option::some(HAULER));
        assert_eq!(agreement.hauler_identity(), option::some(character_id()));
        assert_eq!(
            event::events_by_type<AgreementAccepted>(),
            vector[
                hauling::accepted_event_for_testing(
                    agreement_id,
                    HAULER,
                    option::some(character_id()),
                    option::some(type_name::with_original_ids<Character>()),
                    DEADLINE_MS,
                ),
            ],
        );
        payout::pay_all(cargo, HAULER);
        ts::return_shared(agreement);
        finish(scenario, clock);
    }

    #[test, expected_failure(abort_code = request::ERequestNotComplete)]
    fun plain_accept_cannot_skip_requirements() {
        let (mut scenario, mut clock) = setup();
        let mut d = new_draft(&mut scenario, &clock);
        d.require_to_accept(ext::allowlist(vector[HAULER]));
        publish(d);
        accept_plain(&mut scenario, &mut clock);
        finish(scenario, clock);
    }

    #[test, expected_failure(abort_code = ext::ENotAllowed)]
    fun allowlist_rejects_other_hauler() {
        let (mut scenario, clock) = setup();
        let mut d = new_draft(&mut scenario, &clock);
        d.require_to_accept(ext::allowlist(vector[HAULER]));
        publish(d);
        scenario.next_tx(OTHER);
        let agreement = scenario.take_shared<HaulingAgreement<TOKEN>>();
        let mut req = agreement.begin_accept(&clock, scenario.ctx());
        ext::satisfy_allowlist(&mut req);
        req.destroy_for_testing();
        ts::return_shared(agreement);
        finish(scenario, clock);
    }

    #[test, expected_failure(abort_code = request::EWrongRequirementType)]
    fun accept_rules_must_resolve_in_declaration_order() {
        let (mut scenario, clock) = setup();
        let mut d = new_draft(&mut scenario, &clock);
        d.require_to_accept(ext::allowlist(vector[HAULER]));
        d.require_identity_to_accept(ext::character());
        publish(d);
        scenario.next_tx(HAULER);
        let agreement = scenario.take_shared<HaulingAgreement<TOKEN>>();
        let mut req = agreement.begin_accept(&clock, scenario.ctx());
        ext::satisfy_character(&mut req, character_id());
        req.destroy_for_testing();
        ts::return_shared(agreement);
        finish(scenario, clock);
    }

    #[test, expected_failure(abort_code = request::EIdentityMissing)]
    fun identity_rule_must_record_identity() {
        let (mut scenario, clock) = setup();
        let mut d = new_draft(&mut scenario, &clock);
        d.require_identity_to_accept(ext::character());
        publish(d);
        scenario.next_tx(HAULER);
        let mut agreement = scenario.take_shared<HaulingAgreement<TOKEN>>();
        let mut req = agreement.begin_accept(&clock, scenario.ctx());
        ext::satisfy_character_without_identity(&mut req);
        let collateral = test_config::mint(COLLATERAL_QTY, scenario.ctx());
        let cargo = agreement.finish_accept(req, collateral, &clock);
        payout::pay_all(cargo, HAULER);
        ts::return_shared(agreement);
        finish(scenario, clock);
    }

    #[test, expected_failure(abort_code = request::ENotIdentityRule)]
    fun only_the_identity_rule_may_record_identity() {
        let (mut scenario, clock) = setup();
        let mut d = new_draft(&mut scenario, &clock);
        d.require_to_accept(ext::allowlist(vector[HAULER]));
        d.require_identity_to_accept(ext::character());
        publish(d);
        scenario.next_tx(HAULER);
        let agreement = scenario.take_shared<HaulingAgreement<TOKEN>>();
        let mut req = agreement.begin_accept(&clock, scenario.ctx());
        ext::allowlist_claims_identity(&mut req, character_id());
        req.destroy_for_testing();
        ts::return_shared(agreement);
        finish(scenario, clock);
    }

    #[test]
    fun follow_up_requirements_resolve_next() {
        let (mut scenario, clock) = setup();
        let mut d = new_draft(&mut scenario, &clock);
        d.require_to_accept(ext::chain(vector[HAULER]));
        publish(d);
        scenario.next_tx(HAULER);
        let mut agreement = scenario.take_shared<HaulingAgreement<TOKEN>>();
        let mut req = agreement.begin_accept(&clock, scenario.ctx());
        ext::satisfy_chain(&mut req);
        assert!(req.next().is<ext::Allowlist>());
        ext::satisfy_allowlist(&mut req);
        let collateral = test_config::mint(COLLATERAL_QTY, scenario.ctx());
        let cargo = agreement.finish_accept(req, collateral, &clock);
        payout::pay_all(cargo, HAULER);
        ts::return_shared(agreement);
        finish(scenario, clock);
    }

    #[test, expected_failure(abort_code = request::ERequestNotComplete)]
    fun follow_up_requirements_cannot_be_skipped() {
        let (mut scenario, clock) = setup();
        let mut d = new_draft(&mut scenario, &clock);
        d.require_to_accept(ext::chain(vector[HAULER]));
        publish(d);
        scenario.next_tx(HAULER);
        let mut agreement = scenario.take_shared<HaulingAgreement<TOKEN>>();
        let mut req = agreement.begin_accept(&clock, scenario.ctx());
        ext::satisfy_chain(&mut req);
        let collateral = test_config::mint(COLLATERAL_QTY, scenario.ctx());
        let cargo = agreement.finish_accept(req, collateral, &clock);
        payout::pay_all(cargo, HAULER);
        ts::return_shared(agreement);
        finish(scenario, clock);
    }

    #[test, expected_failure(abort_code = request::EWrongAgreement)]
    fun request_cannot_finish_a_different_agreement() {
        let (mut scenario, clock) = setup();
        // An ungated agreement and one only HAULER may accept.
        let (open_id, _) = publish(new_draft(&mut scenario, &clock));
        let mut gated = new_draft(&mut scenario, &clock);
        gated.require_to_accept(ext::allowlist(vector[HAULER]));
        let (gated_id, _) = publish(gated);

        scenario.next_tx(OTHER);
        let open = scenario.take_shared_by_id<HaulingAgreement<TOKEN>>(open_id);
        let mut gated = scenario.take_shared_by_id<HaulingAgreement<TOKEN>>(gated_id);
        let req = open.begin_accept(&clock, scenario.ctx());
        let collateral = test_config::mint(COLLATERAL_QTY, scenario.ctx());
        let cargo = gated.finish_accept(req, collateral, &clock);
        payout::pay_all(cargo, OTHER);
        ts::return_shared(open);
        ts::return_shared(gated);
        finish(scenario, clock);
    }

    // === Observer ===

    #[test]
    fun observer_records_delivery_with_identity_and_fee() {
        let (mut scenario, mut clock) = setup();
        let ledger_id = create_ledger(&mut scenario);
        let mut d = new_draft(&mut scenario, &clock);
        d.require_identity_to_accept(ext::character());
        bind_ledger(&mut d, ledger_id, &mut scenario);
        let (agreement_id, _) = publish(d);
        accept_as_character(&mut scenario, &mut clock);
        deliver(&mut scenario, &mut clock);

        ingest(ledger_id, &mut scenario);
        scenario.next_tx(OTHER);
        let ledger = scenario.take_shared_by_id<Ledger>(ledger_id);
        assert_eq!(ledger.delivered(), 1);
        assert_eq!(ledger.defaulted(), 0);
        assert_eq!(ledger.fees_credited(), FEE_QTY);
        assert_eq!(ledger.last_agreement_id(), option::some(agreement_id));
        assert_eq!(ledger.last_hauler(), option::some(HAULER));
        assert_eq!(ledger.last_hauler_identity(), option::some(character_id()));
        ts::return_shared(ledger);
        finish(scenario, clock);
    }

    #[test]
    fun observer_records_forfeit_even_though_the_hauler_closes_it() {
        let (mut scenario, mut clock) = setup();
        let ledger_id = create_ledger(&mut scenario);
        let mut d = new_draft(&mut scenario, &clock);
        bind_ledger(&mut d, ledger_id, &mut scenario);
        publish(d);
        accept_plain(&mut scenario, &mut clock);

        scenario.next_tx(HAULER);
        let agreement = scenario.take_shared<HaulingAgreement<TOKEN>>();
        agreement.forfeit(&clock, scenario.ctx());

        ingest(ledger_id, &mut scenario);
        scenario.next_tx(OTHER);
        let ledger = scenario.take_shared_by_id<Ledger>(ledger_id);
        assert_eq!(ledger.defaulted(), 1);
        assert_eq!(ledger.forfeited(), 1);
        assert_eq!(ledger.last_hauler(), option::some(HAULER));
        ts::return_shared(ledger);
        finish(scenario, clock);
    }

    #[test]
    fun observer_records_default_and_cancel() {
        let (mut scenario, mut clock) = setup();
        let ledger_id = create_ledger(&mut scenario);

        // One agreement cancelled while open...
        let mut d = new_draft(&mut scenario, &clock);
        bind_ledger(&mut d, ledger_id, &mut scenario);
        let (cancelled_id, _) = publish(d);
        scenario.next_tx(LISTER);
        let cap = scenario.take_from_sender<ListerCap>();
        let agreement = scenario.take_shared_by_id<HaulingAgreement<TOKEN>>(cancelled_id);
        let (cargo, reward) = agreement.cancel(cap, &clock, scenario.ctx());
        payout::pay_all(cargo, LISTER);
        transfer::public_transfer(reward, LISTER);
        ingest(ledger_id, &mut scenario);

        // ...and one defaulted after the deadline.
        let mut d = new_draft(&mut scenario, &clock);
        bind_ledger(&mut d, ledger_id, &mut scenario);
        publish(d);
        accept_plain(&mut scenario, &mut clock);
        clock.set_for_testing(DEADLINE_MS);
        scenario.next_tx(BENEFICIARY);
        let agreement = scenario.take_shared<HaulingAgreement<TOKEN>>();
        agreement.default(&clock, scenario.ctx());
        ingest(ledger_id, &mut scenario);

        scenario.next_tx(OTHER);
        let ledger = scenario.take_shared_by_id<Ledger>(ledger_id);
        assert_eq!(ledger.cancelled(), 1);
        assert_eq!(ledger.defaulted(), 1);
        assert_eq!(ledger.forfeited(), 0);
        assert_eq!(ledger.fees_credited(), 2 * FEE_QTY);
        ts::return_shared(ledger);
        finish(scenario, clock);
    }

    #[test]
    fun observer_records_a_lapsed_agreement_the_admin_closed() {
        let (mut scenario, mut clock) = setup();
        let ledger_id = create_ledger(&mut scenario);
        let mut d = new_draft(&mut scenario, &clock);
        bind_ledger(&mut d, ledger_id, &mut scenario);
        let (agreement_id, _) = publish(d);

        clock.set_for_testing(ACCEPT_BY_MS);
        scenario.next_tx(OTHER);
        let admin_cap = config::new_admin_cap_for_testing(scenario.ctx());
        let agreement = scenario.take_shared<HaulingAgreement<TOKEN>>();
        agreement.close_lapsed(&admin_cap, &clock, scenario.ctx());
        transfer::public_transfer(admin_cap, OTHER);

        scenario.next_tx(OTHER);
        let mut ledger = scenario.take_shared_by_id<Ledger>(ledger_id);
        let ticket = ts::most_recent_receiving_ticket<OutcomeRecord>(&ledger_id);
        let record = ext::take_record(&mut ledger, ticket);
        assert!(record.record_outcome().outcome_is_lapsed());
        assert!(!record.record_outcome().outcome_is_cancelled());
        assert_eq!(record.record_agreement_id(), agreement_id);
        assert_eq!(record.record_hauler(), option::none());
        assert_eq!(record.record_collateral(), option::none());
        assert_eq!(record.record_deadline_ms(), 0);
        assert_eq!(record.record_closed_at_ms(), ACCEPT_BY_MS);
        record.delete_outcome();
        ts::return_shared(ledger);
        finish(scenario, clock);
    }

    #[test]
    fun ledger_counts_a_lapsed_agreement() {
        let (mut scenario, mut clock) = setup();
        let ledger_id = create_ledger(&mut scenario);
        let mut d = new_draft(&mut scenario, &clock);
        bind_ledger(&mut d, ledger_id, &mut scenario);
        publish(d);

        clock.set_for_testing(ACCEPT_BY_MS);
        scenario.next_tx(OTHER);
        let admin_cap = config::new_admin_cap_for_testing(scenario.ctx());
        let agreement = scenario.take_shared<HaulingAgreement<TOKEN>>();
        agreement.close_lapsed(&admin_cap, &clock, scenario.ctx());
        transfer::public_transfer(admin_cap, OTHER);
        ingest(ledger_id, &mut scenario);

        scenario.next_tx(OTHER);
        let ledger = scenario.take_shared_by_id<Ledger>(ledger_id);
        assert_eq!(ledger.lapsed(), 1);
        assert_eq!(ledger.cancelled(), 0);
        assert_eq!(ledger.fees_credited(), FEE_QTY);
        ts::return_shared(ledger);
        finish(scenario, clock);
    }

    #[test, expected_failure(abort_code = hauling::EWrongObserver)]
    fun observer_rejects_records_from_an_imposter_binding() {
        let (mut scenario, mut clock) = setup();
        let ledger_id = create_ledger(&mut scenario);
        // A different extension type points its records at the real ledger.
        let mut d = new_draft(&mut scenario, &clock);
        ext::bind_imposter_observer(&mut d, ledger_id);
        publish(d);
        accept_plain(&mut scenario, &mut clock);
        deliver(&mut scenario, &mut clock);
        ingest(ledger_id, &mut scenario);
        finish(scenario, clock);
    }
}
