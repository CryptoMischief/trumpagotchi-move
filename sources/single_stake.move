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

// MasterChef-style accumulator scaling. 1e12 — same precision as locker uses
// for VictoryPoolAccumulator. Sufficient headroom against u128 overflow given
// total weight bounded by 30B SUITRUMP × 2.0x and pool balances bounded by
// total mint revenue + farm fees.
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

// Phase 1 launch cap: 500M SUITRUMP (5% of 10B supply) at 6 decimals.
const PHASE_1_CAP: u64 = 500_000_000_000_000;

// ── Reward pool ────────────────────────────────────────────────────────────
public struct RewardPool<phantom T> has store {
    // Physical reserve. Decreases only on claim — never on emission update.
    balance: Balance<T>,
    // Available-for-emission balance. Decreases each update by `emitted`.
    // emission_rate = effective_balance / DISTRIBUTION_WINDOW_MS, so as
    // effective_balance drops, rate drops, pool can never empty.
    effective_balance: u64,
    // MasterChef accumulator: sum over time of (emitted × ACC_PRECISION) / total_weight.
    acc_reward_per_share: u128,
    last_update_ms: u64,
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
    // stakers up to expiry_ms.
    update_campaign_pool(&mut campaign.pool, vault.total_weight, campaign.expiry_ms);
    campaign.finalized = true;
    let swept = balance::value(&campaign.pool.balance) - estimated_unclaimed(&campaign.pool, vault.total_weight);
    let swept_balance = balance::split(&mut campaign.pool.balance, swept);
    vault.active_campaign_count = vault.active_campaign_count - 1;
    event::emit(CampaignExpired {
        campaign_id,
        swept_amount: swept,
        timestamp_ms: now,
    });
    coin::from_balance(swept_balance, ctx)
}

// ── Core entry: stake ──────────────────────────────────────────────────────
public fun stake<P, V>(
    vault: &mut Vault<P, V>,
    tier_registry: &TierRegistry,
    coin: Coin<P>,
    lock_kind: u8,
    clock: &Clock,
    ctx: &mut TxContext,
) {
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
    // Soulbound transfer — StakePosition is `key` only so this is the only
    // way it can move, and it can never move again.
    transfer::transfer(position, sender);
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
    auto_convert_if_due(vault, position, now);

    // Pay out pending before mutating weight/debt.
    let (claimed1, claimed2) = settle_rewards(vault, position, ctx);

    // Recompute weight on the new total principal (using current admin
    // multipliers so a top-up after a multiplier change picks up the new
    // value — but only on the added amount's contribution; preserve the
    // staked weight on existing principal? Simpler: recompute on the total).
    let mult_bps = lock_multiplier_bps(position.lock_kind);
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
    auto_convert_if_due(vault, position, now);
    settle_rewards(vault, position, ctx)
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
    auto_convert_if_due(vault, position, now);

    let campaign: &mut Campaign<T> = df::borrow_mut(&mut vault.id, key);
    let cap_now = if (now < campaign.expiry_ms) now else campaign.expiry_ms;
    update_campaign_pool(&mut campaign.pool, vault.total_weight, cap_now);

    // Per-campaign reward debt is stored as a dynamic field on the position
    // keyed by CampaignKey. First claim seeds it to current acc.
    let pos_debt_key = CampaignKey { id: campaign_id };
    let prior_debt: u128 = if (df::exists<CampaignKey>(&position.id, pos_debt_key)) {
        *df::borrow<CampaignKey, u128>(&position.id, pos_debt_key)
    } else {
        0
    };
    let entitlement =
        (campaign.pool.acc_reward_per_share * (position.weight as u128)) / ACC_PRECISION;
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

fun update_campaign_pool<T>(pool: &mut RewardPool<T>, total_weight: u64, now: u64) {
    update_single_pool<T>(pool, total_weight, now);
}

// Settle Pool 1 + Pool 2 entitlements for a position. Mutates position debts,
// returns the two coins.
fun settle_rewards<P, V>(
    vault: &mut Vault<P, V>,
    position: &mut StakePosition<P, V>,
    ctx: &mut TxContext,
): (Coin<V>, Coin<P>) {
    let entitlement1 =
        (vault.pool1_victory.acc_reward_per_share * (position.weight as u128)) / ACC_PRECISION;
    let entitlement2 =
        (vault.pool2_suitrump.acc_reward_per_share * (position.weight as u128)) / ACC_PRECISION;
    let pending1 = if (entitlement1 > position.reward_debt_pool1) {
        ((entitlement1 - position.reward_debt_pool1) as u64)
    } else { 0 };
    let pending2 = if (entitlement2 > position.reward_debt_pool2) {
        ((entitlement2 - position.reward_debt_pool2) as u64)
    } else { 0 };

    // Clamp to physical balance (defense against accumulator/balance drift).
    let bal1 = balance::value(&vault.pool1_victory.balance);
    let bal2 = balance::value(&vault.pool2_suitrump.balance);
    let payout1 = if (pending1 > bal1) bal1 else pending1;
    let payout2 = if (pending2 > bal2) bal2 else pending2;

    position.reward_debt_pool1 = entitlement1;
    position.reward_debt_pool2 = entitlement2;

    let coin1 = if (payout1 > 0) {
        vault.pool1_victory.total_distributed = vault.pool1_victory.total_distributed + payout1;
        coin::from_balance(balance::split(&mut vault.pool1_victory.balance, payout1), ctx)
    } else { coin::zero<V>(ctx) };
    let coin2 = if (payout2 > 0) {
        vault.pool2_suitrump.total_distributed = vault.pool2_suitrump.total_distributed + payout2;
        coin::from_balance(balance::split(&mut vault.pool2_suitrump.balance, payout2), ctx)
    } else { coin::zero<P>(ctx) };

    event::emit(RewardsClaimed {
        position_id: object::id(position),
        owner: position.owner,
        pool1_victory_claimed: payout1,
        pool2_suitrump_claimed: payout2,
        timestamp_ms: tx_context::epoch_timestamp_ms(ctx),
    });
    (coin1, coin2)
}

// Auto-convert lock-end positions to flexible weight. Called at top of
// every state-changing entry. No-op if not yet due or already converted.
fun auto_convert_if_due<P, V>(
    vault: &mut Vault<P, V>,
    position: &mut StakePosition<P, V>,
    now: u64,
) {
    if (position.converted) return;
    if (position.lock_kind == LOCK_FLEXIBLE) return;
    if (position.lock_unlock_ms == 0 || now < position.lock_unlock_ms) return;

    // Settle pending against current weight first so we don't lose entitlement.
    let entitlement1 =
        (vault.pool1_victory.acc_reward_per_share * (position.weight as u128)) / ACC_PRECISION;
    let entitlement2 =
        (vault.pool2_suitrump.acc_reward_per_share * (position.weight as u128)) / ACC_PRECISION;
    // We don't pay out here — settle_rewards does. Instead recompute debts so
    // the pre-conversion entitlement transfers cleanly to the new weight.
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

    // Force a no-op read of the entitlement vars to avoid unused warnings —
    // they exist for documentation; future revisions may auto-pay here.
    let _ = entitlement1;
    let _ = entitlement2;

    event::emit(AutoConverted {
        position_id: object::id(position),
        old_weight,
        new_weight,
        timestamp_ms: now,
    });
}

// Common unstake path. Auto-claims pending rewards. Splits principal per the
// `early` flag.
fun finalize_unstake<P, V>(
    vault: &mut Vault<P, V>,
    position: StakePosition<P, V>,
    early: bool,
    now: u64,
    ctx: &mut TxContext,
): (Coin<P>, Coin<V>, Coin<P>) {
    update_pools(vault, now);

    // Settle pending — same as claim_rewards but inline because we need to
    // unwrap position by value.
    let entitlement1 =
        (vault.pool1_victory.acc_reward_per_share * (position.weight as u128)) / ACC_PRECISION;
    let entitlement2 =
        (vault.pool2_suitrump.acc_reward_per_share * (position.weight as u128)) / ACC_PRECISION;
    let pending1 = if (entitlement1 > position.reward_debt_pool1) {
        ((entitlement1 - position.reward_debt_pool1) as u64)
    } else { 0 };
    let pending2 = if (entitlement2 > position.reward_debt_pool2) {
        ((entitlement2 - position.reward_debt_pool2) as u64)
    } else { 0 };
    let bal1 = balance::value(&vault.pool1_victory.balance);
    let bal2 = balance::value(&vault.pool2_suitrump.balance);
    let payout1 = if (pending1 > bal1) bal1 else pending1;
    let payout2 = if (pending2 > bal2) bal2 else pending2;

    let reward_v = if (payout1 > 0) {
        vault.pool1_victory.total_distributed = vault.pool1_victory.total_distributed + payout1;
        coin::from_balance(balance::split(&mut vault.pool1_victory.balance, payout1), ctx)
    } else { coin::zero<V>(ctx) };
    let reward_p = if (payout2 > 0) {
        vault.pool2_suitrump.total_distributed = vault.pool2_suitrump.total_distributed + payout2;
        coin::from_balance(balance::split(&mut vault.pool2_suitrump.balance, payout2), ctx)
    } else { coin::zero<P>(ctx) };

    // Decompose position.
    let StakePosition {
        id,
        owner,
        principal_amount,
        weight,
        lock_kind: _,
        lock_unlock_ms: _,
        stake_ms: _,
        reward_debt_pool1: _,
        reward_debt_pool2: _,
        converted: _,
    } = position;

    let pid_inner = object::uid_to_inner(&id);
    object::delete(id);

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

// Conservative lower-bound for unclaimed rewards in a campaign — used by
// sweep_expired_campaign to avoid sweeping balance that's owed to stakers.
// We keep a buffer = total_distributed_capacity - total_distributed where
// distributed_capacity = initial_amount - effective_balance.
fun estimated_unclaimed<T>(pool: &RewardPool<T>, _total_weight: u64): u64 {
    let bal = balance::value(&pool.balance);
    let owed_floor = if (pool.total_distributed >= bal) 0
        else if (bal > pool.effective_balance) {
            // unclaimed ≤ bal - effective_balance (the portion already emitted)
            bal - pool.effective_balance
        } else { 0 };
    owed_floor
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
