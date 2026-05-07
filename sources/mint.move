module trumpagotchi::mint;

use sui::clock::Clock;
use sui::coin::{Self, Coin};
use sui::event;
use sui::sui::SUI;
use trumpagotchi::trumpagotchi::{Self, AdminCap, MintedRegistry, TierRegistry};

// Tier 1 base body identifier — every fresh mint starts here per v8 §3.
// Display template appends "-animated.gif" against the animated quilt.
// Admin can later flip the base identifiers via set_base_identifiers
// when the off-chain identity engine advances tier.
const TIER1_BASE_BODY: vector<u8> = b"Tier1-FakeNews";
const DEFAULT_BASE_BACKGROUND: vector<u8> = b"BlackStars";

// ── Revenue split (basis points, sum to 10_000) ───────────────────────────
// With referrer:    25 + 20 + 30 + 10 +  2.5 + 12.5 = 100
// Without referrer: 25 + 20 + 30 + 10 +  0   + 15.0 = 100
const BPS_DENOM: u64 = 10_000;
const BPS_BUY_BURN: u64 = 2_500;
const BPS_LP: u64 = 2_000;
const BPS_VICTORY: u64 = 3_000;
const BPS_PRIZE: u64 = 1_000;
const BPS_REFERRER: u64 = 250;
// Dev share is computed as the remainder (eats rounding dust). These two
// constants document the spec intent and back the test_only accessors.
#[allow(unused_const)]
const BPS_DEV: u64 = 1_250;
#[allow(unused_const)]
const BPS_DEV_NO_REFERRAL: u64 = 1_500;

// ── Pricing (SUI mist; 1 SUI = 1_000_000_000 mist) ────────────────────────
// Curve: 20 SUI base, +5 SUI every 25 mints, cap 80 SUI from mint #351.
const BASE_PRICE_MIST: u64 = 20_000_000_000;
const PRICE_STEP_MIST: u64 = 5_000_000_000;
const PRICE_STEP_COUNT: u64 = 25;
const PRICE_CAP_MIST: u64 = 80_000_000_000;

// ── Errors ────────────────────────────────────────────────────────────────
// Distinct numeric range from trumpagotchi.move (which uses 0-5).
const EWrongAmount: u64 = 100;
const ESelfReferral: u64 = 101;
const EPaused: u64 = 102;

// ── Shared config (admin-mutable) ─────────────────────────────────────────
public struct MintConfig has key {
    id: UID,
    total_minted: u64,
    paused: bool,
    base_price_mist: u64,
    price_step_mist: u64,
    price_step_count: u64,
    price_cap_mist: u64,
    buy_burn: address,
    lp: address,
    victory_vault: address,
    prize_pool: address,
    dev: address,
}

// ── Events ────────────────────────────────────────────────────────────────
public struct MintPaid has copy, drop {
    nft_id: ID,
    minter: address,
    referrer: Option<address>,
    price_paid: u64,
    buy_burn_amt: u64,
    lp_amt: u64,
    victory_amt: u64,
    prize_amt: u64,
    referrer_amt: u64,
    dev_amt: u64,
    mint_number: u64,
}

public struct AddressesUpdated has copy, drop {
    buy_burn: address,
    lp: address,
    victory_vault: address,
    prize_pool: address,
    dev: address,
}

public struct PricingUpdated has copy, drop {
    base_price_mist: u64,
    price_step_mist: u64,
    price_step_count: u64,
    price_cap_mist: u64,
}

public struct PausedUpdated has copy, drop { paused: bool }

// ── Init ──────────────────────────────────────────────────────────────────
// Creates the shared MintConfig with deployer as every destination. Admin
// must call `set_addresses` post-publish to set the real treasury wallets.
fun init(ctx: &mut TxContext) {
    let cfg = MintConfig {
        id: object::new(ctx),
        total_minted: 0,
        paused: false,
        base_price_mist: BASE_PRICE_MIST,
        price_step_mist: PRICE_STEP_MIST,
        price_step_count: PRICE_STEP_COUNT,
        price_cap_mist: PRICE_CAP_MIST,
        buy_burn: ctx.sender(),
        lp: ctx.sender(),
        victory_vault: ctx.sender(),
        prize_pool: ctx.sender(),
        dev: ctx.sender(),
    };
    transfer::share_object(cfg);
}

// ── Read helpers ──────────────────────────────────────────────────────────
public fun current_price_mist(cfg: &MintConfig): u64 {
    let step = cfg.total_minted / cfg.price_step_count;
    let p = cfg.base_price_mist + step * cfg.price_step_mist;
    if (p > cfg.price_cap_mist) cfg.price_cap_mist else p
}

public fun total_minted(cfg: &MintConfig): u64 { cfg.total_minted }
public fun paused(cfg: &MintConfig): bool { cfg.paused }
public fun addresses(cfg: &MintConfig): (address, address, address, address, address) {
    (cfg.buy_burn, cfg.lp, cfg.victory_vault, cfg.prize_pool, cfg.dev)
}

// ── Public mint ───────────────────────────────────────────────────────────
// Caller passes a Coin<SUI> of EXACTLY the current price (compute via
// `current_price_mist`). Frontend must read price + supply consistently
// because price changes every 25 mints.
//
// Split order (with referrer present):
//   25%  → buy_burn
//   20%  → lp
//   30%  → victory_vault
//   10%  → prize_pool
//   2.5% → referrer (must not be sender)
//   ~12.5% → dev (gets the dust from integer division)
//
// Split without referrer: same first 4 buckets, then ~15% to dev.
public fun mint(
    cfg: &mut MintConfig,
    minted_registry: &mut MintedRegistry,
    tier_registry: &mut TierRegistry,
    payment: Coin<SUI>,
    referrer: Option<address>,
    clock: &Clock,
    ctx: &mut TxContext,
): ID {
    assert!(!cfg.paused, EPaused);
    let price = current_price_mist(cfg);
    assert!(coin::value(&payment) == price, EWrongAmount);

    let has_ref = option::is_some(&referrer);
    if (has_ref) {
        let r = *option::borrow(&referrer);
        assert!(r != ctx.sender(), ESelfReferral);
    };

    cfg.total_minted = cfg.total_minted + 1;
    let mint_number = cfg.total_minted;

    let mut payment = payment;
    let buy_burn_amt = price * BPS_BUY_BURN / BPS_DENOM;
    let lp_amt       = price * BPS_LP        / BPS_DENOM;
    let victory_amt  = price * BPS_VICTORY   / BPS_DENOM;
    let prize_amt    = price * BPS_PRIZE     / BPS_DENOM;

    transfer::public_transfer(coin::split(&mut payment, buy_burn_amt, ctx), cfg.buy_burn);
    transfer::public_transfer(coin::split(&mut payment, lp_amt,       ctx), cfg.lp);
    transfer::public_transfer(coin::split(&mut payment, victory_amt,  ctx), cfg.victory_vault);
    transfer::public_transfer(coin::split(&mut payment, prize_amt,    ctx), cfg.prize_pool);

    let referrer_amt = if (has_ref) {
        let amt = price * BPS_REFERRER / BPS_DENOM;
        transfer::public_transfer(
            coin::split(&mut payment, amt, ctx),
            *option::borrow(&referrer),
        );
        amt
    } else {
        0
    };

    // Dev sweeps the remainder. Math: with referrer this is ~12.5% of price
    // plus any rounding dust (max a few mist); without, ~15%. Keeps the
    // function exact and prevents a stuck partial coin.
    let dev_amt = coin::value(&payment);
    transfer::public_transfer(payment, cfg.dev);

    let nft_id = trumpagotchi::mint_to(
        minted_registry,
        tier_registry,
        ctx.sender(),
        referrer,
        TIER1_BASE_BODY.to_string(),
        DEFAULT_BASE_BACKGROUND.to_string(),
        clock,
        ctx,
    );

    event::emit(MintPaid {
        nft_id,
        minter: ctx.sender(),
        referrer,
        price_paid: price,
        buy_burn_amt,
        lp_amt,
        victory_amt,
        prize_amt,
        referrer_amt,
        dev_amt,
        mint_number,
    });

    nft_id
}

// ── Admin ─────────────────────────────────────────────────────────────────
public fun set_addresses(
    _admin: &AdminCap,
    cfg: &mut MintConfig,
    buy_burn: address,
    lp: address,
    victory_vault: address,
    prize_pool: address,
    dev: address,
) {
    cfg.buy_burn = buy_burn;
    cfg.lp = lp;
    cfg.victory_vault = victory_vault;
    cfg.prize_pool = prize_pool;
    cfg.dev = dev;
    event::emit(AddressesUpdated { buy_burn, lp, victory_vault, prize_pool, dev });
}

public fun set_pricing(
    _admin: &AdminCap,
    cfg: &mut MintConfig,
    base_price_mist: u64,
    price_step_mist: u64,
    price_step_count: u64,
    price_cap_mist: u64,
) {
    assert!(price_step_count > 0, EWrongAmount);
    cfg.base_price_mist = base_price_mist;
    cfg.price_step_mist = price_step_mist;
    cfg.price_step_count = price_step_count;
    cfg.price_cap_mist = price_cap_mist;
    event::emit(PricingUpdated { base_price_mist, price_step_mist, price_step_count, price_cap_mist });
}

public fun set_paused(_admin: &AdminCap, cfg: &mut MintConfig, paused: bool) {
    cfg.paused = paused;
    event::emit(PausedUpdated { paused });
}

// ── Test helpers ──────────────────────────────────────────────────────────
#[test_only]
public fun init_for_testing(ctx: &mut TxContext) { init(ctx); }

#[test_only]
public fun bps_referrer(): u64 { BPS_REFERRER }
#[test_only]
public fun bps_dev_with_ref(): u64 { BPS_DEV }
#[test_only]
public fun bps_dev_no_ref(): u64 { BPS_DEV_NO_REFERRAL }
#[test_only]
public fun bps_buy_burn(): u64 { BPS_BUY_BURN }
#[test_only]
public fun bps_lp(): u64 { BPS_LP }
#[test_only]
public fun bps_victory(): u64 { BPS_VICTORY }
#[test_only]
public fun bps_prize(): u64 { BPS_PRIZE }
#[test_only]
public fun bps_denom(): u64 { BPS_DENOM }
