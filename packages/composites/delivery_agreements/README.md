# delivery_agreements

Minimal on-chain agreements built only on [MultiCoin](https://github.com/Algorithmic-Warfare/multicoin), the shared [agreements](../../primitives/agreements) primitive and the Sui framework. Items are multicoin balances; payments are Sui coins in an admin-approved currency.

- [docs/agreements/design.md](../../docs/agreements/design.md): the full design, its guarantees and how it is meant to be extended.
- [docs/agreements/user-paths.md](../../docs/agreements/user-paths.md): every user path, step by step.
- [agreement_roles](../../extensions/agreement_roles): limit who can claim an agreement to a list of principals (one player, machine keys or an OU's board), as armature_vault does.

## `delivery_agreements::delivery`

A delivery agreement is a forward swap of items between two multicoin balances, backed by collateral and paid in one coin type `T`: a `DeliveryAgreement<T>`. `T` must be approved in the shared `Config` when the agreement is drafted (see [Config](#delivery_agreementsconfig)).

1. **`draft`, then `publish`**: the lister escrows `cargo` (a multicoin `Balance`) and a `reward` (a `Coin<T>`). They name the `want` (an exact collection, asset and quantity that counts as delivery), the collateral a hauler must lock (an amount of `T`), an accept-by time and a haul window, each at most 30 days (`max_duration_ms`). They also pay the posting fee, if one is set. Extensions are attached between the two calls (see [Extensions](#extensions)). `publish` shares the agreement and returns a `ListerCap`. `post` does both for an agreement with no extensions.
2. **`accept`**: a hauler locks a `Coin<T>` of exactly the collateral amount (`EWrongCollateral` otherwise) and receives the cargo at once. The deadline is the accept time plus the haul window. If the agreement has accept requirements, use `begin_accept`, satisfy them, then `finish_accept`.
3. **`deliver`**: anyone hands in exactly the `want` balance before the deadline. It goes to the beneficiary, the delivery fee goes to the treasury, and the rest of the reward plus the collateral go to the hauler. The agreement is deleted.
4. **`default`**: after the deadline, anyone can send the reward and collateral to the beneficiary. The agreement is deleted.
   - **`forfeit`**: the hauler can trigger the same payout before the deadline, for example after deciding not to do the haul. Only the hauler can call it. `default` stays open to anyone, so the funds never depend on a hauler who has walked away.
5. **`cancel`**: while the agreement is still open, the `ListerCap` holder gets the cargo `Balance` and the reward `Coin<T>` back. The agreement is deleted.

Payouts are coins of `T`. A zero amount isn't sent, so nobody receives an empty coin.

There is no dispute step: delivery is a check of the balance's type and amount.

## `delivery_agreements::config`

Approved currencies and protocol fees, set in one shared `Config` created at publish. There is no public constructor, so every agreement is drafted against that config. It starts with no currencies, no fees and the publisher as treasury, so nothing can be drafted until a currency is approved.

- **Approved currencies**: the coin types an agreement may be paid in. `draft<T, F>` aborts with `ECurrencyNotApproved` unless `T` is approved. Revoking a currency stops new agreements in it; agreements already drafted in it run to the end unchanged. Check with `is_approved<T>()` or `currencies()`.
- **Posting fee**: a flat amount in one configured coin type `F` (`post_fee: Option<PostFee { currency, amount }>`) that the lister pays when drafting. `draft` and `post` take `config: &Config, post_fee: Coin<F>` after `beneficiary`. The coin must match the fee exactly (`EWrongPostFeeCurrency`, `EWrongPostFeeAmount`), or be empty, of any type, when there is none (`EUnexpectedFee`). It goes to the treasury at once and is not refunded on cancel.
- **Delivery fee**: `floor(reward * delivery_fee_bps / 10,000)`, taken from the reward at `deliver` and sent to the treasury, in `T`. The hauler gets the rest. `default`, `forfeit` and `cancel` take no fee.
- **Fixed per agreement.** Each agreement copies the delivery rate and treasury when drafted, so config changes never alter existing agreements, open or accepted. Read them with `delivery_fee_bps()` and `treasury()` on the agreement, or from `AgreementPosted`.
- **`AdminCap`** changes the config with `approve_currency<T>` (`ECurrencyAlreadyApproved` if it already is), `revoke_currency<T>` (`ECurrencyNotApproved` if it isn't), `set_post_fee<F>` (`EInvalidPostFee` for 0), `clear_post_fee`, `set_delivery_fee_bps` (`EInvalidBps` above 10,000) and `set_treasury`. Each emits `ConfigUpdated` with the whole config, including the currency list. The publisher receives the cap; it has `store`, so a DAO can hold it.

## Extensions

Two optional extensions. Each is attached to the `Draft`, so it is fixed before anyone commits funds, and neither can stop an agreement from ending.

```mermaid
flowchart LR
    D["draft"] --> R["require_to_accept<br>require_identity_to_accept"]
    D --> O["bind_observer (Permit of O)"]
    R --> P["publish"]
    O --> P
```

### Accept requirements: who may accept

Built on `agreements::request` and `agreements::requirement`, adapted from the `Request`/`Requirement` pattern in world-contracts `dev` (`core::request`, `core::requirement`). The same rules can gate other agreement types built on `agreements`.

- A `Requirement` is a type name plus a BCS-encoded config. Only the module that defines the config type can satisfy it, because satisfying needs `Permit` of that type.
- `begin_accept` returns a `Request` with no abilities. Rule modules satisfy its requirements in declaration order with `take_next`. A rule can add follow-up requirements through the returned `Frame`, which resolve next. A frame can only be enqueued back onto a request for the same agreement and action.
- `finish_accept` completes the request. It aborts unless every requirement is satisfied and the request was created for this agreement and this action, so a request satisfied against a loosely gated agreement can't be finished on a strictly gated one.
- Actions are marker types; delivery's is `AcceptAction`. Only this module can create `Permit` of it, so only it can open or complete its requests. A rule that should gate delivery accepts only can check `request.is_action<AcceptAction>()`.
- `accept` is `begin_accept` plus `finish_accept`. It aborts when requirements exist, so they can't be bypassed.
- **Identity.** `require_identity_to_accept` also trusts that rule to record the hauler's identity with `set_identity`, for example the character ID behind a world `AccessCap`. An agreement has at most one identity rule, and an accept can't complete until it records an identity. Identity appears in `AgreementAccepted`, the terminal events and outcome records. `AgreementAccepted` and outcome records also carry the `identity_rule` that attested it. The lister chooses that rule, so trust an identity only from rules you trust. Key reputation by it: a wallet address is free to replace.

```move
let mut req = agreement.begin_accept(&clock, ctx);
member_rule::satisfy(&mut req, dao);             // takes Permit of its config type
character_rule::satisfy(&mut req, &access_cap);  // records the character ID
let cargo = agreement.finish_accept(req, collateral, &clock);
```

### Observer: an unforgeable track record

- `bind_observer<T, O>(draft, Permit<O>, instance, fee)` can only be called by `O`'s module. That module collects its fee in the same call and declares it as `fee`. This package never holds extension fees.
- Every terminal transition (`deliver`, `default`, `forfeit`, `cancel`) sends an `OutcomeRecord` object to the `instance` object's address. The record holds the outcome, parties, hauler identity and the rule that attested it, the observer binding with its declared fee, the cargo and want specs, the `currency` with the `reward` and `collateral` amounts, and timestamps. The reward is the escrowed reward, before any delivery fee; the collateral is `none` if the agreement was cancelled before anyone accepted.
- The observer collects records whenever it likes with `receive_outcome<O>(Permit<O>, &mut UID, Receiving<OutcomeRecord>)`. That aborts for records bound to a different observer type, so another extension type can't fill a real observer's inbox with records it would count.
- Closing an agreement never runs observer code, so a buggy or hostile observer can't freeze funds. Nobody can suppress a record either: a hauler who forfeits still generates their failure record.
- Each record is a separate object, so there is no contention on one shared object.

**Fees are what give records weight.** Reward and collateral must be in an approved currency, but completing a job between two of your own accounts still costs nothing but the observer's fee, the posting fee and the delivery fee, because the reward and collateral come back to you. An observer should weight completions by fees it collected in an asset it chooses, not count them.

## Events

`cargo`, `want` and `delivered` are `agreements::spec::Spec`s: `{ collection, asset_id, qty }`. Build one with `spec::new`. `reward`, `collateral` and `delivery_fee` are `u64` amounts of `currency`, the agreement's coin type `T` as a `TypeName`. `post_fee` is `Option<PostFee { currency, amount }>`, in its own coin type.

| Event | Fields | Emitted by |
|---|---|---|
| `AgreementPosted` | `agreement_id`, `lister`, `cap_id`, `beneficiary`, `cargo`, `want`, `currency`, `reward`, `collateral`, `accept_by_ms`, `haul_ms`, `accept_requirements`, `identity_rule`, `observer`, `post_fee`, `delivery_fee_bps`, `treasury` | `publish` |
| `AgreementAccepted` | `agreement_id`, `hauler`, `hauler_identity`, `identity_rule`, `deadline_ms` | `finish_accept` |
| `AgreementDelivered` | `agreement_id`, `lister`, `hauler`, `hauler_identity`, `beneficiary`, `delivered`, `currency`, `reward`, `collateral`, `delivery_fee`, `treasury` | `deliver` |
| `AgreementDefaulted` | `agreement_id`, `lister`, `hauler`, `hauler_identity`, `beneficiary`, `currency`, `reward`, `collateral`, `forfeited` | `default` (`forfeited = false`), `forfeit` (`forfeited = true`) |
| `AgreementCancelled` | `agreement_id`, `cancelled_by`, `cargo`, `currency`, `reward` | `cancel` |
| `config::ConfigUpdated` | `config_id`, `currencies`, `post_fee`, `delivery_fee_bps`, `treasury` | `approve_currency`, `revoke_currency`, `set_post_fee`, `clear_post_fee`, `set_delivery_fee_bps`, `set_treasury` |

- **Final events are self-contained.** `Delivered`, `Defaulted` and `Cancelled` delete the agreement object, so each one records who received what. A deleted agreement can't be read back by ID afterwards, so index from the package's publish checkpoint.
- **`AgreementDelivered.reward` is what the hauler received**, after the fee. It plus `delivery_fee` is the escrowed reward.
- **`AgreementPosted` carries every requirement with its config**, in the order an accepting transaction must satisfy them, so a client can build the transaction without reading the object.
- **`lister` is the sender of `draft`.** It can differ from `beneficiary`, for example when a DAO lists for its treasury.
- **Failure rates are indexable.** `AgreementDefaulted` with `hauler` or `hauler_identity` is a failure; `forfeited` tells a hauler who gave up from one who disappeared.
- **Two states have no event.** An open agreement past `accept_by_ms` is *lapsed* until the cap holder cancels it. An accepted agreement past `deadline_ms` is *overdue* until someone calls `default`. Derive both from the latest checkpoint's timestamp.

## Hauling with warehouse receipts

A [warehouse receipt](https://github.com/loash-industries/warehouse-receipts) is a multicoin `Balance` whose collection identifies its Storage Unit and whose asset ID is the item type. A haul from SSU A to SSU B is an agreement with:

- `cargo` set to receipts from A's collection,
- `want` set to the same item type and quantity in B's collection.

The hauler accepts, redeems at A, moves the items however they like, then deposits at B with `deposit_for_receipt` and calls `deliver`. The last two steps can share one transaction. Delivering receipts bought on a market is equally valid, because the beneficiary receives the same claim.

## What the contract does not check

- **Whether a collection is real.** The contract doesn't check that a collection is a warehouse-receipt vault, or that its extension is frozen. Before accepting, a hauler should confirm two things: that `want.collection` belongs to the intended destination SSU, and that they can redeem the cargo.
- **Whether the collateral is enough.** There's no oracle. The lister prices the collateral. If it's below the cargo's value plus the reward, keeping the cargo is the hauler's rational choice.
- **Whether extensions are honest.** Rule and observer modules are trusted code chosen by the lister. The core checks that a permit's type and instance match the binding; the extension's own module must check that its caller speaks for that instance, and its declared fee is taken on trust. Inspect an agreement's requirements and bindings before accepting.
- **SSU loss.** If an SSU is unanchored or destroyed mid-haul, the hauler can't deliver and will default. Price that risk into the reward.
- **That the endpoints stay online.** Minting `want` needs the destination SSU online. Whoever controls it, often the lister, can take it offline until the deadline and collect the collateral by default. Before accepting, check who controls both SSUs.
- **Who the lister and hauler are beyond the signer.** They are the addresses that signed `draft` and the accept. Payouts follow those addresses, not the `ListerCap` or a DAO or other wrapper that funded the agreement.
- **What currencies and fees future agreements use.** The `AdminCap` holder can approve or revoke any coin type, and set any posting fee, a delivery fee up to the whole reward, and any treasury, for agreements drafted afterwards. Haulers should read an agreement's `currency` and `delivery_fee_bps` before accepting.
- **Self-dealing.** One player with two wallets can complete an agreement with themselves. Outcome records include the cargo and want specs and the currency, reward and collateral so an observer can discount cheap or circular jobs.

## Gas

A sponsor pays about 0.0087 SUI net per delivered agreement, nearly all of it storage. The per-feature and per-agreement costs are in [docs/agreements/gas.md](../../../docs/agreements/gas.md). `python3 scripts/gas_harness.py run`, from the repo root, re-measures them on a local network.

## Upgrades

Shared agreements have no version field, so after an upgrade every earlier version's functions stay callable on open agreements, and an upgrade could add a function that moves escrow. Publish the package immutable (`sui::package::make_immutable` on the `UpgradeCap`), and ship fixes as a fresh publish at a cycle rollover.

## Dependency pin

`multicoin` is pinned to the same revision as warehouse-receipts and `agreements` (`2772c26`). On-chain, a `Balance` is only the same type if every package links the same published multicoin, so bump them together. `agreements` is a local dependency and is published first.

## Build & test

```bash
cd packages/composites/delivery_agreements
sui move build --build-env testnet_stillness
sui move test  --build-env testnet_stillness
```

`tests/test_config.move` defines a test coin `TOKEN` and wraps `draft` and `post` with a config that approves it and charges no fees, for tests that aren't about the config. `tests/config_tests.move` covers currencies and fees. `tests/test_extensions.move` holds minimal example extensions used by the tests: an allowlist rule, an identity rule, a rule that adds a follow-up and an observer ledger.
