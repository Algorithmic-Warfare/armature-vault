# agreement_roles

A claim gate for agreements built on [`agreements`](../../primitives/agreements), such as [delivery_agreements](../../composites/delivery_agreements): only a listed set of principals may take the gated action, for example accepting a delivery. It depends on no agreement type. Principals come from [`roles`](../../primitives/roles):

- one `player`: reserves the agreement for that player,
- `machine` keys: service or bot keys,
- an `ou`: any current board member of that [armature](https://github.com/loash-industries/armature) OU.

An agreement with no gate is open to anyone.

- [docs/agreements/design.md](../../../docs/agreements/design.md#agreement_roles-who-may-claim): where the gate fits in the agreement design.
- [docs/agreements/user-paths.md](../../../docs/agreements/user-paths.md#l3-limit-who-can-claim): posting a gated agreement, step by step.

## `agreement_roles::claim`

### Listing

`requirement(principals)` builds the gate. Attach it to a delivery draft as an accept requirement, in the same transaction as `draft` and `publish`:

```move
let mut draft = delivery::draft<T, F>(cargo, reward, terms, &config, post_fee, &clock, ctx);
draft.require_to_accept(claim::requirement(vector[acl::ou(haulers_id), acl::player(freelancer)]));
let cap = draft.publish();
```

- **For a DAO that keeps the cap,** draft on terms from `terms::new_for_cap_holder` with an `ou` gate: only the OU's board can claim, and every payout to the lister's side goes to the cap the DAO holds. See [terms](../../composites/delivery_agreements/README.md#delivery_agreementsterms).
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

A successful claim emits `Claimed { agreement_id, action, actor, principal }`. `principal` is the first listed principal the actor matched, so an `Ou` principal tells an indexer which OU the actor claimed for.

**Filter `Claimed` on `action`.** Anyone can open a request for an action type they define, naming any agreement ID, gate it on their own principals and complete it, so a `Claimed` naming a real agreement can come from an unrelated module. For delivery, accept only events whose `action` is `delivery_agreements::delivery::AcceptAction` under delivery's original package ID. Only delivery can open and complete such a request, so each one shares its transaction with that agreement's `AgreementAccepted`.

### Gating other actions

The gate doesn't check which action it guards, or which agreement type. `requirement(principals)` builds the same requirement for any requirement slot of an agreement type built on `agreements`; the tests gate a bid on a test auction this way.

### Reading a gate

`principals_of(requirement)` decodes the principals from a requirement, for example from `AgreementPosted.accept_requirements`, so a client can show who may claim before building the transaction. It aborts with `ENotClaimGate` for a requirement from another rule.

## Dependencies

| Dependency | Why |
|---|---|
| agreements (local) | `Request` and `Requirement`. The gate works on any agreement type's request. |
| roles (local) | `Principal`. |
| armature `ae60685` | `armature::ou::OU`. The same revision as roles and armature_vault. |

It depends on no agreement type, so a new agreement type can use the gate without linking delivery. CI holds it to these three. Its end-to-end tests with delivery agreements live in the unpublished [delivery_claim_tests](../../integration/delivery_claim_tests) package, since Sui's package manager has no dev-dependencies.

## Build & test

```bash
cd packages/extensions/agreement_roles
sui move build --build-env testnet_stillness
sui move test  --build-env testnet_stillness
```

- `tests/claim_tests.move`: the gate on a test auction's bids (`tests/test_auction.move`, built only on `agreements`): every principal, live OU boards, composed gates, the `Claimed` event (including a forged one), limits and decoding.
- `tests/test_ou.move`: a fixture for an OU and its board.

Delivery accepts through the gate, and whole gated agreements through delivery and default, are tested in [delivery_claim_tests](../../integration/delivery_claim_tests).
