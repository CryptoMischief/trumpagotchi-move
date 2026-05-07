#[test_only]
module trumpagotchi::mint_tests;

use sui::clock;
use sui::coin;
use sui::sui::SUI;
use sui::test_scenario as ts;
use trumpagotchi::mint::{Self, MintConfig};
use trumpagotchi::trumpagotchi::{Self, Trumpagotchi, AdminCap, MintedRegistry, TierRegistry};

const ADMIN: address = @0xA;
const ALICE: address = @0xA11CE;
const BOB: address = @0xB0B;
const REF: address = @0xCAFE;

const BUY_BURN_ADDR: address = @0xB001;
const LP_ADDR: address       = @0xB002;
const VICTORY_ADDR: address  = @0xB003;
const PRIZE_ADDR: address    = @0xB004;
const DEV_ADDR: address      = @0xB005;

const SUI_1: u64 = 1_000_000_000;
const PRICE_T1: u64 = 20_000_000_000; // 20 SUI

fun bootstrap(): ts::Scenario {
    let mut sc = ts::begin(ADMIN);
    trumpagotchi::init_for_testing(sc.ctx());
    mint::init_for_testing(sc.ctx());

    sc.next_tx(ADMIN);
    let admin = sc.take_from_sender<AdminCap>();
    let mut cfg = sc.take_shared<MintConfig>();
    mint::set_addresses(
        &admin, &mut cfg,
        BUY_BURN_ADDR, LP_ADDR, VICTORY_ADDR, PRIZE_ADDR, DEV_ADDR,
    );
    ts::return_shared(cfg);
    sc.return_to_sender(admin);
    sc
}

// Drive a single public mint by `who`, threading both shared registries.
fun do_mint(
    sc: &mut ts::Scenario,
    clk: &clock::Clock,
    referrer: Option<address>,
    price: u64,
) {
    let mut cfg = sc.take_shared<MintConfig>();
    let mut minted = sc.take_shared<MintedRegistry>();
    let mut tier = sc.take_shared<TierRegistry>();
    let pay = coin::mint_for_testing<SUI>(price, sc.ctx());
    mint::mint(&mut cfg, &mut minted, &mut tier, pay, referrer, clk, sc.ctx());
    ts::return_shared(cfg);
    ts::return_shared(minted);
    ts::return_shared(tier);
}

fun sui_balance_of(sc: &mut ts::Scenario, who: address): u64 {
    if (!ts::has_most_recent_for_address<coin::Coin<SUI>>(who)) return 0;
    let c = sc.take_from_address<coin::Coin<SUI>>(who);
    let v = coin::value(&c);
    ts::return_to_address(who, c);
    v
}

#[test]
fun test_price_curve_matches_spec() {
    let mut sc = bootstrap();
    sc.next_tx(ADMIN);
    let cfg = sc.take_shared<MintConfig>();
    assert!(mint::current_price_mist(&cfg) == 20 * SUI_1, 0);
    ts::return_shared(cfg);
    sc.end();
}

#[test]
fun test_mint_with_referrer_splits_correctly() {
    let mut sc = bootstrap();

    sc.next_tx(ALICE);
    let mut clk = clock::create_for_testing(sc.ctx());
    clk.set_for_testing(1_000_000);

    sc.next_tx(ALICE);
    do_mint(&mut sc, &clk, option::some(REF), PRICE_T1);

    sc.next_tx(ADMIN);
    let bb = sui_balance_of(&mut sc, BUY_BURN_ADDR);
    let lp = sui_balance_of(&mut sc, LP_ADDR);
    let vt = sui_balance_of(&mut sc, VICTORY_ADDR);
    let pz = sui_balance_of(&mut sc, PRIZE_ADDR);
    let rf = sui_balance_of(&mut sc, REF);
    let dv = sui_balance_of(&mut sc, DEV_ADDR);

    assert!(bb == PRICE_T1 * 2_500 / 10_000, 1);
    assert!(lp == PRICE_T1 * 2_000 / 10_000, 2);
    assert!(vt == PRICE_T1 * 3_000 / 10_000, 3);
    assert!(pz == PRICE_T1 * 1_000 / 10_000, 4);
    assert!(rf == PRICE_T1 * 250   / 10_000, 5);
    assert!(dv == PRICE_T1 * 1_250 / 10_000, 6);
    assert!(bb + lp + vt + pz + rf + dv == PRICE_T1, 7);

    sc.next_tx(ALICE);
    let nft = sc.take_from_sender<Trumpagotchi>();
    assert!(trumpagotchi::owner(&nft) == ALICE, 8);
    assert!(option::is_some(&trumpagotchi::referrer(&nft)), 9);
    sc.return_to_sender(nft);

    clock::destroy_for_testing(clk);
    sc.end();
}

#[test]
fun test_mint_without_referrer_folds_to_dev() {
    let mut sc = bootstrap();

    sc.next_tx(ALICE);
    let mut clk = clock::create_for_testing(sc.ctx());
    clk.set_for_testing(1_000_000);

    sc.next_tx(ALICE);
    do_mint(&mut sc, &clk, option::none(), PRICE_T1);

    sc.next_tx(ADMIN);
    assert!(sui_balance_of(&mut sc, DEV_ADDR) == PRICE_T1 * 1_500 / 10_000, 0);
    assert!(sui_balance_of(&mut sc, REF) == 0, 1);

    sc.next_tx(ALICE);
    let nft = sc.take_from_sender<Trumpagotchi>();
    assert!(option::is_none(&trumpagotchi::referrer(&nft)), 2);
    sc.return_to_sender(nft);

    clock::destroy_for_testing(clk);
    sc.end();
}

#[test]
fun test_mint_seeds_tier_registry_entry() {
    let mut sc = bootstrap();

    sc.next_tx(ALICE);
    let mut clk = clock::create_for_testing(sc.ctx());
    clk.set_for_testing(1_000_000);

    sc.next_tx(ALICE);
    do_mint(&mut sc, &clk, option::none(), PRICE_T1);

    sc.next_tx(ADMIN);
    let reg = sc.take_shared<TierRegistry>();
    assert!(trumpagotchi::has_entry(&reg, ALICE), 0);
    assert!(trumpagotchi::tier_of(&reg, ALICE) == 1, 1);
    ts::return_shared(reg);

    clock::destroy_for_testing(clk);
    sc.end();
}

#[test, expected_failure(abort_code = mint::EWrongAmount)]
fun test_mint_aborts_when_amount_wrong() {
    let mut sc = bootstrap();

    sc.next_tx(ALICE);
    let mut clk = clock::create_for_testing(sc.ctx());
    clk.set_for_testing(1_000_000);

    sc.next_tx(ALICE);
    do_mint(&mut sc, &clk, option::none(), PRICE_T1 - 1);

    clock::destroy_for_testing(clk);
    sc.end();
}

#[test, expected_failure(abort_code = mint::ESelfReferral)]
fun test_mint_aborts_on_self_referral() {
    let mut sc = bootstrap();

    sc.next_tx(ALICE);
    let mut clk = clock::create_for_testing(sc.ctx());
    clk.set_for_testing(1_000_000);

    sc.next_tx(ALICE);
    do_mint(&mut sc, &clk, option::some(ALICE), PRICE_T1);

    clock::destroy_for_testing(clk);
    sc.end();
}

#[test, expected_failure(abort_code = mint::EPaused)]
fun test_mint_aborts_when_paused() {
    let mut sc = bootstrap();

    sc.next_tx(ADMIN);
    let admin = sc.take_from_sender<AdminCap>();
    let mut cfg = sc.take_shared<MintConfig>();
    mint::set_paused(&admin, &mut cfg, true);
    ts::return_shared(cfg);
    sc.return_to_sender(admin);

    sc.next_tx(BOB);
    let mut clk = clock::create_for_testing(sc.ctx());
    clk.set_for_testing(1_000_000);

    sc.next_tx(BOB);
    do_mint(&mut sc, &clk, option::none(), PRICE_T1);

    clock::destroy_for_testing(clk);
    sc.end();
}

fun price_at(total_minted: u64): u64 {
    let step = total_minted / 25;
    let p = 20 * SUI_1 + step * 5 * SUI_1;
    if (p > 80 * SUI_1) 80 * SUI_1 else p
}

#[test]
fun test_price_curve_boundary_samples() {
    assert!(price_at(0)      == 20 * SUI_1, 0);
    assert!(price_at(24)     == 20 * SUI_1, 1);
    assert!(price_at(25)     == 25 * SUI_1, 2);
    assert!(price_at(350)    == 80 * SUI_1, 3);
    assert!(price_at(10_000) == 80 * SUI_1, 4);
}

#[test]
fun test_price_increments_on_chain() {
    let mut sc = bootstrap();

    sc.next_tx(ADMIN);
    let mut clk = clock::create_for_testing(sc.ctx());
    clk.set_for_testing(1_000_000);

    sc.next_tx(ADMIN);
    {
        let admin = sc.take_from_sender<AdminCap>();
        let mut reg = sc.take_shared<MintedRegistry>();
        trumpagotchi::add_exempt(&admin, &mut reg, ALICE);
        ts::return_shared(reg);
        sc.return_to_sender(admin);
    };

    let mut i = 0u64;
    while (i < 26) {
        sc.next_tx(ALICE);
        let expected = if (i < 25) 20 * SUI_1 else 25 * SUI_1;
        let mut cfg_now = sc.take_shared<MintConfig>();
        let mut minted = sc.take_shared<MintedRegistry>();
        let mut tier = sc.take_shared<TierRegistry>();
        assert!(mint::current_price_mist(&cfg_now) == expected, 100 + i);
        let pay = coin::mint_for_testing<SUI>(expected, sc.ctx());
        mint::mint(&mut cfg_now, &mut minted, &mut tier, pay, option::none(), &clk, sc.ctx());
        ts::return_shared(cfg_now);
        ts::return_shared(minted);
        ts::return_shared(tier);
        i = i + 1;
    };

    sc.next_tx(ADMIN);
    let cfg = sc.take_shared<MintConfig>();
    assert!(mint::total_minted(&cfg) == 26, 200);
    assert!(mint::current_price_mist(&cfg) == 25 * SUI_1, 201);
    ts::return_shared(cfg);

    clock::destroy_for_testing(clk);
    sc.end();
}
