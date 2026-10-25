# Delivery agreements: gas and sponsorship

A sponsor pays about **0.0087 SUI net per agreement** that runs to delivery, about 0.0041 SUI for one cancelled before anyone accepted, and about 0.0056 SUI for one that lapses and the config admin closes. The claim gate adds almost nothing net. Storage is nearly all of it: computation is at the 1,000-unit minimum for every user transaction.

Measured with [`scripts/gas_harness.py`](../../scripts/gas_harness.py) on 2026-10-24: Sui 1.73.1 localnet, reference gas price 1,000 MIST, payments in SUI, protocol fees on (0.01 SUI posting fee, 250 bps delivery fee). Rerun it after any contract change.

## How to read the numbers

- **Outlay** = computation + storage: what the gas payer is charged up front.
- **Rebate** = the storage refund for objects a transaction deletes or shrinks. It goes to the gas payer of *that* transaction.
- **Net** = outlay − rebate.

The agreement object holds most of the storage. `post` pays for it, and the transaction that closes the agreement (`deliver`, `default`, `forfeit`, `cancel` or `close_lapsed`) gets most of it back. If TriEx sponsors both ends, the per-agreement net below is its cost. If a user closes an agreement with their own gas, the user gets that rebate instead and TriEx's cost is the post and accept outlay.

What a sponsor keeps paying for:
- the coins sent to the hauler, beneficiary and treasury;
- the `ListerCap` left with the lister after a non-cancel ending;
- 1% of every storage charge, which Sui never refunds.

## Per agreement

| Life | Outlay | Net |
| --- | ---: | ---: |
| post, accept, deliver | 0.024265 SUI | 0.008675 SUI |
| post, accept, default (or forfeit) | 0.021597 SUI | 0.007670 SUI |
| post, cancel | 0.014092 SUI | 0.004077 SUI |
| post, lapse, close_lapsed (admin) | 0.015391 SUI | 0.005640 SUI |
| claim gate (1 player or 1 OU): post_for, accept, deliver | 0.026043 SUI | 0.008693 SUI |
| claim gate via draft + require_to_claim + publish (2 principals) | 0.026545 SUI | 0.008698 SUI |
| claim gate with 32 principals: post_for, accept, deliver | 0.041608 SUI | 0.008849 SUI |

A big gate raises the outlay, because the agreement object holds the principal list, but nearly all of it comes back when the agreement closes.

## Per transaction

| Feature | Who | Outlay | Net |
| --- | --- | ---: | ---: |
| `post` | lister | 0.009436 | 0.006795 |
| `claim::post_for` (1 principal) | lister | 0.010325 | 0.007684 |
| `claim::post_for` (32 principals) | lister | 0.018108 | 0.015467 |
| `accept` | hauler | 0.008197 | 0.002374 |
| accept through a claim gate (player or OU) | hauler | 0.009086 | 0.002383 |
| `deliver` | anyone | 0.006632 | −0.000494 (open) to −0.009079 (32-principal gate) |
| `default` / `forfeit` | anyone / hauler | 0.003964 | −0.001498 |
| `cancel` | lister | 0.004656 | −0.002718 to −0.003598 |
| `close_lapsed` | admin | 0.005955 | −0.001155 |
| config admin (`approve_currency`, fee setters) | admin | 0.004846–0.006046 | 0.000420–0.001675 |

All amounts in SUI. The closing transactions are negative because their rebate is larger than their outlay. Their exact rebate depends on the agreement's size, which grows with its accept requirements. `close_lapsed` gets back less than `cancel` because the lister's `ListerCap` survives it.

Publishing the stack once costs about 0.79 SUI, mostly armature (0.58 SUI) if it is not already on chain.

## Re-pricing for another network

Computation scales with the reference gas price, and storage doesn't, because the storage price is a protocol constant. To estimate on another network:
- multiply the 1,000,000 MIST computation per transaction by that network's reference gas price ÷ 1,000;
- keep the storage and rebate figures as they are.

## Not measured

- Warehouse-receipt deposits and redemptions. These are game-side and need world contracts on chain.
- Observer bindings. No production observer exists yet.
- Creating the OU used by the OU-gated path. This is a one-time setup, not an agreement cost.

## Running it

```bash
python3 scripts/gas_harness.py run          # fresh localnet, publish, measure, write report, stop
python3 scripts/gas_harness.py run --keep   # leave the chain running afterwards
python3 scripts/gas_harness.py reset        # stop and delete .gas-harness/
```

Results go to `.gas-harness/results/gas-report.{md,json}`, with every transaction digest.
