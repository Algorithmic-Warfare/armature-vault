/// Terms that pay the cap holder: every payout to the lister's side goes to the
/// agreement's `ListerCap` as one `Proceeds`, which whoever holds the cap opens
/// with `collect`.
#[test_only]
module hauling_agreements::proceeds_tests {
    use agreements::spec::{Self, Spec};
    use hauling_agreements::{
        config,
        hauling::{
            Self,
            HaulingAgreement,
            ListerCap,
            Proceeds,
            AgreementPosted,
            AgreementDelivered,
            AgreementDefaulted,
            AgreementLapsed,
            ProceedsCollected
        },
        terms::{Self, Terms},
        test_config::{Self, TOKEN}
    };
    use multicoin::multicoin::{Self, Balance};
    use std::unit_test::assert_eq;
    use sui::{clock::{Self, Clock}, coin::Coin, event, test_scenario::{Self as ts, Scenario}};

    const LISTER: address = @0xA;
    const HAULER: address = @0xB;
    const OTHER: address = @0xD;
    const ADMIN: address = @0xE;
    /// Holds the cap after LISTER hands it over, as a DAO or other wrapper would.
    const CUSTODIAN: address = @0xDA0;

    const ITEM: u64 = 7;
    const CARGO_QTY: u64 = 10;
    // Reward and collateral, in TOKEN.
    const REWARD_QTY: u64 = 100;
    const COLLATERAL_QTY: u64 = 500;

    const START_MS: u64 = 1_000;
    const ACCEPT_BY_MS: u64 = 5_000;
    const ACCEPT_MS: u64 = 4_000; // ACCEPT_BY_MS - START_MS, posting at START_MS
    const HAUL_MS: u64 = 10_000;
    const ACCEPT_AT_MS: u64 = 2_000;
    const DEADLINE_MS: u64 = 12_000; // ACCEPT_AT_MS + HAUL_MS

    // === Fixtures ===

    fun src(): ID { object::id_from_address(@0x51) }

    fun dst(): ID { object::id_from_address(@0xD5) }

    fun mint(collection: ID, asset_id: u64, qty: u64, scenario: &mut Scenario): Balance {
        multicoin::create_balance_for_testing(collection, asset_id, qty, scenario.ctx())
    }

    fun want(): Spec { spec::new(dst(), ITEM, CARGO_QTY) }

    fun cargo_spec(): Spec { spec::new(src(), ITEM, CARGO_QTY) }

    fun cap_holder_terms(): Terms {
        terms::new_for_cap_holder(want(), COLLATERAL_QTY, ACCEPT_MS, HAUL_MS)
    }

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

    /// LISTER posts `cargo_qty` of cargo and a reward of `reward_qty` on terms that
    /// pay the cap holder, and keeps the cap. Returns `(agreement_id, cap_id)`;
    /// the posting transaction is still current, so its events remain visible.
    fun post_escrow(
        cargo_qty: u64,
        reward_qty: u64,
        scenario: &mut Scenario,
        clock: &Clock,
    ): (ID, ID) {
        scenario.next_tx(LISTER);
        let cargo = mint(src(), ITEM, cargo_qty, scenario);
        let reward = test_config::mint(reward_qty, scenario.ctx());
        let cap = test_config::post_with_terms(
            cargo,
            reward,
            cap_holder_terms(),
            clock,
            scenario.ctx(),
        );
        let (agreement_id, cap_id) = (cap.cap_agreement_id(), object::id(&cap));
        transfer::public_transfer(cap, LISTER);
        (agreement_id, cap_id)
    }

    /// The standard agreement: CARGO_QTY of cargo for a reward of REWARD_QTY.
    fun post(scenario: &mut Scenario, clock: &Clock): (ID, ID) {
        post_escrow(CARGO_QTY, REWARD_QTY, scenario, clock)
    }

    /// HAULER accepts at ACCEPT_AT_MS and keeps the cargo.
    fun accept(scenario: &mut Scenario, clock: &mut Clock) {
        clock.set_for_testing(ACCEPT_AT_MS);
        scenario.next_tx(HAULER);
        let collateral = test_config::mint(COLLATERAL_QTY, scenario.ctx());
        let mut agreement = scenario.take_shared<HaulingAgreement<TOKEN>>();
        let cargo = agreement.accept(collateral, clock, scenario.ctx());
        transfer::public_transfer(cargo, HAULER);
        ts::return_shared(agreement);
    }

    /// OTHER delivers the want just before the deadline.
    fun deliver(scenario: &mut Scenario, clock: &mut Clock) {
        clock.set_for_testing(DEADLINE_MS - 1);
        scenario.next_tx(OTHER);
        let delivered = mint(dst(), ITEM, CARGO_QTY, scenario);
        let agreement = scenario.take_shared<HaulingAgreement<TOKEN>>();
        agreement.deliver(delivered, clock, scenario.ctx());
    }

    /// The config admin closes the listing `agreement_id` once it has lapsed.
    fun close_lapsed(agreement_id: ID, scenario: &mut Scenario, clock: &mut Clock) {
        clock.set_for_testing(ACCEPT_BY_MS);
        scenario.next_tx(ADMIN);
        let admin_cap = config::new_admin_cap_for_testing(scenario.ctx());
        let agreement = scenario.take_shared_by_id<HaulingAgreement<TOKEN>>(agreement_id);
        agreement.close_lapsed(&admin_cap, clock, scenario.ctx());
        transfer::public_transfer(admin_cap, ADMIN);
    }

    /// The `Proceeds` waiting at cap `cap_id`. Call it once the transaction that
    /// sent them has finished.
    fun proceeds_at(cap_id: ID): ID {
        ts::most_recent_id_for_address<Proceeds<TOKEN>>(cap_id.to_address()).destroy_some()
    }

    /// In a new transaction, `holder` collects the proceeds sent to cap `cap_id`,
    /// and `ProceedsCollected` reports what came out.
    fun collect(
        holder: address,
        cap_id: ID,
        scenario: &mut Scenario,
    ): (Option<Balance>, Coin<TOKEN>) {
        scenario.next_tx(holder);
        let cap = scenario.take_from_sender_by_id<ListerCap>(cap_id);
        let agreement_id = cap.cap_agreement_id();
        let proceeds_id = proceeds_at(cap_id);
        let ticket = ts::most_recent_receiving_ticket<Proceeds<TOKEN>>(&cap_id);
        let (items, coins) = cap.collect(ticket, scenario.ctx());
        assert_eq!(
            event::events_by_type<ProceedsCollected>(),
            vector[
                hauling::collected_event_for_testing(
                    agreement_id,
                    cap_id,
                    proceeds_id,
                    holder,
                    items.map_ref!(|balance| spec::of(balance)),
                    test_config::token(),
                    coins.value(),
                ),
            ],
        );
        (items, coins)
    }

    /// Nothing reached LISTER's own address, and LISTER no longer holds a cap.
    fun assert_lister_holds_nothing(scenario: &mut Scenario) {
        scenario.next_tx(OTHER);
        assert_eq!(ts::ids_for_address<Balance>(LISTER).length(), 0);
        assert_eq!(ts::ids_for_address<Coin<TOKEN>>(LISTER).length(), 0);
        assert_eq!(ts::ids_for_address<ListerCap>(LISTER).length(), 0);
    }

    // === Posting ===

    #[test]
    fun posting_for_the_cap_holder_makes_the_cap_the_beneficiary() {
        let (mut scenario, clock) = setup();
        let (agreement_id, cap_id) = post(&mut scenario, &clock);
        assert_eq!(
            event::events_by_type<AgreementPosted>(),
            vector[
                hauling::posted_event_for_testing(
                    agreement_id,
                    LISTER,
                    option::none(),
                    cap_id,
                    cap_id.to_address(),
                    true,
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
                    option::none(),
                    option::none(),
                    0,
                    test_config::treasury(),
                ),
            ],
        );

        scenario.next_tx(LISTER);
        let cap = scenario.take_from_sender<ListerCap>();
        assert!(cap.cap_receives_proceeds());
        scenario.return_to_sender(cap);
        let agreement = scenario.take_shared<HaulingAgreement<TOKEN>>();
        assert!(agreement.pays_cap_holder());
        assert_eq!(agreement.beneficiary(), cap_id.to_address());
        assert_eq!(agreement.terms(), cap_holder_terms());
        ts::return_shared(agreement);
        finish(scenario, clock);
    }

    // === Endings ===

    #[test]
    fun deliver_sends_the_want_to_the_cap() {
        let (mut scenario, mut clock) = setup();
        let (agreement_id, cap_id) = post(&mut scenario, &clock);
        accept(&mut scenario, &mut clock);
        deliver(&mut scenario, &mut clock);
        let delivered = event::events_by_type<AgreementDelivered>();
        scenario.next_tx(OTHER);
        assert_eq!(
            delivered,
            vector[
                hauling::delivered_event_for_testing(
                    agreement_id,
                    LISTER,
                    HAULER,
                    option::none(),
                    cap_id.to_address(),
                    want(),
                    test_config::token(),
                    REWARD_QTY,
                    COLLATERAL_QTY,
                    0,
                    test_config::treasury(),
                    option::some(proceeds_at(cap_id)),
                ),
            ],
        );
        // The hauler is paid at their own address as usual.
        assert_eq!(test_config::coins<TOKEN>(&scenario, HAULER), REWARD_QTY + COLLATERAL_QTY);

        let (items, coins) = collect(LISTER, cap_id, &mut scenario);
        let items = items.destroy_some();
        assert_eq!(spec::of(&items), want());
        assert_eq!(coins.value(), 0);
        transfer::public_transfer(items, OTHER);
        coins.destroy_zero();
        assert_lister_holds_nothing(&mut scenario);
        finish(scenario, clock);
    }

    #[test]
    fun default_sends_reward_and_collateral_to_the_cap() {
        let (mut scenario, mut clock) = setup();
        let (agreement_id, cap_id) = post(&mut scenario, &clock);
        accept(&mut scenario, &mut clock);
        clock.set_for_testing(DEADLINE_MS);
        scenario.next_tx(OTHER);
        let agreement = scenario.take_shared<HaulingAgreement<TOKEN>>();
        agreement.default(&clock, scenario.ctx());
        let defaulted = event::events_by_type<AgreementDefaulted>();
        scenario.next_tx(OTHER);
        assert_eq!(
            defaulted,
            vector[
                hauling::defaulted_event_for_testing(
                    agreement_id,
                    LISTER,
                    HAULER,
                    option::none(),
                    cap_id.to_address(),
                    test_config::token(),
                    REWARD_QTY,
                    COLLATERAL_QTY,
                    false,
                    option::some(proceeds_at(cap_id)),
                ),
            ],
        );

        let (items, coins) = collect(LISTER, cap_id, &mut scenario);
        assert!(items.is_none());
        items.destroy_none();
        // Reward and collateral arrive together, as one coin.
        assert_eq!(coins.value(), REWARD_QTY + COLLATERAL_QTY);
        transfer::public_transfer(coins, OTHER);
        assert_lister_holds_nothing(&mut scenario);
        finish(scenario, clock);
    }

    #[test]
    fun forfeit_sends_reward_and_collateral_to_the_cap() {
        let (mut scenario, mut clock) = setup();
        let (agreement_id, cap_id) = post(&mut scenario, &clock);
        accept(&mut scenario, &mut clock);
        scenario.next_tx(HAULER);
        let agreement = scenario.take_shared<HaulingAgreement<TOKEN>>();
        agreement.forfeit(&clock, scenario.ctx());
        let defaulted = event::events_by_type<AgreementDefaulted>();
        scenario.next_tx(OTHER);
        assert_eq!(
            defaulted,
            vector[
                hauling::defaulted_event_for_testing(
                    agreement_id,
                    LISTER,
                    HAULER,
                    option::none(),
                    cap_id.to_address(),
                    test_config::token(),
                    REWARD_QTY,
                    COLLATERAL_QTY,
                    true,
                    option::some(proceeds_at(cap_id)),
                ),
            ],
        );

        let (items, coins) = collect(LISTER, cap_id, &mut scenario);
        items.destroy_none();
        assert_eq!(coins.value(), REWARD_QTY + COLLATERAL_QTY);
        transfer::public_transfer(coins, OTHER);
        assert_lister_holds_nothing(&mut scenario);
        finish(scenario, clock);
    }

    /// The admin's `close_lapsed` refunds the cap, not the signer of `draft`, so a
    /// wrapper that drafted through someone else's key still gets its escrow back.
    #[test]
    fun close_lapsed_sends_cargo_and_reward_to_the_cap() {
        let (mut scenario, mut clock) = setup();
        let (agreement_id, cap_id) = post(&mut scenario, &clock);
        close_lapsed(agreement_id, &mut scenario, &mut clock);
        let lapsed = event::events_by_type<AgreementLapsed>();
        scenario.next_tx(OTHER);
        assert_eq!(
            lapsed,
            vector[
                hauling::lapsed_event_for_testing(
                    agreement_id,
                    LISTER,
                    cap_id.to_address(),
                    ADMIN,
                    cargo_spec(),
                    test_config::token(),
                    REWARD_QTY,
                    option::some(proceeds_at(cap_id)),
                ),
            ],
        );

        let (items, coins) = collect(LISTER, cap_id, &mut scenario);
        let items = items.destroy_some();
        assert_eq!(spec::of(&items), cargo_spec());
        assert_eq!(coins.value(), REWARD_QTY);
        transfer::public_transfer(items, OTHER);
        transfer::public_transfer(coins, OTHER);
        assert_lister_holds_nothing(&mut scenario);
        finish(scenario, clock);
    }

    /// An empty escrow still sends `Proceeds`, so the cap can always be collected
    /// and deleted.
    #[test]
    fun close_lapsed_with_empty_escrow_still_sends_proceeds() {
        let (mut scenario, mut clock) = setup();
        let (agreement_id, cap_id) = post_escrow(0, 0, &mut scenario, &clock);
        close_lapsed(agreement_id, &mut scenario, &mut clock);

        let (items, coins) = collect(LISTER, cap_id, &mut scenario);
        items.destroy_none();
        coins.destroy_zero();
        assert_lister_holds_nothing(&mut scenario);
        finish(scenario, clock);
    }

    /// `cancel` hands the escrow straight to the cap holder and sends no
    /// `Proceeds`.
    #[test]
    fun cancel_returns_the_escrow_directly() {
        let (mut scenario, clock) = setup();
        let (_, cap_id) = post(&mut scenario, &clock);
        scenario.next_tx(LISTER);
        let cap = scenario.take_from_sender<ListerCap>();
        let agreement = scenario.take_shared<HaulingAgreement<TOKEN>>();
        let (cargo, reward) = agreement.cancel(cap, &clock, scenario.ctx());
        assert_eq!(spec::of(&cargo), cargo_spec());
        assert_eq!(reward.value(), REWARD_QTY);
        transfer::public_transfer(cargo, LISTER);
        transfer::public_transfer(reward, LISTER);

        scenario.next_tx(OTHER);
        assert_eq!(ts::ids_for_address<Proceeds<TOKEN>>(cap_id.to_address()).length(), 0);
        finish(scenario, clock);
    }

    // === Following the cap ===

    /// Whoever holds the cap when the agreement ends collects its proceeds.
    #[test]
    fun proceeds_follow_the_cap_to_its_holder() {
        let (mut scenario, mut clock) = setup();
        let (_, cap_id) = post(&mut scenario, &clock);
        scenario.next_tx(LISTER);
        let cap = scenario.take_from_sender<ListerCap>();
        transfer::public_transfer(cap, CUSTODIAN);
        accept(&mut scenario, &mut clock);
        deliver(&mut scenario, &mut clock);

        let (items, coins) = collect(CUSTODIAN, cap_id, &mut scenario);
        let items = items.destroy_some();
        assert_eq!(spec::of(&items), want());
        transfer::public_transfer(items, CUSTODIAN);
        coins.destroy_zero();
        assert_lister_holds_nothing(&mut scenario);
        finish(scenario, clock);
    }

    #[test, expected_failure(abort_code = hauling::ECapReceivesProceeds)]
    fun delete_cap_rejects_a_cap_that_receives_proceeds() {
        let (mut scenario, mut clock) = setup();
        post(&mut scenario, &clock);
        accept(&mut scenario, &mut clock);
        deliver(&mut scenario, &mut clock);
        scenario.next_tx(LISTER);
        hauling::delete_cap(scenario.take_from_sender<ListerCap>(), scenario.ctx());
        finish(scenario, clock);
    }

    /// Proceeds open only with the cap they were sent to.
    #[test, expected_failure(abort_code = sui::transfer::EUnableToReceiveObject)]
    fun collect_rejects_another_agreements_proceeds() {
        let (mut scenario, mut clock) = setup();
        let (first_id, first_cap_id) = post(&mut scenario, &clock);
        let (_, second_cap_id) = post(&mut scenario, &clock);
        close_lapsed(first_id, &mut scenario, &mut clock);

        scenario.next_tx(LISTER);
        let second_cap = scenario.take_from_sender_by_id<ListerCap>(second_cap_id);
        let ticket = ts::most_recent_receiving_ticket<Proceeds<TOKEN>>(&first_cap_id);
        let (items, coins) = second_cap.collect(ticket, scenario.ctx());
        items.destroy_none();
        transfer::public_transfer(coins, LISTER);
        finish(scenario, clock);
    }
}
