/// A stand-in second agreement type built only on `agreements`: a shared
/// auction whose `Bid` action is gated by requirements, as hauling's accept
/// is. It holds no funds; it records the last bidder so tests can see who got
/// through the gate.
#[test_only]
module agreement_roles::test_auction {
    use agreements::{request::{Self, Request}, requirement::Requirement};
    use std::internal;

    public struct Bid has drop {}

    public struct Auction has key {
        id: UID,
        bid_requirements: vector<Requirement>,
        last_bidder: Option<address>,
    }

    /// Share an auction whose bids must satisfy `bid_requirements`.
    public fun create(bid_requirements: vector<Requirement>, ctx: &mut TxContext): ID {
        let auction = Auction {
            id: object::new(ctx),
            bid_requirements,
            last_bidder: option::none(),
        };
        let id = object::id(&auction);
        transfer::share_object(auction);
        id
    }

    public fun begin_bid(self: &Auction, ctx: &TxContext): Request {
        request::new(
            internal::permit<Bid>(),
            object::id(self),
            option::none(),
            self.bid_requirements,
            ctx,
        )
    }

    public fun finish_bid(self: &mut Auction, request: Request) {
        let (bidder, _) = request.complete(internal::permit<Bid>(), object::id(self));
        self.last_bidder = option::some(bidder);
    }

    public fun last_bidder(self: &Auction): Option<address> { self.last_bidder }
}
