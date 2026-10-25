# delivery_claim_tests

Unpublished. End-to-end tests of the [agreement_roles](../../extensions/agreement_roles) claim gate on [delivery_agreements](../../composites/delivery_agreements).

`agreement_roles` gates any agreement type and depends on none of them. Sui's package manager has no dev-dependencies, so tests that need both packages live here instead: a package with only `tests/`, which nothing depends on and which is never published.

## Dependencies

| Dependency | Why |
|---|---|
| agreement_roles (local) | The claim gate under test. |
| delivery_agreements (local) | The agreement type it gates. |
| agreements, roles (local) | `Request`, `Spec` and `Principal`, used directly by the tests. |
| armature `ae60685` | `armature::ou::OU`, as in agreement_roles and roles. |
| multicoin `2772c26` | Cargo and `want` balances, as in agreements and delivery_agreements. |

## Test

```bash
cd packages/integration/delivery_claim_tests
sui move test --build-env testnet_stillness
```

- `tests/accept_gate_tests.move`: a gate attached with `require_to_accept`: what the posted agreement records, terms that pay the cap holder, and that neither `accept` nor `begin_accept` straight into `finish_accept` skips it.
- `tests/flow_tests.move`: whole gated, observed agreements claimed by OU members and listed players, through delivery and default, including board changes after posting, checking every event, balance and outcome record.
- `tests/test_ledger.move`: an observer that reads outcome records. The fee-free drafting and OU fixtures are the dependencies' own `delivery_agreements::test_config` and `agreement_roles::test_ou`: a dependency's `#[test_only]` modules build in test mode too.
