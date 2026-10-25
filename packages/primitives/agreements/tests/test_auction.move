/// A second stand-in agreement type, in its own module, with a `Bid` action.
/// Only this module can open or complete bid requests, so a lease request can
/// never complete here and a bid request can never complete a lease.
#[test_only]
module agreements::test_auction {
    use agreements::{request::{Self, Request}, requirement::Requirement};
    use std::internal;

    public struct Bid has drop {}

    public fun open_bid(
        auction_id: ID,
        requires: vector<Requirement>,
        ctx: &mut TxContext,
    ): Request {
        request::new(internal::permit<Bid>(), auction_id, option::none(), requires, ctx)
    }

    public fun complete_bid(request: Request, auction_id: ID): (address, Option<ID>) {
        request.complete(internal::permit<Bid>(), auction_id)
    }
}
