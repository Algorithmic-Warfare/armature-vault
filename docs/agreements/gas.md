# Delivery agreements: gas and sponsorship

A sponsor pays about **0.0087 SUI net per agreement** that runs to delivery (0.0081 SUI if the lister then deletes the spent `ListerCap`, or 0.0082 SUI with terms that pay the cap holder, including `collect`), about 0.0041 SUI for one cancelled before anyone accepted, and about 0.0057 SUI for one that lapses and the config admin closes (0.0051 SUI with terms that pay the cap holder). The claim gate adds almost nothing net. Storage is nearly all of it: computation is at the 1,000-unit minimum for every user transaction.

Measured with [`scripts/gas_harness.py`](../../scripts/gas_harness.py) on 2026-10-24: Sui 1.73.1 localnet, reference gas price 1,000 MIST, payments in SUI, protocol fees on (0.01 SUI posting fee, 250 bps delivery fee). Rerun it after any contract change.

## How to read the numbers

- **Outlay** = computation + storage: what the gas payer is charged up front.
- **Rebate** = the storage refund for objects a transaction deletes or shrinks. It goes to the gas payer of *that* transaction.
- **Net** = outlay − rebate.

The agreement object holds most of the storage. `post` pays for it, and the transaction that closes the agreement (`deliver`, `default`, `forfeit`, `cancel` or `close_lapsed`) gets most of it back. With terms that pay the cap holder, the closing transaction creates a `Proceeds` object for the cap, and `collect` gets that back together with the cap's own storage. If TriEx sponsors both ends, the per-agreement net below is its cost. If a user closes an agreement with their own gas, the user gets that rebate instead and TriEx's cost is the post and accept outlay.

What a sponsor keeps paying for:
- the coins sent to the hauler, beneficiary and treasury;
- the `ListerCap` left with the lister after a non-cancel ending, until they delete it with `delete_cap` (with terms that pay the cap holder, `collect` deletes it);
- 1% of every storage charge, which Sui never refunds.

## Per agreement

| Life | Outlay | Net |
| --- | ---: | ---: |
| post, accept, deliver | 0.024911 SUI | 0.008689 SUI |
| post, accept, deliver, delete_cap | 0.026899 SUI | 0.008141 SUI |
| post, accept, default (or forfeit) | 0.022243 SUI | 0.007684 SUI |
| post, cancel | 0.014418 SUI | 0.004080 SUI |
| post, lapse, close_lapsed (admin) | 0.015718 SUI | 0.005651 SUI |
| cap holder: post, accept, deliver, collect | 0.028966 SUI | 0.008162 SUI |
| cap holder: post, lapse, close_lapsed (admin), collect | 0.020016 SUI | 0.005126 SUI |
| claim gate (1 player or 1 OU): post_for, accept, deliver | 0.026689 SUI | 0.008707 SUI |
| claim gate via draft + require_to_claim + publish (2 principals) | 0.027191 SUI | 0.008712 SUI |
| claim gate with 32 principals: post_for, accept, deliver | 0.042254 SUI | 0.008862 SUI |

A big gate raises the outlay, because the agreement object holds the principal list, but nearly all of it comes back when the agreement closes.

## Per transaction

| Feature | Who | Outlay | Net |
| --- | --- | ---: | ---: |
| `post` | lister | 0.009763 | 0.007122 |
| `post`, terms that pay the cap holder | lister | 0.009520 | 0.006879 |
| `claim::post_for` (1 principal) | lister | 0.010652 | 0.008011 |
| `claim::post_for` (32 principals) | lister | 0.018434 | 0.015793 |
| `accept` | hauler | 0.008516 | 0.002377 |
| accept through a claim gate (player or OU) | hauler | 0.009406 | 0.002386 |
| `deliver` | anyone | 0.006632 | −0.000810 (open) to −0.009395 (32-principal gate) |
| `deliver`, to the cap | anyone | 0.007506 | 0.000305 |
| `default` / `forfeit` | anyone / hauler | 0.003964 | −0.001814 |
| `cancel` | lister | 0.004656 | −0.003041 to −0.003922 |
| `close_lapsed` | admin | 0.005955 | −0.001471 |
| `close_lapsed`, to the cap | admin | 0.005841 | −0.001344 |
| `collect` | cap holder | 0.003668 | −0.001396 (after `deliver`) to −0.000408 (after `close_lapsed`) |
| `delete_cap` | lister | 0.001988 | −0.000548 |
| config admin (`approve_currency`, fee setters) | admin | 0.004846–0.006046 | 0.000420–0.001675 |

All amounts in SUI. The closing transactions are negative because their rebate is larger than their outlay. Their exact rebate depends on the agreement's size, which grows with its accept requirements. `close_lapsed` gets back less than `cancel` because the lister's `ListerCap` survives it; `delete_cap` returns that part later. With terms that pay the cap holder, `deliver` costs a little net because it creates the `Proceeds` instead of sending a balance, and `collect` returns that storage with the cap's.

Publishing the stack once costs about 0.81 SUI, mostly armature (0.58 SUI) if it is not already on chain.

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
