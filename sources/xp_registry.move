module trumpagotchi::xp_registry;

// Engagement-layer accumulator. Per Phase 2 v2 spec §3 + §4: XP is the
// engagement axis (separate from PR-based tier). XP earn rates and caps are
// configured off-chain — the contract is dumb about amounts. Backend keeper
// signs PTBs that bundle `record_rally` + `add_xp` (and optionally streak
// bonuses) in a single transaction.
//
// XP does not gate single-stake (Trumpagotchi NFT holder is the only gate),
// does not affect tier, does not decay at launch. Built with decay capability
// so admin can flip on later via `set_xp` overrides if needed.
//
// Why a separate shared object instead of an NFT field: v9 Trumpagotchi NFT
// struct is frozen (Move forbids struct field additions across upgrades).
// Mirroring the TierRegistry pattern keeps XP read/write entirely on the
// admin path without touching user-owned objects.

use std::type_name::{Self, TypeName};
use sui::clock::{Self, Clock};
use sui::coin::{Self, Coin};
use sui::dynamic_field as df;
use sui::event;
use sui::table::{Self, Table};
use trumpagotchi::trumpagotchi::AdminCap;

// ── Defaults (admin-configurable) ──────────────────────────────────────────
const DEFAULT_RALLY_WINDOW_MS: u64 = 86_400_000;     // 24h — between rallies
const DEFAULT_STREAK_BREAK_MS: u64 = 172_800_000;    // 48h — gap that resets streak
const DEFAULT_LOSING_STEAM_MS: u64 = 86_400_000;     // 24h+ since rally = Losing Steam
const DEFAULT_GONE_QUIET_MS: u64 = 345_600_000;      // 96h+ since rally = Gone Quiet

// ── State codes (returned by state_of view) ────────────────────────────────
const STATE_RALLYING: u8 = 0;
const STATE_LOSING_STEAM: u8 = 1;
const STATE_GONE_QUIET: u8 = 2;

// ── Reason codes for XP grants (event indexing — backend resolves to action) ─
const REASON_RALLY: u8 = 1;
const REASON_QUEST_INDIVIDUAL: u8 = 2;
const REASON_QUEST_COMMUNITY: u8 = 3;
const REASON_RAID: u8 = 4;
const REASON_STREAK_BONUS: u8 = 5;
const REASON_ADMIN_GRANT: u8 = 6;
const REASON_OTHER: u8 = 7;

// ── Meal Box (v16) ────────────────────────────────────────────────────────
// Per Phase 2 v2 spec §4.3: when a Trumpagotchi enters Gone Quiet (96h+ no
// rally) the only way to resume earning XP is to buy a McDonalds Meal Box
// from the shop. The buy burns 5,000 SUITRUMP to @0x0 and stamps
// meal_box_at_ms on the buyer's XpEntry so the next rally within
// rally_window forgives the streak break (per spec §4.5).
//
// The expected coin type is stored as a dynamic field on XpRegistry rather
// than as a struct field — Move package upgrades cannot extend existing
// structs. The admin sets it once post-upgrade via admin_set_meal_box_coin
// and can rotate it for the mainnet SUITRUMP type later.
const MEAL_BOX_COIN_KEY: vector<u8> = b"meal_box_coin_type";
const MEAL_BOX_PRICE: u64 = 5_000_000_000; // 5,000 SUITRUMP @ 6 decimals
const BURN_ADDRESS: address = @0x0;

// ── Errors ─────────────────────────────────────────────────────────────────
const ERallyTooSoon: u64 = 1;
const EVecLengthMismatch: u64 = 2;
const EInvalidReasonCode: u64 = 3;
const EZeroAmount: u64 = 4;
const EWrongCoinType: u64 = 5;
const EInsufficientPayment: u64 = 6;
const ENotGoneQuiet: u64 = 7;
const EMealBoxNotInitialized: u64 = 8;

// ── Structs ────────────────────────────────────────────────────────────────
public struct XpRegistry has key {
    id: UID,
    entries: Table<address, XpEntry>,
    rally_window_ms: u64,
    streak_break_ms: u64,
    losing_steam_threshold_ms: u64,
    gone_quiet_threshold_ms: u64,
}

public struct XpEntry has store, copy, drop {
    xp: u64,
    streak: u32,
    longest_streak: u32,
    last_rally_ms: u64,
    total_rallies: u64,
    // 0 = never. Set when user buys McDonalds Meal Box from shop (Track B
    // item 2). If meal_box_at_ms is within rally_window of the next rally,
    // a gap that would normally break the streak is forgiven instead.
    meal_box_at_ms: u64,
    created_at_ms: u64,
}

// ── Events ─────────────────────────────────────────────────────────────────
public struct XpAwarded has copy, drop {
    addr: address,
    amount: u64,
    reason_code: u8,
    new_total: u64,
    timestamp_ms: u64,
}

public struct RallyRecorded has copy, drop {
    addr: address,
    new_streak: u32,
    longest_streak: u32,
    total_rallies: u64,
    streak_was_broken: bool,
    streak_preserved_by_meal_box: bool,
    timestamp_ms: u64,
}

public struct StreakSet has copy, drop {
    addr: address,
    old_streak: u32,
    new_streak: u32,
    reason_code: u8,
    timestamp_ms: u64,
}

public struct MealBoxConsumed has copy, drop {
    addr: address,
    timestamp_ms: u64,
}

// Emitted by buy_meal_box. Distinct from MealBoxConsumed (the admin-path
// event from apply_meal_box) so indexers can tell paid-burns apart from
// admin grants. The off-chain xp-keeper subscribes to neither — meal_box
// is a fire-and-forget on-chain effect now.
public struct MealBoxPurchased has copy, drop {
    buyer: address,
    amount: u64,
    coin_type: TypeName,
    timestamp_ms: u64,
}

public struct MealBoxCoinTypeSet has copy, drop {
    coin_type: TypeName,
    timestamp_ms: u64,
}

public struct XpRegistryConfigUpdated has copy, drop {
    rally_window_ms: u64,
    streak_break_ms: u64,
    losing_steam_threshold_ms: u64,
    gone_quiet_threshold_ms: u64,
    timestamp_ms: u64,
}

public struct XpRegistryCreated has copy, drop {
    registry_id: ID,
}

// ── Create ────────────────────────────────────────────────────────────────
// Sui's upgrade path does not run `init()` for newly-added modules
// (FeatureNotYetSupported). The XpRegistry shared object is therefore
// created post-upgrade by an explicit admin call to `create_registry`. One
// call is enough — the result is a single shared XpRegistry the dapp +
// backend keeper reference forever after.

fun create_registry_internal(ctx: &mut TxContext) {
    let registry = XpRegistry {
        id: object::new(ctx),
        entries: table::new<address, XpEntry>(ctx),
        rally_window_ms: DEFAULT_RALLY_WINDOW_MS,
        streak_break_ms: DEFAULT_STREAK_BREAK_MS,
        losing_steam_threshold_ms: DEFAULT_LOSING_STEAM_MS,
        gone_quiet_threshold_ms: DEFAULT_GONE_QUIET_MS,
    };
    let registry_id = object::id(&registry);
    transfer::share_object(registry);
    event::emit(XpRegistryCreated { registry_id });
}

// Manual creation path. Called once after the package upgrade lands this
// module. Admin-only.
public fun create_registry(_admin: &AdminCap, ctx: &mut TxContext) {
    create_registry_internal(ctx);
}

// ── XP grants ──────────────────────────────────────────────────────────────
// Backend-signed. Amount is resolved off-chain from the action and the
// admin-config table (rally = 200, quest = varies, etc. — see XP_EARN_ENGINE.md).
public fun add_xp(
    _admin: &AdminCap,
    registry: &mut XpRegistry,
    addr: address,
    amount: u64,
    reason_code: u8,
    clock: &Clock,
) {
    assert!(amount > 0, EZeroAmount);
    assert!(
        reason_code >= REASON_RALLY && reason_code <= REASON_OTHER,
        EInvalidReasonCode,
    );
    let now = clock::timestamp_ms(clock);

    ensure_entry(registry, addr, now);

    let entry_ref = table::borrow_mut(&mut registry.entries, addr);
    entry_ref.xp = entry_ref.xp + amount;
    let new_total = entry_ref.xp;

    event::emit(XpAwarded {
        addr,
        amount,
        reason_code,
        new_total,
        timestamp_ms: now,
    });
}

public fun batch_add_xp(
    admin: &AdminCap,
    registry: &mut XpRegistry,
    addrs: vector<address>,
    amounts: vector<u64>,
    reason_codes: vector<u8>,
    clock: &Clock,
) {
    let n = vector::length(&addrs);
    assert!(vector::length(&amounts) == n, EVecLengthMismatch);
    assert!(vector::length(&reason_codes) == n, EVecLengthMismatch);
    let mut i = 0;
    while (i < n) {
        add_xp(
            admin,
            registry,
            *vector::borrow(&addrs, i),
            *vector::borrow(&amounts, i),
            *vector::borrow(&reason_codes, i),
            clock,
        );
        i = i + 1;
    };
}

// Admin override — sets absolute XP value. Emits XpAwarded for positive
// deltas only (negative deltas mean clawback, no event). Useful for: bulk
// migrations, correcting indexer bugs, or enabling decay (admin cron lowers
// XP per the future decay rule).
public fun set_xp(
    _admin: &AdminCap,
    registry: &mut XpRegistry,
    addr: address,
    new_xp: u64,
    clock: &Clock,
) {
    let now = clock::timestamp_ms(clock);
    ensure_entry(registry, addr, now);
    let entry_ref = table::borrow_mut(&mut registry.entries, addr);
    let old = entry_ref.xp;
    entry_ref.xp = new_xp;
    if (new_xp > old) {
        let delta = new_xp - old;
        event::emit(XpAwarded {
            addr,
            amount: delta,
            reason_code: REASON_ADMIN_GRANT,
            new_total: new_xp,
            timestamp_ms: now,
        });
    };
}

// ── Rally ──────────────────────────────────────────────────────────────────
// Streak rule:
//   - First rally ever: streak = 1
//   - Gap > streak_break_ms AND no recent meal_box: reset to 1 (streak broken)
//   - Gap > streak_break_ms WITH meal_box within rally_window: keep + 1 (forgiven)
//   - Gap <= streak_break_ms: increment
public fun record_rally(
    _admin: &AdminCap,
    registry: &mut XpRegistry,
    addr: address,
    clock: &Clock,
) {
    let now = clock::timestamp_ms(clock);
    ensure_entry(registry, addr, now);

    let rally_window = registry.rally_window_ms;
    let streak_break = registry.streak_break_ms;

    let entry_ref = table::borrow_mut(&mut registry.entries, addr);

    // Rate limit: one rally per window. First rally bypasses the check.
    if (entry_ref.total_rallies > 0) {
        assert!(now >= entry_ref.last_rally_ms + rally_window, ERallyTooSoon);
    };

    let mut streak_was_broken = false;
    let mut streak_preserved_by_meal_box = false;

    let new_streak: u32 = if (entry_ref.total_rallies == 0) {
        1
    } else {
        let gap = now - entry_ref.last_rally_ms;
        if (gap > streak_break) {
            let meal_box_active = entry_ref.meal_box_at_ms > 0
                && now >= entry_ref.meal_box_at_ms
                && now - entry_ref.meal_box_at_ms <= rally_window;
            if (meal_box_active) {
                streak_preserved_by_meal_box = true;
                entry_ref.streak + 1
            } else {
                streak_was_broken = true;
                1
            }
        } else {
            entry_ref.streak + 1
        }
    };

    entry_ref.streak = new_streak;
    if (new_streak > entry_ref.longest_streak) {
        entry_ref.longest_streak = new_streak;
    };
    entry_ref.last_rally_ms = now;
    entry_ref.total_rallies = entry_ref.total_rallies + 1;

    let longest = entry_ref.longest_streak;
    let total = entry_ref.total_rallies;

    event::emit(RallyRecorded {
        addr,
        new_streak,
        longest_streak: longest,
        total_rallies: total,
        streak_was_broken,
        streak_preserved_by_meal_box,
        timestamp_ms: now,
    });
}

// Admin override of streak — used by paid streak recovery flow (spec §4.5)
// and any future admin correction. longest_streak is bumped only if needed.
public fun set_streak(
    _admin: &AdminCap,
    registry: &mut XpRegistry,
    addr: address,
    new_streak: u32,
    reason_code: u8,
    clock: &Clock,
) {
    assert!(
        reason_code >= REASON_RALLY && reason_code <= REASON_OTHER,
        EInvalidReasonCode,
    );
    let now = clock::timestamp_ms(clock);
    ensure_entry(registry, addr, now);
    let entry_ref = table::borrow_mut(&mut registry.entries, addr);
    let old = entry_ref.streak;
    entry_ref.streak = new_streak;
    if (new_streak > entry_ref.longest_streak) {
        entry_ref.longest_streak = new_streak;
    };
    event::emit(StreakSet {
        addr,
        old_streak: old,
        new_streak,
        reason_code,
        timestamp_ms: now,
    });
}

// Admin-called by shop module (or its backend mirror) when user purchases
// a McDonalds Meal Box. Sets meal_box_at_ms so the next rally within
// rally_window forgives a streak break. Per spec §4.5.
//
// v16 note: superseded by `buy_meal_box` for normal user flow. Kept for
// upgrade compatibility (we cannot remove public functions) and for admin
// gifting / migration scenarios.
public fun apply_meal_box(
    _admin: &AdminCap,
    registry: &mut XpRegistry,
    addr: address,
    clock: &Clock,
) {
    let now = clock::timestamp_ms(clock);
    ensure_entry(registry, addr, now);
    let entry_ref = table::borrow_mut(&mut registry.entries, addr);
    entry_ref.meal_box_at_ms = now;
    event::emit(MealBoxConsumed { addr, timestamp_ms: now });
}

// ── Meal Box: on-chain user flow (v16) ─────────────────────────────────────
// Direct user-signed buy. The payment coin must match the type stored in
// the MEAL_BOX_COIN_KEY dynamic field (admin-set, rotatable for mainnet
// SUITRUMP). The coin is burned to @0x0 — we do not own the SUITRUMP
// TreasuryCap, so this is the canonical SUITRUMP burn pattern used across
// the ecosystem. Caller must be in Gone Quiet state, preventing accidental
// burns from Rallying / Losing Steam wallets.
//
// Returns the buyer's address to the meal_box state but does NOT count as
// a rally — the user still has to rally once before the streak resumes,
// per spec §4.5. Reads cleanly across the v8 Display.image_url state lookup
// since meal_box_at_ms is on XpEntry which the dapp already polls.
public fun buy_meal_box<T>(
    registry: &mut XpRegistry,
    payment: Coin<T>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let buyer = tx_context::sender(ctx);
    let now = clock::timestamp_ms(clock);

    assert!(
        df::exists(&registry.id, MEAL_BOX_COIN_KEY),
        EMealBoxNotInitialized,
    );
    let expected: &TypeName = df::borrow(&registry.id, MEAL_BOX_COIN_KEY);
    let actual = type_name::with_defining_ids<T>();
    assert!(actual == *expected, EWrongCoinType);

    let amount = coin::value(&payment);
    assert!(amount >= MEAL_BOX_PRICE, EInsufficientPayment);

    assert!(state_of(registry, buyer, clock) == STATE_GONE_QUIET, ENotGoneQuiet);

    transfer::public_transfer(payment, BURN_ADDRESS);

    ensure_entry(registry, buyer, now);
    let entry_ref = table::borrow_mut(&mut registry.entries, buyer);
    entry_ref.meal_box_at_ms = now;

    event::emit(MealBoxPurchased {
        buyer,
        amount,
        coin_type: actual,
        timestamp_ms: now,
    });
}

// Admin: set or rotate the meal-box accepted coin type. Idempotent.
// Must be called once after the v16 upgrade lands to initialize the
// dynamic field — until then buy_meal_box aborts EMealBoxNotInitialized.
public fun admin_set_meal_box_coin<T>(
    _admin: &AdminCap,
    registry: &mut XpRegistry,
    clock: &Clock,
) {
    let new_type = type_name::with_defining_ids<T>();
    if (df::exists(&registry.id, MEAL_BOX_COIN_KEY)) {
        let slot: &mut TypeName = df::borrow_mut(&mut registry.id, MEAL_BOX_COIN_KEY);
        *slot = new_type;
    } else {
        df::add(&mut registry.id, MEAL_BOX_COIN_KEY, new_type);
    };
    event::emit(MealBoxCoinTypeSet {
        coin_type: new_type,
        timestamp_ms: clock::timestamp_ms(clock),
    });
}

// ── Meal Box + Rally bundle (v17, single-signature UX) ────────────────────
// Atomic version of buy_meal_box: in addition to burning SUITRUMP and
// stamping meal_box_at_ms, it also records the rally and grants the 200
// XP that record_rally + add_xp normally award. Single user signature,
// no keeper round-trip, single tx.
//
// Why this is safe without AdminCap: the user paid 5,000 SUITRUMP (burned
// to @0x0) for the privilege. The rally cooldown (rally_window_ms) still
// applies, so a malicious user can't farm XP — at most one rally per
// rally_window per wallet, identical to the keeper-mediated path.
//
// XP_PER_RALLY is hardcoded at 200 per Phase 2 v2 spec §3.1. Changing
// the rally rate requires a package upgrade — by design, the rate is a
// product decision not an admin config.
const XP_PER_RALLY: u64 = 200;

public fun buy_meal_box_and_rally<T>(
    registry: &mut XpRegistry,
    payment: Coin<T>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let buyer = tx_context::sender(ctx);
    let now = clock::timestamp_ms(clock);

    // ── Meal box gate ─────────────────────────────────────────────────────
    assert!(
        df::exists(&registry.id, MEAL_BOX_COIN_KEY),
        EMealBoxNotInitialized,
    );
    let expected: &TypeName = df::borrow(&registry.id, MEAL_BOX_COIN_KEY);
    let actual = type_name::with_defining_ids<T>();
    assert!(actual == *expected, EWrongCoinType);

    let amount = coin::value(&payment);
    assert!(amount >= MEAL_BOX_PRICE, EInsufficientPayment);

    assert!(state_of(registry, buyer, clock) == STATE_GONE_QUIET, ENotGoneQuiet);

    // ── Burn ──────────────────────────────────────────────────────────────
    transfer::public_transfer(payment, BURN_ADDRESS);

    // ── Stamp meal box ────────────────────────────────────────────────────
    ensure_entry(registry, buyer, now);
    let rally_window = registry.rally_window_ms;
    let streak_break = registry.streak_break_ms;
    let entry_ref = table::borrow_mut(&mut registry.entries, buyer);
    entry_ref.meal_box_at_ms = now;

    event::emit(MealBoxPurchased {
        buyer,
        amount,
        coin_type: actual,
        timestamp_ms: now,
    });

    // ── Rally body (inlined from record_rally so we don't need AdminCap)
    //    State == Gone Quiet implies total_rallies > 0 and the rally
    //    cooldown is satisfied (gap >= gone_quiet >= rally_window in any
    //    sane config). Asserting anyway keeps the contract honest.
    assert!(entry_ref.total_rallies > 0, ERallyTooSoon); // defensive
    assert!(now >= entry_ref.last_rally_ms + rally_window, ERallyTooSoon);

    // meal_box was just stamped this same tx, so streak is always preserved
    // when the gap exceeds streak_break. RallyRecorded's streak_was_broken
    // is always false for this code path.
    let gap = now - entry_ref.last_rally_ms;
    let streak_preserved_by_meal_box = gap > streak_break;
    let new_streak: u32 = entry_ref.streak + 1;

    entry_ref.streak = new_streak;
    if (new_streak > entry_ref.longest_streak) {
        entry_ref.longest_streak = new_streak;
    };
    entry_ref.last_rally_ms = now;
    entry_ref.total_rallies = entry_ref.total_rallies + 1;
    entry_ref.xp = entry_ref.xp + XP_PER_RALLY;

    let longest = entry_ref.longest_streak;
    let total = entry_ref.total_rallies;
    let new_total_xp = entry_ref.xp;

    event::emit(RallyRecorded {
        addr: buyer,
        new_streak,
        longest_streak: longest,
        total_rallies: total,
        streak_was_broken: false,
        streak_preserved_by_meal_box,
        timestamp_ms: now,
    });
    event::emit(XpAwarded {
        addr: buyer,
        amount: XP_PER_RALLY,
        reason_code: REASON_RALLY,
        new_total: new_total_xp,
        timestamp_ms: now,
    });
}

// Read-only view: returns the configured meal-box coin TypeName, or None
// if not yet initialized. Frontend uses this to render the correct price
// pill and SUITRUMP type tag in the burn PTB.
public fun meal_box_coin_type(registry: &XpRegistry): std::option::Option<TypeName> {
    if (df::exists(&registry.id, MEAL_BOX_COIN_KEY)) {
        let t: &TypeName = df::borrow(&registry.id, MEAL_BOX_COIN_KEY);
        std::option::some(*t)
    } else {
        std::option::none<TypeName>()
    }
}

public fun meal_box_price(): u64 { MEAL_BOX_PRICE }

// ── Admin config ───────────────────────────────────────────────────────────
public fun set_config(
    _admin: &AdminCap,
    registry: &mut XpRegistry,
    rally_window_ms: u64,
    streak_break_ms: u64,
    losing_steam_threshold_ms: u64,
    gone_quiet_threshold_ms: u64,
    clock: &Clock,
) {
    registry.rally_window_ms = rally_window_ms;
    registry.streak_break_ms = streak_break_ms;
    registry.losing_steam_threshold_ms = losing_steam_threshold_ms;
    registry.gone_quiet_threshold_ms = gone_quiet_threshold_ms;
    event::emit(XpRegistryConfigUpdated {
        rally_window_ms,
        streak_break_ms,
        losing_steam_threshold_ms,
        gone_quiet_threshold_ms,
        timestamp_ms: clock::timestamp_ms(clock),
    });
}

// ── Reads (public) ─────────────────────────────────────────────────────────
public fun xp_of(registry: &XpRegistry, addr: address): u64 {
    if (!table::contains(&registry.entries, addr)) return 0;
    table::borrow(&registry.entries, addr).xp
}

public fun streak_of(registry: &XpRegistry, addr: address): u32 {
    if (!table::contains(&registry.entries, addr)) return 0;
    table::borrow(&registry.entries, addr).streak
}

public fun longest_streak_of(registry: &XpRegistry, addr: address): u32 {
    if (!table::contains(&registry.entries, addr)) return 0;
    table::borrow(&registry.entries, addr).longest_streak
}

public fun last_rally_ms_of(registry: &XpRegistry, addr: address): u64 {
    if (!table::contains(&registry.entries, addr)) return 0;
    table::borrow(&registry.entries, addr).last_rally_ms
}

public fun total_rallies_of(registry: &XpRegistry, addr: address): u64 {
    if (!table::contains(&registry.entries, addr)) return 0;
    table::borrow(&registry.entries, addr).total_rallies
}

public fun meal_box_at_ms_of(registry: &XpRegistry, addr: address): u64 {
    if (!table::contains(&registry.entries, addr)) return 0;
    table::borrow(&registry.entries, addr).meal_box_at_ms
}

public fun entry_of(registry: &XpRegistry, addr: address): XpEntry {
    *table::borrow(&registry.entries, addr)
}

public fun has_entry(registry: &XpRegistry, addr: address): bool {
    table::contains(&registry.entries, addr)
}

// State code: 0 = Rallying, 1 = Losing Steam, 2 = Gone Quiet. Brand-new
// entries with no rallies yet are Rallying.
public fun state_of(registry: &XpRegistry, addr: address, clock: &Clock): u8 {
    if (!table::contains(&registry.entries, addr)) return STATE_RALLYING;
    let entry = table::borrow(&registry.entries, addr);
    if (entry.total_rallies == 0) return STATE_RALLYING;
    let now = clock::timestamp_ms(clock);
    if (now <= entry.last_rally_ms) return STATE_RALLYING;
    let gap = now - entry.last_rally_ms;
    if (gap >= registry.gone_quiet_threshold_ms) STATE_GONE_QUIET
    else if (gap >= registry.losing_steam_threshold_ms) STATE_LOSING_STEAM
    else STATE_RALLYING
}

public fun rally_window_ms(registry: &XpRegistry): u64 { registry.rally_window_ms }
public fun streak_break_ms(registry: &XpRegistry): u64 { registry.streak_break_ms }
public fun losing_steam_threshold_ms(registry: &XpRegistry): u64 { registry.losing_steam_threshold_ms }
public fun gone_quiet_threshold_ms(registry: &XpRegistry): u64 { registry.gone_quiet_threshold_ms }

// XpEntry field accessors (struct fields are not pub)
public fun entry_xp(e: &XpEntry): u64 { e.xp }
public fun entry_streak(e: &XpEntry): u32 { e.streak }
public fun entry_longest_streak(e: &XpEntry): u32 { e.longest_streak }
public fun entry_last_rally_ms(e: &XpEntry): u64 { e.last_rally_ms }
public fun entry_total_rallies(e: &XpEntry): u64 { e.total_rallies }
public fun entry_meal_box_at_ms(e: &XpEntry): u64 { e.meal_box_at_ms }
public fun entry_created_at_ms(e: &XpEntry): u64 { e.created_at_ms }

// State + reason code constants for external (frontend / backend) consumption
public fun state_rallying(): u8 { STATE_RALLYING }
public fun state_losing_steam(): u8 { STATE_LOSING_STEAM }
public fun state_gone_quiet(): u8 { STATE_GONE_QUIET }

public fun reason_rally(): u8 { REASON_RALLY }
public fun reason_quest_individual(): u8 { REASON_QUEST_INDIVIDUAL }
public fun reason_quest_community(): u8 { REASON_QUEST_COMMUNITY }
public fun reason_raid(): u8 { REASON_RAID }
public fun reason_streak_bonus(): u8 { REASON_STREAK_BONUS }
public fun reason_admin_grant(): u8 { REASON_ADMIN_GRANT }
public fun reason_other(): u8 { REASON_OTHER }

// ── Internal ───────────────────────────────────────────────────────────────
fun ensure_entry(registry: &mut XpRegistry, addr: address, now: u64) {
    if (!table::contains(&registry.entries, addr)) {
        let entry = XpEntry {
            xp: 0,
            streak: 0,
            longest_streak: 0,
            last_rally_ms: 0,
            total_rallies: 0,
            meal_box_at_ms: 0,
            created_at_ms: now,
        };
        table::add(&mut registry.entries, addr, entry);
    };
}

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    create_registry_internal(ctx)
}
