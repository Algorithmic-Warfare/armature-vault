/// A config with no fees that approves `TOKEN`, for tests that don't exercise
/// the protocol config, and the coin those tests pay in.
#[test_only]
module agreement_roles::test_config;

use delivery_agreements::config::{Self, Config};
use std::type_name::{Self, TypeName};
use sui::coin::{Self, Coin};

/// The coin every agreement here is paid in.
public struct TOKEN has drop {}

/// Treasury of every config made here.
const TREASURY: address = @0xFEE;

public fun treasury(): address { TREASURY }

/// `TOKEN`'s currency, as agreements and events record it.
public fun token(): TypeName { type_name::with_original_ids<TOKEN>() }

/// A coin of `amount` `TOKEN`.
public fun mint(amount: u64, ctx: &mut TxContext): Coin<TOKEN> {
    coin::mint_for_testing(amount, ctx)
}

/// `TOKEN` approved, no posting fee and a 0 bps delivery fee.
public fun no_fees(ctx: &mut TxContext): Config {
    let mut config = config::new_for_testing(option::none(), 0, TREASURY, ctx);
    config.approve_for_testing<TOKEN>();
    config
}

/// The empty posting-fee coin a config with no posting fee expects.
public fun empty(ctx: &mut TxContext): Coin<TOKEN> { coin::zero(ctx) }
