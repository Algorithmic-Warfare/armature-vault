/// Config-free drafting for tests that are not about the protocol config:
/// agreements paid in `TOKEN`, with no protocol fees. `draft` and `post` take
/// the same arguments as `delivery`'s minus the config and posting fee. Each
/// call drafts against a fresh config that approves `TOKEN` and has no posting
/// fee and 0 bps, pays an empty posting fee, and deletes the config again.
///
/// Also the coin helpers every test shares: minting `TOKEN` and totalling the
/// coins an address owns.
#[test_only]
module delivery_agreements::test_config;

use agreements::spec::Spec;
use delivery_agreements::config;
use delivery_agreements::delivery::{Self, Draft, ListerCap};
use multicoin::multicoin::Balance;
use std::type_name::{Self, TypeName};
use sui::clock::Clock;
use sui::coin::{Self, Coin};
use sui::test_scenario::{Self as ts, Scenario};

/// The coin every test agreement is paid in, unless a test is about
/// currencies.
public struct TOKEN has drop {}

/// The treasury every fee-free agreement records. Nothing is ever paid to it.
const NO_FEE_TREASURY: address = @0xFEE;

public fun treasury(): address { NO_FEE_TREASURY }

/// `TOKEN`'s currency, as agreements and events record it.
public fun token(): TypeName { type_name::with_original_ids<TOKEN>() }

/// A coin of `amount` `TOKEN`.
public fun mint(amount: u64, ctx: &mut TxContext): Coin<TOKEN> {
    coin::mint_for_testing(amount, ctx)
}

/// Total value of the `Coin<T>` objects `owner` holds. Call it in a fresh
/// transaction after the coins were sent.
public fun coins<T>(scenario: &Scenario, owner: address): u64 {
    let mut total = 0;
    ts::ids_for_address<Coin<T>>(owner).do!(|id| {
        let coin = scenario.take_from_address_by_id<Coin<T>>(owner, id);
        total = total + coin.value();
        ts::return_to_address(owner, coin);
    });
    total
}

/// How many `Coin<T>` objects `owner` holds.
public fun coin_count<T>(owner: address): u64 { ts::ids_for_address<Coin<T>>(owner).length() }

/// `delivery::draft` in `TOKEN` against a fee-free config.
public fun draft(
    cargo: Balance,
    reward: Coin<TOKEN>,
    want: Spec,
    collateral: u64,
    accept_by_ms: u64,
    haul_ms: u64,
    beneficiary: address,
    clock: &Clock,
    ctx: &mut TxContext,
): Draft<TOKEN> {
    let mut config = config::new_for_testing(option::none(), 0, NO_FEE_TREASURY, ctx);
    config.approve_for_testing<TOKEN>();
    let draft = delivery::draft(
        cargo, reward, want, collateral, accept_by_ms, haul_ms, beneficiary, &config,
        coin::zero<TOKEN>(ctx), clock, ctx,
    );
    config.destroy_for_testing();
    draft
}

/// `delivery::post` in `TOKEN` against a fee-free config.
public fun post(
    cargo: Balance,
    reward: Coin<TOKEN>,
    want: Spec,
    collateral: u64,
    accept_by_ms: u64,
    haul_ms: u64,
    beneficiary: address,
    clock: &Clock,
    ctx: &mut TxContext,
): ListerCap {
    draft(cargo, reward, want, collateral, accept_by_ms, haul_ms, beneficiary, clock, ctx)
        .publish(ctx)
}
