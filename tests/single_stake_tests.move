#[test_only]
module trumpagotchi::single_stake_tests;

use std::string;
use std::unit_test::assert_eq;
use sui::clock::{Self, Clock};
use sui::coin::{Self, Coin};
use sui::test_scenario as ts;
use std::unit_test::destroy;
use trumpagotchi::single_stake::{Self, Vault, StakePosition};
use trumpagotchi::trumpagotchi::{Self, AdminCap, TierRegistry};

// Test reward and principal coin types.
public struct TEST_SUITRUMP has drop {}
public struct TEST_VICTORY has drop {}
public struct TEST_CAMPAIGN has drop {}

const ADMIN: address = @0xA;
const ALICE: address = @0xA11CE;
const BOB: address = @0xB0B;
const CAROL: address = @0xCA401; // intentionally NOT seeded — non-gotchi-holder

// SUITRUMP has 6 decimals.
const D6: u64 = 1_000_000;
const STAKE_10K: u64 = 10_000 * 1_000_000;
const STAKE_50K: u64 = 50_000 * 1_000_000;
const TOP_UP_1K: u64 = 1_000 * 1_000_000;
const SEED_1M: u64 = 1_000_000 * 1_000_000;

// Lock kind constants (mirrored from single_stake.move).
const LOCK_FLEXIBLE: u8 = 0;
const LOCK_30D: u8 = 1;
const LOCK_90D: u8 = 2;
const LOCK_180D: u8 = 3;

// Time constants.
const ONE_DAY_MS: u64 = 86_400_000;
const THIRTY_DAYS_MS: u64 = 2_592_000_000;
const NINETY_DAYS_MS: u64 = 7_776_000_000;
const ONE_HUNDRED_EIGHTY_DAYS_MS: u64 = 15_552_000_000;

// ── Bootstrap ──────────────────────────────────────────────────────────────
// Inits trumpagotchi (creating AdminCap + TierRegistry), seeds tier entries
// for ALICE and BOB so they pass the gotchi-holder gate, and sets up a Clock.
// Caller is responsible for calling end_scenario(sc, clk).
fun bootstrap(): (ts::Scenario, Clock) {
    let mut sc = ts::begin(ADMIN);
    trumpagotchi::init_for_testing(sc.ctx());

    // Seed gotchi-holder TierEntries for ALICE + BOB.
    sc.next_tx(ADMIN);
    let admin = sc.take_from_sender<AdminCap>();
    let mut tier = sc.take_shared<TierRegistry>();
    let clk = clock::create_for_testing(sc.ctx());
    trumpagotchi::set_tier(
        &admin, &mut tier, ALICE, 1, 0,
        string::utf8(b"Tier1-FakeNews"),
        string::utf8(b"BlackStars"),
        &clk,
    );
    trumpagotchi::set_tier(
        &admin, &mut tier, BOB, 1, 0,
        string::utf8(b"Tier1-FakeNews"),
        string::utf8(b"BlackStars"),
        &clk,
    );
    ts::return_shared(tier);

    // Set up the Vault as ADMIN.
    single_stake::setup_vault<TEST_SUITRUMP, TEST_VICTORY>(&admin, &clk, sc.ctx());
    sc.return_to_sender(admin);

    (sc, clk)
}

fun end_scenario(sc: ts::Scenario, clk: Clock) {
    clock::destroy_for_testing(clk);
    sc.end();
}

fun mint_p(amount: u64, ctx: &mut TxContext): Coin<TEST_SUITRUMP> {
    coin::mint_for_testing<TEST_SUITRUMP>(amount, ctx)
}

fun mint_v(amount: u64, ctx: &mut TxContext): Coin<TEST_VICTORY> {
    coin::mint_for_testing<TEST_VICTORY>(amount, ctx)
}

fun seed_pool1(sc: &mut ts::Scenario, clk: &Clock, amount: u64) {
    sc.next_tx(ADMIN);
    let admin = sc.take_from_sender<AdminCap>();
    let mut vault = sc.take_shared<Vault<TEST_SUITRUMP, TEST_VICTORY>>();
    let coin = mint_v(amount, sc.ctx());
    single_stake::seed_pool1(&admin, &mut vault, coin, clk);
    ts::return_shared(vault);
    sc.return_to_sender(admin);
}

fun seed_pool2(sc: &mut ts::Scenario, clk: &Clock, amount: u64) {
    sc.next_tx(ADMIN);
    let admin = sc.take_from_sender<AdminCap>();
    let mut vault = sc.take_shared<Vault<TEST_SUITRUMP, TEST_VICTORY>>();
    let coin = mint_p(amount, sc.ctx());
    single_stake::seed_pool2(&admin, &mut vault, coin, clk);
    ts::return_shared(vault);
    sc.return_to_sender(admin);
}

// Stake helper: as `who`, stakes `amount` with `lock_kind`. Position is
// transferred to `who`'s inventory.
fun do_stake(sc: &mut ts::Scenario, clk: &Clock, who: address, amount: u64, lock_kind: u8) {
    sc.next_tx(who);
    let mut vault = sc.take_shared<Vault<TEST_SUITRUMP, TEST_VICTORY>>();
    let tier = sc.take_shared<TierRegistry>();
    let coin = mint_p(amount, sc.ctx());
    single_stake::stake(&mut vault, &tier, coin, lock_kind, clk, sc.ctx());
    ts::return_shared(vault);
    ts::return_shared(tier);
}

// ── Setup correctness ─────────────────────────────────────────────────────
#[test]
fun test_setup_creates_shared_vault_with_initial_state() {
    let (mut sc, clk) = bootstrap();
    sc.next_tx(ADMIN);
    let vault = sc.take_shared<Vault<TEST_SUITRUMP, TEST_VICTORY>>();
    let (
        total_locked,
        cap,
        cap_active,
        pool1_bal,
        pool1_eff,
        pool2_bal,
        pool2_eff,
        total_weight,
    ) = single_stake::get_vault_status(&vault);
    assert_eq!(total_locked, 0);
    assert!(cap > 0);
    assert!(cap_active);
    assert_eq!(pool1_bal, 0);
    assert_eq!(pool1_eff, 0);
    assert_eq!(pool2_bal, 0);
    assert_eq!(pool2_eff, 0);
    assert_eq!(total_weight, 0);
    ts::return_shared(vault);
    end_scenario(sc, clk);
}

// ── Gating ─────────────────────────────────────────────────────────────────
#[test]
#[expected_failure(abort_code = single_stake::ENotGotchiHolder)]
fun test_stake_fails_for_non_gotchi_holder() {
    let (mut sc, clk) = bootstrap();
    // CAROL has no TierRegistry entry — should be rejected.
    do_stake(&mut sc, &clk, CAROL, STAKE_10K, LOCK_FLEXIBLE);
    end_scenario(sc, clk);
}

#[test]
#[expected_failure(abort_code = single_stake::EBelowMinStake)]
fun test_stake_fails_below_min_stake() {
    let (mut sc, clk) = bootstrap();
    do_stake(&mut sc, &clk, ALICE, STAKE_10K - 1, LOCK_FLEXIBLE);
    end_scenario(sc, clk);
}

#[test]
#[expected_failure(abort_code = single_stake::EInvalidLockKind)]
fun test_stake_fails_invalid_lock_kind() {
    let (mut sc, clk) = bootstrap();
    do_stake(&mut sc, &clk, ALICE, STAKE_10K, 99);
    end_scenario(sc, clk);
}

#[test]
#[expected_failure(abort_code = single_stake::EVaultPaused)]
fun test_stake_fails_when_paused() {
    let (mut sc, clk) = bootstrap();
    sc.next_tx(ADMIN);
    let admin = sc.take_from_sender<AdminCap>();
    let mut vault = sc.take_shared<Vault<TEST_SUITRUMP, TEST_VICTORY>>();
    single_stake::set_vault_cap_active(&admin, &mut vault, false, &clk);
    ts::return_shared(vault);
    sc.return_to_sender(admin);
    do_stake(&mut sc, &clk, ALICE, STAKE_10K, LOCK_FLEXIBLE);
    end_scenario(sc, clk);
}

#[test]
#[expected_failure(abort_code = single_stake::ECapExceeded)]
fun test_stake_fails_when_cap_exceeded() {
    let (mut sc, clk) = bootstrap();
    // Lower cap to STAKE_10K so a 50k stake exceeds it.
    sc.next_tx(ADMIN);
    let admin = sc.take_from_sender<AdminCap>();
    let mut vault = sc.take_shared<Vault<TEST_SUITRUMP, TEST_VICTORY>>();
    single_stake::set_vault_cap(&admin, &mut vault, STAKE_10K, &clk);
    ts::return_shared(vault);
    sc.return_to_sender(admin);
    do_stake(&mut sc, &clk, ALICE, STAKE_50K, LOCK_FLEXIBLE);
    end_scenario(sc, clk);
}

// ── Stake mechanics ────────────────────────────────────────────────────────
#[test]
fun test_stake_creates_position_with_correct_weight_and_state() {
    let (mut sc, clk) = bootstrap();
    do_stake(&mut sc, &clk, ALICE, STAKE_10K, LOCK_180D);

    sc.next_tx(ALICE);
    let position = sc.take_from_sender<StakePosition<TEST_SUITRUMP, TEST_VICTORY>>();
    let (owner, principal, weight, kind, unlock_ms, _stake_ms, converted) =
        single_stake::get_position(&position);
    assert_eq!(owner, ALICE);
    assert_eq!(principal, STAKE_10K);
    // 180d → 2.0x → weight = principal × 20000 / 10000 = principal × 2
    assert_eq!(weight, STAKE_10K * 2);
    assert_eq!(kind, LOCK_180D);
    assert!(unlock_ms > 0);
    assert!(!converted);
    sc.return_to_sender(position);

    // Vault aggregates updated.
    sc.next_tx(ADMIN);
    let vault = sc.take_shared<Vault<TEST_SUITRUMP, TEST_VICTORY>>();
    let (total_locked, _, _, _, _, _, _, total_weight) = single_stake::get_vault_status(&vault);
    assert_eq!(total_locked, STAKE_10K);
    assert_eq!(total_weight, STAKE_10K * 2);
    ts::return_shared(vault);
    end_scenario(sc, clk);
}

#[test]
fun test_stake_flexible_has_zero_unlock_ms_and_1x_weight() {
    let (mut sc, clk) = bootstrap();
    do_stake(&mut sc, &clk, ALICE, STAKE_10K, LOCK_FLEXIBLE);
    sc.next_tx(ALICE);
    let position = sc.take_from_sender<StakePosition<TEST_SUITRUMP, TEST_VICTORY>>();
    let (_, principal, weight, _, unlock_ms, _, _) = single_stake::get_position(&position);
    assert_eq!(principal, STAKE_10K);
    assert_eq!(weight, STAKE_10K);
    assert_eq!(unlock_ms, 0);
    sc.return_to_sender(position);
    end_scenario(sc, clk);
}

// ── Pool seeding ───────────────────────────────────────────────────────────
#[test]
fun test_seed_pool1_increases_balance_and_effective() {
    let (mut sc, clk) = bootstrap();
    seed_pool1(&mut sc, &clk, SEED_1M);
    sc.next_tx(ADMIN);
    let vault = sc.take_shared<Vault<TEST_SUITRUMP, TEST_VICTORY>>();
    let (_, _, _, p1_bal, p1_eff, _, _, _) = single_stake::get_vault_status(&vault);
    assert_eq!(p1_bal, SEED_1M);
    assert_eq!(p1_eff, SEED_1M);
    ts::return_shared(vault);
    end_scenario(sc, clk);
}

#[test]
fun test_seed_pool2_increases_balance_and_effective() {
    let (mut sc, clk) = bootstrap();
    seed_pool2(&mut sc, &clk, SEED_1M);
    sc.next_tx(ADMIN);
    let vault = sc.take_shared<Vault<TEST_SUITRUMP, TEST_VICTORY>>();
    let (_, _, _, _, _, p2_bal, p2_eff, _) = single_stake::get_vault_status(&vault);
    assert_eq!(p2_bal, SEED_1M);
    assert_eq!(p2_eff, SEED_1M);
    ts::return_shared(vault);
    end_scenario(sc, clk);
}

#[test]
#[expected_failure(abort_code = single_stake::EZeroAmount)]
fun test_seed_pool_zero_amount_aborts() {
    let (mut sc, clk) = bootstrap();
    sc.next_tx(ADMIN);
    let admin = sc.take_from_sender<AdminCap>();
    let mut vault = sc.take_shared<Vault<TEST_SUITRUMP, TEST_VICTORY>>();
    let zero_coin = mint_v(0, sc.ctx());
    single_stake::seed_pool1(&admin, &mut vault, zero_coin, &clk);
    ts::return_shared(vault);
    sc.return_to_sender(admin);
    end_scenario(sc, clk);
}

// ── Emission accuracy ──────────────────────────────────────────────────────
// Single staker, single seed of Pool 1. After dt elapsed, claimable rewards
// should match (effective × dt / 90d), within rounding.
#[test]
fun test_single_staker_emission_matches_balance_over_90d() {
    let (mut sc, mut clk) = bootstrap();
    seed_pool1(&mut sc, &clk, SEED_1M);
    do_stake(&mut sc, &clk, ALICE, STAKE_10K, LOCK_FLEXIBLE);

    // Advance 30 days. Expected emission = SEED_1M × 30d / 90d ≈ SEED_1M / 3.
    clock::increment_for_testing(&mut clk, THIRTY_DAYS_MS);

    sc.next_tx(ALICE);
    let mut vault = sc.take_shared<Vault<TEST_SUITRUMP, TEST_VICTORY>>();
    let mut position = sc.take_from_sender<StakePosition<TEST_SUITRUMP, TEST_VICTORY>>();
    let (claim_v, claim_p) = single_stake::claim_rewards(&mut vault, &mut position, &clk, sc.ctx());

    let v_amount = coin::value(&claim_v);
    let p_amount = coin::value(&claim_p);
    // Pool 2 was empty so P claim = 0.
    assert_eq!(p_amount, 0);
    // Pool 1: at flexible 1.0x and ALICE is the only staker, ALICE captures
    // all emissions. Expected ≈ SEED_1M × 30/90 = ~333_333_333_333. Allow
    // ±0.1% tolerance for integer rounding.
    let expected = SEED_1M / 3;
    let lower = expected - expected / 1000;
    let upper = expected + expected / 1000;
    assert!(v_amount >= lower);
    assert!(v_amount <= upper);

    destroy(claim_v);
    destroy(claim_p);
    sc.return_to_sender(position);
    ts::return_shared(vault);
    end_scenario(sc, clk);
}

// Two stakers with different lock multipliers. 180d (2.0x) gets 2x the
// emission share of flexible (1.0x) for the same principal.
#[test]
fun test_lock_multiplier_share_is_2x_180d_vs_flexible() {
    let (mut sc, mut clk) = bootstrap();
    seed_pool1(&mut sc, &clk, SEED_1M);
    do_stake(&mut sc, &clk, ALICE, STAKE_10K, LOCK_FLEXIBLE);
    do_stake(&mut sc, &clk, BOB, STAKE_10K, LOCK_180D);

    clock::increment_for_testing(&mut clk, THIRTY_DAYS_MS);

    // ALICE claims.
    sc.next_tx(ALICE);
    let mut vault = sc.take_shared<Vault<TEST_SUITRUMP, TEST_VICTORY>>();
    let mut alice_pos = sc.take_from_sender<StakePosition<TEST_SUITRUMP, TEST_VICTORY>>();
    let (alice_v, alice_p) =
        single_stake::claim_rewards(&mut vault, &mut alice_pos, &clk, sc.ctx());
    let alice_amt = coin::value(&alice_v);
    destroy(alice_v);
    destroy(alice_p);
    sc.return_to_sender(alice_pos);
    ts::return_shared(vault);

    // BOB claims.
    sc.next_tx(BOB);
    let mut vault2 = sc.take_shared<Vault<TEST_SUITRUMP, TEST_VICTORY>>();
    let mut bob_pos = sc.take_from_sender<StakePosition<TEST_SUITRUMP, TEST_VICTORY>>();
    let (bob_v, bob_p) =
        single_stake::claim_rewards(&mut vault2, &mut bob_pos, &clk, sc.ctx());
    let bob_amt = coin::value(&bob_v);
    destroy(bob_v);
    destroy(bob_p);
    sc.return_to_sender(bob_pos);
    ts::return_shared(vault2);

    // BOB had weight 2× ALICE's, so BOB's claim should be ≈ 2× ALICE's.
    // Allow ±0.5% tolerance for rounding and the small dt drift from
    // separate transactions advancing time within the test.
    let expected_bob = alice_amt * 2;
    let lower = expected_bob - expected_bob / 200;
    let upper = expected_bob + expected_bob / 200;
    assert!(bob_amt >= lower);
    assert!(bob_amt <= upper);

    end_scenario(sc, clk);
}

// Self-stabilising property: as effective_balance drains, emission rate
// drops. Checked by comparing rewards in two equal-length periods with
// no top-ups.
#[test]
fun test_emission_rate_decreases_as_pool_drains() {
    let (mut sc, mut clk) = bootstrap();
    seed_pool1(&mut sc, &clk, SEED_1M);
    do_stake(&mut sc, &clk, ALICE, STAKE_10K, LOCK_FLEXIBLE);

    // Period 1: 30 days.
    clock::increment_for_testing(&mut clk, THIRTY_DAYS_MS);
    sc.next_tx(ALICE);
    let mut vault = sc.take_shared<Vault<TEST_SUITRUMP, TEST_VICTORY>>();
    let mut position = sc.take_from_sender<StakePosition<TEST_SUITRUMP, TEST_VICTORY>>();
    let (v1, p1) = single_stake::claim_rewards(&mut vault, &mut position, &clk, sc.ctx());
    let period1_amt = coin::value(&v1);
    destroy(v1);
    destroy(p1);
    ts::return_shared(vault);

    // Period 2: another 30 days, no new seeds.
    clock::increment_for_testing(&mut clk, THIRTY_DAYS_MS);
    sc.next_tx(ALICE);
    let mut vault2 = sc.take_shared<Vault<TEST_SUITRUMP, TEST_VICTORY>>();
    let (v2, p2) = single_stake::claim_rewards(&mut vault2, &mut position, &clk, sc.ctx());
    let period2_amt = coin::value(&v2);
    destroy(v2);
    destroy(p2);
    sc.return_to_sender(position);
    ts::return_shared(vault2);

    // Rate must have dropped — period2 < period1.
    assert!(period2_amt < period1_amt);
    end_scenario(sc, clk);
}

// ── Top-up ─────────────────────────────────────────────────────────────────
#[test]
fun test_top_up_adds_principal_and_recomputes_weight() {
    let (mut sc, clk) = bootstrap();
    do_stake(&mut sc, &clk, ALICE, STAKE_10K, LOCK_180D);

    sc.next_tx(ALICE);
    let mut vault = sc.take_shared<Vault<TEST_SUITRUMP, TEST_VICTORY>>();
    let mut position = sc.take_from_sender<StakePosition<TEST_SUITRUMP, TEST_VICTORY>>();
    let topup = mint_p(TOP_UP_1K, sc.ctx());
    let (claim_v, claim_p) =
        single_stake::top_up(&mut vault, &mut position, topup, &clk, sc.ctx());

    let (_, principal, weight, kind, _, _, _) = single_stake::get_position(&position);
    assert_eq!(principal, STAKE_10K + TOP_UP_1K);
    // 180d still — weight = (10k + 1k) × 2.0 = 22k * D6
    assert_eq!(weight, (STAKE_10K + TOP_UP_1K) * 2);
    assert_eq!(kind, LOCK_180D);

    destroy(claim_v);
    destroy(claim_p);
    sc.return_to_sender(position);
    ts::return_shared(vault);
    end_scenario(sc, clk);
}

#[test]
#[expected_failure(abort_code = single_stake::EBelowMinTopUp)]
fun test_top_up_below_min_aborts() {
    let (mut sc, clk) = bootstrap();
    do_stake(&mut sc, &clk, ALICE, STAKE_10K, LOCK_180D);
    sc.next_tx(ALICE);
    let mut vault = sc.take_shared<Vault<TEST_SUITRUMP, TEST_VICTORY>>();
    let mut position = sc.take_from_sender<StakePosition<TEST_SUITRUMP, TEST_VICTORY>>();
    let topup = mint_p(TOP_UP_1K - 1, sc.ctx());
    let (v, p) = single_stake::top_up(&mut vault, &mut position, topup, &clk, sc.ctx());
    destroy(v);
    destroy(p);
    sc.return_to_sender(position);
    ts::return_shared(vault);
    end_scenario(sc, clk);
}

// ── Unstake — at maturity ──────────────────────────────────────────────────
#[test]
fun test_unstake_at_maturity_returns_full_principal_plus_rewards() {
    let (mut sc, mut clk) = bootstrap();
    seed_pool1(&mut sc, &clk, SEED_1M);
    do_stake(&mut sc, &clk, ALICE, STAKE_10K, LOCK_30D);

    // Advance past lock end.
    clock::increment_for_testing(&mut clk, THIRTY_DAYS_MS + 1);

    sc.next_tx(ALICE);
    let mut vault = sc.take_shared<Vault<TEST_SUITRUMP, TEST_VICTORY>>();
    let position = sc.take_from_sender<StakePosition<TEST_SUITRUMP, TEST_VICTORY>>();
    let (principal_back, reward_v, reward_p) =
        single_stake::unstake_at_maturity(&mut vault, position, &clk, sc.ctx());

    assert_eq!(coin::value(&principal_back), STAKE_10K);
    assert!(coin::value(&reward_v) > 0);
    assert_eq!(coin::value(&reward_p), 0);

    destroy(principal_back);
    destroy(reward_v);
    destroy(reward_p);
    ts::return_shared(vault);
    end_scenario(sc, clk);
}

#[test]
#[expected_failure(abort_code = single_stake::EPositionNotMature)]
fun test_unstake_at_maturity_before_lock_end_aborts() {
    let (mut sc, clk) = bootstrap();
    do_stake(&mut sc, &clk, ALICE, STAKE_10K, LOCK_30D);
    sc.next_tx(ALICE);
    let mut vault = sc.take_shared<Vault<TEST_SUITRUMP, TEST_VICTORY>>();
    let position = sc.take_from_sender<StakePosition<TEST_SUITRUMP, TEST_VICTORY>>();
    let (p, v, p2) = single_stake::unstake_at_maturity(&mut vault, position, &clk, sc.ctx());
    destroy(p);
    destroy(v);
    destroy(p2);
    ts::return_shared(vault);
    end_scenario(sc, clk);
}

// ── Unstake — flexible ─────────────────────────────────────────────────────
#[test]
fun test_unstake_flexible_returns_full_principal_no_penalty() {
    let (mut sc, clk) = bootstrap();
    do_stake(&mut sc, &clk, ALICE, STAKE_10K, LOCK_FLEXIBLE);
    sc.next_tx(ALICE);
    let mut vault = sc.take_shared<Vault<TEST_SUITRUMP, TEST_VICTORY>>();
    let position = sc.take_from_sender<StakePosition<TEST_SUITRUMP, TEST_VICTORY>>();
    let (principal_back, v, p) =
        single_stake::unstake_flexible(&mut vault, position, &clk, sc.ctx());
    assert_eq!(coin::value(&principal_back), STAKE_10K);
    destroy(principal_back);
    destroy(v);
    destroy(p);
    ts::return_shared(vault);
    end_scenario(sc, clk);
}

#[test]
#[expected_failure(abort_code = single_stake::EInvalidLockKind)]
fun test_unstake_flexible_on_locked_position_aborts() {
    let (mut sc, clk) = bootstrap();
    do_stake(&mut sc, &clk, ALICE, STAKE_10K, LOCK_30D);
    sc.next_tx(ALICE);
    let mut vault = sc.take_shared<Vault<TEST_SUITRUMP, TEST_VICTORY>>();
    let position = sc.take_from_sender<StakePosition<TEST_SUITRUMP, TEST_VICTORY>>();
    let (p, v, p2) = single_stake::unstake_flexible(&mut vault, position, &clk, sc.ctx());
    destroy(p);
    destroy(v);
    destroy(p2);
    ts::return_shared(vault);
    end_scenario(sc, clk);
}

// ── Unstake — early ────────────────────────────────────────────────────────
#[test]
fun test_unstake_early_returns_50pct_principal_and_full_rewards() {
    let (mut sc, mut clk) = bootstrap();
    seed_pool1(&mut sc, &clk, SEED_1M);
    do_stake(&mut sc, &clk, ALICE, STAKE_10K, LOCK_180D);

    // Advance partway — not past lock end.
    clock::increment_for_testing(&mut clk, THIRTY_DAYS_MS);

    sc.next_tx(ALICE);
    let mut vault = sc.take_shared<Vault<TEST_SUITRUMP, TEST_VICTORY>>();
    let position = sc.take_from_sender<StakePosition<TEST_SUITRUMP, TEST_VICTORY>>();
    let (principal_back, reward_v, reward_p) =
        single_stake::unstake_early(&mut vault, position, &clk, sc.ctx());

    // Principal returned: 50% of 10k.
    assert_eq!(coin::value(&principal_back), STAKE_10K / 2);
    // Rewards: full amount, untaxed.
    assert!(coin::value(&reward_v) > 0);
    assert_eq!(coin::value(&reward_p), 0);

    // Forfeited 50% should be in Pool 2 reward bucket now.
    let (_, _, _, _, _, p2_bal, p2_eff, _) = single_stake::get_vault_status(&vault);
    assert_eq!(p2_bal, STAKE_10K / 2);
    assert_eq!(p2_eff, STAKE_10K / 2);

    destroy(principal_back);
    destroy(reward_v);
    destroy(reward_p);
    ts::return_shared(vault);
    end_scenario(sc, clk);
}

#[test]
#[expected_failure(abort_code = single_stake::EFlexibleHasNoEarlyExit)]
fun test_unstake_early_on_flexible_aborts() {
    let (mut sc, clk) = bootstrap();
    do_stake(&mut sc, &clk, ALICE, STAKE_10K, LOCK_FLEXIBLE);
    sc.next_tx(ALICE);
    let mut vault = sc.take_shared<Vault<TEST_SUITRUMP, TEST_VICTORY>>();
    let position = sc.take_from_sender<StakePosition<TEST_SUITRUMP, TEST_VICTORY>>();
    let (p, v, p2) = single_stake::unstake_early(&mut vault, position, &clk, sc.ctx());
    destroy(p);
    destroy(v);
    destroy(p2);
    ts::return_shared(vault);
    end_scenario(sc, clk);
}

#[test]
#[expected_failure(abort_code = single_stake::EPositionNotMature)]
fun test_unstake_early_after_lock_end_aborts() {
    let (mut sc, mut clk) = bootstrap();
    do_stake(&mut sc, &clk, ALICE, STAKE_10K, LOCK_30D);
    clock::increment_for_testing(&mut clk, THIRTY_DAYS_MS + 1);
    sc.next_tx(ALICE);
    let mut vault = sc.take_shared<Vault<TEST_SUITRUMP, TEST_VICTORY>>();
    let position = sc.take_from_sender<StakePosition<TEST_SUITRUMP, TEST_VICTORY>>();
    let (p, v, p2) = single_stake::unstake_early(&mut vault, position, &clk, sc.ctx());
    destroy(p);
    destroy(v);
    destroy(p2);
    ts::return_shared(vault);
    end_scenario(sc, clk);
}

// ── Auto-convert at lock end ──────────────────────────────────────────────
#[test]
fun test_auto_convert_drops_weight_to_1x_at_lock_end_on_claim() {
    let (mut sc, mut clk) = bootstrap();
    seed_pool1(&mut sc, &clk, SEED_1M);
    do_stake(&mut sc, &clk, ALICE, STAKE_10K, LOCK_180D);

    // Past lock end.
    clock::increment_for_testing(&mut clk, ONE_HUNDRED_EIGHTY_DAYS_MS + 1);

    sc.next_tx(ALICE);
    let mut vault = sc.take_shared<Vault<TEST_SUITRUMP, TEST_VICTORY>>();
    let mut position = sc.take_from_sender<StakePosition<TEST_SUITRUMP, TEST_VICTORY>>();
    let (v, p) = single_stake::claim_rewards(&mut vault, &mut position, &clk, sc.ctx());

    let (_, principal, weight, _, _, _, converted) = single_stake::get_position(&position);
    assert_eq!(principal, STAKE_10K);
    // After auto-convert, weight = principal × 1.0x.
    assert_eq!(weight, STAKE_10K);
    assert!(converted);

    // Vault total_weight should reflect the conversion.
    let (_, _, _, _, _, _, _, total_weight) = single_stake::get_vault_status(&vault);
    assert_eq!(total_weight, STAKE_10K);

    destroy(v);
    destroy(p);
    sc.return_to_sender(position);
    ts::return_shared(vault);
    end_scenario(sc, clk);
}

// ── Wrong-owner gates ─────────────────────────────────────────────────────
// StakePosition is `key` only and never gets `store` — we verify the owner
// gate inside our entry functions still catches a hostile call. We can't
// transfer the position to BOB, so we instead simulate by having BOB attempt
// to claim against ALICE's position via shared state. Since Move owned-object
// semantics prevent BOB from even getting access to ALICE's position, the
// owner check is belt-and-braces — testable here only via direct construction
// in a test_only path which we do not expose. Skipping for v0 — rely on
// owned-object isolation as the primary gate.

// ── Pending rewards view ──────────────────────────────────────────────────
#[test]
fun test_pending_rewards_simulation_matches_subsequent_claim() {
    let (mut sc, mut clk) = bootstrap();
    seed_pool1(&mut sc, &clk, SEED_1M);
    do_stake(&mut sc, &clk, ALICE, STAKE_10K, LOCK_FLEXIBLE);

    clock::increment_for_testing(&mut clk, THIRTY_DAYS_MS);

    sc.next_tx(ALICE);
    let mut vault = sc.take_shared<Vault<TEST_SUITRUMP, TEST_VICTORY>>();
    let mut position = sc.take_from_sender<StakePosition<TEST_SUITRUMP, TEST_VICTORY>>();
    let (pending_v, pending_p) = single_stake::pending_rewards(&vault, &position, &clk);
    let (claim_v, claim_p) = single_stake::claim_rewards(&mut vault, &mut position, &clk, sc.ctx());

    // pending should match claim exactly when no time elapsed between read and claim.
    assert_eq!(coin::value(&claim_v), pending_v);
    assert_eq!(coin::value(&claim_p), pending_p);

    destroy(claim_v);
    destroy(claim_p);
    sc.return_to_sender(position);
    ts::return_shared(vault);
    end_scenario(sc, clk);
}

// ── TVL cap behaviour ─────────────────────────────────────────────────────
#[test]
fun test_set_vault_cap_lowers_cap_grandfathers_existing_stakers() {
    let (mut sc, clk) = bootstrap();
    do_stake(&mut sc, &clk, ALICE, STAKE_50K, LOCK_FLEXIBLE);

    // Lower cap below current TVL — existing stake should be untouched.
    sc.next_tx(ADMIN);
    let admin = sc.take_from_sender<AdminCap>();
    let mut vault = sc.take_shared<Vault<TEST_SUITRUMP, TEST_VICTORY>>();
    single_stake::set_vault_cap(&admin, &mut vault, STAKE_10K, &clk);
    let (total_locked, cap, _, _, _, _, _, _) = single_stake::get_vault_status(&vault);
    assert_eq!(total_locked, STAKE_50K);
    assert_eq!(cap, STAKE_10K);
    ts::return_shared(vault);
    sc.return_to_sender(admin);

    end_scenario(sc, clk);
}
