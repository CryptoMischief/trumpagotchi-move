#[test_only]
module trumpagotchi::shop_tests;

use std::string;
use sui::clock;
use sui::coin;
use sui::sui::SUI;
use sui::test_scenario as ts;
use trumpagotchi::shop::{Self, Shop};
use trumpagotchi::trumpagotchi::{Self, Cosmetic, AdminCap, TierRegistry};

const ADMIN: address = @0xA;
const ALICE: address = @0xA11CE;

const BUY_BURN_ADDR: address = @0xB001;
const LP_ADDR: address       = @0xB002;
const VICTORY_ADDR: address  = @0xB003;
const PRIZE_ADDR: address    = @0xB004;
const DEV_ADDR: address      = @0xB005;

const SUI_1: u64 = 1_000_000_000;
const TUXEDO_PRICE: u64 = 5_000_000_000;  // 5 SUI

fun bootstrap(): ts::Scenario {
    let mut sc = ts::begin(ADMIN);
    trumpagotchi::init_for_testing(sc.ctx());
    shop::init_for_testing(sc.ctx());

    sc.next_tx(ADMIN);
    let admin = sc.take_from_sender<AdminCap>();
    let mut shop_obj = sc.take_shared<Shop>();
    shop::admin_set_addresses(
        &admin, &mut shop_obj,
        BUY_BURN_ADDR, LP_ADDR, VICTORY_ADDR, PRIZE_ADDR, DEV_ADDR,
    );
    ts::return_shared(shop_obj);
    sc.return_to_sender(admin);
    sc
}

// Push a tier onto the registry for `who`. Lets tests simulate a holder at
// any tier so the shop's tier-gate check can be exercised both ways.
fun set_tier(sc: &mut ts::Scenario, clk: &clock::Clock, who: address, tier: u8) {
    sc.next_tx(ADMIN);
    let admin = sc.take_from_sender<AdminCap>();
    let mut tier_reg = sc.take_shared<TierRegistry>();
    trumpagotchi::set_tier(
        &admin, &mut tier_reg, who, tier, 0,
        string::utf8(b"Tier1-FakeNews"),
        string::utf8(b"BlackStars"),
        clk,
    );
    ts::return_shared(tier_reg);
    sc.return_to_sender(admin);
}

// Add a Tuxedo listing (tier-gate 4) at TUXEDO_PRICE with N initial stock.
fun add_tuxedo(sc: &mut ts::Scenario, clk: &clock::Clock, stock: u64): u64 {
    sc.next_tx(ADMIN);
    let admin = sc.take_from_sender<AdminCap>();
    let mut shop_obj = sc.take_shared<Shop>();
    let sku = shop::admin_add_listing(
        &admin, &mut shop_obj,
        0,                                       // outfit
        string::utf8(b"Tuxedo"),
        4,                                       // tier_gate = 4
        1,                                       // rarity = rare
        string::utf8(b"TUXEDO.png"),
        string::utf8(b"Tuxedo"),
        TUXEDO_PRICE,
        stock,
        clk,
    );
    ts::return_shared(shop_obj);
    sc.return_to_sender(admin);
    sku
}

fun sui_balance_of(sc: &mut ts::Scenario, who: address): u64 {
    if (!ts::has_most_recent_for_address<coin::Coin<SUI>>(who)) return 0;
    let c = sc.take_from_address<coin::Coin<SUI>>(who);
    let v = coin::value(&c);
    ts::return_to_address(who, c);
    v
}

#[test]
fun test_init_creates_empty_shop() {
    let mut sc = bootstrap();
    sc.next_tx(ADMIN);
    let s = sc.take_shared<Shop>();
    assert!(shop::next_sku(&s) == 1, 0);
    assert!(!shop::paused(&s), 1);
    assert!(shop::total_purchases(&s) == 0, 2);
    assert!(shop::total_revenue_mist(&s) == 0, 3);
    ts::return_shared(s);
    sc.end();
}

#[test]
fun test_admin_add_listing_assigns_sequential_sku() {
    let mut sc = bootstrap();
    let clk = clock::create_for_testing(sc.ctx());

    let sku1 = add_tuxedo(&mut sc, &clk, 10);
    assert!(sku1 == 1, 0);
    let sku2 = add_tuxedo(&mut sc, &clk, 5);
    assert!(sku2 == 2, 1);

    sc.next_tx(ADMIN);
    let s = sc.take_shared<Shop>();
    assert!(shop::next_sku(&s) == 3, 2);
    let l = shop::listing(&s, sku1);
    assert!(shop::listing_stock(&l) == 10, 3);
    assert!(shop::listing_price_mist(&l) == TUXEDO_PRICE, 4);
    assert!(shop::listing_tier_gate(&l) == 4, 5);
    assert!(shop::listing_active(&l), 6);
    ts::return_shared(s);

    clock::destroy_for_testing(clk);
    sc.end();
}

#[test]
fun test_buy_at_tier_succeeds_and_splits_sui() {
    let mut sc = bootstrap();
    let clk = clock::create_for_testing(sc.ctx());
    let sku = add_tuxedo(&mut sc, &clk, 3);
    set_tier(&mut sc, &clk, ALICE, 5);  // T5 > tier_gate 4

    sc.next_tx(ALICE);
    let mut shop_obj = sc.take_shared<Shop>();
    let tier_reg = sc.take_shared<TierRegistry>();
    let pay = coin::mint_for_testing<SUI>(TUXEDO_PRICE, sc.ctx());
    shop::buy_cosmetic(&mut shop_obj, &tier_reg, sku, pay, &clk, sc.ctx());
    ts::return_shared(shop_obj);
    ts::return_shared(tier_reg);

    sc.next_tx(ADMIN);
    let s = sc.take_shared<Shop>();
    let l = shop::listing(&s, sku);
    assert!(shop::listing_stock(&l) == 2, 0);
    assert!(shop::listing_total_minted(&l) == 1, 1);
    assert!(shop::total_purchases(&s) == 1, 2);
    assert!(shop::total_revenue_mist(&s) == TUXEDO_PRICE, 3);
    ts::return_shared(s);

    // Cosmetic must have landed with ALICE.
    sc.next_tx(ALICE);
    assert!(ts::has_most_recent_for_address<Cosmetic>(ALICE), 4);

    // SUI splits sum to TUXEDO_PRICE — buy_burn 25%, lp 20%, victory 30%,
    // prize 10%, dev = remainder (~15%).
    let bb = sui_balance_of(&mut sc, BUY_BURN_ADDR);
    let lp = sui_balance_of(&mut sc, LP_ADDR);
    let vt = sui_balance_of(&mut sc, VICTORY_ADDR);
    let pz = sui_balance_of(&mut sc, PRIZE_ADDR);
    let dv = sui_balance_of(&mut sc, DEV_ADDR);
    assert!(bb == TUXEDO_PRICE * 2_500 / 10_000, 5);
    assert!(lp == TUXEDO_PRICE * 2_000 / 10_000, 6);
    assert!(vt == TUXEDO_PRICE * 3_000 / 10_000, 7);
    assert!(pz == TUXEDO_PRICE * 1_000 / 10_000, 8);
    assert!(bb + lp + vt + pz + dv == TUXEDO_PRICE, 9);

    clock::destroy_for_testing(clk);
    sc.end();
}

#[test]
#[expected_failure(abort_code = shop::EBelowTierGate)]
fun test_buy_below_tier_fails() {
    let mut sc = bootstrap();
    let clk = clock::create_for_testing(sc.ctx());
    let sku = add_tuxedo(&mut sc, &clk, 3);
    set_tier(&mut sc, &clk, ALICE, 2);  // below the gate of 4

    sc.next_tx(ALICE);
    let mut shop_obj = sc.take_shared<Shop>();
    let tier_reg = sc.take_shared<TierRegistry>();
    let pay = coin::mint_for_testing<SUI>(TUXEDO_PRICE, sc.ctx());
    shop::buy_cosmetic(&mut shop_obj, &tier_reg, sku, pay, &clk, sc.ctx());
    ts::return_shared(shop_obj);
    ts::return_shared(tier_reg);
    clock::destroy_for_testing(clk);
    sc.end();
}

#[test]
#[expected_failure(abort_code = shop::EWrongAmount)]
fun test_buy_wrong_amount_fails() {
    let mut sc = bootstrap();
    let clk = clock::create_for_testing(sc.ctx());
    let sku = add_tuxedo(&mut sc, &clk, 3);
    set_tier(&mut sc, &clk, ALICE, 5);

    sc.next_tx(ALICE);
    let mut shop_obj = sc.take_shared<Shop>();
    let tier_reg = sc.take_shared<TierRegistry>();
    // Pay 1 SUI under the listed price — should abort with EWrongAmount.
    let pay = coin::mint_for_testing<SUI>(TUXEDO_PRICE - SUI_1, sc.ctx());
    shop::buy_cosmetic(&mut shop_obj, &tier_reg, sku, pay, &clk, sc.ctx());
    ts::return_shared(shop_obj);
    ts::return_shared(tier_reg);
    clock::destroy_for_testing(clk);
    sc.end();
}

#[test]
#[expected_failure(abort_code = shop::ESoldOut)]
fun test_buy_sold_out_fails() {
    let mut sc = bootstrap();
    let clk = clock::create_for_testing(sc.ctx());
    // Single-stock listing — drain it then try a second buy.
    let sku = add_tuxedo(&mut sc, &clk, 1);
    set_tier(&mut sc, &clk, ALICE, 5);

    sc.next_tx(ALICE);
    let mut shop_obj = sc.take_shared<Shop>();
    let tier_reg = sc.take_shared<TierRegistry>();
    let pay = coin::mint_for_testing<SUI>(TUXEDO_PRICE, sc.ctx());
    shop::buy_cosmetic(&mut shop_obj, &tier_reg, sku, pay, &clk, sc.ctx());
    ts::return_shared(shop_obj);
    ts::return_shared(tier_reg);

    sc.next_tx(ALICE);
    let mut shop_obj = sc.take_shared<Shop>();
    let tier_reg = sc.take_shared<TierRegistry>();
    let pay2 = coin::mint_for_testing<SUI>(TUXEDO_PRICE, sc.ctx());
    shop::buy_cosmetic(&mut shop_obj, &tier_reg, sku, pay2, &clk, sc.ctx());
    ts::return_shared(shop_obj);
    ts::return_shared(tier_reg);
    clock::destroy_for_testing(clk);
    sc.end();
}

#[test]
fun test_restock_adds_stock() {
    let mut sc = bootstrap();
    let clk = clock::create_for_testing(sc.ctx());
    let sku = add_tuxedo(&mut sc, &clk, 1);

    sc.next_tx(ADMIN);
    let admin = sc.take_from_sender<AdminCap>();
    let mut shop_obj = sc.take_shared<Shop>();
    shop::admin_restock(&admin, &mut shop_obj, sku, 9, &clk);
    let l = shop::listing(&shop_obj, sku);
    assert!(shop::listing_stock(&l) == 10, 0);
    ts::return_shared(shop_obj);
    sc.return_to_sender(admin);

    clock::destroy_for_testing(clk);
    sc.end();
}

#[test]
fun test_set_price_changes_listing() {
    let mut sc = bootstrap();
    let clk = clock::create_for_testing(sc.ctx());
    let sku = add_tuxedo(&mut sc, &clk, 5);

    sc.next_tx(ADMIN);
    let admin = sc.take_from_sender<AdminCap>();
    let mut shop_obj = sc.take_shared<Shop>();
    shop::admin_set_price(&admin, &mut shop_obj, sku, 8 * SUI_1, &clk);
    let l = shop::listing(&shop_obj, sku);
    assert!(shop::listing_price_mist(&l) == 8 * SUI_1, 0);
    ts::return_shared(shop_obj);
    sc.return_to_sender(admin);

    clock::destroy_for_testing(clk);
    sc.end();
}

#[test]
#[expected_failure(abort_code = shop::ENotActive)]
fun test_set_active_false_blocks_buy() {
    let mut sc = bootstrap();
    let clk = clock::create_for_testing(sc.ctx());
    let sku = add_tuxedo(&mut sc, &clk, 5);
    set_tier(&mut sc, &clk, ALICE, 5);

    // Soft-disable.
    sc.next_tx(ADMIN);
    let admin = sc.take_from_sender<AdminCap>();
    let mut shop_obj = sc.take_shared<Shop>();
    shop::admin_set_active(&admin, &mut shop_obj, sku, false, &clk);
    ts::return_shared(shop_obj);
    sc.return_to_sender(admin);

    sc.next_tx(ALICE);
    let mut shop_obj = sc.take_shared<Shop>();
    let tier_reg = sc.take_shared<TierRegistry>();
    let pay = coin::mint_for_testing<SUI>(TUXEDO_PRICE, sc.ctx());
    shop::buy_cosmetic(&mut shop_obj, &tier_reg, sku, pay, &clk, sc.ctx());
    ts::return_shared(shop_obj);
    ts::return_shared(tier_reg);
    clock::destroy_for_testing(clk);
    sc.end();
}

#[test]
#[expected_failure(abort_code = shop::EPaused)]
fun test_paused_shop_blocks_buy() {
    let mut sc = bootstrap();
    let clk = clock::create_for_testing(sc.ctx());
    let sku = add_tuxedo(&mut sc, &clk, 5);
    set_tier(&mut sc, &clk, ALICE, 5);

    sc.next_tx(ADMIN);
    let admin = sc.take_from_sender<AdminCap>();
    let mut shop_obj = sc.take_shared<Shop>();
    shop::admin_set_paused(&admin, &mut shop_obj, true);
    ts::return_shared(shop_obj);
    sc.return_to_sender(admin);

    sc.next_tx(ALICE);
    let mut shop_obj = sc.take_shared<Shop>();
    let tier_reg = sc.take_shared<TierRegistry>();
    let pay = coin::mint_for_testing<SUI>(TUXEDO_PRICE, sc.ctx());
    shop::buy_cosmetic(&mut shop_obj, &tier_reg, sku, pay, &clk, sc.ctx());
    ts::return_shared(shop_obj);
    ts::return_shared(tier_reg);
    clock::destroy_for_testing(clk);
    sc.end();
}

#[test]
fun test_remove_listing_clears_sku() {
    let mut sc = bootstrap();
    let clk = clock::create_for_testing(sc.ctx());
    let sku = add_tuxedo(&mut sc, &clk, 5);

    sc.next_tx(ADMIN);
    let admin = sc.take_from_sender<AdminCap>();
    let mut shop_obj = sc.take_shared<Shop>();
    shop::admin_remove_listing(&admin, &mut shop_obj, sku, &clk);
    assert!(!shop::listing_exists(&shop_obj, sku), 0);
    ts::return_shared(shop_obj);
    sc.return_to_sender(admin);

    clock::destroy_for_testing(clk);
    sc.end();
}

#[test]
#[expected_failure(abort_code = shop::ENoListing)]
fun test_buy_unknown_sku_fails() {
    let mut sc = bootstrap();
    let clk = clock::create_for_testing(sc.ctx());
    set_tier(&mut sc, &clk, ALICE, 5);

    sc.next_tx(ALICE);
    let mut shop_obj = sc.take_shared<Shop>();
    let tier_reg = sc.take_shared<TierRegistry>();
    let pay = coin::mint_for_testing<SUI>(TUXEDO_PRICE, sc.ctx());
    shop::buy_cosmetic(&mut shop_obj, &tier_reg, 999, pay, &clk, sc.ctx());
    ts::return_shared(shop_obj);
    ts::return_shared(tier_reg);
    clock::destroy_for_testing(clk);
    sc.end();
}

#[test]
#[expected_failure(abort_code = shop::EInvalidKind)]
fun test_add_invalid_kind_fails() {
    let mut sc = bootstrap();
    let clk = clock::create_for_testing(sc.ctx());

    sc.next_tx(ADMIN);
    let admin = sc.take_from_sender<AdminCap>();
    let mut shop_obj = sc.take_shared<Shop>();
    shop::admin_add_listing(
        &admin, &mut shop_obj,
        7,  // invalid kind
        string::utf8(b"Bogus"),
        1, 0,
        string::utf8(b"x.png"),
        string::utf8(b"x"),
        SUI_1, 1,
        &clk,
    );
    ts::return_shared(shop_obj);
    sc.return_to_sender(admin);
    clock::destroy_for_testing(clk);
    sc.end();
}

// ── admin_set_* field-edit functions (v15 additions) ──────────────────────

#[test]
fun test_admin_set_equipped_value_changes_listing() {
    let mut sc = bootstrap();
    let clk = clock::create_for_testing(sc.ctx());
    let sku = add_tuxedo(&mut sc, &clk, 5);

    sc.next_tx(ADMIN);
    let admin = sc.take_from_sender<AdminCap>();
    let mut shop_obj = sc.take_shared<Shop>();
    shop::admin_set_equipped_value(
        &admin, &mut shop_obj, sku, string::utf8(b"VacationMode"), &clk,
    );
    let l = shop::listing(&shop_obj, sku);
    assert!(shop::listing_equipped_value(&l) == string::utf8(b"VacationMode"), 0);
    ts::return_shared(shop_obj);
    sc.return_to_sender(admin);

    clock::destroy_for_testing(clk);
    sc.end();
}

#[test]
#[expected_failure(abort_code = shop::ENoListing)]
fun test_admin_set_equipped_value_unknown_sku_fails() {
    let mut sc = bootstrap();
    let clk = clock::create_for_testing(sc.ctx());

    sc.next_tx(ADMIN);
    let admin = sc.take_from_sender<AdminCap>();
    let mut shop_obj = sc.take_shared<Shop>();
    shop::admin_set_equipped_value(
        &admin, &mut shop_obj, 999, string::utf8(b"X"), &clk,
    );
    ts::return_shared(shop_obj);
    sc.return_to_sender(admin);
    clock::destroy_for_testing(clk);
    sc.end();
}

#[test]
fun test_admin_set_tier_gate_changes_listing() {
    let mut sc = bootstrap();
    let clk = clock::create_for_testing(sc.ctx());
    let sku = add_tuxedo(&mut sc, &clk, 5);

    sc.next_tx(ADMIN);
    let admin = sc.take_from_sender<AdminCap>();
    let mut shop_obj = sc.take_shared<Shop>();
    shop::admin_set_tier_gate(&admin, &mut shop_obj, sku, 6, &clk);
    let l = shop::listing(&shop_obj, sku);
    assert!(shop::listing_tier_gate(&l) == 6, 0);
    ts::return_shared(shop_obj);
    sc.return_to_sender(admin);

    clock::destroy_for_testing(clk);
    sc.end();
}

#[test]
fun test_admin_set_name_changes_listing() {
    let mut sc = bootstrap();
    let clk = clock::create_for_testing(sc.ctx());
    let sku = add_tuxedo(&mut sc, &clk, 5);

    sc.next_tx(ADMIN);
    let admin = sc.take_from_sender<AdminCap>();
    let mut shop_obj = sc.take_shared<Shop>();
    shop::admin_set_name(&admin, &mut shop_obj, sku, string::utf8(b"Premium Tuxedo"), &clk);
    let l = shop::listing(&shop_obj, sku);
    assert!(shop::listing_name(&l) == string::utf8(b"Premium Tuxedo"), 0);
    ts::return_shared(shop_obj);
    sc.return_to_sender(admin);

    clock::destroy_for_testing(clk);
    sc.end();
}

#[test]
fun test_admin_set_walrus_standalone_changes_listing() {
    let mut sc = bootstrap();
    let clk = clock::create_for_testing(sc.ctx());
    let sku = add_tuxedo(&mut sc, &clk, 5);

    sc.next_tx(ADMIN);
    let admin = sc.take_from_sender<AdminCap>();
    let mut shop_obj = sc.take_shared<Shop>();
    shop::admin_set_walrus_standalone(
        &admin, &mut shop_obj, sku, string::utf8(b"NEW_TUX.png"), &clk,
    );
    let l = shop::listing(&shop_obj, sku);
    assert!(shop::listing_walrus_standalone(&l) == string::utf8(b"NEW_TUX.png"), 0);
    ts::return_shared(shop_obj);
    sc.return_to_sender(admin);

    clock::destroy_for_testing(clk);
    sc.end();
}

// Verifies the buy flow still respects the NEW equipped_value after an
// admin edit — the cosmetic minted from the listing carries the updated
// suffix, not the original.
#[test]
fun test_set_equipped_value_then_buy_uses_new_value() {
    let mut sc = bootstrap();
    let clk = clock::create_for_testing(sc.ctx());
    let sku = add_tuxedo(&mut sc, &clk, 5);
    set_tier(&mut sc, &clk, ALICE, 5);

    sc.next_tx(ADMIN);
    let admin = sc.take_from_sender<AdminCap>();
    let mut shop_obj = sc.take_shared<Shop>();
    shop::admin_set_equipped_value(
        &admin, &mut shop_obj, sku, string::utf8(b"VacationMode"), &clk,
    );
    ts::return_shared(shop_obj);
    sc.return_to_sender(admin);

    sc.next_tx(ALICE);
    let mut shop_obj = sc.take_shared<Shop>();
    let tier_reg = sc.take_shared<TierRegistry>();
    let pay = coin::mint_for_testing<SUI>(TUXEDO_PRICE, sc.ctx());
    shop::buy_cosmetic(&mut shop_obj, &tier_reg, sku, pay, &clk, sc.ctx());
    ts::return_shared(shop_obj);
    ts::return_shared(tier_reg);

    sc.next_tx(ALICE);
    let cos = sc.take_from_sender<trumpagotchi::Cosmetic>();
    assert!(trumpagotchi::cosmetic_equipped_value(&cos) == string::utf8(b"VacationMode"), 0);
    sc.return_to_sender(cos);

    clock::destroy_for_testing(clk);
    sc.end();
}
