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

// ── Multi-staker proportional share ───────────────────────────────────────
// Bob (180D, 2.0x weight) earns exactly 2x what Alice (FLEX, 1.0x weight) earns
// when both stake the same principal. Catches any future drift in the
// MasterChef per-share math.
#[test]
fun test_multi_staker_pool2_emission_scales_with_weight() {
    let (mut sc, mut clk) = bootstrap();
    seed_pool2(&mut sc, &clk, SEED_1M);

    do_stake(&mut sc, &clk, ALICE, STAKE_10K, LOCK_FLEXIBLE); // weight = 10k
    do_stake(&mut sc, &clk, BOB, STAKE_10K, LOCK_180D);       // weight = 20k
    // total_weight = 30k. Bob's share = 20/30, Alice's = 10/30.

    // Advance ~30 days — pool emits, both have pending in 1:2 ratio.
    clock::increment_for_testing(&mut clk, THIRTY_DAYS_MS);

    // Alice claims.
    sc.next_tx(ALICE);
    let mut vault = sc.take_shared<Vault<TEST_SUITRUMP, TEST_VICTORY>>();
    let mut a_pos = sc.take_from_sender<StakePosition<TEST_SUITRUMP, TEST_VICTORY>>();
    let (a_v, a_p) = single_stake::claim_rewards(&mut vault, &mut a_pos, &clk, sc.ctx());
    let alice_p = coin::value(&a_p);
    assert_eq!(coin::value(&a_v), 0); // pool 1 empty
    destroy(a_v);
    destroy(a_p);
    sc.return_to_sender(a_pos);
    ts::return_shared(vault);

    // Bob claims same instant — same `now`, identical acc snapshot.
    sc.next_tx(BOB);
    let mut vault = sc.take_shared<Vault<TEST_SUITRUMP, TEST_VICTORY>>();
    let mut b_pos = sc.take_from_sender<StakePosition<TEST_SUITRUMP, TEST_VICTORY>>();
    let (b_v, b_p) = single_stake::claim_rewards(&mut vault, &mut b_pos, &clk, sc.ctx());
    let bob_p = coin::value(&b_p);
    destroy(b_v);
    destroy(b_p);
    sc.return_to_sender(b_pos);
    ts::return_shared(vault);

    // Both > 0.
    assert!(alice_p > 0);
    assert!(bob_p > 0);
    // Bob's share = 2x Alice's. Allow ±1 raw unit for rounding.
    let two_alice = alice_p * 2;
    let diff = if (bob_p > two_alice) bob_p - two_alice else two_alice - bob_p;
    assert!(diff <= 1);

    end_scenario(sc, clk);
}

// ── total_weight invariant after early-unstake ────────────────────────────
// vault.total_weight must remain consistent with sum-of-position-weights even
// across early-unstake (which deletes a position). Catches accounting drift.
#[test]
fun test_total_weight_decreases_correctly_after_early_unstake() {
    let (mut sc, mut clk) = bootstrap();
    do_stake(&mut sc, &clk, ALICE, STAKE_10K, LOCK_180D); // weight = 20k

    sc.next_tx(ADMIN);
    let vault = sc.take_shared<Vault<TEST_SUITRUMP, TEST_VICTORY>>();
    let (_, _, _, _, _, _, _, total_weight) = single_stake::get_vault_status(&vault);
    assert_eq!(total_weight, STAKE_10K * 2);
    ts::return_shared(vault);

    // Advance 1 day so we're still inside the lock.
    clock::increment_for_testing(&mut clk, ONE_DAY_MS);

    sc.next_tx(ALICE);
    let mut vault = sc.take_shared<Vault<TEST_SUITRUMP, TEST_VICTORY>>();
    let position = sc.take_from_sender<StakePosition<TEST_SUITRUMP, TEST_VICTORY>>();
    let (returned_p, v, p) = single_stake::unstake_early(&mut vault, position, &clk, sc.ctx());
    // 50% returned, 50% forfeited (deposited to pool 2).
    assert_eq!(coin::value(&returned_p), STAKE_10K / 2);
    destroy(returned_p);
    destroy(v);
    destroy(p);

    let (total_locked, _, _, _, _, pool2_bal, _, total_weight_after) =
        single_stake::get_vault_status(&vault);
    assert_eq!(total_weight_after, 0);
    assert_eq!(total_locked, 0);
    // Pool 2 should have the 50% forfeit deposited.
    assert_eq!(pool2_bal, STAKE_10K / 2);
    ts::return_shared(vault);

    end_scenario(sc, clk);
}

// ── Empty-pool emission no-op ─────────────────────────────────────────────
// Stake into a vault with both reward pools at zero balance. update_pools
// should no-op cleanly; claim_rewards should return zero coins (not abort).
#[test]
fun test_empty_pool_emission_is_zero_no_abort() {
    let (mut sc, mut clk) = bootstrap();
    do_stake(&mut sc, &clk, ALICE, STAKE_10K, LOCK_FLEXIBLE);

    clock::increment_for_testing(&mut clk, THIRTY_DAYS_MS);

    sc.next_tx(ALICE);
    let mut vault = sc.take_shared<Vault<TEST_SUITRUMP, TEST_VICTORY>>();
    let mut position = sc.take_from_sender<StakePosition<TEST_SUITRUMP, TEST_VICTORY>>();
    let (v, p) = single_stake::claim_rewards(&mut vault, &mut position, &clk, sc.ctx());
    assert_eq!(coin::value(&v), 0);
    assert_eq!(coin::value(&p), 0);
    destroy(v);
    destroy(p);
    sc.return_to_sender(position);
    ts::return_shared(vault);

    end_scenario(sc, clk);
}

// ── Pool seed during paused vault works ───────────────────────────────────
// Admin must be able to seed pools even while staking is paused — the pause
// only blocks new stakes / top-ups, not admin-side liquidity ops.
#[test]
fun test_seed_pool_succeeds_when_vault_paused() {
    let (mut sc, clk) = bootstrap();

    sc.next_tx(ADMIN);
    let admin = sc.take_from_sender<AdminCap>();
    let mut vault = sc.take_shared<Vault<TEST_SUITRUMP, TEST_VICTORY>>();
    single_stake::set_vault_cap_active(&admin, &mut vault, false, &clk);
    // While paused, seed should still work.
    let coin = mint_p(SEED_1M, sc.ctx());
    single_stake::seed_pool2(&admin, &mut vault, coin, &clk);
    let (_, _, _, _, _, pool2_bal, _, _) = single_stake::get_vault_status(&vault);
    assert_eq!(pool2_bal, SEED_1M);
    ts::return_shared(vault);
    sc.return_to_sender(admin);

    end_scenario(sc, clk);
}

// ── Pool 3 happy path: create + claim + sweep ─────────────────────────────
// Full lifecycle of a campaign vault. Stake exists, campaign emits, staker
// claims residual after sweep.
#[test]
fun test_campaign_create_claim_sweep_full_lifecycle() {
    let (mut sc, mut clk) = bootstrap();
    do_stake(&mut sc, &clk, ALICE, STAKE_10K, LOCK_FLEXIBLE);

    // Admin seeds a 100k TEST_CAMPAIGN reward over ~2x the lock window
    // so emission is reasonable for the test.
    let campaign_amt = 100_000 * D6;
    let campaign_duration_ms = NINETY_DAYS_MS;

    sc.next_tx(ADMIN);
    let admin = sc.take_from_sender<AdminCap>();
    let mut vault = sc.take_shared<Vault<TEST_SUITRUMP, TEST_VICTORY>>();
    let camp_coin = coin::mint_for_testing<TEST_CAMPAIGN>(campaign_amt, sc.ctx());
    single_stake::create_campaign<TEST_SUITRUMP, TEST_VICTORY, TEST_CAMPAIGN>(
        &admin, &mut vault, camp_coin, campaign_duration_ms, &clk,
    );
    ts::return_shared(vault);
    sc.return_to_sender(admin);

    // Half-way through the campaign: staker claims partial.
    clock::increment_for_testing(&mut clk, campaign_duration_ms / 2);
    sc.next_tx(ALICE);
    let mut vault = sc.take_shared<Vault<TEST_SUITRUMP, TEST_VICTORY>>();
    let mut position = sc.take_from_sender<StakePosition<TEST_SUITRUMP, TEST_VICTORY>>();
    let mid_payout = single_stake::claim_campaign<TEST_SUITRUMP, TEST_VICTORY, TEST_CAMPAIGN>(
        &mut vault, &mut position, 0, &clk, sc.ctx(),
    );
    let mid_paid = coin::value(&mid_payout);
    assert!(mid_paid > 0);
    destroy(mid_payout);
    sc.return_to_sender(position);
    ts::return_shared(vault);

    // Past expiry: admin sweeps remaining undistributed back.
    clock::increment_for_testing(&mut clk, campaign_duration_ms);
    sc.next_tx(ADMIN);
    let admin = sc.take_from_sender<AdminCap>();
    let mut vault = sc.take_shared<Vault<TEST_SUITRUMP, TEST_VICTORY>>();
    let swept = single_stake::sweep_expired_campaign<TEST_SUITRUMP, TEST_VICTORY, TEST_CAMPAIGN>(
        &admin, &mut vault, 0, &clk, sc.ctx(),
    );
    // v11 linear release: with a single staker that mid-claimed, the
    // remaining pool is exactly the second-half emissions still owed to
    // that staker. F14 floor preserves all of it; sweep returns 0 (or
    // close to it after rounding). Pre-v11 self-stabilising rule left an
    // asymptotic chunk for admin — that's not the design anymore.
    let swept_amt = coin::value(&swept);
    assert!(swept_amt <= campaign_amt / 100);
    destroy(swept);
    ts::return_shared(vault);
    sc.return_to_sender(admin);

    // Alice claims her residual share of the second half — proves F14
    // floor + finalized campaign correctly preserves the staker's owed
    // entitlement past sweep.
    sc.next_tx(ALICE);
    let mut vault = sc.take_shared<Vault<TEST_SUITRUMP, TEST_VICTORY>>();
    let mut position = sc.take_from_sender<StakePosition<TEST_SUITRUMP, TEST_VICTORY>>();
    let post_sweep_payout = single_stake::claim_campaign<TEST_SUITRUMP, TEST_VICTORY, TEST_CAMPAIGN>(
        &mut vault, &mut position, 0, &clk, sc.ctx(),
    );
    assert!(coin::value(&post_sweep_payout) > 0);
    destroy(post_sweep_payout);
    sc.return_to_sender(position);
    ts::return_shared(vault);

    // active_campaign_count decremented after sweep.
    sc.next_tx(ADMIN);
    let vault = sc.take_shared<Vault<TEST_SUITRUMP, TEST_VICTORY>>();
    // (no public getter for active_campaign_count yet; trust that subsequent
    // create works under the cap.)
    ts::return_shared(vault);

    end_scenario(sc, clk);
}

// ── Pool 3 sweep before expiry aborts ─────────────────────────────────────
#[test]
#[expected_failure(abort_code = single_stake::ECampaignNotExpired)]
fun test_sweep_before_expiry_aborts() {
    let (mut sc, clk) = bootstrap();

    sc.next_tx(ADMIN);
    let admin = sc.take_from_sender<AdminCap>();
    let mut vault = sc.take_shared<Vault<TEST_SUITRUMP, TEST_VICTORY>>();
    let camp_coin = coin::mint_for_testing<TEST_CAMPAIGN>(100_000 * D6, sc.ctx());
    single_stake::create_campaign<TEST_SUITRUMP, TEST_VICTORY, TEST_CAMPAIGN>(
        &admin, &mut vault, camp_coin, NINETY_DAYS_MS, &clk,
    );
    // Try to sweep immediately — campaign hasn't expired yet.
    let swept = single_stake::sweep_expired_campaign<TEST_SUITRUMP, TEST_VICTORY, TEST_CAMPAIGN>(
        &admin, &mut vault, 0, &clk, sc.ctx(),
    );
    destroy(swept);
    ts::return_shared(vault);
    sc.return_to_sender(admin);
    end_scenario(sc, clk);
}

// ── Pool 3 MAX_ACTIVE_CAMPAIGNS limit ─────────────────────────────────────
#[test]
#[expected_failure(abort_code = single_stake::ETooManyActiveCampaigns)]
fun test_create_campaign_aborts_at_max_active() {
    let (mut sc, clk) = bootstrap();

    sc.next_tx(ADMIN);
    let admin = sc.take_from_sender<AdminCap>();
    let mut vault = sc.take_shared<Vault<TEST_SUITRUMP, TEST_VICTORY>>();
    // MAX_ACTIVE_CAMPAIGNS = 5. Create 5 then attempt the 6th.
    let mut i = 0;
    while (i < 6) {
        let coin = coin::mint_for_testing<TEST_CAMPAIGN>(100 * D6, sc.ctx());
        single_stake::create_campaign<TEST_SUITRUMP, TEST_VICTORY, TEST_CAMPAIGN>(
            &admin, &mut vault, coin, NINETY_DAYS_MS, &clk,
        );
        i = i + 1;
    };
    // Unreachable — abort fires on the 6th.
    ts::return_shared(vault);
    sc.return_to_sender(admin);
    end_scenario(sc, clk);
}

// ── Pool 3 finalized campaign still claimable for accrued debt ────────────
// After sweep, the dynamic-field campaign struct remains with the unclaimed
// residual. A staker who held a position during the active window can still
// call claim_campaign and pull their residual.
#[test]
fun test_finalized_campaign_still_claimable_for_residual() {
    let (mut sc, mut clk) = bootstrap();
    do_stake(&mut sc, &clk, ALICE, STAKE_10K, LOCK_FLEXIBLE);

    sc.next_tx(ADMIN);
    let admin = sc.take_from_sender<AdminCap>();
    let mut vault = sc.take_shared<Vault<TEST_SUITRUMP, TEST_VICTORY>>();
    let camp_coin = coin::mint_for_testing<TEST_CAMPAIGN>(100_000 * D6, sc.ctx());
    single_stake::create_campaign<TEST_SUITRUMP, TEST_VICTORY, TEST_CAMPAIGN>(
        &admin, &mut vault, camp_coin, NINETY_DAYS_MS, &clk,
    );
    ts::return_shared(vault);
    sc.return_to_sender(admin);

    // Skip ahead past expiry without any claims during the active window.
    clock::increment_for_testing(&mut clk, NINETY_DAYS_MS + 1);

    // Admin sweeps. The campaign keeps its residual = unclaimed_emitted_floor.
    sc.next_tx(ADMIN);
    let admin = sc.take_from_sender<AdminCap>();
    let mut vault = sc.take_shared<Vault<TEST_SUITRUMP, TEST_VICTORY>>();
    let swept = single_stake::sweep_expired_campaign<TEST_SUITRUMP, TEST_VICTORY, TEST_CAMPAIGN>(
        &admin, &mut vault, 0, &clk, sc.ctx(),
    );
    destroy(swept);
    ts::return_shared(vault);
    sc.return_to_sender(admin);

    // Alice claims — should still get her share of what was emitted before
    // expiry, even though the campaign is finalized.
    sc.next_tx(ALICE);
    let mut vault = sc.take_shared<Vault<TEST_SUITRUMP, TEST_VICTORY>>();
    let mut position = sc.take_from_sender<StakePosition<TEST_SUITRUMP, TEST_VICTORY>>();
    let payout = single_stake::claim_campaign<TEST_SUITRUMP, TEST_VICTORY, TEST_CAMPAIGN>(
        &mut vault, &mut position, 0, &clk, sc.ctx(),
    );
    assert!(coin::value(&payout) > 0);
    destroy(payout);
    sc.return_to_sender(position);
    ts::return_shared(vault);

    end_scenario(sc, clk);
}

// ── Overflow guard smoke ──────────────────────────────────────────────────
// Stake the largest amount permitted under PHASE_1_CAP, seed pool 2 to a
// realistic upper bound (100M SUITRUMP), advance 90 days, claim. Verifies
// the u128 acc math doesn't wrap and the payout is sensible.
#[test]
fun test_overflow_smoke_max_stake_max_pool() {
    let (mut sc, mut clk) = bootstrap();
    // Seed Pool 2 with 100M SUITRUMP (Phase 2 v2 launch seed).
    seed_pool2(&mut sc, &clk, 100_000_000 * D6);

    // Stake 100M (exactly the cap) at 180D for max weight = 200M.
    let big_stake = 100_000_000 * D6;
    sc.next_tx(ALICE);
    let mut vault = sc.take_shared<Vault<TEST_SUITRUMP, TEST_VICTORY>>();
    let tier = sc.take_shared<TierRegistry>();
    let coin = mint_p(big_stake, sc.ctx());
    single_stake::stake(&mut vault, &tier, coin, LOCK_180D, &clk, sc.ctx());
    ts::return_shared(vault);
    ts::return_shared(tier);

    // Skip a full distribution window — pool 2 effective_balance fully drains.
    clock::increment_for_testing(&mut clk, NINETY_DAYS_MS + 1);

    sc.next_tx(ALICE);
    let mut vault = sc.take_shared<Vault<TEST_SUITRUMP, TEST_VICTORY>>();
    let mut position = sc.take_from_sender<StakePosition<TEST_SUITRUMP, TEST_VICTORY>>();
    let (v, p) = single_stake::claim_rewards(&mut vault, &mut position, &clk, sc.ctx());
    let payout = coin::value(&p);
    // Single staker so they get ~all of what emitted. Should be close to the
    // entire seed (100M SUITRUMP). Floor at 99% to allow for rounding.
    assert!(payout >= 99_000_000 * D6);
    assert!(payout <= 100_000_000 * D6);
    destroy(v);
    destroy(p);
    sc.return_to_sender(position);
    ts::return_shared(vault);

    end_scenario(sc, clk);
}

// ── F12 regression: auto-convert pays out OLD-weight pending ──────────────
// Pre-fix: claim_rewards / top_up / claim_campaign at exactly lock-end forfeited
// all rewards accrued at the locked weight. This test asserts pending is paid
// to the owner during auto-conversion (via direct transfer from inside
// auto_convert_if_due, then RewardsClaimed event emitted).
#[test]
fun test_f12_auto_convert_pays_out_pre_conversion_pending() {
    let (mut sc, mut clk) = bootstrap();
    seed_pool2(&mut sc, &clk, SEED_1M);
    do_stake(&mut sc, &clk, ALICE, STAKE_10K, LOCK_180D);

    // Past lock end — pool 2 has emitted significantly to ALICE (sole staker).
    clock::increment_for_testing(&mut clk, ONE_HUNDRED_EIGHTY_DAYS_MS + 1);

    sc.next_tx(ALICE);
    let mut vault = sc.take_shared<Vault<TEST_SUITRUMP, TEST_VICTORY>>();
    let mut position = sc.take_from_sender<StakePosition<TEST_SUITRUMP, TEST_VICTORY>>();

    // claim_rewards triggers auto_convert. The (v, p) returned coins reflect
    // the SETTLE step at the new (flexible) weight — for ALICE this is 0
    // (auto_convert just paid everything). The ACTUAL pending payout from
    // auto_convert is transferred separately to ALICE's inventory.
    let (v, p) = single_stake::claim_rewards(&mut vault, &mut position, &clk, sc.ctx());
    assert_eq!(coin::value(&v), 0);
    assert_eq!(coin::value(&p), 0);
    destroy(v);
    destroy(p);
    sc.return_to_sender(position);
    ts::return_shared(vault);

    // Auto-convert should have transferred a non-zero Pool 2 coin to ALICE.
    sc.next_tx(ALICE);
    let received_p = sc.take_from_sender<Coin<TEST_SUITRUMP>>();
    assert!(coin::value(&received_p) > 0);
    destroy(received_p);

    // Pool 1 has zero balance (we didn't seed_pool1) so the V coin transferred
    // by auto_convert is zero. The ts::take_from_sender mechanism still finds
    // a zero coin — destroy it to clean up.
    let v_coin = sc.take_from_sender<Coin<TEST_VICTORY>>();
    assert_eq!(coin::value(&v_coin), 0);
    destroy(v_coin);

    end_scenario(sc, clk);
}

// ── F13 regression: top-up after auto-convert uses flexible mult ──────────
// Pre-fix: top_up after auto_convert recomputed weight using the original
// lock multiplier (e.g. 2.0x for LOCK_180D), undoing the conversion. This test
// asserts the new weight uses MULT_FLEXIBLE_BPS (1.0x) when position.converted.
#[test]
fun test_f13_top_up_after_auto_convert_uses_flexible_multiplier() {
    let (mut sc, mut clk) = bootstrap();
    seed_pool2(&mut sc, &clk, SEED_1M);
    do_stake(&mut sc, &clk, ALICE, STAKE_10K, LOCK_180D);

    // Past lock end — auto-convert triggers on first interaction.
    clock::increment_for_testing(&mut clk, ONE_HUNDRED_EIGHTY_DAYS_MS + 1);

    sc.next_tx(ALICE);
    let mut vault = sc.take_shared<Vault<TEST_SUITRUMP, TEST_VICTORY>>();
    let mut position = sc.take_from_sender<StakePosition<TEST_SUITRUMP, TEST_VICTORY>>();
    let coin = mint_p(TOP_UP_1K, sc.ctx());
    let (v, p) = single_stake::top_up(&mut vault, &mut position, coin, &clk, sc.ctx());
    destroy(v);
    destroy(p);

    let (_, principal, weight, _, _, _, converted) = single_stake::get_position(&position);
    assert!(converted);
    assert_eq!(principal, STAKE_10K + TOP_UP_1K);
    // F13: weight should be (10k + 1k) × 1.0x = 11k. Pre-fix would have been
    // (10k + 1k) × 2.0x = 22k — silently re-applying the 180D lock multiplier.
    assert_eq!(weight, STAKE_10K + TOP_UP_1K);

    sc.return_to_sender(position);
    ts::return_shared(vault);

    // Drain inventory of the auto-convert payout coin so end_scenario clean.
    sc.next_tx(ALICE);
    let payout_p = sc.take_from_sender<Coin<TEST_SUITRUMP>>();
    destroy(payout_p);
    let payout_v = sc.take_from_sender<Coin<TEST_VICTORY>>();
    destroy(payout_v);

    end_scenario(sc, clk);
}

// ── F12 parity across lock kinds: 30D ─────────────────────────────────────
#[test]
fun test_f12_auto_convert_pays_pending_for_30d_lock() {
    let (mut sc, mut clk) = bootstrap();
    seed_pool2(&mut sc, &clk, SEED_1M);
    do_stake(&mut sc, &clk, ALICE, STAKE_10K, LOCK_30D);

    clock::increment_for_testing(&mut clk, THIRTY_DAYS_MS + 1);

    sc.next_tx(ALICE);
    let mut vault = sc.take_shared<Vault<TEST_SUITRUMP, TEST_VICTORY>>();
    let mut position = sc.take_from_sender<StakePosition<TEST_SUITRUMP, TEST_VICTORY>>();
    let (v, p) = single_stake::claim_rewards(&mut vault, &mut position, &clk, sc.ctx());
    assert_eq!(coin::value(&v), 0);
    assert_eq!(coin::value(&p), 0);
    destroy(v);
    destroy(p);
    sc.return_to_sender(position);
    ts::return_shared(vault);

    sc.next_tx(ALICE);
    let received_p = sc.take_from_sender<Coin<TEST_SUITRUMP>>();
    assert!(coin::value(&received_p) > 0);
    destroy(received_p);
    let v_coin = sc.take_from_sender<Coin<TEST_VICTORY>>();
    destroy(v_coin);

    end_scenario(sc, clk);
}

// ── F12 parity across lock kinds: 90D ─────────────────────────────────────
#[test]
fun test_f12_auto_convert_pays_pending_for_90d_lock() {
    let (mut sc, mut clk) = bootstrap();
    seed_pool2(&mut sc, &clk, SEED_1M);
    do_stake(&mut sc, &clk, ALICE, STAKE_10K, LOCK_90D);

    clock::increment_for_testing(&mut clk, NINETY_DAYS_MS + 1);

    sc.next_tx(ALICE);
    let mut vault = sc.take_shared<Vault<TEST_SUITRUMP, TEST_VICTORY>>();
    let mut position = sc.take_from_sender<StakePosition<TEST_SUITRUMP, TEST_VICTORY>>();
    let (v, p) = single_stake::claim_rewards(&mut vault, &mut position, &clk, sc.ctx());
    assert_eq!(coin::value(&v), 0);
    assert_eq!(coin::value(&p), 0);
    destroy(v);
    destroy(p);
    sc.return_to_sender(position);
    ts::return_shared(vault);

    sc.next_tx(ALICE);
    let received_p = sc.take_from_sender<Coin<TEST_SUITRUMP>>();
    assert!(coin::value(&received_p) > 0);
    destroy(received_p);
    let v_coin = sc.take_from_sender<Coin<TEST_VICTORY>>();
    destroy(v_coin);

    end_scenario(sc, clk);
}

// ── Cap boundary: stake exactly at cap succeeds ───────────────────────────
#[test]
fun test_stake_exactly_at_cap_succeeds() {
    let (mut sc, clk) = bootstrap();

    // Lower cap to STAKE_50K so we can land exactly on it.
    sc.next_tx(ADMIN);
    let admin = sc.take_from_sender<AdminCap>();
    let mut vault = sc.take_shared<Vault<TEST_SUITRUMP, TEST_VICTORY>>();
    single_stake::set_vault_cap(&admin, &mut vault, STAKE_50K, &clk);
    ts::return_shared(vault);
    sc.return_to_sender(admin);

    do_stake(&mut sc, &clk, ALICE, STAKE_50K, LOCK_FLEXIBLE);

    sc.next_tx(ADMIN);
    let vault = sc.take_shared<Vault<TEST_SUITRUMP, TEST_VICTORY>>();
    let (total_locked, cap, _, _, _, _, _, _) = single_stake::get_vault_status(&vault);
    assert_eq!(total_locked, STAKE_50K);
    assert_eq!(cap, STAKE_50K);
    ts::return_shared(vault);

    end_scenario(sc, clk);
}

// ── Cap raise unblocks new stakes that previously aborted ─────────────────
// Critical for Phase 2 v2 cap-tier progression: 500M → 1.5B → 3B → uncapped.
// Lowering grandfathers existing; raising must immediately allow new stakes.
#[test]
fun test_raising_cap_unblocks_new_stakes() {
    let (mut sc, clk) = bootstrap();

    // Set cap = STAKE_10K. Alice fills it.
    sc.next_tx(ADMIN);
    let admin = sc.take_from_sender<AdminCap>();
    let mut vault = sc.take_shared<Vault<TEST_SUITRUMP, TEST_VICTORY>>();
    single_stake::set_vault_cap(&admin, &mut vault, STAKE_10K, &clk);
    ts::return_shared(vault);
    sc.return_to_sender(admin);

    do_stake(&mut sc, &clk, ALICE, STAKE_10K, LOCK_FLEXIBLE);

    // Raise cap to STAKE_50K. Bob can now stake the additional 40k headroom.
    sc.next_tx(ADMIN);
    let admin = sc.take_from_sender<AdminCap>();
    let mut vault = sc.take_shared<Vault<TEST_SUITRUMP, TEST_VICTORY>>();
    single_stake::set_vault_cap(&admin, &mut vault, STAKE_50K, &clk);
    ts::return_shared(vault);
    sc.return_to_sender(admin);

    do_stake(&mut sc, &clk, BOB, STAKE_10K * 4, LOCK_FLEXIBLE);

    sc.next_tx(ADMIN);
    let vault = sc.take_shared<Vault<TEST_SUITRUMP, TEST_VICTORY>>();
    let (total_locked, cap, _, _, _, _, _, _) = single_stake::get_vault_status(&vault);
    assert_eq!(total_locked, STAKE_50K);
    assert_eq!(cap, STAKE_50K);
    ts::return_shared(vault);

    end_scenario(sc, clk);
}

// ── Cap raise on a *full* vault: prior overflow attempt would fail ────────
// Verifies that a stake that ECapExceeded'd before the raise succeeds after.
#[test]
fun test_stake_blocked_at_cap_succeeds_after_raise() {
    let (mut sc, clk) = bootstrap();

    sc.next_tx(ADMIN);
    let admin = sc.take_from_sender<AdminCap>();
    let mut vault = sc.take_shared<Vault<TEST_SUITRUMP, TEST_VICTORY>>();
    single_stake::set_vault_cap(&admin, &mut vault, STAKE_10K, &clk);
    ts::return_shared(vault);
    sc.return_to_sender(admin);

    do_stake(&mut sc, &clk, ALICE, STAKE_10K, LOCK_FLEXIBLE);
    // Vault is now exactly at cap. Bob attempting any stake would abort
    // with ECapExceeded — covered by test_stake_fails_when_cap_exceeded.
    // After raise, Bob's stake of MIN should succeed.

    sc.next_tx(ADMIN);
    let admin = sc.take_from_sender<AdminCap>();
    let mut vault = sc.take_shared<Vault<TEST_SUITRUMP, TEST_VICTORY>>();
    single_stake::set_vault_cap(&admin, &mut vault, STAKE_10K * 3, &clk);
    ts::return_shared(vault);
    sc.return_to_sender(admin);

    do_stake(&mut sc, &clk, BOB, STAKE_10K, LOCK_FLEXIBLE);

    sc.next_tx(ADMIN);
    let vault = sc.take_shared<Vault<TEST_SUITRUMP, TEST_VICTORY>>();
    let (total_locked, _, _, _, _, _, _, _) = single_stake::get_vault_status(&vault);
    assert_eq!(total_locked, STAKE_10K * 2);
    ts::return_shared(vault);

    end_scenario(sc, clk);
}

// ── F14 regression: sweep preserves balance when bal <= effective ─────────
// With no stakers during the campaign window, total_weight stays 0 so
// update_single_pool early-returns and effective_balance never decreases.
// At sweep time bal == effective == initial — the previous floor returned 0
// here (draining the entire balance). The fix returns `bal`, so swept == 0.
// This is the safe-side behaviour: we never over-sweep when math says
// outstanding could exist (acc_reward_per_share-vs-debt drift, no-weight
// windows, or pure rounding edges).
#[test]
fun test_f14_sweep_preserves_residual_when_balance_below_effective() {
    let (mut sc, mut clk) = bootstrap();

    // No stakes. Admin creates a campaign — no holder will accrue.
    sc.next_tx(ADMIN);
    let admin = sc.take_from_sender<AdminCap>();
    let mut vault = sc.take_shared<Vault<TEST_SUITRUMP, TEST_VICTORY>>();
    let camp_amt = 100_000 * D6;
    let camp_coin = coin::mint_for_testing<TEST_CAMPAIGN>(camp_amt, sc.ctx());
    single_stake::create_campaign<TEST_SUITRUMP, TEST_VICTORY, TEST_CAMPAIGN>(
        &admin, &mut vault, camp_coin, NINETY_DAYS_MS, &clk,
    );
    ts::return_shared(vault);
    sc.return_to_sender(admin);

    // Expire without anyone staking.
    clock::increment_for_testing(&mut clk, NINETY_DAYS_MS + 1);

    sc.next_tx(ADMIN);
    let admin = sc.take_from_sender<AdminCap>();
    let mut vault = sc.take_shared<Vault<TEST_SUITRUMP, TEST_VICTORY>>();
    let swept = single_stake::sweep_expired_campaign<TEST_SUITRUMP, TEST_VICTORY, TEST_CAMPAIGN>(
        &admin, &mut vault, 0, &clk, sc.ctx(),
    );
    // F14 fix: bal == effective at sweep time → floor returns bal → swept = 0.
    // Pre-fix this returned the entire 100k campaign as swept, which would
    // have drained any latent residual entitlement in pools that hit the
    // same code path through rounding drift.
    assert_eq!(coin::value(&swept), 0);
    destroy(swept);
    ts::return_shared(vault);
    sc.return_to_sender(admin);

    end_scenario(sc, clk);
}

// ── F15 regression: new positions cannot claim historical campaign emissions ─
// Pre-fix, claim_campaign's lazy-init fell through to prior_debt = 0, so any
// position calling claim_campaign for the FIRST time would pay out
// weight × acc / PRECISION — i.e. it claimed every emission that had
// accrued to the campaign's acc_reward_per_share before the position
// existed. This let new stakers drain finalised-residual campaigns and
// over-claim from active campaigns that had been emitting to OTHER
// positions before they joined.
//
// Fix: lazy-init compares position.stake_ms vs campaign.start_ms. If the
// position post-dates the campaign, prior_debt is seeded to current
// entitlement so the first claim returns 0 and only future deltas accrue.
#[test]
fun test_f15_late_joiner_cannot_drain_historical_emissions() {
    let (mut sc, mut clk) = bootstrap();

    // Alice stakes BEFORE the campaign exists.
    do_stake(&mut sc, &clk, ALICE, STAKE_10K, LOCK_FLEXIBLE);

    // Admin creates a 100k campaign over 90 days.
    sc.next_tx(ADMIN);
    let admin = sc.take_from_sender<AdminCap>();
    let mut vault = sc.take_shared<Vault<TEST_SUITRUMP, TEST_VICTORY>>();
    let camp_amt = 100_000 * D6;
    let camp_coin = coin::mint_for_testing<TEST_CAMPAIGN>(camp_amt, sc.ctx());
    single_stake::create_campaign<TEST_SUITRUMP, TEST_VICTORY, TEST_CAMPAIGN>(
        &admin, &mut vault, camp_coin, NINETY_DAYS_MS, &clk,
    );
    ts::return_shared(vault);
    sc.return_to_sender(admin);

    // Half-way through campaign — Alice has been the sole staker so the
    // campaign's acc_reward_per_share has been growing against her weight.
    clock::increment_for_testing(&mut clk, NINETY_DAYS_MS / 2);

    // Bob joins NOW (mid-campaign). Pre-fix, Bob's first claim_campaign
    // would drain weight × acc / PRECISION ≈ half of all emissions — i.e.
    // emissions that flowed to Alice's weight, not his.
    do_stake(&mut sc, &clk, BOB, STAKE_10K, LOCK_FLEXIBLE);

    sc.next_tx(BOB);
    let mut vault = sc.take_shared<Vault<TEST_SUITRUMP, TEST_VICTORY>>();
    let mut position = sc.take_from_sender<StakePosition<TEST_SUITRUMP, TEST_VICTORY>>();
    let payout = single_stake::claim_campaign<TEST_SUITRUMP, TEST_VICTORY, TEST_CAMPAIGN>(
        &mut vault, &mut position, 0, &clk, sc.ctx(),
    );
    // F15 fix: Bob's first claim must pay 0 — he didn't exist when those
    // emissions accrued and shouldn't be able to harvest them.
    assert_eq!(coin::value(&payout), 0);
    destroy(payout);
    sc.return_to_sender(position);
    ts::return_shared(vault);

    end_scenario(sc, clk);
}

// ── F15 mitigation: init_campaign_debt closes the forfeit window ─────────
// The lazy-init branch of claim_campaign protects against historical drain
// but creates an edge case: positions that join AFTER a campaign was
// created forfeit emissions accrued to `acc` between their stake_ms and
// their first claim_campaign call. init_campaign_debt is the explicit
// frontend tool to close that window — call it right after stake and the
// position's debt is locked to current entitlement immediately.
//
// This test verifies: (a) init_campaign_debt seeds debt correctly,
// (b) a follow-up claim_campaign pays 0, (c) emissions accruing AFTER
// init are still claimable as deltas.
#[test]
fun test_f15_init_campaign_debt_locks_entry_point() {
    let (mut sc, mut clk) = bootstrap();

    // Alice stakes first — she'll be the sole emission target for a bit.
    do_stake(&mut sc, &clk, ALICE, STAKE_10K, LOCK_FLEXIBLE);

    sc.next_tx(ADMIN);
    let admin = sc.take_from_sender<AdminCap>();
    let mut vault = sc.take_shared<Vault<TEST_SUITRUMP, TEST_VICTORY>>();
    let camp_coin = coin::mint_for_testing<TEST_CAMPAIGN>(100_000 * D6, sc.ctx());
    single_stake::create_campaign<TEST_SUITRUMP, TEST_VICTORY, TEST_CAMPAIGN>(
        &admin, &mut vault, camp_coin, NINETY_DAYS_MS, &clk,
    );
    ts::return_shared(vault);
    sc.return_to_sender(admin);

    // Quarter-way through campaign — emissions have been flowing to Alice.
    clock::increment_for_testing(&mut clk, NINETY_DAYS_MS / 4);

    // Bob joins mid-campaign and IMMEDIATELY locks his debt via the new
    // entry point. Pre-mitigation he'd forfeit anything in `acc` since his
    // first claim_campaign would be deferred to settle / unstake time.
    do_stake(&mut sc, &clk, BOB, STAKE_10K, LOCK_FLEXIBLE);

    sc.next_tx(BOB);
    let mut vault = sc.take_shared<Vault<TEST_SUITRUMP, TEST_VICTORY>>();
    let mut position = sc.take_from_sender<StakePosition<TEST_SUITRUMP, TEST_VICTORY>>();
    single_stake::init_campaign_debt<TEST_SUITRUMP, TEST_VICTORY, TEST_CAMPAIGN>(
        &mut vault, &mut position, 0, &clk, sc.ctx(),
    );

    // (a)+(b) Immediate claim must be 0 — debt is current entitlement.
    let payout1 = single_stake::claim_campaign<TEST_SUITRUMP, TEST_VICTORY, TEST_CAMPAIGN>(
        &mut vault, &mut position, 0, &clk, sc.ctx(),
    );
    assert_eq!(coin::value(&payout1), 0);
    destroy(payout1);

    // Advance another quarter — emissions now share between Alice and Bob.
    clock::increment_for_testing(&mut clk, NINETY_DAYS_MS / 4);

    // (c) Bob's second claim pays his half of the second quarter's
    // emissions only — not any historical share.
    let payout2 = single_stake::claim_campaign<TEST_SUITRUMP, TEST_VICTORY, TEST_CAMPAIGN>(
        &mut vault, &mut position, 0, &clk, sc.ctx(),
    );
    assert!(coin::value(&payout2) > 0);
    destroy(payout2);

    sc.return_to_sender(position);
    ts::return_shared(vault);

    end_scenario(sc, clk);
}

// ── v13: recover_stranded_residual closes partner-token leakage ──────────
// After a campaign expires and is swept, F14's floor preserves
// `bal - effective` (the unclaimed-emitted portion) so legitimate stakers
// can still claim. But if those stakers' positions were consumed without
// the unstake bundle including claim_campaign for this campaign (e.g.
// frontend cache stale at unstake time), F15 prevents any future position
// from claiming that share → it's permanently stranded.
//
// recover_stranded_residual lets the admin reclaim that balance after a
// 30-day grace period past expiry. Grace gives stakers a final claim
// window post-sweep.
#[test]
fun test_recover_stranded_residual_after_grace() {
    let (mut sc, mut clk) = bootstrap();
    do_stake(&mut sc, &clk, ALICE, STAKE_10K, LOCK_FLEXIBLE);

    sc.next_tx(ADMIN);
    let admin = sc.take_from_sender<AdminCap>();
    let mut vault = sc.take_shared<Vault<TEST_SUITRUMP, TEST_VICTORY>>();
    let camp_coin = coin::mint_for_testing<TEST_CAMPAIGN>(1_000 * D6, sc.ctx());
    single_stake::create_campaign<TEST_SUITRUMP, TEST_VICTORY, TEST_CAMPAIGN>(
        &admin, &mut vault, camp_coin, NINETY_DAYS_MS, &clk,
    );
    ts::return_shared(vault);
    sc.return_to_sender(admin);

    // Run past expiry, then sweep — preserves the unclaimed residual
    // (Alice never called claim_campaign).
    clock::increment_for_testing(&mut clk, NINETY_DAYS_MS + 1);
    sc.next_tx(ADMIN);
    let admin = sc.take_from_sender<AdminCap>();
    let mut vault = sc.take_shared<Vault<TEST_SUITRUMP, TEST_VICTORY>>();
    let swept = single_stake::sweep_expired_campaign<TEST_SUITRUMP, TEST_VICTORY, TEST_CAMPAIGN>(
        &admin, &mut vault, 0, &clk, sc.ctx(),
    );
    // Linear release fully drains effective by expiry, so sweep returns
    // near-zero — Alice's full share is in the preserved residual.
    let swept_amt = coin::value(&swept);
    assert!(swept_amt < 1_000 * D6 / 100);
    destroy(swept);
    ts::return_shared(vault);
    sc.return_to_sender(admin);

    // Try to recover BEFORE the 30-day grace elapses — must abort.
    // (Tested in test_recover_stranded_aborts_before_grace below.)
    // Here we advance past the grace, then recover.
    clock::increment_for_testing(&mut clk, THIRTY_DAYS_MS + 1);

    sc.next_tx(ADMIN);
    let admin = sc.take_from_sender<AdminCap>();
    let mut vault = sc.take_shared<Vault<TEST_SUITRUMP, TEST_VICTORY>>();
    let recovered = single_stake::recover_stranded_residual<TEST_SUITRUMP, TEST_VICTORY, TEST_CAMPAIGN>(
        &admin, &mut vault, 0, &clk, sc.ctx(),
    );
    // Recovery returns the full preserved residual.
    let recovered_amt = coin::value(&recovered);
    assert!(recovered_amt > 0);
    destroy(recovered);
    ts::return_shared(vault);
    sc.return_to_sender(admin);

    end_scenario(sc, clk);
}

#[test]
#[expected_failure(abort_code = single_stake::ERecoveryGraceNotElapsed)]
fun test_recover_stranded_aborts_before_grace() {
    let (mut sc, mut clk) = bootstrap();
    do_stake(&mut sc, &clk, ALICE, STAKE_10K, LOCK_FLEXIBLE);

    sc.next_tx(ADMIN);
    let admin = sc.take_from_sender<AdminCap>();
    let mut vault = sc.take_shared<Vault<TEST_SUITRUMP, TEST_VICTORY>>();
    let camp_coin = coin::mint_for_testing<TEST_CAMPAIGN>(1_000 * D6, sc.ctx());
    single_stake::create_campaign<TEST_SUITRUMP, TEST_VICTORY, TEST_CAMPAIGN>(
        &admin, &mut vault, camp_coin, NINETY_DAYS_MS, &clk,
    );
    ts::return_shared(vault);
    sc.return_to_sender(admin);

    clock::increment_for_testing(&mut clk, NINETY_DAYS_MS + 1);
    sc.next_tx(ADMIN);
    let admin = sc.take_from_sender<AdminCap>();
    let mut vault = sc.take_shared<Vault<TEST_SUITRUMP, TEST_VICTORY>>();
    let swept = single_stake::sweep_expired_campaign<TEST_SUITRUMP, TEST_VICTORY, TEST_CAMPAIGN>(
        &admin, &mut vault, 0, &clk, sc.ctx(),
    );
    destroy(swept);
    ts::return_shared(vault);
    sc.return_to_sender(admin);

    // Advance only 29 days post-expiry — still within grace. Recovery
    // attempt must abort.
    clock::increment_for_testing(&mut clk, THIRTY_DAYS_MS - ONE_DAY_MS);

    sc.next_tx(ADMIN);
    let admin = sc.take_from_sender<AdminCap>();
    let mut vault = sc.take_shared<Vault<TEST_SUITRUMP, TEST_VICTORY>>();
    let recovered = single_stake::recover_stranded_residual<TEST_SUITRUMP, TEST_VICTORY, TEST_CAMPAIGN>(
        &admin, &mut vault, 0, &clk, sc.ctx(),
    );
    destroy(recovered);
    ts::return_shared(vault);
    sc.return_to_sender(admin);

    end_scenario(sc, clk);
}

#[test]
#[expected_failure(abort_code = single_stake::ECampaignNotFinalized)]
fun test_recover_stranded_aborts_when_not_finalized() {
    let (mut sc, mut clk) = bootstrap();
    do_stake(&mut sc, &clk, ALICE, STAKE_10K, LOCK_FLEXIBLE);

    sc.next_tx(ADMIN);
    let admin = sc.take_from_sender<AdminCap>();
    let mut vault = sc.take_shared<Vault<TEST_SUITRUMP, TEST_VICTORY>>();
    let camp_coin = coin::mint_for_testing<TEST_CAMPAIGN>(1_000 * D6, sc.ctx());
    single_stake::create_campaign<TEST_SUITRUMP, TEST_VICTORY, TEST_CAMPAIGN>(
        &admin, &mut vault, camp_coin, NINETY_DAYS_MS, &clk,
    );
    ts::return_shared(vault);
    sc.return_to_sender(admin);

    // Skip past expiry + grace, but never call sweep_expired_campaign —
    // campaign is unfinalized. Recovery must abort because the contract
    // requires sweep to have run first.
    clock::increment_for_testing(&mut clk, NINETY_DAYS_MS + THIRTY_DAYS_MS + 1);

    sc.next_tx(ADMIN);
    let admin = sc.take_from_sender<AdminCap>();
    let mut vault = sc.take_shared<Vault<TEST_SUITRUMP, TEST_VICTORY>>();
    let recovered = single_stake::recover_stranded_residual<TEST_SUITRUMP, TEST_VICTORY, TEST_CAMPAIGN>(
        &admin, &mut vault, 0, &clk, sc.ctx(),
    );
    destroy(recovered);
    ts::return_shared(vault);
    sc.return_to_sender(admin);

    end_scenario(sc, clk);
}

// ── v11: Pool 3 linear release ────────────────────────────────────────────
// Partner campaigns emit at constant rate `initial / duration` so a
// `$X for D days` partner contribution drains fully (modulo F14 dust)
// by `start + D`. Test: single staker, 1000-unit campaign, 1000ms
// duration. After full duration + sweep, distributed should equal the
// initial amount (within rounding floor). Pool 1 / Pool 2 keep the
// self-stabilising rule and are NOT affected by this change.
#[test]
fun test_v11_campaign_linear_release_fully_emits() {
    let (mut sc, mut clk) = bootstrap();
    do_stake(&mut sc, &clk, ALICE, STAKE_10K, LOCK_FLEXIBLE);

    // 1000-unit campaign, 1000ms duration → 1 unit / ms emission rate.
    let camp_amt = 1_000 * D6;
    let camp_duration_ms = 1_000;

    sc.next_tx(ADMIN);
    let admin = sc.take_from_sender<AdminCap>();
    let mut vault = sc.take_shared<Vault<TEST_SUITRUMP, TEST_VICTORY>>();
    let camp_coin = coin::mint_for_testing<TEST_CAMPAIGN>(camp_amt, sc.ctx());
    single_stake::create_campaign<TEST_SUITRUMP, TEST_VICTORY, TEST_CAMPAIGN>(
        &admin, &mut vault, camp_coin, camp_duration_ms, &clk,
    );
    ts::return_shared(vault);
    sc.return_to_sender(admin);

    // Advance past expiry — Alice should be entitled to almost the entire
    // pool (she's the only staker the whole window).
    clock::increment_for_testing(&mut clk, camp_duration_ms + 1);

    sc.next_tx(ALICE);
    let mut vault = sc.take_shared<Vault<TEST_SUITRUMP, TEST_VICTORY>>();
    let mut position = sc.take_from_sender<StakePosition<TEST_SUITRUMP, TEST_VICTORY>>();
    let payout = single_stake::claim_campaign<TEST_SUITRUMP, TEST_VICTORY, TEST_CAMPAIGN>(
        &mut vault, &mut position, 0, &clk, sc.ctx(),
    );
    // Linear release: by expiry, the full campaign should have emitted.
    // Single-staker with weight = STAKE_10K (LOCK_FLEXIBLE = 1.0x) and
    // total_weight = STAKE_10K → 100% of emissions go to Alice. Allow 1%
    // tolerance for rounding in the acc accumulator math.
    let payout_amt = coin::value(&payout);
    assert!(payout_amt >= (camp_amt * 99) / 100);
    assert!(payout_amt <= camp_amt);
    destroy(payout);
    sc.return_to_sender(position);
    ts::return_shared(vault);

    end_scenario(sc, clk);
}

// ── v11: sweep after linear release leaves only rounding dust ─────────────
// Continuation of the linear-release check: after Alice claims, admin
// sweeps. The pool should have effectively zero recoverable balance
// (everything legitimately emitted, only F14 floor dust remains).
#[test]
fun test_v11_sweep_after_linear_release_drains_pool() {
    let (mut sc, mut clk) = bootstrap();
    do_stake(&mut sc, &clk, ALICE, STAKE_10K, LOCK_FLEXIBLE);

    let camp_amt = 1_000 * D6;
    let camp_duration_ms = 1_000;

    sc.next_tx(ADMIN);
    let admin = sc.take_from_sender<AdminCap>();
    let mut vault = sc.take_shared<Vault<TEST_SUITRUMP, TEST_VICTORY>>();
    let camp_coin = coin::mint_for_testing<TEST_CAMPAIGN>(camp_amt, sc.ctx());
    single_stake::create_campaign<TEST_SUITRUMP, TEST_VICTORY, TEST_CAMPAIGN>(
        &admin, &mut vault, camp_coin, camp_duration_ms, &clk,
    );
    ts::return_shared(vault);
    sc.return_to_sender(admin);

    clock::increment_for_testing(&mut clk, camp_duration_ms + 1);

    // Alice claims everything.
    sc.next_tx(ALICE);
    let mut vault = sc.take_shared<Vault<TEST_SUITRUMP, TEST_VICTORY>>();
    let mut position = sc.take_from_sender<StakePosition<TEST_SUITRUMP, TEST_VICTORY>>();
    let payout = single_stake::claim_campaign<TEST_SUITRUMP, TEST_VICTORY, TEST_CAMPAIGN>(
        &mut vault, &mut position, 0, &clk, sc.ctx(),
    );
    destroy(payout);
    sc.return_to_sender(position);
    ts::return_shared(vault);

    // Admin sweeps. With linear release the pool should be near-empty;
    // any swept amount is just rounding-floor noise.
    sc.next_tx(ADMIN);
    let admin = sc.take_from_sender<AdminCap>();
    let mut vault = sc.take_shared<Vault<TEST_SUITRUMP, TEST_VICTORY>>();
    let swept = single_stake::sweep_expired_campaign<TEST_SUITRUMP, TEST_VICTORY, TEST_CAMPAIGN>(
        &admin, &mut vault, 0, &clk, sc.ctx(),
    );
    // < 1% of initial — i.e. dust, not a stranded chunk.
    assert!(coin::value(&swept) < camp_amt / 100);
    destroy(swept);
    ts::return_shared(vault);
    sc.return_to_sender(admin);

    end_scenario(sc, clk);
}

// ── Composable stake flow — stake_non_entry chains with init + transfer ──
// Demonstrates the audit-recommended PTB pattern from Sui Move best
// practices (https://docs.sui.io/develop/write-move/move-best-practices):
// instead of self-transferring inside stake(), callers receive the
// position by value, pass it to init_campaign_debt for every active
// campaign to lock the F15 entry-point at stake time, then route it home
// via transfer_position_to_owner — all in one Move-level sequence.
// Mirrors Sui's request_add_stake / request_add_stake_non_entry pair.
#[test]
fun test_composable_stake_with_init_chain() {
    let (mut sc, mut clk) = bootstrap();

    // Pre-existing staker so the campaign's acc grows AGAINST another
    // weight, not in a vacuum.
    do_stake(&mut sc, &clk, ALICE, STAKE_10K, LOCK_FLEXIBLE);

    sc.next_tx(ADMIN);
    let admin = sc.take_from_sender<AdminCap>();
    let mut vault = sc.take_shared<Vault<TEST_SUITRUMP, TEST_VICTORY>>();
    let camp_coin = coin::mint_for_testing<TEST_CAMPAIGN>(100_000 * D6, sc.ctx());
    single_stake::create_campaign<TEST_SUITRUMP, TEST_VICTORY, TEST_CAMPAIGN>(
        &admin, &mut vault, camp_coin, NINETY_DAYS_MS, &clk,
    );
    ts::return_shared(vault);
    sc.return_to_sender(admin);

    // Let acc grow for Alice.
    clock::increment_for_testing(&mut clk, NINETY_DAYS_MS / 4);

    // Bob's composable stake — mirrors what the frontend PTB would do.
    sc.next_tx(BOB);
    let mut vault = sc.take_shared<Vault<TEST_SUITRUMP, TEST_VICTORY>>();
    let tier = sc.take_shared<TierRegistry>();
    let coin = mint_p(STAKE_10K, sc.ctx());
    let mut position = single_stake::stake_non_entry(
        &mut vault, &tier, coin, LOCK_FLEXIBLE, &clk, sc.ctx(),
    );
    single_stake::init_campaign_debt<TEST_SUITRUMP, TEST_VICTORY, TEST_CAMPAIGN>(
        &mut vault, &mut position, 0, &clk, sc.ctx(),
    );
    single_stake::transfer_position_to_owner(position);
    ts::return_shared(tier);
    ts::return_shared(vault);

    // Bob now owns the position and can claim — first claim must pay 0
    // because init_campaign_debt locked his debt at the stake-time
    // entitlement (no historical drain, no forfeit window).
    sc.next_tx(BOB);
    let mut vault = sc.take_shared<Vault<TEST_SUITRUMP, TEST_VICTORY>>();
    let mut position = sc.take_from_sender<StakePosition<TEST_SUITRUMP, TEST_VICTORY>>();
    let payout = single_stake::claim_campaign<TEST_SUITRUMP, TEST_VICTORY, TEST_CAMPAIGN>(
        &mut vault, &mut position, 0, &clk, sc.ctx(),
    );
    assert_eq!(coin::value(&payout), 0);
    destroy(payout);

    // Advance — Bob should now earn his share of fresh emissions.
    clock::increment_for_testing(&mut clk, NINETY_DAYS_MS / 4);
    let payout2 = single_stake::claim_campaign<TEST_SUITRUMP, TEST_VICTORY, TEST_CAMPAIGN>(
        &mut vault, &mut position, 0, &clk, sc.ctx(),
    );
    assert!(coin::value(&payout2) > 0);
    destroy(payout2);

    sc.return_to_sender(position);
    ts::return_shared(vault);
    end_scenario(sc, clk);
}

// ── transfer_position_to_owner routes to position.owner only ─────────────
// Even if some other address ends up holding a position by value through
// a PTB result, the only place transfer_position_to_owner can send it is
// the address recorded in position.owner at stake time. This guards the
// soulbound invariant.
#[test]
fun test_transfer_position_to_owner_routes_correctly() {
    let (mut sc, clk) = bootstrap();

    // Bob calls stake_non_entry and gets the position by value.
    sc.next_tx(BOB);
    let mut vault = sc.take_shared<Vault<TEST_SUITRUMP, TEST_VICTORY>>();
    let tier = sc.take_shared<TierRegistry>();
    let coin = mint_p(STAKE_10K, sc.ctx());
    let position = single_stake::stake_non_entry(
        &mut vault, &tier, coin, LOCK_FLEXIBLE, &clk, sc.ctx(),
    );
    single_stake::transfer_position_to_owner(position);
    ts::return_shared(tier);
    ts::return_shared(vault);

    // Bob (the staker) must own the position now.
    sc.next_tx(BOB);
    let position = sc.take_from_sender<StakePosition<TEST_SUITRUMP, TEST_VICTORY>>();
    sc.return_to_sender(position);

    end_scenario(sc, clk);
}

// ── F15 mitigation: init_campaign_debt is idempotent ─────────────────────
// Calling init_campaign_debt twice (or after the position has already
// claimed) must NOT overwrite the existing debt — otherwise repeated
// init calls would zero out a position's accrued legitimate entitlement.
#[test]
fun test_f15_init_campaign_debt_is_idempotent() {
    let (mut sc, mut clk) = bootstrap();
    do_stake(&mut sc, &clk, ALICE, STAKE_10K, LOCK_FLEXIBLE);

    sc.next_tx(ADMIN);
    let admin = sc.take_from_sender<AdminCap>();
    let mut vault = sc.take_shared<Vault<TEST_SUITRUMP, TEST_VICTORY>>();
    let camp_coin = coin::mint_for_testing<TEST_CAMPAIGN>(100_000 * D6, sc.ctx());
    single_stake::create_campaign<TEST_SUITRUMP, TEST_VICTORY, TEST_CAMPAIGN>(
        &admin, &mut vault, camp_coin, NINETY_DAYS_MS, &clk,
    );
    ts::return_shared(vault);
    sc.return_to_sender(admin);

    // Alice predates campaign → init seeds debt = 0.
    sc.next_tx(ALICE);
    let mut vault = sc.take_shared<Vault<TEST_SUITRUMP, TEST_VICTORY>>();
    let mut position = sc.take_from_sender<StakePosition<TEST_SUITRUMP, TEST_VICTORY>>();
    single_stake::init_campaign_debt<TEST_SUITRUMP, TEST_VICTORY, TEST_CAMPAIGN>(
        &mut vault, &mut position, 0, &clk, sc.ctx(),
    );

    // Advance and let Alice accrue.
    clock::increment_for_testing(&mut clk, NINETY_DAYS_MS / 2);

    // Second init call — must be a no-op. If it overwrote, Alice's
    // accrued entitlement would be lost.
    single_stake::init_campaign_debt<TEST_SUITRUMP, TEST_VICTORY, TEST_CAMPAIGN>(
        &mut vault, &mut position, 0, &clk, sc.ctx(),
    );

    // Alice claims — must receive non-zero (her predating-campaign share).
    let payout = single_stake::claim_campaign<TEST_SUITRUMP, TEST_VICTORY, TEST_CAMPAIGN>(
        &mut vault, &mut position, 0, &clk, sc.ctx(),
    );
    assert!(coin::value(&payout) > 0);
    destroy(payout);

    sc.return_to_sender(position);
    ts::return_shared(vault);

    end_scenario(sc, clk);
}

// ── F15 regression: position predating campaign still earns full window ──
// Counterpart to the late-joiner test: when a position is staked BEFORE
// the campaign is created, its first claim_campaign should pay out the
// full accrued share. The fix's stake_ms ≤ campaign.start_ms branch keeps
// prior_debt = 0 in that case, preserving the original entitlement.
#[test]
fun test_f15_position_predating_campaign_claims_full_share() {
    let (mut sc, mut clk) = bootstrap();

    // Alice stakes first.
    do_stake(&mut sc, &clk, ALICE, STAKE_10K, LOCK_FLEXIBLE);

    // 1 second later admin creates the campaign — Alice predates it but
    // only barely. Time then passes and emissions accrue against her.
    clock::increment_for_testing(&mut clk, 1_000);
    sc.next_tx(ADMIN);
    let admin = sc.take_from_sender<AdminCap>();
    let mut vault = sc.take_shared<Vault<TEST_SUITRUMP, TEST_VICTORY>>();
    let camp_coin = coin::mint_for_testing<TEST_CAMPAIGN>(100_000 * D6, sc.ctx());
    single_stake::create_campaign<TEST_SUITRUMP, TEST_VICTORY, TEST_CAMPAIGN>(
        &admin, &mut vault, camp_coin, NINETY_DAYS_MS, &clk,
    );
    ts::return_shared(vault);
    sc.return_to_sender(admin);

    // Mid-campaign.
    clock::increment_for_testing(&mut clk, NINETY_DAYS_MS / 2);

    sc.next_tx(ALICE);
    let mut vault = sc.take_shared<Vault<TEST_SUITRUMP, TEST_VICTORY>>();
    let mut position = sc.take_from_sender<StakePosition<TEST_SUITRUMP, TEST_VICTORY>>();
    let payout = single_stake::claim_campaign<TEST_SUITRUMP, TEST_VICTORY, TEST_CAMPAIGN>(
        &mut vault, &mut position, 0, &clk, sc.ctx(),
    );
    // Alice was the only staker and existed before the campaign, so she
    // should claim a non-zero share of the campaign's emissions so far.
    assert!(coin::value(&payout) > 0);
    destroy(payout);
    sc.return_to_sender(position);
    ts::return_shared(vault);

    end_scenario(sc, clk);
}
