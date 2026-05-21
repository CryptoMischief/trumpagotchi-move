#[test_only]
module trumpagotchi::xp_registry_tests;

use sui::clock;
use sui::coin;
use sui::test_scenario as ts;
use trumpagotchi::trumpagotchi::{Self, AdminCap};
use trumpagotchi::xp_registry::{Self, XpRegistry};

// Test-only coin types. TEST_SUITRUMP stands in for the real SUITRUMP type
// in v16 meal-box tests; WRONG_COIN exercises the type-mismatch abort.
public struct TEST_SUITRUMP has drop {}
public struct WRONG_COIN has drop {}

const ADMIN: address = @0xA;
const ALICE: address = @0xA11CE;
const BOB:   address = @0xB0B;
const CAROL: address = @0xC0;

const ONE_DAY_MS: u64 = 86_400_000;
const TWO_DAYS_MS: u64 = 172_800_000;
const FIVE_DAYS_MS: u64 = 432_000_000;
const FOUR_DAYS_MS: u64 = 345_600_000;

fun bootstrap(): ts::Scenario {
    let mut sc = ts::begin(ADMIN);
    trumpagotchi::init_for_testing(sc.ctx());
    xp_registry::init_for_testing(sc.ctx());
    sc
}

fun take_admin_reg_clock(sc: &mut ts::Scenario): (AdminCap, XpRegistry, clock::Clock) {
    sc.next_tx(ADMIN);
    let admin = sc.take_from_sender<AdminCap>();
    let reg = sc.take_shared<XpRegistry>();
    let clk = clock::create_for_testing(sc.ctx());
    (admin, reg, clk)
}

fun put_back(sc: &mut ts::Scenario, admin: AdminCap, reg: XpRegistry, clk: clock::Clock) {
    ts::return_shared(reg);
    sc.return_to_sender(admin);
    clock::destroy_for_testing(clk);
}

// ── init / create_registry ─────────────────────────────────────────────────

// Production path: admin calls create_registry after the package upgrade
// lands this module. Tests that signature directly.
#[test]
fun test_create_registry_via_admin_cap() {
    let mut sc = ts::begin(ADMIN);
    trumpagotchi::init_for_testing(sc.ctx());

    sc.next_tx(ADMIN);
    let admin = sc.take_from_sender<AdminCap>();
    xp_registry::create_registry(&admin, sc.ctx());
    sc.return_to_sender(admin);

    sc.next_tx(ADMIN);
    let reg = sc.take_shared<XpRegistry>();
    assert!(xp_registry::rally_window_ms(&reg) == 86_400_000, 0);
    ts::return_shared(reg);
    sc.end();
}

#[test]
fun test_init_creates_empty_registry_with_defaults() {
    let mut sc = bootstrap();
    sc.next_tx(ADMIN);
    let reg = sc.take_shared<XpRegistry>();
    let clk = clock::create_for_testing(sc.ctx());
    assert!(xp_registry::rally_window_ms(&reg) == 86_400_000, 0);
    assert!(xp_registry::streak_break_ms(&reg) == 172_800_000, 1);
    assert!(xp_registry::losing_steam_threshold_ms(&reg) == 86_400_000, 2);
    assert!(xp_registry::gone_quiet_threshold_ms(&reg) == 345_600_000, 3);
    assert!(!xp_registry::has_entry(&reg, ALICE), 4);
    assert!(xp_registry::xp_of(&reg, ALICE) == 0, 5);
    assert!(xp_registry::streak_of(&reg, ALICE) == 0, 6);
    assert!(xp_registry::state_of(&reg, ALICE, &clk) == xp_registry::state_rallying(), 7);
    clock::destroy_for_testing(clk);
    ts::return_shared(reg);
    sc.end();
}

// ── add_xp ─────────────────────────────────────────────────────────────────

#[test]
fun test_add_xp_creates_entry_and_accumulates() {
    let mut sc = bootstrap();
    let (admin, mut reg, clk) = take_admin_reg_clock(&mut sc);

    xp_registry::add_xp(&admin, &mut reg, ALICE, 200, xp_registry::reason_rally(), &clk);
    assert!(xp_registry::xp_of(&reg, ALICE) == 200, 0);
    assert!(xp_registry::has_entry(&reg, ALICE), 1);

    xp_registry::add_xp(&admin, &mut reg, ALICE, 1_000, xp_registry::reason_quest_individual(), &clk);
    assert!(xp_registry::xp_of(&reg, ALICE) == 1_200, 2);

    xp_registry::add_xp(&admin, &mut reg, ALICE, 500, xp_registry::reason_raid(), &clk);
    assert!(xp_registry::xp_of(&reg, ALICE) == 1_700, 3);

    put_back(&mut sc, admin, reg, clk);
    sc.end();
}

#[test]
#[expected_failure(abort_code = xp_registry::EZeroAmount)]
fun test_add_xp_rejects_zero_amount() {
    let mut sc = bootstrap();
    let (admin, mut reg, clk) = take_admin_reg_clock(&mut sc);
    xp_registry::add_xp(&admin, &mut reg, ALICE, 0, xp_registry::reason_rally(), &clk);
    put_back(&mut sc, admin, reg, clk);
    sc.end();
}

#[test]
#[expected_failure(abort_code = xp_registry::EInvalidReasonCode)]
fun test_add_xp_rejects_invalid_reason_code() {
    let mut sc = bootstrap();
    let (admin, mut reg, clk) = take_admin_reg_clock(&mut sc);
    xp_registry::add_xp(&admin, &mut reg, ALICE, 100, 99, &clk);
    put_back(&mut sc, admin, reg, clk);
    sc.end();
}

#[test]
#[expected_failure(abort_code = xp_registry::EInvalidReasonCode)]
fun test_add_xp_rejects_reason_code_zero() {
    let mut sc = bootstrap();
    let (admin, mut reg, clk) = take_admin_reg_clock(&mut sc);
    xp_registry::add_xp(&admin, &mut reg, ALICE, 100, 0, &clk);
    put_back(&mut sc, admin, reg, clk);
    sc.end();
}

// ── batch_add_xp ───────────────────────────────────────────────────────────

#[test]
fun test_batch_add_xp_distributes_correctly() {
    let mut sc = bootstrap();
    let (admin, mut reg, clk) = take_admin_reg_clock(&mut sc);

    let addrs = vector[ALICE, BOB, CAROL];
    let amounts = vector[100u64, 200u64, 300u64];
    let reasons = vector[
        xp_registry::reason_rally(),
        xp_registry::reason_quest_community(),
        xp_registry::reason_raid(),
    ];
    xp_registry::batch_add_xp(&admin, &mut reg, addrs, amounts, reasons, &clk);

    assert!(xp_registry::xp_of(&reg, ALICE) == 100, 0);
    assert!(xp_registry::xp_of(&reg, BOB) == 200, 1);
    assert!(xp_registry::xp_of(&reg, CAROL) == 300, 2);

    put_back(&mut sc, admin, reg, clk);
    sc.end();
}

#[test]
#[expected_failure(abort_code = xp_registry::EVecLengthMismatch)]
fun test_batch_add_xp_rejects_length_mismatch() {
    let mut sc = bootstrap();
    let (admin, mut reg, clk) = take_admin_reg_clock(&mut sc);
    let addrs = vector[ALICE, BOB];
    let amounts = vector[100u64];
    let reasons = vector[xp_registry::reason_rally(), xp_registry::reason_rally()];
    xp_registry::batch_add_xp(&admin, &mut reg, addrs, amounts, reasons, &clk);
    put_back(&mut sc, admin, reg, clk);
    sc.end();
}

// ── set_xp ─────────────────────────────────────────────────────────────────

#[test]
fun test_set_xp_overrides_value() {
    let mut sc = bootstrap();
    let (admin, mut reg, clk) = take_admin_reg_clock(&mut sc);

    xp_registry::add_xp(&admin, &mut reg, ALICE, 500, xp_registry::reason_rally(), &clk);
    assert!(xp_registry::xp_of(&reg, ALICE) == 500, 0);

    // Bump up
    xp_registry::set_xp(&admin, &mut reg, ALICE, 10_000, &clk);
    assert!(xp_registry::xp_of(&reg, ALICE) == 10_000, 1);

    // Clawback (no event, but state set)
    xp_registry::set_xp(&admin, &mut reg, ALICE, 1_000, &clk);
    assert!(xp_registry::xp_of(&reg, ALICE) == 1_000, 2);

    put_back(&mut sc, admin, reg, clk);
    sc.end();
}

#[test]
fun test_set_xp_creates_entry_if_missing() {
    let mut sc = bootstrap();
    let (admin, mut reg, clk) = take_admin_reg_clock(&mut sc);
    xp_registry::set_xp(&admin, &mut reg, ALICE, 1_234, &clk);
    assert!(xp_registry::has_entry(&reg, ALICE), 0);
    assert!(xp_registry::xp_of(&reg, ALICE) == 1_234, 1);
    put_back(&mut sc, admin, reg, clk);
    sc.end();
}

// ── record_rally ───────────────────────────────────────────────────────────

#[test]
fun test_first_rally_sets_streak_to_one() {
    let mut sc = bootstrap();
    let (admin, mut reg, clk) = take_admin_reg_clock(&mut sc);
    xp_registry::record_rally(&admin, &mut reg, ALICE, &clk);
    assert!(xp_registry::streak_of(&reg, ALICE) == 1, 0);
    assert!(xp_registry::longest_streak_of(&reg, ALICE) == 1, 1);
    assert!(xp_registry::total_rallies_of(&reg, ALICE) == 1, 2);
    put_back(&mut sc, admin, reg, clk);
    sc.end();
}

#[test]
fun test_consecutive_rallies_increment_streak() {
    let mut sc = bootstrap();
    let (admin, mut reg, mut clk) = take_admin_reg_clock(&mut sc);

    xp_registry::record_rally(&admin, &mut reg, ALICE, &clk);
    clock::increment_for_testing(&mut clk, ONE_DAY_MS);
    xp_registry::record_rally(&admin, &mut reg, ALICE, &clk);
    clock::increment_for_testing(&mut clk, ONE_DAY_MS);
    xp_registry::record_rally(&admin, &mut reg, ALICE, &clk);

    assert!(xp_registry::streak_of(&reg, ALICE) == 3, 0);
    assert!(xp_registry::longest_streak_of(&reg, ALICE) == 3, 1);
    assert!(xp_registry::total_rallies_of(&reg, ALICE) == 3, 2);
    put_back(&mut sc, admin, reg, clk);
    sc.end();
}

#[test]
#[expected_failure(abort_code = xp_registry::ERallyTooSoon)]
fun test_second_rally_within_window_aborts() {
    let mut sc = bootstrap();
    let (admin, mut reg, mut clk) = take_admin_reg_clock(&mut sc);
    xp_registry::record_rally(&admin, &mut reg, ALICE, &clk);
    clock::increment_for_testing(&mut clk, ONE_DAY_MS - 1);
    xp_registry::record_rally(&admin, &mut reg, ALICE, &clk);  // should abort
    put_back(&mut sc, admin, reg, clk);
    sc.end();
}

#[test]
fun test_rally_after_break_resets_streak() {
    let mut sc = bootstrap();
    let (admin, mut reg, mut clk) = take_admin_reg_clock(&mut sc);

    // Build streak of 3
    xp_registry::record_rally(&admin, &mut reg, ALICE, &clk);
    clock::increment_for_testing(&mut clk, ONE_DAY_MS);
    xp_registry::record_rally(&admin, &mut reg, ALICE, &clk);
    clock::increment_for_testing(&mut clk, ONE_DAY_MS);
    xp_registry::record_rally(&admin, &mut reg, ALICE, &clk);
    assert!(xp_registry::streak_of(&reg, ALICE) == 3, 0);

    // Skip more than streak_break_ms (48h)
    clock::increment_for_testing(&mut clk, TWO_DAYS_MS + 1);
    xp_registry::record_rally(&admin, &mut reg, ALICE, &clk);

    assert!(xp_registry::streak_of(&reg, ALICE) == 1, 1);
    assert!(xp_registry::longest_streak_of(&reg, ALICE) == 3, 2);  // high-water preserved
    assert!(xp_registry::total_rallies_of(&reg, ALICE) == 4, 3);
    put_back(&mut sc, admin, reg, clk);
    sc.end();
}

#[test]
fun test_meal_box_preserves_streak_after_gap() {
    let mut sc = bootstrap();
    let (admin, mut reg, mut clk) = take_admin_reg_clock(&mut sc);

    xp_registry::record_rally(&admin, &mut reg, ALICE, &clk);
    clock::increment_for_testing(&mut clk, ONE_DAY_MS);
    xp_registry::record_rally(&admin, &mut reg, ALICE, &clk);
    assert!(xp_registry::streak_of(&reg, ALICE) == 2, 0);

    // Skip past streak_break (96h gap from last rally — Gone Quiet territory)
    clock::increment_for_testing(&mut clk, FOUR_DAYS_MS);

    // Buy meal box (resets state to Rallying)
    xp_registry::apply_meal_box(&admin, &mut reg, ALICE, &clk);

    // Rally same day — within rally_window of meal box. Streak preserved.
    xp_registry::record_rally(&admin, &mut reg, ALICE, &clk);
    assert!(xp_registry::streak_of(&reg, ALICE) == 3, 1);
    assert!(xp_registry::longest_streak_of(&reg, ALICE) == 3, 2);
    put_back(&mut sc, admin, reg, clk);
    sc.end();
}

#[test]
fun test_meal_box_does_not_preserve_streak_if_rally_too_late() {
    let mut sc = bootstrap();
    let (admin, mut reg, mut clk) = take_admin_reg_clock(&mut sc);

    xp_registry::record_rally(&admin, &mut reg, ALICE, &clk);
    clock::increment_for_testing(&mut clk, ONE_DAY_MS);
    xp_registry::record_rally(&admin, &mut reg, ALICE, &clk);
    assert!(xp_registry::streak_of(&reg, ALICE) == 2, 0);

    // Gone Quiet
    clock::increment_for_testing(&mut clk, FOUR_DAYS_MS);
    xp_registry::apply_meal_box(&admin, &mut reg, ALICE, &clk);

    // User waits more than rally_window after meal box before rallying — meal
    // box no longer protects. Streak resets.
    clock::increment_for_testing(&mut clk, ONE_DAY_MS + 1);
    xp_registry::record_rally(&admin, &mut reg, ALICE, &clk);
    assert!(xp_registry::streak_of(&reg, ALICE) == 1, 1);
    put_back(&mut sc, admin, reg, clk);
    sc.end();
}

// ── set_streak (admin override / paid recovery) ────────────────────────────

#[test]
fun test_set_streak_admin_override() {
    let mut sc = bootstrap();
    let (admin, mut reg, clk) = take_admin_reg_clock(&mut sc);

    xp_registry::record_rally(&admin, &mut reg, ALICE, &clk);
    assert!(xp_registry::streak_of(&reg, ALICE) == 1, 0);

    xp_registry::set_streak(&admin, &mut reg, ALICE, 30, xp_registry::reason_other(), &clk);
    assert!(xp_registry::streak_of(&reg, ALICE) == 30, 1);
    assert!(xp_registry::longest_streak_of(&reg, ALICE) == 30, 2);
    put_back(&mut sc, admin, reg, clk);
    sc.end();
}

#[test]
#[expected_failure(abort_code = xp_registry::EInvalidReasonCode)]
fun test_set_streak_rejects_invalid_reason() {
    let mut sc = bootstrap();
    let (admin, mut reg, clk) = take_admin_reg_clock(&mut sc);
    xp_registry::set_streak(&admin, &mut reg, ALICE, 5, 99, &clk);
    put_back(&mut sc, admin, reg, clk);
    sc.end();
}

// ── state_of view ──────────────────────────────────────────────────────────

#[test]
fun test_state_transitions_with_time() {
    let mut sc = bootstrap();
    let (admin, mut reg, mut clk) = take_admin_reg_clock(&mut sc);

    // No entry yet — Rallying
    assert!(xp_registry::state_of(&reg, ALICE, &clk) == xp_registry::state_rallying(), 0);

    // First rally — Rallying
    xp_registry::record_rally(&admin, &mut reg, ALICE, &clk);
    assert!(xp_registry::state_of(&reg, ALICE, &clk) == xp_registry::state_rallying(), 1);

    // 23h59m later — still Rallying
    clock::increment_for_testing(&mut clk, ONE_DAY_MS - 60_000);
    assert!(xp_registry::state_of(&reg, ALICE, &clk) == xp_registry::state_rallying(), 2);

    // 24h+ — Losing Steam
    clock::increment_for_testing(&mut clk, 120_000);
    assert!(xp_registry::state_of(&reg, ALICE, &clk) == xp_registry::state_losing_steam(), 3);

    // 96h+ — Gone Quiet
    clock::increment_for_testing(&mut clk, FOUR_DAYS_MS);
    assert!(xp_registry::state_of(&reg, ALICE, &clk) == xp_registry::state_gone_quiet(), 4);
    put_back(&mut sc, admin, reg, clk);
    sc.end();
}

// ── apply_meal_box ─────────────────────────────────────────────────────────

#[test]
fun test_apply_meal_box_records_timestamp() {
    let mut sc = bootstrap();
    let (admin, mut reg, mut clk) = take_admin_reg_clock(&mut sc);
    clock::increment_for_testing(&mut clk, 500_000);
    xp_registry::apply_meal_box(&admin, &mut reg, ALICE, &clk);
    assert!(xp_registry::meal_box_at_ms_of(&reg, ALICE) == 500_000, 0);
    assert!(xp_registry::has_entry(&reg, ALICE), 1);
    put_back(&mut sc, admin, reg, clk);
    sc.end();
}

// ── set_config ─────────────────────────────────────────────────────────────

#[test]
fun test_set_config_updates_all_thresholds() {
    let mut sc = bootstrap();
    let (admin, mut reg, clk) = take_admin_reg_clock(&mut sc);
    xp_registry::set_config(
        &admin, &mut reg,
        100, 200, 300, 400,
        &clk,
    );
    assert!(xp_registry::rally_window_ms(&reg) == 100, 0);
    assert!(xp_registry::streak_break_ms(&reg) == 200, 1);
    assert!(xp_registry::losing_steam_threshold_ms(&reg) == 300, 2);
    assert!(xp_registry::gone_quiet_threshold_ms(&reg) == 400, 3);
    put_back(&mut sc, admin, reg, clk);
    sc.end();
}

// ── view helpers ───────────────────────────────────────────────────────────

#[test]
fun test_view_functions_return_zero_for_missing_entry() {
    let mut sc = bootstrap();
    sc.next_tx(ADMIN);
    let reg = sc.take_shared<XpRegistry>();
    assert!(xp_registry::xp_of(&reg, BOB) == 0, 0);
    assert!(xp_registry::streak_of(&reg, BOB) == 0, 1);
    assert!(xp_registry::longest_streak_of(&reg, BOB) == 0, 2);
    assert!(xp_registry::last_rally_ms_of(&reg, BOB) == 0, 3);
    assert!(xp_registry::total_rallies_of(&reg, BOB) == 0, 4);
    assert!(xp_registry::meal_box_at_ms_of(&reg, BOB) == 0, 5);
    assert!(!xp_registry::has_entry(&reg, BOB), 6);
    ts::return_shared(reg);
    sc.end();
}

#[test]
fun test_entry_of_returns_struct_with_accessors() {
    let mut sc = bootstrap();
    let (admin, mut reg, clk) = take_admin_reg_clock(&mut sc);

    xp_registry::add_xp(&admin, &mut reg, ALICE, 750, xp_registry::reason_quest_individual(), &clk);
    xp_registry::record_rally(&admin, &mut reg, ALICE, &clk);

    let entry = xp_registry::entry_of(&reg, ALICE);
    assert!(xp_registry::entry_xp(&entry) == 750, 0);
    assert!(xp_registry::entry_streak(&entry) == 1, 1);
    assert!(xp_registry::entry_total_rallies(&entry) == 1, 2);
    assert!(xp_registry::entry_meal_box_at_ms(&entry) == 0, 3);

    put_back(&mut sc, admin, reg, clk);
    sc.end();
}

// ── reason / state code stability (constants don't drift) ─────────────────

#[test]
fun test_reason_and_state_codes() {
    assert!(xp_registry::reason_rally() == 1, 0);
    assert!(xp_registry::reason_quest_individual() == 2, 1);
    assert!(xp_registry::reason_quest_community() == 3, 2);
    assert!(xp_registry::reason_raid() == 4, 3);
    assert!(xp_registry::reason_streak_bonus() == 5, 4);
    assert!(xp_registry::reason_admin_grant() == 6, 5);
    assert!(xp_registry::reason_other() == 7, 6);
    assert!(xp_registry::state_rallying() == 0, 7);
    assert!(xp_registry::state_losing_steam() == 1, 8);
    assert!(xp_registry::state_gone_quiet() == 2, 9);
}

// ── full rally cadence (7-day streak shape) ────────────────────────────────

#[test]
fun test_seven_day_rally_cadence() {
    let mut sc = bootstrap();
    let (admin, mut reg, mut clk) = take_admin_reg_clock(&mut sc);

    let mut i: u64 = 0;
    while (i < 7) {
        xp_registry::record_rally(&admin, &mut reg, ALICE, &clk);
        // Award rally XP (backend bundles this into same PTB in prod)
        xp_registry::add_xp(&admin, &mut reg, ALICE, 200, xp_registry::reason_rally(), &clk);
        clock::increment_for_testing(&mut clk, ONE_DAY_MS);
        i = i + 1;
    };

    assert!(xp_registry::streak_of(&reg, ALICE) == 7, 0);
    assert!(xp_registry::total_rallies_of(&reg, ALICE) == 7, 1);
    assert!(xp_registry::xp_of(&reg, ALICE) == 1_400, 2);  // 200 × 7

    // Backend awards 7-day streak bonus
    xp_registry::add_xp(&admin, &mut reg, ALICE, 500, xp_registry::reason_streak_bonus(), &clk);
    assert!(xp_registry::xp_of(&reg, ALICE) == 1_900, 3);

    put_back(&mut sc, admin, reg, clk);
    sc.end();
}

// ── buy_meal_box (v16, on-chain user flow) ─────────────────────────────────

// Helper: drives a wallet to Gone Quiet state by rallying once then
// advancing the clock past gone_quiet_threshold_ms (96h default).
fun seed_gone_quiet(
    sc: &mut ts::Scenario,
    admin: &AdminCap,
    reg: &mut XpRegistry,
    clk: &mut clock::Clock,
    addr: address,
) {
    xp_registry::record_rally(admin, reg, addr, clk);
    // 96h + 1ms — strictly past the Gone Quiet threshold (>=, so 96h exact works too).
    clock::increment_for_testing(clk, FOUR_DAYS_MS + 1);
    let _ = sc;
}

#[test]
fun test_admin_set_meal_box_coin_initializes_type() {
    let mut sc = bootstrap();
    let (admin, mut reg, clk) = take_admin_reg_clock(&mut sc);

    // Before init the read-side option is none.
    assert!(std::option::is_none(&xp_registry::meal_box_coin_type(&reg)), 0);

    xp_registry::admin_set_meal_box_coin<TEST_SUITRUMP>(&admin, &mut reg, &clk);
    assert!(std::option::is_some(&xp_registry::meal_box_coin_type(&reg)), 1);

    // Rotate to a different type — exercises the "update existing" path.
    xp_registry::admin_set_meal_box_coin<WRONG_COIN>(&admin, &mut reg, &clk);
    let opt = xp_registry::meal_box_coin_type(&reg);
    assert!(std::option::is_some(&opt), 2);

    put_back(&mut sc, admin, reg, clk);
    sc.end();
}

#[test]
fun test_buy_meal_box_happy_path() {
    let mut sc = bootstrap();
    let (admin, mut reg, mut clk) = take_admin_reg_clock(&mut sc);

    xp_registry::admin_set_meal_box_coin<TEST_SUITRUMP>(&admin, &mut reg, &clk);
    seed_gone_quiet(&mut sc, &admin, &mut reg, &mut clk, ALICE);
    assert!(xp_registry::state_of(&reg, ALICE, &clk) == xp_registry::state_gone_quiet(), 0);

    // Switch sender to ALICE for the buy.
    sc.next_tx(ALICE);
    let payment = coin::mint_for_testing<TEST_SUITRUMP>(xp_registry::meal_box_price(), sc.ctx());
    xp_registry::buy_meal_box<TEST_SUITRUMP>(&mut reg, payment, &clk, sc.ctx());

    // meal_box_at_ms stamped to current clock.
    let now = clock::timestamp_ms(&clk);
    assert!(xp_registry::meal_box_at_ms_of(&reg, ALICE) == now, 1);

    sc.next_tx(ADMIN);
    put_back(&mut sc, admin, reg, clk);
    sc.end();
}

#[test]
fun test_buy_meal_box_allows_overpayment() {
    let mut sc = bootstrap();
    let (admin, mut reg, mut clk) = take_admin_reg_clock(&mut sc);

    xp_registry::admin_set_meal_box_coin<TEST_SUITRUMP>(&admin, &mut reg, &clk);
    seed_gone_quiet(&mut sc, &admin, &mut reg, &mut clk, ALICE);

    sc.next_tx(ALICE);
    // 2× the price — should still succeed; overpayment burns entirely.
    let payment = coin::mint_for_testing<TEST_SUITRUMP>(
        xp_registry::meal_box_price() * 2,
        sc.ctx(),
    );
    xp_registry::buy_meal_box<TEST_SUITRUMP>(&mut reg, payment, &clk, sc.ctx());

    sc.next_tx(ADMIN);
    put_back(&mut sc, admin, reg, clk);
    sc.end();
}

#[test]
#[expected_failure(abort_code = xp_registry::EMealBoxNotInitialized)]
fun test_buy_meal_box_aborts_when_coin_type_not_initialized() {
    let mut sc = bootstrap();
    let (admin, mut reg, mut clk) = take_admin_reg_clock(&mut sc);

    // Skip admin_set_meal_box_coin — should abort EMealBoxNotInitialized.
    seed_gone_quiet(&mut sc, &admin, &mut reg, &mut clk, ALICE);

    sc.next_tx(ALICE);
    let payment = coin::mint_for_testing<TEST_SUITRUMP>(xp_registry::meal_box_price(), sc.ctx());
    xp_registry::buy_meal_box<TEST_SUITRUMP>(&mut reg, payment, &clk, sc.ctx());

    put_back(&mut sc, admin, reg, clk);
    sc.end();
}

#[test]
#[expected_failure(abort_code = xp_registry::EWrongCoinType)]
fun test_buy_meal_box_aborts_on_wrong_coin_type() {
    let mut sc = bootstrap();
    let (admin, mut reg, mut clk) = take_admin_reg_clock(&mut sc);

    xp_registry::admin_set_meal_box_coin<TEST_SUITRUMP>(&admin, &mut reg, &clk);
    seed_gone_quiet(&mut sc, &admin, &mut reg, &mut clk, ALICE);

    sc.next_tx(ALICE);
    let payment = coin::mint_for_testing<WRONG_COIN>(xp_registry::meal_box_price(), sc.ctx());
    xp_registry::buy_meal_box<WRONG_COIN>(&mut reg, payment, &clk, sc.ctx());

    put_back(&mut sc, admin, reg, clk);
    sc.end();
}

#[test]
#[expected_failure(abort_code = xp_registry::EInsufficientPayment)]
fun test_buy_meal_box_aborts_on_insufficient_payment() {
    let mut sc = bootstrap();
    let (admin, mut reg, mut clk) = take_admin_reg_clock(&mut sc);

    xp_registry::admin_set_meal_box_coin<TEST_SUITRUMP>(&admin, &mut reg, &clk);
    seed_gone_quiet(&mut sc, &admin, &mut reg, &mut clk, ALICE);

    sc.next_tx(ALICE);
    let payment = coin::mint_for_testing<TEST_SUITRUMP>(
        xp_registry::meal_box_price() - 1,
        sc.ctx(),
    );
    xp_registry::buy_meal_box<TEST_SUITRUMP>(&mut reg, payment, &clk, sc.ctx());

    put_back(&mut sc, admin, reg, clk);
    sc.end();
}

#[test]
#[expected_failure(abort_code = xp_registry::ENotGoneQuiet)]
fun test_buy_meal_box_aborts_when_rallying() {
    let mut sc = bootstrap();
    let (admin, mut reg, clk) = take_admin_reg_clock(&mut sc);

    xp_registry::admin_set_meal_box_coin<TEST_SUITRUMP>(&admin, &mut reg, &clk);
    // ALICE never rallied → STATE_RALLYING. Should abort ENotGoneQuiet.

    sc.next_tx(ALICE);
    let payment = coin::mint_for_testing<TEST_SUITRUMP>(xp_registry::meal_box_price(), sc.ctx());
    xp_registry::buy_meal_box<TEST_SUITRUMP>(&mut reg, payment, &clk, sc.ctx());

    put_back(&mut sc, admin, reg, clk);
    sc.end();
}

#[test]
#[expected_failure(abort_code = xp_registry::ENotGoneQuiet)]
fun test_buy_meal_box_aborts_when_losing_steam() {
    let mut sc = bootstrap();
    let (admin, mut reg, mut clk) = take_admin_reg_clock(&mut sc);

    xp_registry::admin_set_meal_box_coin<TEST_SUITRUMP>(&admin, &mut reg, &clk);
    xp_registry::record_rally(&admin, &mut reg, ALICE, &clk);
    // 25h gap → Losing Steam, NOT Gone Quiet yet.
    clock::increment_for_testing(&mut clk, ONE_DAY_MS + 3_600_000);
    assert!(xp_registry::state_of(&reg, ALICE, &clk) == xp_registry::state_losing_steam(), 0);

    sc.next_tx(ALICE);
    let payment = coin::mint_for_testing<TEST_SUITRUMP>(xp_registry::meal_box_price(), sc.ctx());
    xp_registry::buy_meal_box<TEST_SUITRUMP>(&mut reg, payment, &clk, sc.ctx());

    put_back(&mut sc, admin, reg, clk);
    sc.end();
}

// End-to-end: Gone Quiet → buy meal box → rally within rally_window →
// streak is preserved instead of being reset.
#[test]
fun test_buy_meal_box_then_rally_preserves_streak() {
    let mut sc = bootstrap();
    let (admin, mut reg, mut clk) = take_admin_reg_clock(&mut sc);

    xp_registry::admin_set_meal_box_coin<TEST_SUITRUMP>(&admin, &mut reg, &clk);

    // Build a 3-day streak first.
    xp_registry::record_rally(&admin, &mut reg, ALICE, &clk);
    clock::increment_for_testing(&mut clk, ONE_DAY_MS);
    xp_registry::record_rally(&admin, &mut reg, ALICE, &clk);
    clock::increment_for_testing(&mut clk, ONE_DAY_MS);
    xp_registry::record_rally(&admin, &mut reg, ALICE, &clk);
    assert!(xp_registry::streak_of(&reg, ALICE) == 3, 0);

    // Lapse to Gone Quiet (>= 96h since last rally).
    clock::increment_for_testing(&mut clk, FOUR_DAYS_MS + 1);
    assert!(xp_registry::state_of(&reg, ALICE, &clk) == xp_registry::state_gone_quiet(), 1);

    // Buy meal box.
    sc.next_tx(ALICE);
    let payment = coin::mint_for_testing<TEST_SUITRUMP>(xp_registry::meal_box_price(), sc.ctx());
    xp_registry::buy_meal_box<TEST_SUITRUMP>(&mut reg, payment, &clk, sc.ctx());

    // Rally inside the rally_window — streak preserved (3 + 1 = 4),
    // not reset to 1. This is the spec §4.5 contract.
    sc.next_tx(ADMIN);
    xp_registry::record_rally(&admin, &mut reg, ALICE, &clk);
    assert!(xp_registry::streak_of(&reg, ALICE) == 4, 2);

    put_back(&mut sc, admin, reg, clk);
    sc.end();
}

#[test]
fun test_meal_box_price_constant() {
    assert!(xp_registry::meal_box_price() == 5_000_000_000, 0);
}

// ── buy_meal_box_and_rally (v17, atomic one-signature flow) ────────────────

#[test]
fun test_buy_meal_box_and_rally_happy_path() {
    let mut sc = bootstrap();
    let (admin, mut reg, mut clk) = take_admin_reg_clock(&mut sc);

    xp_registry::admin_set_meal_box_coin<TEST_SUITRUMP>(&admin, &mut reg, &clk);
    // Build a 3-day streak first so we can verify it's preserved (not reset).
    xp_registry::record_rally(&admin, &mut reg, ALICE, &clk);
    clock::increment_for_testing(&mut clk, ONE_DAY_MS);
    xp_registry::record_rally(&admin, &mut reg, ALICE, &clk);
    clock::increment_for_testing(&mut clk, ONE_DAY_MS);
    xp_registry::record_rally(&admin, &mut reg, ALICE, &clk);
    assert!(xp_registry::streak_of(&reg, ALICE) == 3, 0);
    let xp_before = xp_registry::xp_of(&reg, ALICE);

    // Lapse to Gone Quiet
    clock::increment_for_testing(&mut clk, FOUR_DAYS_MS + 1);
    assert!(xp_registry::state_of(&reg, ALICE, &clk) == xp_registry::state_gone_quiet(), 1);

    // Atomic buy + rally
    sc.next_tx(ALICE);
    let payment = coin::mint_for_testing<TEST_SUITRUMP>(
        xp_registry::meal_box_price(),
        sc.ctx(),
    );
    xp_registry::buy_meal_box_and_rally<TEST_SUITRUMP>(&mut reg, payment, &clk, sc.ctx());

    // Streak preserved (3 + 1 = 4), not reset to 1.
    assert!(xp_registry::streak_of(&reg, ALICE) == 4, 2);
    assert!(xp_registry::longest_streak_of(&reg, ALICE) == 4, 3);
    // +200 XP awarded
    assert!(xp_registry::xp_of(&reg, ALICE) == xp_before + 200, 4);
    // meal_box stamped + last_rally_ms updated
    let now = clock::timestamp_ms(&clk);
    assert!(xp_registry::meal_box_at_ms_of(&reg, ALICE) == now, 5);
    assert!(xp_registry::last_rally_ms_of(&reg, ALICE) == now, 6);
    assert!(xp_registry::total_rallies_of(&reg, ALICE) == 4, 7);
    // State flipped back to Rallying (last_rally_ms == now)
    assert!(xp_registry::state_of(&reg, ALICE, &clk) == xp_registry::state_rallying(), 8);

    sc.next_tx(ADMIN);
    put_back(&mut sc, admin, reg, clk);
    sc.end();
}

#[test]
#[expected_failure(abort_code = xp_registry::EWrongCoinType)]
fun test_buy_meal_box_and_rally_aborts_on_wrong_coin_type() {
    let mut sc = bootstrap();
    let (admin, mut reg, mut clk) = take_admin_reg_clock(&mut sc);

    xp_registry::admin_set_meal_box_coin<TEST_SUITRUMP>(&admin, &mut reg, &clk);
    seed_gone_quiet(&mut sc, &admin, &mut reg, &mut clk, ALICE);

    sc.next_tx(ALICE);
    let payment = coin::mint_for_testing<WRONG_COIN>(xp_registry::meal_box_price(), sc.ctx());
    xp_registry::buy_meal_box_and_rally<WRONG_COIN>(&mut reg, payment, &clk, sc.ctx());

    sc.next_tx(ADMIN);
    put_back(&mut sc, admin, reg, clk);
    sc.end();
}

#[test]
#[expected_failure(abort_code = xp_registry::EInsufficientPayment)]
fun test_buy_meal_box_and_rally_aborts_on_insufficient_payment() {
    let mut sc = bootstrap();
    let (admin, mut reg, mut clk) = take_admin_reg_clock(&mut sc);

    xp_registry::admin_set_meal_box_coin<TEST_SUITRUMP>(&admin, &mut reg, &clk);
    seed_gone_quiet(&mut sc, &admin, &mut reg, &mut clk, ALICE);

    sc.next_tx(ALICE);
    let payment = coin::mint_for_testing<TEST_SUITRUMP>(
        xp_registry::meal_box_price() - 1,
        sc.ctx(),
    );
    xp_registry::buy_meal_box_and_rally<TEST_SUITRUMP>(&mut reg, payment, &clk, sc.ctx());

    sc.next_tx(ADMIN);
    put_back(&mut sc, admin, reg, clk);
    sc.end();
}

#[test]
#[expected_failure(abort_code = xp_registry::ENotGoneQuiet)]
fun test_buy_meal_box_and_rally_aborts_when_rallying() {
    let mut sc = bootstrap();
    let (admin, mut reg, clk) = take_admin_reg_clock(&mut sc);

    xp_registry::admin_set_meal_box_coin<TEST_SUITRUMP>(&admin, &mut reg, &clk);
    // ALICE never rallied → STATE_RALLYING. Atomic path requires Gone Quiet.

    sc.next_tx(ALICE);
    let payment = coin::mint_for_testing<TEST_SUITRUMP>(xp_registry::meal_box_price(), sc.ctx());
    xp_registry::buy_meal_box_and_rally<TEST_SUITRUMP>(&mut reg, payment, &clk, sc.ctx());

    sc.next_tx(ADMIN);
    put_back(&mut sc, admin, reg, clk);
    sc.end();
}

#[test]
#[expected_failure(abort_code = xp_registry::EMealBoxNotInitialized)]
fun test_buy_meal_box_and_rally_aborts_when_coin_type_not_initialized() {
    let mut sc = bootstrap();
    let (admin, mut reg, mut clk) = take_admin_reg_clock(&mut sc);

    // Skip admin_set_meal_box_coin — should abort EMealBoxNotInitialized.
    seed_gone_quiet(&mut sc, &admin, &mut reg, &mut clk, ALICE);

    sc.next_tx(ALICE);
    let payment = coin::mint_for_testing<TEST_SUITRUMP>(xp_registry::meal_box_price(), sc.ctx());
    xp_registry::buy_meal_box_and_rally<TEST_SUITRUMP>(&mut reg, payment, &clk, sc.ctx());

    sc.next_tx(ADMIN);
    put_back(&mut sc, admin, reg, clk);
    sc.end();
}
