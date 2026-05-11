module trumpagotchi::single_stake;

// Single-Stake SUITRUMP vault — Phase 2 v2 spec §2.
//
// One shared `Vault<P, V>` per (principal, victory) pair.
// - P = SUITRUMP coin type (principal). Pool 2 rewards are also paid in P.
// - V = VICTORY coin type (Pool 1 rewards).
// Pool 3 (campaigns) is reward-token-generic via dynamic fields keyed by
// CampaignKey. Each campaign vault stores its own Balance<T>.
//
// Architecture is single-weighted-pool per reward token: ONE accumulator per
// pool, lock multipliers act as share weights only. Self-stabilising emission:
// `emissions_per_second = effective_balance / DISTRIBUTION_WINDOW`.
//
// Visibility: every public entry is `public`, NOT `entry`. None of these
// functions consume `&Random`, so the entry-only-for-randomness rule from
// the Sui security best-practices doesn't apply. PTB composability is
// intentional (e.g. claim+top_up in the same transaction).
//
// Capability pattern: all admin mutations take `&AdminCap` by reference (the
// AdminCap is the trumpagotchi package's existing admin token, defined in
// `trumpagotchi::trumpagotchi`). No address whitelists.
//
// Soulbound positions: StakePosition has `key` only, no `store`. Cannot be
// transferred via `public_transfer`, cannot be wrapped or stored in another
// object. Combined with the explicit `position.owner == sender` check on
// every mutation, this is belt-and-braces against post-stake transfer
// attacks (e.g. stake-then-sell-position, like the StakeReceipt CTF).

use sui::balance::{Self, Balance};
use sui::clock::{Self, Clock};
use sui::coin::{Self, Coin};
use sui::dynamic_field as df;
use sui::event;
use trumpagotchi::trumpagotchi::{Self, AdminCap, TierRegistry};

// ── Errors ─────────────────────────────────────────────────────────────────
// Numeric range 200-249 to stay clear of trumpagotchi.move (0-99) and
// mint.move (100-199).
const ENotGotchiHolder: u64 = 200;
const EBelowMinStake: u64 = 201;
const EBelowMinTopUp: u64 = 202;
const EInvalidLockKind: u64 = 203;
const EVaultPaused: u64 = 204;
const ECapExceeded: u64 = 205;
const EPositionNotMature: u64 = 206;
const EFlexibleHasNoEarlyExit: u64 = 207;
const EWrongOwner: u64 = 208;
const EZeroAmount: u64 = 209;
const ECampaignNotFound: u64 = 211;
const ETooManyActiveCampaigns: u64 = 212;
const ECampaignNotExpired: u64 = 213;
const ECampaignNotFinalized: u64 = 214;
const ERecoveryGraceNotElapsed: u64 = 215;

// ── Lock kinds ─────────────────────────────────────────────────────────────
const LOCK_FLEXIBLE: u8 = 0;
const LOCK_30D: u8 = 1;
const LOCK_90D: u8 = 2;
const LOCK_180D: u8 = 3;

// ── Constants ──────────────────────────────────────────────────────────────
// SUITRUMP has 6 decimals — 10_000 SUITRUMP = 10_000 * 1e6 base units.
const MIN_STAKE_NEW: u64 = 10_000_000_000;
const MIN_STAKE_TOP_UP: u64 = 1_000_000_000;

// 90 days, milliseconds. The single distribution window for the self-stabilising
// emission rule. emission_rate = effective_balance / DISTRIBUTION_WINDOW_MS.
const DISTRIBUTION_WINDOW_MS: u64 = 7_776_000_000;

// MasterChef-style accumulator scaling. 1e12 precision — matches the audited
// SuiDex VictoryPoolAccumulator pattern.
//
// Overflow analysis:
//   acc_reward_per_share grows by `(emitted × ACC_PRECISION) / total_weight`.
//   Worst case for a single update: emitted = pool.balance, total_weight = MIN_STAKE × 1.0x.
//   Pool 2 cap (Phase 1): 100M SUITRUMP = 1e8 × 1e6 = 1e14 raw.
//   1e14 × 1e12 / (1e10) = 1e16. Cumulative over the contract lifetime
//   bounded by total emissions ≤ pool seeds. Acc_reward_per_share remains
//   well within u128 (max ≈ 3.4e38).
//
//   Per-position entitlement: weight × acc / ACC_PRECISION.
//     max weight: cap × 2.0x = 100M × 1e6 × 2 = 2e14.
//     max acc:    1e16 (as above).
//     product:    2e30. Safe in u128.
//
//   Position reward_debt is u128 holding the same product. Same headroom.
const ACC_PRECISION: u128 = 1_000_000_000_000;
const BPS_DENOM: u64 = 10_000;

// Lock multipliers (basis points). Hardcoded — not admin-adjustable.
// Changing rates after launch would require touching every existing position
// to keep reward accounting consistent (otherwise pending rewards drift). If
// rates ever need to change, that's a contract upgrade with a migration step,
// not an ongoing admin function.
const MULT_FLEXIBLE_BPS: u64 = 10_000;  // 1.0x
const MULT_30D_BPS: u64 = 12_500;       // 1.25x
const MULT_90D_BPS: u64 = 16_000;       // 1.6x
const MULT_180D_BPS: u64 = 20_000;      // 2.0x

// Lock durations in ms.
const LOCK_30D_MS: u64 = 2_592_000_000;
const LOCK_90D_MS: u64 = 7_776_000_000;
const LOCK_180D_MS: u64 = 15_552_000_000;

// Pool 3 — bound on concurrent campaigns to keep claim_campaign gas predictable.
const MAX_ACTIVE_CAMPAIGNS: u64 = 5;

// Early-unstake principal forfeit (50%). Forfeit goes to Pool 2 reward bucket.
const EARLY_UNSTAKE_FORFEIT_BPS: u64 = 5_000;

// Grace period after campaign expiry before admin can recover stranded
// residual via recover_stranded_residual. 30 days. Gives stakers a full
// month post-expiry/sweep to notice and claim what F14's floor preserved.
// After this window, anything still in the campaign is treated as
// permanently stranded (positions unstaked without bundling claim_campaign,
// frontend cache races, etc.) and admin reclaims it to prevent
// indefinite partner-token leakage.
const RECOVERY_GRACE_MS: u64 = 2_592_000_000;

// Phase 1 launch cap: 500M SUITRUMP (5% of 10B supply) at 6 decimals.
const PHASE_1_CAP: u64 = 500_000_000_000_000;

// ── Reward pool ────────────────────────────────────────────────────────────
public struct RewardPool<phantom T> has store {
    // INVARIANT: balance ≥ Σ(unclaimed pending) at all times. Decreases only
    // on claim, never on emission update. Increases only on seed_pool* /
    // forfeit deposit / campaign create.
    balance: Balance<T>,
    // INVARIANT: 0 ≤ effective_balance ≤ initial_seeded.
    // Available-for-emission balance. Decreases each update by `emitted`.
    // emission_rate = effective_balance / DISTRIBUTION_WINDOW_MS, so as
    // effective_balance drops, rate drops, pool can never empty (asymptotic).
    effective_balance: u64,
    // INVARIANT: monotonically non-decreasing across update_single_pool calls.
    // MasterChef accumulator: cumulative (emitted × ACC_PRECISION) / total_weight.
    acc_reward_per_share: u128,
    // INVARIANT: monotonically non-decreasing.
    last_update_ms: u64,
    // INVARIANT: ≤ total ever seeded. Increments on every claim by payout amount.
    total_distributed: u64,
}

// ── Campaign vault (Pool 3) ────────────────────────────────────────────────
// Stored as dynamic field on Vault keyed by CampaignKey { id }. Active
// campaigns receive emissions via update_pools while expired campaigns stop
// emitting (caller can sweep remaining balance via admin path).
public struct CampaignKey has copy, drop, store { id: u64 }

public struct Campaign<phantom T> has store {
    id: u64,
    pool: RewardPool<T>,
    start_ms: u64,
    expiry_ms: u64,
    initial_amount: u64,
    finalized: bool,
}

// ── Stake position ─────────────────────────────────────────────────────────
// `key` only (not store) — soulbound. Prevents wallet A from staking under a
// gotchi-held wallet, transferring the position to wallet B (no gotchi), and
// having B unstake. Gotchi is soulbound; positions tied to their original
// staker.
public struct StakePosition<phantom P, phantom V> has key {
    id: UID,
    owner: address,
    // Principal lives in Vault.principal — this is the per-position tally.
    principal_amount: u64,
    // weight = principal_amount * lock_multiplier_bps / BPS_DENOM at stake time.
    // Recomputed on top_up and on auto-convert at lock end.
    weight: u64,
    lock_kind: u8,
    // 0 if Flexible; otherwise stake_ms + lock_duration_ms(lock_kind). After
    // lock_unlock_ms passes the position auto-converts to flexible weight on
    // the next state-changing call (top_up / claim / unstake).
    lock_unlock_ms: u64,
    stake_ms: u64,
    // MasterChef debt — entitlement snapshot at last accounting touchpoint.
    // pending = (weight × acc_reward_per_share / ACC_PRECISION) - reward_debt.
    reward_debt_pool1: u128,
    reward_debt_pool2: u128,
    // Auto-convert flag — set true after first state-change post lock_unlock_ms.
    // Read-only views check both this and current time so frontends can preview
    // post-unlock weight without the user paying gas.
    converted: bool,
}

// ── Vault (shared) ─────────────────────────────────────────────────────────
public struct Vault<phantom P, phantom V> has key {
    id: UID,
    // Principal aggregate — locked tokens, never used for rewards.
    principal: Balance<P>,
    total_locked: u64,
    // Pool 1 (VICTORY) and Pool 2 (SUITRUMP) reward pools.
    pool1_victory: RewardPool<V>,
    pool2_suitrump: RewardPool<P>,
    // Pool 3 — Campaigns stored as dynamic fields keyed by CampaignKey { id }.
    next_campaign_id: u64,
    active_campaign_count: u64,
    // Sum of all live position weights — denominator for emission share calc.
    total_weight: u64,
    // TVL cap. Lowering grandfathers existing stakers — only blocks new
    // deposits. Pause via cap_active = false.
    cap: u64,
    cap_active: bool,
    position_count: u64,
}

// ── Events ─────────────────────────────────────────────────────────────────
public struct Staked has copy, drop {
    position_id: ID,
    owner: address,
    principal: u64,
    lock_kind: u8,
    lock_unlock_ms: u64,
    weight: u64,
    timestamp_ms: u64,
}

public struct ToppedUp has copy, drop {
    position_id: ID,
    added_principal: u64,
    new_total_principal: u64,
    new_weight: u64,
    timestamp_ms: u64,
}

public struct Unstaked has copy, drop {
    position_id: ID,
    owner: address,
    principal_returned: u64,
    principal_forfeited: u64,
    early: bool,
    timestamp_ms: u64,
}

public struct RewardsClaimed has copy, drop {
    position_id: ID,
    owner: address,
    pool1_victory_claimed: u64,
    pool2_suitrump_claimed: u64,
    timestamp_ms: u64,
}

public struct CampaignClaimed has copy, drop {
    position_id: ID,
    owner: address,
    campaign_id: u64,
    amount_claimed: u64,
    timestamp_ms: u64,
}

public struct PoolSeeded has copy, drop {
    pool_kind: u8, // 1 = Pool 1 VICTORY, 2 = Pool 2 SUITRUMP
    amount: u64,
    new_balance: u64,
    new_effective_balance: u64,
    timestamp_ms: u64,
}

public struct CampaignCreated has copy, drop {
    campaign_id: u64,
    expiry_ms: u64,
    amount: u64,
    timestamp_ms: u64,
}

public struct CampaignExpired has copy, drop {
    campaign_id: u64,
    swept_amount: u64,
    timestamp_ms: u64,
}

public struct StrandedResidualRecovered has copy, drop {
    campaign_id: u64,
    amount: u64,
    timestamp_ms: u64,
}

public struct CapUpdated has copy, drop {
    new_cap: u64,
    timestamp_ms: u64,
}

public struct CapPauseToggled has copy, drop {
    cap_active: bool,
    timestamp_ms: u64,
}

public struct AutoConverted has copy, drop {
    position_id: ID,
    old_weight: u64,
    new_weight: u64,
    timestamp_ms: u64,
}

// ── Setup ──────────────────────────────────────────────────────────────────
// Called once after package upgrade publishes this module. Move package
// upgrades don't re-run module init() so creating the shared Vault is admin-
// invoked. Type params P (principal coin) and V (VICTORY coin) are bound at
// call time.
public fun setup_vault<P, V>(
    _admin: &AdminCap,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let now = clock::timestamp_ms(clock);
    let vault = Vault<P, V> {
        id: object::new(ctx),
        principal: balance::zero<P>(),
        total_locked: 0,
        pool1_victory: RewardPool<V> {
            balance: balance::zero<V>(),
            effective_balance: 0,
            acc_reward_per_share: 0,
            last_update_ms: now,
            total_distributed: 0,
        },
        pool2_suitrump: RewardPool<P> {
            balance: balance::zero<P>(),
            effective_balance: 0,
            acc_reward_per_share: 0,
            last_update_ms: now,
            total_distributed: 0,
        },
        next_campaign_id: 0,
        active_campaign_count: 0,
        total_weight: 0,
        cap: PHASE_1_CAP,
        cap_active: true,
        position_count: 0,
    };
    transfer::share_object(vault);
}

// ── Admin ──────────────────────────────────────────────────────────────────
public fun set_vault_cap<P, V>(
    _admin: &AdminCap,
    vault: &mut Vault<P, V>,
    new_cap: u64,
    clock: &Clock,
) {
    vault.cap = new_cap;
    event::emit(CapUpdated { new_cap, timestamp_ms: clock::timestamp_ms(clock) });
}

public fun set_vault_cap_active<P, V>(
    _admin: &AdminCap,
    vault: &mut Vault<P, V>,
    active: bool,
    clock: &Clock,
) {
    vault.cap_active = active;
    event::emit(CapPauseToggled { cap_active: active, timestamp_ms: clock::timestamp_ms(clock) });
}

public fun seed_pool1<P, V>(
    _admin: &AdminCap,
    vault: &mut Vault<P, V>,
    coin: Coin<V>,
    clock: &Clock,
) {
    let amount = coin::value(&coin);
    assert!(amount > 0, EZeroAmount);
    let now = clock::timestamp_ms(clock);
    update_pools(vault, now);
    balance::join(&mut vault.pool1_victory.balance, coin::into_balance(coin));
    vault.pool1_victory.effective_balance = vault.pool1_victory.effective_balance + amount;
    event::emit(PoolSeeded {
        pool_kind: 1,
        amount,
        new_balance: balance::value(&vault.pool1_victory.balance),
        new_effective_balance: vault.pool1_victory.effective_balance,
        timestamp_ms: now,
    });
}

public fun seed_pool2<P, V>(
    _admin: &AdminCap,
    vault: &mut Vault<P, V>,
    coin: Coin<P>,
    clock: &Clock,
) {
    let amount = coin::value(&coin);
    assert!(amount > 0, EZeroAmount);
    let now = clock::timestamp_ms(clock);
    update_pools(vault, now);
    balance::join(&mut vault.pool2_suitrump.balance, coin::into_balance(coin));
    vault.pool2_suitrump.effective_balance = vault.pool2_suitrump.effective_balance + amount;
    event::emit(PoolSeeded {
        pool_kind: 2,
        amount,
        new_balance: balance::value(&vault.pool2_suitrump.balance),
        new_effective_balance: vault.pool2_suitrump.effective_balance,
        timestamp_ms: now,
    });
}

// Pool 3 — create a campaign vault for a partner reward token T.
// Stored as dynamic field on Vault.id keyed by CampaignKey { campaign_id }.
public fun create_campaign<P, V, T>(
    _admin: &AdminCap,
    vault: &mut Vault<P, V>,
    coin: Coin<T>,
    duration_ms: u64,
    clock: &Clock,
) {
    assert!(vault.active_campaign_count < MAX_ACTIVE_CAMPAIGNS, ETooManyActiveCampaigns);
    let amount = coin::value(&coin);
    assert!(amount > 0, EZeroAmount);
    let now = clock::timestamp_ms(clock);
    let id = vault.next_campaign_id;
    vault.next_campaign_id = id + 1;
    vault.active_campaign_count = vault.active_campaign_count + 1;

    let campaign = Campaign<T> {
        id,
        pool: RewardPool<T> {
            balance: coin::into_balance(coin),
            effective_balance: amount,
            acc_reward_per_share: 0,
            last_update_ms: now,
            total_distributed: 0,
        },
        start_ms: now,
        expiry_ms: now + duration_ms,
        initial_amount: amount,
        finalized: false,
    };
    df::add(&mut vault.id, CampaignKey { id }, campaign);
    event::emit(CampaignCreated {
        campaign_id: id,
        expiry_ms: now + duration_ms,
        amount,
        timestamp_ms: now,
    });
}

// Sweep an expired campaign's remaining balance back to admin.
public fun sweep_expired_campaign<P, V, T>(
    _admin: &AdminCap,
    vault: &mut Vault<P, V>,
    campaign_id: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<T> {
    let key = CampaignKey { id: campaign_id };
    assert!(df::exists<CampaignKey>(&vault.id, key), ECampaignNotFound);
    let now = clock::timestamp_ms(clock);
    let campaign: &mut Campaign<T> = df::borrow_mut(&mut vault.id, key);
    assert!(now >= campaign.expiry_ms, ECampaignNotExpired);
    // Final emission update so unclaimed-at-expiry rewards are accounted to
    // stakers up to expiry_ms. Linear release (v11) — pool drains fully by
    // expiry_ms modulo rounding dust preserved by F14 floor.
    let expiry = campaign.expiry_ms;
    update_campaign_pool(campaign, vault.total_weight, expiry);
    campaign.finalized = true;
    let swept = balance::value(&campaign.pool.balance) - unclaimed_emitted_floor(&campaign.pool);
    let swept_balance = balance::split(&mut campaign.pool.balance, swept);
    vault.active_campaign_count = vault.active_campaign_count - 1;
    event::emit(CampaignExpired {
        campaign_id,
        swept_amount: swept,
        timestamp_ms: now,
    });
    coin::from_balance(swept_balance, ctx)
}

// ── Stranded residual recovery (v13) ──────────────────────────────────────
// Closes the partner-token leakage hole created by the F14 + unstake-bundle
// interaction. Background:
//
//   F14 (unclaimed_emitted_floor) was added to keep `sweep_expired_campaign`
//   from over-draining when emissions had accrued to acc that stakers
//   hadn't claimed yet. It preserves `bal - effective` worth of balance in
//   the campaign post-sweep so legitimate stakers can still pull their
//   residual via claim_campaign.
//
//   But if a position is consumed (unstake) WITHOUT the unstake PTB
//   including a claim_campaign call for that campaign — e.g. when the
//   frontend's active-campaign list is stale and skips a new campaign —
//   the position's accrued share remains owed by `acc_reward_per_share` to
//   no one. F14 preserves it, F15 prevents future positions from claiming
//   it (lazy-init locks new positions' debt at current entitlement). The
//   residual becomes permanently stranded.
//
// This function lets the admin reclaim that stranded balance after a
// 30-day grace period (RECOVERY_GRACE_MS) past campaign expiry. Stakers
// get a full month of post-expiry / post-sweep time to notice and claim
// what's legitimately theirs. After that window, anything left is treated
// as forfeit-and-recoverable.
//
// Requires:
//   - campaign exists
//   - campaign.finalized == true (must have been swept first — this is
//     the second-pass cleanup, not a replacement for sweep)
//   - now >= campaign.expiry_ms + RECOVERY_GRACE_MS
//
// Idempotent: subsequent calls return a zero-balance Coin<T>.
public fun recover_stranded_residual<P, V, T>(
    _admin: &AdminCap,
    vault: &mut Vault<P, V>,
    campaign_id: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<T> {
    let key = CampaignKey { id: campaign_id };
    assert!(df::exists<CampaignKey>(&vault.id, key), ECampaignNotFound);
    let campaign: &mut Campaign<T> = df::borrow_mut(&mut vault.id, key);
    assert!(campaign.finalized, ECampaignNotFinalized);
    let now = clock::timestamp_ms(clock);
    assert!(now >= campaign.expiry_ms + RECOVERY_GRACE_MS, ERecoveryGraceNotElapsed);
    let amount = balance::value(&campaign.pool.balance);
    let recovered_balance = balance::split(&mut campaign.pool.balance, amount);
    event::emit(StrandedResidualRecovered {
        campaign_id,
        amount,
        timestamp_ms: now,
    });
    coin::from_balance(recovered_balance, ctx)
}

// ── Core entry: stake ──────────────────────────────────────────────────────
// Convenience entry that creates a position and routes it to the sender in
// one call. Equivalent to:
//   stake_non_entry(...) -> position
//   transfer_position_to_owner(position)
// Frontends that want to atomically initialise per-campaign reward_debt
// (closing the F15 forfeit window) should bypass this and chain the two
// composable variants directly in a single PTB. See module-level doc.
public fun stake<P, V>(
    vault: &mut Vault<P, V>,
    tier_registry: &TierRegistry,
    coin: Coin<P>,
    lock_kind: u8,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let position = stake_non_entry(vault, tier_registry, coin, lock_kind, clock, ctx);
    transfer_position_to_owner(position);
}

// ── Composable variant — returns position by value ────────────────────────
// Mirrors Sui's own `request_add_stake_non_entry` convention: creates and
// returns the StakePosition instead of transferring it, so callers can
// chain it through subsequent PTB commands (e.g. init_campaign_debt for
// every active campaign) before the final transfer.
//
// Same authorisation, validation, and accounting as `stake` — only the
// transfer step is hoisted out. ALL state mutation (principal join, total
// locked/weight/position_count increments, Staked event) happens here so
// every code path observes a consistent vault state.
public fun stake_non_entry<P, V>(
    vault: &mut Vault<P, V>,
    tier_registry: &TierRegistry,
    coin: Coin<P>,
    lock_kind: u8,
    clock: &Clock,
    ctx: &mut TxContext,
): StakePosition<P, V> {
    assert!(vault.cap_active, EVaultPaused);
    assert!(
        lock_kind == LOCK_FLEXIBLE
        || lock_kind == LOCK_30D
        || lock_kind == LOCK_90D
        || lock_kind == LOCK_180D,
        EInvalidLockKind,
    );
    let sender = tx_context::sender(ctx);
    // Gotchi-holder gate. has_entry returns true iff the wallet was seeded in
    // TierRegistry on mint — and Trumpagotchi is soulbound, so the entry
    // never gets stale.
    assert!(trumpagotchi::has_entry(tier_registry, sender), ENotGotchiHolder);

    let amount = coin::value(&coin);
    assert!(amount >= MIN_STAKE_NEW, EBelowMinStake);
    assert!(vault.total_locked + amount <= vault.cap, ECapExceeded);

    let now = clock::timestamp_ms(clock);
    update_pools(vault, now);

    let mult_bps = lock_multiplier_bps(lock_kind);
    let lock_ms = lock_duration_ms(lock_kind);
    let weight = (((amount as u128) * (mult_bps as u128)) / (BPS_DENOM as u128)) as u64;

    let lock_unlock_ms = if (lock_kind == LOCK_FLEXIBLE) 0 else now + lock_ms;

    // Initial reward debt — captures the current accumulator so this position
    // doesn't earn for time before it existed.
    let debt1 = (vault.pool1_victory.acc_reward_per_share * (weight as u128)) / ACC_PRECISION;
    let debt2 = (vault.pool2_suitrump.acc_reward_per_share * (weight as u128)) / ACC_PRECISION;

    balance::join(&mut vault.principal, coin::into_balance(coin));
    vault.total_locked = vault.total_locked + amount;
    vault.total_weight = vault.total_weight + weight;
    vault.position_count = vault.position_count + 1;

    let position = StakePosition<P, V> {
        id: object::new(ctx),
        owner: sender,
        principal_amount: amount,
        weight,
        lock_kind,
        lock_unlock_ms,
        stake_ms: now,
        reward_debt_pool1: debt1,
        reward_debt_pool2: debt2,
        converted: false,
    };
    let pid = object::id(&position);
    event::emit(Staked {
        position_id: pid,
        owner: sender,
        principal: amount,
        lock_kind,
        lock_unlock_ms,
        weight,
        timestamp_ms: now,
    });
    position
}

// ── Soulbound transfer helper ─────────────────────────────────────────────
// Routes a position to its stored owner. Needed because StakePosition is
// `key`-only (intentional — positions are non-transferable once placed)
// which means tx.transferObjects in a PTB cannot consume it (that command
// requires `key + store`). This helper bridges the gap: PTB callers chain
// stake_non_entry → init_campaign_debt(s) → transfer_position_to_owner
// to atomically stake, lock per-campaign debt at entry, and finalise the
// soulbound routing in a single transaction.
//
// No authorisation check: the destination address is whatever was stored
// in `position.owner` at stake time — there is no way for a caller to
// redirect it. Anyone who somehow ends up holding a freshly-returned
// position by value can only send it home.
public fun transfer_position_to_owner<P, V>(position: StakePosition<P, V>) {
    let owner = position.owner;
    transfer::transfer(position, owner);
}

// ── Top-up ─────────────────────────────────────────────────────────────────
// Adds principal to an existing position without changing its lock kind or
// unlock timestamp. Min top-up 1k SUITRUMP. Auto-claims any pending rewards
// in the same call (cleanest accounting — no debt drift).
public fun top_up<P, V>(
    vault: &mut Vault<P, V>,
    position: &mut StakePosition<P, V>,
    coin: Coin<P>,
    clock: &Clock,
    ctx: &mut TxContext,
): (Coin<V>, Coin<P>) {
    assert!(vault.cap_active, EVaultPaused);
    let sender = tx_context::sender(ctx);
    assert!(position.owner == sender, EWrongOwner);
    let added = coin::value(&coin);
    assert!(added >= MIN_STAKE_TOP_UP, EBelowMinTopUp);
    assert!(vault.total_locked + added <= vault.cap, ECapExceeded);

    let now = clock::timestamp_ms(clock);
    update_pools(vault, now);
    auto_convert_if_due(vault, position, now, ctx);

    // Pay out pending before mutating weight/debt.
    let (claimed1, claimed2) = settle_rewards(vault, position, now, ctx);

    // Recompute weight on the new total principal. F13 fix: if the position
    // has been auto-converted (past lock end), use the flexible multiplier
    // — otherwise topping up a converted position would silently re-apply
    // the original lock's multiplier without re-locking the position.
    let mult_bps = if (position.converted) MULT_FLEXIBLE_BPS
        else lock_multiplier_bps(position.lock_kind);
    let new_principal = position.principal_amount + added;
    let new_weight = (((new_principal as u128) * (mult_bps as u128)) / (BPS_DENOM as u128)) as u64;

    balance::join(&mut vault.principal, coin::into_balance(coin));
    vault.total_locked = vault.total_locked + added;
    vault.total_weight = vault.total_weight + new_weight - position.weight;

    position.principal_amount = new_principal;
    position.weight = new_weight;
    position.reward_debt_pool1 =
        (vault.pool1_victory.acc_reward_per_share * (new_weight as u128)) / ACC_PRECISION;
    position.reward_debt_pool2 =
        (vault.pool2_suitrump.acc_reward_per_share * (new_weight as u128)) / ACC_PRECISION;

    event::emit(ToppedUp {
        position_id: object::id(position),
        added_principal: added,
        new_total_principal: new_principal,
        new_weight,
        timestamp_ms: now,
    });

    (claimed1, claimed2)
}

// ── Claim rewards (Pool 1 + Pool 2) ────────────────────────────────────────
// Pool 3 (campaigns) claimed separately via claim_campaign<T> per-campaign
// because each campaign is type-parameterised differently.
public fun claim_rewards<P, V>(
    vault: &mut Vault<P, V>,
    position: &mut StakePosition<P, V>,
    clock: &Clock,
    ctx: &mut TxContext,
): (Coin<V>, Coin<P>) {
    let sender = tx_context::sender(ctx);
    assert!(position.owner == sender, EWrongOwner);
    let now = clock::timestamp_ms(clock);
    update_pools(vault, now);
    auto_convert_if_due(vault, position, now, ctx);
    settle_rewards(vault, position, now, ctx)
}

// Per-campaign claim. Caller must specify the campaign's reward token T.
public fun claim_campaign<P, V, T>(
    vault: &mut Vault<P, V>,
    position: &mut StakePosition<P, V>,
    campaign_id: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<T> {
    let sender = tx_context::sender(ctx);
    assert!(position.owner == sender, EWrongOwner);
    let key = CampaignKey { id: campaign_id };
    assert!(df::exists<CampaignKey>(&vault.id, key), ECampaignNotFound);
    let now = clock::timestamp_ms(clock);
    update_pools(vault, now);
    auto_convert_if_due(vault, position, now, ctx);

    let campaign: &mut Campaign<T> = df::borrow_mut(&mut vault.id, key);
    let cap_now = if (now < campaign.expiry_ms) now else campaign.expiry_ms;
    update_campaign_pool(campaign, vault.total_weight, cap_now);

    // Per-campaign reward debt is stored as a dynamic field on the position
    // keyed by CampaignKey. First encounter:
    //   - Position predates campaign (stake_ms <= campaign.start_ms):
    //     entitled to all emissions from campaign start → prior_debt = 0.
    //   - Position joined after campaign created (stake_ms > start_ms):
    //     NOT entitled to past emissions → prior_debt = current entitlement
    //     so the first claim pays 0 and the position only accrues deltas
    //     from now forward.
    //
    // F15 fix: pre-fix `else 0` let a position that joined long after a
    // campaign was created (or after the campaign was finalized with a
    // residual) drain weight × current_acc / PRECISION on its first
    // claim_campaign — i.e. harvest historical emissions it didn't earn.
    //
    // EDGE CASE — late-joiner forfeit: a position that joins mid-campaign
    // and lets time pass before its first claim_campaign forfeits the
    // emissions between its stake_ms and that first call. Mitigation:
    // the frontend bundles a claim_campaign in every unstake PTB (see
    // buildUnstakeAtMaturityTx / buildUnstakeFlexibleTx /
    // buildUnstakeEarlyTx) which initialises the debt at exit. For longer
    // engagement, callers should call claim_campaign once shortly after
    // stake to lock the entry-point. Move's lack of variadic type-args
    // prevents a stake-time auto-init across all active campaign types.
    let pos_debt_key = CampaignKey { id: campaign_id };
    let entitlement =
        (campaign.pool.acc_reward_per_share * (position.weight as u128)) / ACC_PRECISION;
    let prior_debt: u128 = if (df::exists<CampaignKey>(&position.id, pos_debt_key)) {
        *df::borrow<CampaignKey, u128>(&position.id, pos_debt_key)
    } else if (position.stake_ms <= campaign.start_ms) {
        0
    } else {
        entitlement
    };
    let claimable = if (entitlement > prior_debt) {
        ((entitlement - prior_debt) as u64)
    } else { 0 };

    let pool_bal = balance::value(&campaign.pool.balance);
    let payout = if (claimable > pool_bal) pool_bal else claimable;

    if (df::exists<CampaignKey>(&position.id, pos_debt_key)) {
        let stored: &mut u128 = df::borrow_mut(&mut position.id, pos_debt_key);
        *stored = entitlement;
    } else {
        df::add<CampaignKey, u128>(&mut position.id, pos_debt_key, entitlement);
    };

    let coin_out = if (payout > 0) {
        campaign.pool.total_distributed = campaign.pool.total_distributed + payout;
        let bal = balance::split(&mut campaign.pool.balance, payout);
        coin::from_balance(bal, ctx)
    } else {
        coin::zero<T>(ctx)
    };

    event::emit(CampaignClaimed {
        position_id: object::id(position),
        owner: sender,
        campaign_id,
        amount_claimed: payout,
        timestamp_ms: now,
    });
    coin_out
}

// ── F15 forfeit-window mitigation ─────────────────────────────────────────
// init_campaign_debt locks a position's per-campaign reward_debt at the
// CURRENT accumulator value without paying anything out. It exists to
// close the "between-stake-and-first-claim forfeit" edge case that the
// F15 fix introduces: a position that joins after a campaign has started
// has its prior_debt lazily initialised to current entitlement on first
// claim_campaign — which means any emissions accrued to `acc` between
// stake_ms and that first call are absorbed by the debt and become
// unclaimable. Frontends SHOULD submit a follow-up PTB right after
// `stake` that calls init_campaign_debt for each active campaign,
// shrinking the forfeit window to ~one block.
//
// Idempotent — calling on a position that already has a debt DF entry
// for this campaign is a no-op (existing stored debt is left untouched).
// Same authorisation as claim_campaign (sender must own the position).
//
// Does NOT mutate campaign state beyond running its update_single_pool
// emission tick (needed to compute current acc accurately). Pays no coin.
public fun init_campaign_debt<P, V, T>(
    vault: &mut Vault<P, V>,
    position: &mut StakePosition<P, V>,
    campaign_id: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let sender = tx_context::sender(ctx);
    assert!(position.owner == sender, EWrongOwner);
    let key = CampaignKey { id: campaign_id };
    assert!(df::exists<CampaignKey>(&vault.id, key), ECampaignNotFound);
    let now = clock::timestamp_ms(clock);
    update_pools(vault, now);
    auto_convert_if_due(vault, position, now, ctx);

    let campaign: &mut Campaign<T> = df::borrow_mut(&mut vault.id, key);
    let cap_now = if (now < campaign.expiry_ms) now else campaign.expiry_ms;
    update_campaign_pool(campaign, vault.total_weight, cap_now);

    let pos_debt_key = CampaignKey { id: campaign_id };
    if (df::exists<CampaignKey>(&position.id, pos_debt_key)) return;

    // Mirrors claim_campaign's lazy-init branch: positions predating the
    // campaign get debt = 0 (entitled to whole window); late joiners get
    // debt = current entitlement (no historical drain).
    let initial_debt: u128 = if (position.stake_ms <= campaign.start_ms) {
        0
    } else {
        (campaign.pool.acc_reward_per_share * (position.weight as u128)) / ACC_PRECISION
    };
    df::add<CampaignKey, u128>(&mut position.id, pos_debt_key, initial_debt);
}

// ── Unstake at maturity ────────────────────────────────────────────────────
// 30/90/180 lock at or past lock_unlock_ms. Returns 100% principal + auto-claim.
public fun unstake_at_maturity<P, V>(
    vault: &mut Vault<P, V>,
    position: StakePosition<P, V>,
    clock: &Clock,
    ctx: &mut TxContext,
): (Coin<P>, Coin<V>, Coin<P>) {
    let sender = tx_context::sender(ctx);
    assert!(position.owner == sender, EWrongOwner);
    assert!(position.lock_kind != LOCK_FLEXIBLE, EFlexibleHasNoEarlyExit);
    let now = clock::timestamp_ms(clock);
    assert!(now >= position.lock_unlock_ms, EPositionNotMature);
    finalize_unstake(vault, position, false, now, ctx)
}

// ── Unstake flexible ───────────────────────────────────────────────────────
// 1.0x positions only — no penalty, callable any time.
public fun unstake_flexible<P, V>(
    vault: &mut Vault<P, V>,
    position: StakePosition<P, V>,
    clock: &Clock,
    ctx: &mut TxContext,
): (Coin<P>, Coin<V>, Coin<P>) {
    let sender = tx_context::sender(ctx);
    assert!(position.owner == sender, EWrongOwner);
    assert!(position.lock_kind == LOCK_FLEXIBLE, EInvalidLockKind);
    let now = clock::timestamp_ms(clock);
    finalize_unstake(vault, position, false, now, ctx)
}

// ── Unstake early ──────────────────────────────────────────────────────────
// 30/90/180 lock pre lock_unlock_ms. Returns 50% principal, 50% to Pool 2
// reward bucket. Rewards auto-claimed at full amount (per Phase 2 v2 §2.5
// correction — penalty is on principal, not rewards).
public fun unstake_early<P, V>(
    vault: &mut Vault<P, V>,
    position: StakePosition<P, V>,
    clock: &Clock,
    ctx: &mut TxContext,
): (Coin<P>, Coin<V>, Coin<P>) {
    let sender = tx_context::sender(ctx);
    assert!(position.owner == sender, EWrongOwner);
    assert!(position.lock_kind != LOCK_FLEXIBLE, EFlexibleHasNoEarlyExit);
    let now = clock::timestamp_ms(clock);
    assert!(now < position.lock_unlock_ms, EPositionNotMature);
    finalize_unstake(vault, position, true, now, ctx)
}

// ── Internal helpers ───────────────────────────────────────────────────────
fun update_pools<P, V>(vault: &mut Vault<P, V>, now: u64) {
    update_single_pool<V>(&mut vault.pool1_victory, vault.total_weight, now);
    update_single_pool<P>(&mut vault.pool2_suitrump, vault.total_weight, now);
}

// Pool 3 (partner campaign) emission tick — LINEAR release.
//
// Unlike Pool 1 / Pool 2 which use the self-stabilising rule
// (`emission = effective × dt / DISTRIBUTION_WINDOW_MS`) so the protocol's
// deep reward pools asymptotically empty without ever hitting zero,
// partner campaigns are explicitly bounded: a partner deposits an amount
// X intending it to drain over duration D. Linear release gives constant
// emission rate `X / D`, so the pool reaches dust by `start + D` (modulo
// the rounding floor preserved by F14 on sweep).
//
// Math:
//   emit_rate = initial_amount / duration_ms (raw per ms, constant)
//   emitted_in_dt = initial_amount × dt / duration_ms
//
// Clamped to `effective_balance` so we never over-emit past what has
// actually been deposited (defensive against fp drift in repeated calls).
// Callers MUST pass `now` already capped at `campaign.expiry_ms` so no
// emissions are credited past expiry.
fun update_campaign_pool<T>(campaign: &mut Campaign<T>, total_weight: u64, now: u64) {
    if (now <= campaign.pool.last_update_ms) return;
    if (total_weight == 0 || campaign.pool.effective_balance == 0) {
        campaign.pool.last_update_ms = now;
        return
    };
    let dt_ms = now - campaign.pool.last_update_ms;
    let duration_ms = campaign.expiry_ms - campaign.start_ms;
    let mut emitted_u128 =
        ((campaign.initial_amount as u128) * (dt_ms as u128)) / (duration_ms as u128);
    let eff_u128 = campaign.pool.effective_balance as u128;
    if (emitted_u128 > eff_u128) emitted_u128 = eff_u128;
    if (emitted_u128 == 0) {
        campaign.pool.last_update_ms = now;
        return
    };
    let emitted = (emitted_u128 as u64);
    let acc_delta = (emitted_u128 * ACC_PRECISION) / (total_weight as u128);
    campaign.pool.acc_reward_per_share = campaign.pool.acc_reward_per_share + acc_delta;
    campaign.pool.effective_balance = campaign.pool.effective_balance - emitted;
    campaign.pool.last_update_ms = now;
}

fun update_single_pool<T>(pool: &mut RewardPool<T>, total_weight: u64, now: u64) {
    if (now <= pool.last_update_ms) return;
    if (total_weight == 0 || pool.effective_balance == 0) {
        pool.last_update_ms = now;
        return
    };
    let dt_ms = now - pool.last_update_ms;
    // emitted = effective_balance × dt_ms / DISTRIBUTION_WINDOW_MS, clamped to
    // effective_balance — when dt exceeds the distribution window, the linear
    // approximation overshoots and would underflow the subtraction below.
    // Clamping is safe because effective_balance is the upper bound on what
    // can be emitted.
    let mut emitted_u128 =
        ((pool.effective_balance as u128) * (dt_ms as u128)) / (DISTRIBUTION_WINDOW_MS as u128);
    let eff_u128 = pool.effective_balance as u128;
    if (emitted_u128 > eff_u128) emitted_u128 = eff_u128;
    if (emitted_u128 == 0) {
        pool.last_update_ms = now;
        return
    };
    let emitted = (emitted_u128 as u64);
    let acc_delta = (emitted_u128 * ACC_PRECISION) / (total_weight as u128);
    pool.acc_reward_per_share = pool.acc_reward_per_share + acc_delta;
    pool.effective_balance = pool.effective_balance - emitted;
    pool.last_update_ms = now;
}

// Compute Pool 1 + Pool 2 entitlements for a given weight + prior debts and
// pay them out as coins. Pure helper — does NOT touch any position state, so
// it works in both the by-ref settle path (settle_rewards, top_up_settle) and
// the by-value unstake path (finalize_unstake) where the position has already
// been decomposed.
//
// Returns: (coin_v, coin_p, payout1, payout2, new_debt1, new_debt2).
// Caller is responsible for persisting new_debt1 / new_debt2 if the position
// continues to exist.
//
// INVARIANT: payout ≤ pending ≤ entitlement. The clamp to physical balance
// defends against accumulator / balance drift causing overdraw.
fun pay_pending<P, V>(
    vault: &mut Vault<P, V>,
    weight: u64,
    prior_debt1: u128,
    prior_debt2: u128,
    ctx: &mut TxContext,
): (Coin<V>, Coin<P>, u64, u64, u128, u128) {
    let entitlement1 =
        (vault.pool1_victory.acc_reward_per_share * (weight as u128)) / ACC_PRECISION;
    let entitlement2 =
        (vault.pool2_suitrump.acc_reward_per_share * (weight as u128)) / ACC_PRECISION;
    let pending1 = if (entitlement1 > prior_debt1) {
        ((entitlement1 - prior_debt1) as u64)
    } else { 0 };
    let pending2 = if (entitlement2 > prior_debt2) {
        ((entitlement2 - prior_debt2) as u64)
    } else { 0 };

    // Clamp to physical balance (defense against accumulator/balance drift).
    let bal1 = balance::value(&vault.pool1_victory.balance);
    let bal2 = balance::value(&vault.pool2_suitrump.balance);
    let payout1 = if (pending1 > bal1) bal1 else pending1;
    let payout2 = if (pending2 > bal2) bal2 else pending2;

    let coin1 = if (payout1 > 0) {
        vault.pool1_victory.total_distributed = vault.pool1_victory.total_distributed + payout1;
        coin::from_balance(balance::split(&mut vault.pool1_victory.balance, payout1), ctx)
    } else { coin::zero<V>(ctx) };
    let coin2 = if (payout2 > 0) {
        vault.pool2_suitrump.total_distributed = vault.pool2_suitrump.total_distributed + payout2;
        coin::from_balance(balance::split(&mut vault.pool2_suitrump.balance, payout2), ctx)
    } else { coin::zero<P>(ctx) };

    (coin1, coin2, payout1, payout2, entitlement1, entitlement2)
}

// Settle Pool 1 + Pool 2 entitlements for a position. Persists updated debts
// and emits RewardsClaimed. `now` is threaded in from the caller so the event
// timestamp matches every other event in the same tx.
fun settle_rewards<P, V>(
    vault: &mut Vault<P, V>,
    position: &mut StakePosition<P, V>,
    now: u64,
    ctx: &mut TxContext,
): (Coin<V>, Coin<P>) {
    let (coin1, coin2, payout1, payout2, new_debt1, new_debt2) = pay_pending(
        vault,
        position.weight,
        position.reward_debt_pool1,
        position.reward_debt_pool2,
        ctx,
    );
    position.reward_debt_pool1 = new_debt1;
    position.reward_debt_pool2 = new_debt2;

    event::emit(RewardsClaimed {
        position_id: object::id(position),
        owner: position.owner,
        pool1_victory_claimed: payout1,
        pool2_suitrump_claimed: payout2,
        timestamp_ms: now,
    });
    (coin1, coin2)
}

// Auto-convert lock-end positions to flexible weight. Called at top of
// every state-changing entry. No-op if not yet due or already converted.
//
// Pays out OLD-weight pending Pool 1 + Pool 2 rewards before resetting the
// position's weight + debt. Without this, the user would forfeit all rewards
// accrued at the locked weight from stake-time to lock-end (see F12 in
// AUDIT_READINESS.md). Coins are transferred directly to position.owner since
// the pending unambiguously belongs to them and there's no choice for the
// caller to make.
//
// (Note: `unstake_at_maturity` does not call this function — `finalize_unstake`
// pays pending at the OLD weight via `pay_pending` and consumes the position,
// so the conversion is implicit and the same forfeit hazard does not apply.)
fun auto_convert_if_due<P, V>(
    vault: &mut Vault<P, V>,
    position: &mut StakePosition<P, V>,
    now: u64,
    ctx: &mut TxContext,
) {
    if (position.converted) return;
    if (position.lock_kind == LOCK_FLEXIBLE) return;
    if (position.lock_unlock_ms == 0 || now < position.lock_unlock_ms) return;

    // Pay OLD-weight pending before resetting debt. F12 fix.
    let owner = position.owner;
    let position_id = object::id(position);
    let (coin_v, coin_p, payout1, payout2, _new_debt1, _new_debt2) = pay_pending(
        vault,
        position.weight,
        position.reward_debt_pool1,
        position.reward_debt_pool2,
        ctx,
    );
    transfer::public_transfer(coin_v, owner);
    transfer::public_transfer(coin_p, owner);
    if (payout1 > 0 || payout2 > 0) {
        event::emit(RewardsClaimed {
            position_id,
            owner,
            pool1_victory_claimed: payout1,
            pool2_suitrump_claimed: payout2,
            timestamp_ms: now,
        });
    };

    let new_weight =
        (((position.principal_amount as u128) * (MULT_FLEXIBLE_BPS as u128))
            / (BPS_DENOM as u128)) as u64;

    let old_weight = position.weight;
    vault.total_weight = vault.total_weight + new_weight - old_weight;
    position.weight = new_weight;
    position.reward_debt_pool1 =
        (vault.pool1_victory.acc_reward_per_share * (new_weight as u128)) / ACC_PRECISION;
    position.reward_debt_pool2 =
        (vault.pool2_suitrump.acc_reward_per_share * (new_weight as u128)) / ACC_PRECISION;
    position.converted = true;

    event::emit(AutoConverted {
        position_id,
        old_weight,
        new_weight,
        timestamp_ms: now,
    });
}

// Common unstake path. Auto-claims pending rewards via pay_pending (shared
// with settle_rewards), then splits principal per the `early` flag.
fun finalize_unstake<P, V>(
    vault: &mut Vault<P, V>,
    position: StakePosition<P, V>,
    early: bool,
    now: u64,
    ctx: &mut TxContext,
): (Coin<P>, Coin<V>, Coin<P>) {
    update_pools(vault, now);

    // Decompose position. We need weight + debts as locals to pass to
    // pay_pending (the position is consumed by-value here, so &mut won't work).
    let StakePosition {
        id,
        owner,
        principal_amount,
        weight,
        lock_kind: _,
        lock_unlock_ms: _,
        stake_ms: _,
        reward_debt_pool1,
        reward_debt_pool2,
        converted: _,
    } = position;

    let pid_inner = object::uid_to_inner(&id);
    object::delete(id);

    // Settle pending rewards — same math as settle_rewards. Updated debts are
    // discarded since the position no longer exists.
    let (reward_v, reward_p, payout1, payout2, _new_debt1, _new_debt2) = pay_pending(
        vault,
        weight,
        reward_debt_pool1,
        reward_debt_pool2,
        ctx,
    );

    vault.total_locked = vault.total_locked - principal_amount;
    vault.total_weight = vault.total_weight - weight;
    vault.position_count = vault.position_count - 1;

    let principal_balance = balance::split(&mut vault.principal, principal_amount);

    let (return_amount, forfeited_amount) = if (early) {
        let forfeit =
            (((principal_amount as u128) * (EARLY_UNSTAKE_FORFEIT_BPS as u128))
                / (BPS_DENOM as u128)) as u64;
        (principal_amount - forfeit, forfeit)
    } else {
        (principal_amount, 0)
    };

    let mut principal_balance_mut = principal_balance;
    let to_user = balance::split(&mut principal_balance_mut, return_amount);
    if (forfeited_amount > 0) {
        // Remaining balance = forfeit. Deposit to Pool 2.
        balance::join(&mut vault.pool2_suitrump.balance, principal_balance_mut);
        vault.pool2_suitrump.effective_balance =
            vault.pool2_suitrump.effective_balance + forfeited_amount;
    } else {
        balance::destroy_zero(principal_balance_mut);
    };

    event::emit(Unstaked {
        position_id: pid_inner,
        owner,
        principal_returned: return_amount,
        principal_forfeited: forfeited_amount,
        early,
        timestamp_ms: now,
    });
    event::emit(RewardsClaimed {
        position_id: pid_inner,
        owner,
        pool1_victory_claimed: payout1,
        pool2_suitrump_claimed: payout2,
        timestamp_ms: now,
    });

    (coin::from_balance(to_user, ctx), reward_v, reward_p)
}

fun lock_multiplier_bps(lock_kind: u8): u64 {
    if (lock_kind == LOCK_FLEXIBLE) MULT_FLEXIBLE_BPS
    else if (lock_kind == LOCK_30D) MULT_30D_BPS
    else if (lock_kind == LOCK_90D) MULT_90D_BPS
    else if (lock_kind == LOCK_180D) MULT_180D_BPS
    else 0
}

fun lock_duration_ms(lock_kind: u8): u64 {
    if (lock_kind == LOCK_FLEXIBLE) 0
    else if (lock_kind == LOCK_30D) LOCK_30D_MS
    else if (lock_kind == LOCK_90D) LOCK_90D_MS
    else if (lock_kind == LOCK_180D) LOCK_180D_MS
    else 0
}

// Lower-bound on rewards that have been emitted (added to acc_reward_per_share)
// but not yet claimed by stakers. Used by sweep_expired_campaign to keep the
// owed-but-unclaimed portion in the pool so post-expiry claim_campaign calls
// can still pay the residual.
//
// INVARIANT: 0 ≤ unclaimed_emitted_floor ≤ pool.balance.
//
// Reasoning: balance starts at initial_amount and decreases only via claims.
// effective_balance starts at initial_amount and decreases only via emissions.
// In the clean case `balance ≥ effective_balance` always holds and
// `balance - effective_balance` = (initial - claims) - (initial - emissions)
//                               = emissions - claims = unclaimed-emitted.
//
// Edge case: when `bal ≤ effective_balance` (no emissions have happened OR
// rounding drift), we preserve the FULL balance — sweep takes 0. This is the
// safest behavior because acc_reward_per_share may still be ahead of some
// stakers' reward_debt, so unclaimed residual must remain pull-able. The
// previous `total_distributed`-based guard was dropped: it fired past 50%
// drain (wrong threshold) and short-circuited the floor to 0, draining
// legitimate residual.
fun unclaimed_emitted_floor<T>(pool: &RewardPool<T>): u64 {
    let bal = balance::value(&pool.balance);
    if (bal > pool.effective_balance) bal - pool.effective_balance
    else bal
}

// ── Read-only views ────────────────────────────────────────────────────────
public fun get_vault_status<P, V>(vault: &Vault<P, V>): (u64, u64, bool, u64, u64, u64, u64, u64) {
    (
        vault.total_locked,
        vault.cap,
        vault.cap_active,
        balance::value(&vault.pool1_victory.balance),
        vault.pool1_victory.effective_balance,
        balance::value(&vault.pool2_suitrump.balance),
        vault.pool2_suitrump.effective_balance,
        vault.total_weight,
    )
}

public fun get_position<P, V>(p: &StakePosition<P, V>): (address, u64, u64, u8, u64, u64, bool) {
    (p.owner, p.principal_amount, p.weight, p.lock_kind, p.lock_unlock_ms, p.stake_ms, p.converted)
}

public fun pending_rewards<P, V>(
    vault: &Vault<P, V>,
    position: &StakePosition<P, V>,
    clock: &Clock,
): (u64, u64) {
    // Read-only — does not mutate vault state. We compute a forward emission
    // estimate to give frontends an up-to-date view without paying gas.
    let now = clock::timestamp_ms(clock);
    let acc1 = simulated_acc<V>(&vault.pool1_victory, vault.total_weight, now);
    let acc2 = simulated_acc<P>(&vault.pool2_suitrump, vault.total_weight, now);
    let entitlement1 = (acc1 * (position.weight as u128)) / ACC_PRECISION;
    let entitlement2 = (acc2 * (position.weight as u128)) / ACC_PRECISION;
    let pending1 = if (entitlement1 > position.reward_debt_pool1) {
        ((entitlement1 - position.reward_debt_pool1) as u64)
    } else { 0 };
    let pending2 = if (entitlement2 > position.reward_debt_pool2) {
        ((entitlement2 - position.reward_debt_pool2) as u64)
    } else { 0 };
    (pending1, pending2)
}

fun simulated_acc<T>(pool: &RewardPool<T>, total_weight: u64, now: u64): u128 {
    if (now <= pool.last_update_ms || total_weight == 0 || pool.effective_balance == 0) {
        return pool.acc_reward_per_share
    };
    let dt_ms = now - pool.last_update_ms;
    let mut emitted_u128 =
        ((pool.effective_balance as u128) * (dt_ms as u128)) / (DISTRIBUTION_WINDOW_MS as u128);
    let eff_u128 = pool.effective_balance as u128;
    if (emitted_u128 > eff_u128) emitted_u128 = eff_u128;
    if (emitted_u128 == 0) return pool.acc_reward_per_share;
    let acc_delta = (emitted_u128 * ACC_PRECISION) / (total_weight as u128);
    pool.acc_reward_per_share + acc_delta
}

// Lock kind constants exported for SDK / frontend use.
public fun lock_kind_flexible(): u8 { LOCK_FLEXIBLE }
public fun lock_kind_30d(): u8 { LOCK_30D }
public fun lock_kind_90d(): u8 { LOCK_90D }
public fun lock_kind_180d(): u8 { LOCK_180D }
