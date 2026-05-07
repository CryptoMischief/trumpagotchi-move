module trumpagotchi::shop;

use std::string::String;
use sui::clock::{Self, Clock};
use sui::coin::{Self, Coin};
use sui::event;
use sui::sui::SUI;
use sui::table::{Self, Table};
use trumpagotchi::trumpagotchi::{Self, AdminCap, TierRegistry};

// ── Errors (200-range — distinct from trumpagotchi.move 0-10 and mint.move 100-102)
const EPaused: u64 = 200;          // shop globally paused
const ENotActive: u64 = 201;       // specific listing soft-disabled
const ESoldOut: u64 = 202;         // listing.stock == 0
const EBelowTierGate: u64 = 203;   // buyer's TierRegistry tier < listing.tier_gate
const EWrongAmount: u64 = 204;     // payment != listing.price_mist
const ENoListing: u64 = 205;       // sku not in shop.listings
const EInvalidKind: u64 = 206;     // kind not in {0, 1, 2}
const EInvalidQty: u64 = 207;      // restock qty == 0

// ── Cosmetic kind sentinels (must match trumpagotchi.move) ────────────────
const KIND_OUTFIT: u8 = 0;
const KIND_BACKGROUND: u8 = 1;
const KIND_SHELL: u8 = 2;

// ── Revenue split (basis points, sum to 10_000) ───────────────────────────
// Same five buckets as mint.move's no-referrer split. Shop sales don't
// carry a referral incentive — buyers are already in the dapp.
const BPS_DENOM: u64 = 10_000;
const BPS_BUY_BURN: u64 = 2_500;
const BPS_LP: u64 = 2_000;
const BPS_VICTORY: u64 = 3_000;
const BPS_PRIZE: u64 = 1_000;
// Dev gets the remainder (~15% + rounding dust).
#[allow(unused_const)]
const BPS_DEV: u64 = 1_500;

// ── Shop config ───────────────────────────────────────────────────────────
// Shared object holding the catalog. Admin manages listings; users read +
// buy. `next_sku` is monotonic so SKUs stay stable across remove + re-add
// operations (the frontend can cache them safely).
public struct Shop has key {
    id: UID,
    next_sku: u64,
    listings: Table<u64, Listing>,
    paused: bool,
    // Same 5 destinations as MintConfig — separate setters so revenue can be
    // routed differently for shop vs mint sales.
    buy_burn: address,
    lp: address,
    victory_vault: address,
    prize_pool: address,
    dev: address,
    total_purchases: u64,
    total_revenue_mist: u64,
}

// Listing template — admin sets these when adding a SKU; on each buy a fresh
// Cosmetic NFT is minted from these params via trumpagotchi::issue_cosmetic.
// Storing a counter rather than pre-minted Cosmetic objects keeps storage
// small and makes restock = `stock += qty`.
public struct Listing has store, copy, drop {
    sku: u64,
    kind: u8,
    name: String,
    tier_gate: u8,
    rarity: u8,
    walrus_identifier_standalone: String,
    equipped_value: String,
    price_mist: u64,
    stock: u64,           // remaining inventory; -1 each buy
    total_minted: u64,    // lifetime sales of this SKU
    active: bool,         // soft-disable without removing the listing
    created_at_ms: u64,
}

// ── Events ────────────────────────────────────────────────────────────────
public struct ShopCreated has copy, drop {
    shop_id: ID,
    timestamp_ms: u64,
}

public struct ListingAdded has copy, drop {
    sku: u64,
    kind: u8,
    name: String,
    tier_gate: u8,
    rarity: u8,
    walrus_identifier_standalone: String,
    equipped_value: String,
    price_mist: u64,
    initial_stock: u64,
    timestamp_ms: u64,
}

public struct ListingRestocked has copy, drop {
    sku: u64,
    qty_added: u64,
    new_stock: u64,
    timestamp_ms: u64,
}

public struct ListingPriceChanged has copy, drop {
    sku: u64,
    old_price_mist: u64,
    new_price_mist: u64,
    timestamp_ms: u64,
}

public struct ListingActiveChanged has copy, drop {
    sku: u64,
    active: bool,
    timestamp_ms: u64,
}

public struct ListingRemoved has copy, drop {
    sku: u64,
    timestamp_ms: u64,
}

public struct CosmeticPurchased has copy, drop {
    sku: u64,
    cosmetic_id: ID,
    kind: u8,
    name: String,
    buyer: address,
    price_paid: u64,
    buy_burn_amt: u64,
    lp_amt: u64,
    victory_amt: u64,
    prize_amt: u64,
    dev_amt: u64,
    new_stock: u64,
    new_total_minted: u64,
    timestamp_ms: u64,
}

public struct ShopAddressesUpdated has copy, drop {
    buy_burn: address,
    lp: address,
    victory_vault: address,
    prize_pool: address,
    dev: address,
}

public struct ShopPausedUpdated has copy, drop { paused: bool }

// ── Create ────────────────────────────────────────────────────────────────
// Sui's upgrade path does not run `init()` for newly-added modules
// (FeatureNotYetSupported). The Shop shared object is therefore created
// post-upgrade by an explicit admin call to `create_shop`. One call is
// enough — the result is a single shared Shop the dapp + admin scripts
// reference forever after.

fun create_shop_internal(ctx: &mut TxContext) {
    let shop = Shop {
        id: object::new(ctx),
        next_sku: 1,
        listings: table::new<u64, Listing>(ctx),
        paused: false,
        buy_burn: ctx.sender(),
        lp: ctx.sender(),
        victory_vault: ctx.sender(),
        prize_pool: ctx.sender(),
        dev: ctx.sender(),
        total_purchases: 0,
        total_revenue_mist: 0,
    };
    let shop_id = object::id(&shop);
    transfer::share_object(shop);
    event::emit(ShopCreated { shop_id, timestamp_ms: 0 });
}

// Manual creation path. Useful as an upgrade fallback or to spin up a
// secondary shop instance (e.g. limited-time event shop). Admin-only.
public fun create_shop(_admin: &AdminCap, ctx: &mut TxContext) {
    create_shop_internal(ctx);
}

// ── Public reads ──────────────────────────────────────────────────────────
public fun next_sku(shop: &Shop): u64 { shop.next_sku }
public fun paused(shop: &Shop): bool { shop.paused }
public fun total_purchases(shop: &Shop): u64 { shop.total_purchases }
public fun total_revenue_mist(shop: &Shop): u64 { shop.total_revenue_mist }
public fun listing_exists(shop: &Shop, sku: u64): bool {
    table::contains(&shop.listings, sku)
}
public fun listing(shop: &Shop, sku: u64): Listing {
    assert!(table::contains(&shop.listings, sku), ENoListing);
    *table::borrow(&shop.listings, sku)
}

public fun listing_sku(l: &Listing): u64 { l.sku }
public fun listing_kind(l: &Listing): u8 { l.kind }
public fun listing_name(l: &Listing): String { l.name }
public fun listing_tier_gate(l: &Listing): u8 { l.tier_gate }
public fun listing_rarity(l: &Listing): u8 { l.rarity }
public fun listing_walrus_standalone(l: &Listing): String {
    l.walrus_identifier_standalone
}
public fun listing_equipped_value(l: &Listing): String { l.equipped_value }
public fun listing_price_mist(l: &Listing): u64 { l.price_mist }
public fun listing_stock(l: &Listing): u64 { l.stock }
public fun listing_total_minted(l: &Listing): u64 { l.total_minted }
public fun listing_active(l: &Listing): bool { l.active }

// ── Admin: catalog management ─────────────────────────────────────────────
// Add a new SKU to the catalog. Returns the assigned sku so the caller can
// reference it later (frontend listing card / restocks / repricing).
//
// `initial_stock` may be 0 — useful to publish a SKU early and restock it
// with a separate transaction once Walrus assets are pinned.
public fun admin_add_listing(
    _admin: &AdminCap,
    shop: &mut Shop,
    kind: u8,
    name: String,
    tier_gate: u8,
    rarity: u8,
    walrus_identifier_standalone: String,
    equipped_value: String,
    price_mist: u64,
    initial_stock: u64,
    clock: &Clock,
): u64 {
    assert!(
        kind == KIND_OUTFIT || kind == KIND_BACKGROUND || kind == KIND_SHELL,
        EInvalidKind,
    );
    let sku = shop.next_sku;
    shop.next_sku = shop.next_sku + 1;

    let now = clock::timestamp_ms(clock);
    let listing = Listing {
        sku,
        kind,
        name,
        tier_gate,
        rarity,
        walrus_identifier_standalone,
        equipped_value,
        price_mist,
        stock: initial_stock,
        total_minted: 0,
        active: true,
        created_at_ms: now,
    };
    table::add(&mut shop.listings, sku, listing);

    event::emit(ListingAdded {
        sku, kind,
        name: listing.name,
        tier_gate, rarity,
        walrus_identifier_standalone: listing.walrus_identifier_standalone,
        equipped_value: listing.equipped_value,
        price_mist, initial_stock,
        timestamp_ms: now,
    });
    sku
}

// Add stock to an existing SKU. qty must be > 0. New listings should use
// admin_add_listing; this is for refilling once stock runs low.
public fun admin_restock(
    _admin: &AdminCap,
    shop: &mut Shop,
    sku: u64,
    qty: u64,
    clock: &Clock,
) {
    assert!(qty > 0, EInvalidQty);
    assert!(table::contains(&shop.listings, sku), ENoListing);
    let l = table::borrow_mut(&mut shop.listings, sku);
    l.stock = l.stock + qty;
    event::emit(ListingRestocked {
        sku, qty_added: qty, new_stock: l.stock,
        timestamp_ms: clock::timestamp_ms(clock),
    });
}

public fun admin_set_price(
    _admin: &AdminCap,
    shop: &mut Shop,
    sku: u64,
    price_mist: u64,
    clock: &Clock,
) {
    assert!(table::contains(&shop.listings, sku), ENoListing);
    let l = table::borrow_mut(&mut shop.listings, sku);
    let old = l.price_mist;
    l.price_mist = price_mist;
    event::emit(ListingPriceChanged {
        sku, old_price_mist: old, new_price_mist: price_mist,
        timestamp_ms: clock::timestamp_ms(clock),
    });
}

// Soft-disable a listing without dropping its SKU. Use this to take a SKU
// offline temporarily; admin_remove_listing for permanent deletion.
public fun admin_set_active(
    _admin: &AdminCap,
    shop: &mut Shop,
    sku: u64,
    active: bool,
    clock: &Clock,
) {
    assert!(table::contains(&shop.listings, sku), ENoListing);
    let l = table::borrow_mut(&mut shop.listings, sku);
    l.active = active;
    event::emit(ListingActiveChanged {
        sku, active,
        timestamp_ms: clock::timestamp_ms(clock),
    });
}

public fun admin_remove_listing(
    _admin: &AdminCap,
    shop: &mut Shop,
    sku: u64,
    clock: &Clock,
) {
    assert!(table::contains(&shop.listings, sku), ENoListing);
    table::remove(&mut shop.listings, sku);
    event::emit(ListingRemoved {
        sku, timestamp_ms: clock::timestamp_ms(clock),
    });
}

public fun admin_set_addresses(
    _admin: &AdminCap,
    shop: &mut Shop,
    buy_burn: address,
    lp: address,
    victory_vault: address,
    prize_pool: address,
    dev: address,
) {
    shop.buy_burn = buy_burn;
    shop.lp = lp;
    shop.victory_vault = victory_vault;
    shop.prize_pool = prize_pool;
    shop.dev = dev;
    event::emit(ShopAddressesUpdated {
        buy_burn, lp, victory_vault, prize_pool, dev,
    });
}

public fun admin_set_paused(
    _admin: &AdminCap,
    shop: &mut Shop,
    paused: bool,
) {
    shop.paused = paused;
    event::emit(ShopPausedUpdated { paused });
}

// ── Public buy ────────────────────────────────────────────────────────────
// Buyer passes a Coin<SUI> of EXACTLY listing.price_mist. Frontend reads the
// listing immediately before tx submit so the price doesn't drift between
// quote and execute.
//
// Tier gate: read from TierRegistry.tier_of(buyer). New wallets without an
// entry default to MIN_TIER (1) per the registry's accessor — they'll fail
// any non-zero gate, which is the correct UX (they need to mint + score).
public fun buy_cosmetic(
    shop: &mut Shop,
    tier_registry: &TierRegistry,
    sku: u64,
    payment: Coin<SUI>,
    clock: &Clock,
    ctx: &mut TxContext,
): ID {
    assert!(!shop.paused, EPaused);
    assert!(table::contains(&shop.listings, sku), ENoListing);

    // Snapshot the listing fields we need before borrowing mutably + before
    // we hand off into issue_cosmetic. Listing is `copy` so this is cheap.
    let l_snapshot = *table::borrow(&shop.listings, sku);
    assert!(l_snapshot.active, ENotActive);
    assert!(l_snapshot.stock > 0, ESoldOut);
    assert!(coin::value(&payment) == l_snapshot.price_mist, EWrongAmount);

    let buyer = ctx.sender();
    let buyer_tier = trumpagotchi::tier_of(tier_registry, buyer);
    assert!(buyer_tier >= l_snapshot.tier_gate, EBelowTierGate);

    // Decrement stock + bump counters before payment + mint, so an event
    // emitted on a panicked tx never lies about state. (Aborts roll back, so
    // this is safe either way; ordering is for clarity.)
    let new_stock;
    let new_total_minted;
    {
        let l = table::borrow_mut(&mut shop.listings, sku);
        l.stock = l.stock - 1;
        l.total_minted = l.total_minted + 1;
        new_stock = l.stock;
        new_total_minted = l.total_minted;
    };
    shop.total_purchases = shop.total_purchases + 1;
    shop.total_revenue_mist = shop.total_revenue_mist + l_snapshot.price_mist;

    // 5-way SUI split. Mint module's pattern, no referrer leg. Dev gets the
    // remainder so any rounding dust ends up in one explicit destination
    // (no trapped sub-mist coins).
    let mut payment = payment;
    let price = l_snapshot.price_mist;
    let buy_burn_amt = price * BPS_BUY_BURN / BPS_DENOM;
    let lp_amt       = price * BPS_LP        / BPS_DENOM;
    let victory_amt  = price * BPS_VICTORY   / BPS_DENOM;
    let prize_amt    = price * BPS_PRIZE     / BPS_DENOM;

    transfer::public_transfer(coin::split(&mut payment, buy_burn_amt, ctx), shop.buy_burn);
    transfer::public_transfer(coin::split(&mut payment, lp_amt,       ctx), shop.lp);
    transfer::public_transfer(coin::split(&mut payment, victory_amt,  ctx), shop.victory_vault);
    transfer::public_transfer(coin::split(&mut payment, prize_amt,    ctx), shop.prize_pool);
    let dev_amt = coin::value(&payment);
    transfer::public_transfer(payment, shop.dev);

    // Mint the Cosmetic via the parent module's package-visible helper.
    let cid = trumpagotchi::issue_cosmetic(
        l_snapshot.kind,
        l_snapshot.name,
        l_snapshot.tier_gate,
        l_snapshot.rarity,
        l_snapshot.walrus_identifier_standalone,
        l_snapshot.equipped_value,
        buyer,
        ctx,
    );

    event::emit(CosmeticPurchased {
        sku,
        cosmetic_id: cid,
        kind: l_snapshot.kind,
        name: l_snapshot.name,
        buyer,
        price_paid: price,
        buy_burn_amt, lp_amt, victory_amt, prize_amt, dev_amt,
        new_stock,
        new_total_minted,
        timestamp_ms: clock::timestamp_ms(clock),
    });

    cid
}

// ── Test helpers ──────────────────────────────────────────────────────────
#[test_only]
public fun init_for_testing(ctx: &mut TxContext) { create_shop_internal(ctx); }

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
