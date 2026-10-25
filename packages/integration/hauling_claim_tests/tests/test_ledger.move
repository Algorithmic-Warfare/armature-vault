/// Binds an observer so the flow tests can read each agreement's outcome
/// record. It charges no fee and keeps nothing.
#[test_only]
module hauling_claim_tests::test_ledger;

use hauling_agreements::hauling::{Self, Draft, OutcomeRecord};
use std::internal;
use sui::transfer::Receiving;

public struct TestLedger has key {
    id: UID,
}

public fun new(ctx: &mut TxContext): ID {
    let ledger = TestLedger { id: object::new(ctx) };
    let id = object::id(&ledger);
    transfer::share_object(ledger);
    id
}

public fun bind<T>(ledger: &TestLedger, draft: &mut Draft<T>) {
    draft.bind_observer(internal::permit<TestLedger>(), object::id(ledger), option::none());
}

public fun take_record(ledger: &mut TestLedger, ticket: Receiving<OutcomeRecord>): OutcomeRecord {
    hauling::receive_outcome(internal::permit<TestLedger>(), &mut ledger.id, ticket)
}
