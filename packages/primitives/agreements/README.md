# agreements

What every agreement type in this repo shares. It depends only on [MultiCoin](https://github.com/Algorithmic-Warfare/multicoin).

- [delivery_agreements](../../composites/delivery_agreements) is built on it now. Auctions and item exchanges will be too.
- [agreement_roles](../../extensions/agreement_roles) gates any agreement type through it.

## `agreements::request` and `agreements::requirement`

How extensions gate an agreement's actions. Adapted from world-contracts `dev` (`core::request`, `core::requirement`).

- **A `Requirement`** is a config type's name plus its BCS encoding. Only the module that defines the config type can satisfy it, because satisfying needs `Permit` of that type.
- **An action is a marker type** the agreement module defines, such as delivery's `AcceptAction`. `request::new<A>` and `request::complete<A>` take `Permit<A>`, so only that module can open or complete requests for its actions.
- **A `Request`** has no abilities. It holds the agreement ID, the action, the actor (always the sender), an optional identity rule and the outstanding requirements. The transaction can't end until the agreement module completes it.
- **Rules satisfy requirements in declaration order** with `take_next`. A rule can add follow-ups through the returned `Frame`, which resolve next. A frame only goes back onto a request for the same agreement and action.
- **`complete`** aborts unless the request was opened for this agreement and action, every requirement is satisfied, and the identity rule (if any) recorded an identity.

An agreement module opens and completes its own requests:

```move
public struct Bid has drop {}

public fun begin_bid(self: &Auction, ctx: &TxContext): Request {
    request::new(internal::permit<Bid>(), object::id(self), option::none(), self.bid_requirements, ctx)
}

public fun finish_bid(self: &mut Auction, request: Request) {
    let (bidder, _identity) = request.complete(internal::permit<Bid>(), object::id(self));
    // ...
}
```

Anyone can open requests for an action type they define. A rule that should gate only some agreement types or actions checks `request.is_action<A>()` before taking anything of value.

| Error | When |
|---|---|
| `EWrongRequirementType` | `take_next` by a rule that isn't the next requirement's |
| `EFrameNotEmpty` | `destroy_empty_frame` on a frame with follow-ups |
| `ERequestNotComplete` | `complete` with requirements left |
| `ENoRequirements` | `take_next` or `next` on an empty request |
| `EWrongAgreement` | `complete` on another agreement |
| `ENotIdentityRule` | `set_identity` by a rule the agreement didn't name |
| `EIdentityAlreadySet` | a second `set_identity` |
| `EIdentityMissing` | `complete` before the identity rule recorded an identity |
| `EWrongAction` | `complete` for another action |
| `EWrongFrame` | `enqueue` onto a request for another agreement or action |

## `agreements::spec`

A `Spec` is an exact multicoin amount: `{ collection, asset_id, qty }`.

- `spec::new(collection, asset_id, qty)` builds one and `spec::of(&balance)` describes a balance.
- `spec.assert_matches(&balance)` aborts with `EWrongAsset` for another collection or asset and `EWrongAmount` for another quantity.

## `agreements::payout`

`pay_by_bps(balance, shares, recipients, ctx)` divides a balance among recipients by basis points:

- Shares must sum to 10,000, with one per recipient and at least one recipient (`EInvalidShares`).
- Each recipient gets the floor of their share. The units left over go one each to the largest fractional remainders, with ties going to the earlier recipient.
- Nobody without a share is paid, and nobody gets more than one unit over their exact share.

## Dependency pin

`multicoin` is pinned to `2772c26`, the same revision as warehouse-receipts and every agreement package. On-chain, a `Balance` is only the same type if every package links the same published multicoin, so bump them together.

## Upgrades

Agreement types depend on these types, and moving them later breaks upgrade compatibility. Publish this package immutable alongside the agreement packages, and ship changes as a fresh publish at a cycle rollover.

## Build & test

```bash
cd packages/primitives/agreements
sui move build --build-env testnet_stillness
sui move test  --build-env testnet_stillness
```

- `tests/request_tests.move`: ordering, follow-ups, identity, and every abort. It uses two stand-in agreement types, `tests/test_agreements.move` (a lease with two actions, plus example rules) and `tests/test_auction.move`, so requests are shown not to cross actions or agreement types.
- `tests/spec_tests.move`: `Spec` and `Requirement`.
- `tests/payout_tests.move`: exact and rounded splits, ties, zero shares, empty and maximum balances, invalid shares, and a sweep of totals checking every payout adds up and stays within one unit of its exact share.
