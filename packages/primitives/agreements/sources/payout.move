/// Divide a balance among recipients by basis points.
module agreements::payout;

use multicoin::multicoin::{Self, Balance};

// === Errors ===

#[error(code = 0)]
const EInvalidShares: vector<u8> =
    b"Need one share per recipient, at least one recipient, and shares summing to 10,000 bps";

// === Constants ===

const BPS: u64 = 10_000;

// === Public Functions ===

/// Pay `balance` to `recipients` by `shares` (in bps, summing to 10,000), by
/// largest remainder: each recipient gets the floor of their share, then the
/// units left over go one each to the largest fractional remainders, ties to
/// the earlier recipient. Nobody without a share is paid, and nobody gets more
/// than one unit over their exact share.
public fun pay_by_bps(
    mut balance: Balance,
    shares: vector<u16>,
    recipients: vector<address>,
    ctx: &mut TxContext,
) {
    let n = recipients.length();
    assert!(n > 0 && shares.length() == n, EInvalidShares);
    let mut sum = 0;
    shares.do_ref!(|bps| sum = sum + (*bps as u64));
    assert!(sum == BPS, EInvalidShares);

    let total = multicoin::value(&balance) as u128;
    let mut amounts = vector[];
    let mut remainders = vector[];
    let mut leftover = total;
    shares.do_ref!(|bps| {
        let exact = total * (*bps as u128);
        amounts.push_back(exact / (BPS as u128));
        remainders.push_back(exact % (BPS as u128));
        leftover = leftover - exact / (BPS as u128);
    });
    // `leftover` is the sum of the fractional parts, so it is smaller than the
    // number of nonzero remainders and each round finds one.
    while (leftover > 0) {
        let mut best = 0;
        let mut i = 1;
        while (i < n) {
            if (remainders[i] > remainders[best]) best = i;
            i = i + 1;
        };
        *&mut amounts[best] = amounts[best] + 1;
        *&mut remainders[best] = 0;
        leftover = leftover - 1;
    };
    // The amounts sum to the total, so the last recipient's is what remains.
    let mut i = 0;
    while (i < n - 1) {
        let amount = amounts[i] as u64;
        if (amount > 0) transfer::public_transfer(balance.split(amount, ctx), recipients[i]);
        i = i + 1;
    };
    if (multicoin::value(&balance) == 0) multicoin::destroy_zero(balance)
    else transfer::public_transfer(balance, recipients[n - 1]);
}

public fun bps(): u64 { BPS }
