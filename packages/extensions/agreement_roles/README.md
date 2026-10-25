# agreement_roles

A claim gate for agreements built on [`agreements`](../../primitives/agreements), such as [delivery_agreements](../../composites/delivery_agreements): only a listed set of principals may take the gated action, for example accepting a delivery. Principals come from [`roles`](../../primitives/roles):

- one `player`: reserves the agreement for that player,
- `machine` keys: service or bot keys,
- an `ou`: any current board member of that [armature](https://github.com/loash-industries/armature) OU.

An agreement with no gate is open to anyone.

- [docs/agreements/design.md](../../../docs/agreements/design.md#agreement_roles-who-may-claim): where the gate fits in the agreement design.
- [docs/agreements/user-paths.md](../../../docs/agreements/user-paths.md#l3-limit-who-can-claim): posting a gated agreement, step by step.

## `agreement_roles::claim`

### Listing

```move
// One call: draft, gate and publish.
let terms = terms::new(want, collateral, accept_ms, haul_ms, beneficiary);
let cap = claim::post_for<T, F>(cargo, reward, terms,
    vector[acl::ou(haulers_id), acl::player(freelancer)], &config, post_fee, &clock, ctx);

// Or gate a draft that also gets other extensions.
claim::require_to_claim(&mut draft, vector[acl::ou(haulers_id), acl::player(freelancer)]);
```

- `post_for<T, F>` takes `delivery::draft`'s arguments with `principals` after `terms`: the cargo `Balance`, a `Coin<T>` reward and the agreement's `delivery_agreements::terms::Terms`, then the shared `delivery_agreements::config::Config` and a `post_fee` coin of exactly the posting fee (an empty coin of any type when none is set). `T` must be an approved currency. See [terms](../../composites/delivery_agreements/README.md#delivery_agreementsterms) and [config](../../composites/delivery_agreements/README.md#delivery_agreementsconfig).
- **For a DAO that keeps the cap,** pass terms from `terms::new_for_cap_holder` with an `ou` gate: only the OU's board can claim, and every payout to the lister's side goes to the cap the DAO holds.
- `require_to_claim<T>` gates a `Draft<T>` in any currency.
- A gate lists 1 to 32 principals (`EInvalidPrincipals` otherwise).
- **The list is fixed when the agreement is published.** To change it, cancel and post again with the same `agreement.terms()`.
- **OU membership is not fixed.** An `ou` principal is checked at claim time, so board changes after posting apply to open agreements. Anything that must change while an agreement is open belongs in an OU.
- An agreement can carry several gates. Each must pass, in the order they were added.

### Claiming

Accept with `begin_accept` and `finish_accept`, and satisfy the gate in between. Use one of:

- **`satisfy(&mut req, &org)`**: acting as a board member of `org`. A listed `player` or `machine` also passes, whatever OU is passed.
- **`satisfy_directly(&mut req)`**: as a listed `player` or `machine`, with no OU.

```move
let mut req = agreement.begin_accept(&clock, ctx);
claim::satisfy(&mut req, &haulers);      // or claim::satisfy_directly(&mut req)
let cargo = agreement.finish_accept(req, collateral, &clock);   // collateral: Coin<T>
```

A caller who satisfies no listed principal aborts with `ENotAuthorized`. Calling `accept` without satisfying the gate aborts with `agreements::request::ERequestNotComplete`.

A successful claim emits `Claimed { agreement_id, action, actor, principal }`. `principal` is the first listed principal the actor matched, so an `Ou` principal tells an indexer which OU the actor claimed for. The event only lands if the action completes, because the request must finish in the same transaction.

### Gating other actions

The gate doesn't check which action it guards, or which agreement type. `requirement(principals)` builds the same requirement for any requirement slot of an agreement type built on `agreements`; `tests/any_agreement_tests.move` gates a bid on a test auction this way.

### Reading a gate

`principals_of(requirement)` decodes the principals from a requirement, for example from `AgreementPosted.accept_requirements`, so a client can show who may claim before building the transaction. It aborts with `ENotClaimGate` for a requirement from another rule.

## Dependencies

| Dependency | Why |
|---|---|
| agreements (local) | `Request`, `Requirement` and `Spec`. The gate works on any agreement type's request. |
| roles (local) | `Principal`. |
| delivery_agreements (local) | `Draft`, `ListerCap`, `Terms` and `Config`, for the delivery shortcuts `require_to_claim` and `post_for`, and the end-to-end tests. |
| armature `ae60685` | `armature::ou::OU`. The same revision as roles and armature_vault. |
| multicoin `2772c26` | `Balance`, for `post_for`'s cargo. The same revision as delivery_agreements. |

Only `require_to_claim` and `post_for` need `delivery_agreements`. Sui's package manager has no dev-dependencies, so dropping it would also mean moving the delivery end-to-end tests into a separate test package.

## Build & test

```bash
cd packages/extensions/agreement_roles
sui move build --build-env testnet_stillness
sui move test  --build-env testnet_stillness
```

- `tests/claim_tests.move`: the gate's checks, limits and decoding.
- `tests/flow_tests.move`: whole agreements claimed by OU members and listed players, through delivery and default, including board changes after posting.
- `tests/any_agreement_tests.move`: the same gate on a second agreement type (`tests/test_auction.move`, built only on `agreements`), with live OU boards, and a delivery request that can't complete a bid.
- `tests/test_ou.move`, `tests/test_ledger.move`: test fixtures for an OU and its board, and an observer that reads outcome records.
