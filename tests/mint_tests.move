#[test_only]
module trumpagotchi::mint_tests;

use sui::clock;
use sui::coin;
use sui::sui::SUI;
use sui::test_scenario as ts;
use trumpagotchi::mint::{Self, MintConfig};
use trumpagotchi::trumpagotchi::{Self, Trumpagotchi, AdminCap};

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

// Spin up a scenario with both modules initialised + addresses set, return
// the scenario ready for test transactions to start.
fun bootstrap(): ts::Scenario {
    let mut sc = ts::begin(ADMIN);
    trumpagotchi::init_for_testing(sc.ctx());
    mint::init_for_testing(sc.ctx());

    // Wire the 5 addresses
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

// Take the (single) SUI coin sitting at `who`, read its value, return it.
// Returns 0 if the address has no Coin<SUI>. Each test mints only once per
// address so there's exactly one coin per destination — no iteration.
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
    // Mint #1 (total_minted=0): floor(0/25)*5 + 20 = 20 SUI
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
    let mut cfg = sc.take_shared<MintConfig>();
    let pay = coin::mint_for_testing<SUI>(PRICE_T1, sc.ctx());
    mint::mint(&mut cfg, pay, option::some(REF), &clk, sc.ctx());
    ts::return_shared(cfg);

    // Verify all splits landed correctly. Read all 6 balances FIRST, then
    // assert — repeated take+return cycles in the same tx context are
    // brittle, so collecting once is safer.
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
    // Dev gets the remainder = 12.5% (no dust at 20 SUI price).
    assert!(dv == PRICE_T1 * 1_250 / 10_000, 6);
    // Sanity: every mist is accounted for.
    assert!(bb + lp + vt + pz + rf + dv == PRICE_T1, 7);

    // Alice received the NFT and it has the referrer trait.
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
    let mut cfg = sc.take_shared<MintConfig>();
    let pay = coin::mint_for_testing<SUI>(PRICE_T1, sc.ctx());
    mint::mint(&mut cfg, pay, option::none(), &clk, sc.ctx());
    ts::return_shared(cfg);

    sc.next_tx(ADMIN);
    // Dev now gets 15% (12.5% + folded referrer 2.5%).
    assert!(sui_balance_of(&mut sc, DEV_ADDR) == PRICE_T1 * 1_500 / 10_000, 0);
    assert!(sui_balance_of(&mut sc, REF) == 0, 1);

    sc.next_tx(ALICE);
    let nft = sc.take_from_sender<Trumpagotchi>();
    assert!(option::is_none(&trumpagotchi::referrer(&nft)), 2);
    sc.return_to_sender(nft);

    clock::destroy_for_testing(clk);
    sc.end();
}

// EWrongAmount = 100, ESelfReferral = 101, EPaused = 102 in mint.move.
#[test, expected_failure(abort_code = mint::EWrongAmount)]
fun test_mint_aborts_when_amount_wrong() {
    let mut sc = bootstrap();

    sc.next_tx(ALICE);
    let mut clk = clock::create_for_testing(sc.ctx());
    clk.set_for_testing(1_000_000);

    sc.next_tx(ALICE);
    let mut cfg = sc.take_shared<MintConfig>();
    let pay = coin::mint_for_testing<SUI>(PRICE_T1 - 1, sc.ctx()); // off by 1 mist
    mint::mint(&mut cfg, pay, option::none(), &clk, sc.ctx());
    ts::return_shared(cfg);

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
    let mut cfg = sc.take_shared<MintConfig>();
    let pay = coin::mint_for_testing<SUI>(PRICE_T1, sc.ctx());
    mint::mint(&mut cfg, pay, option::some(ALICE), &clk, sc.ctx());
    ts::return_shared(cfg);

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
    let mut cfg = sc.take_shared<MintConfig>();
    let pay = coin::mint_for_testing<SUI>(PRICE_T1, sc.ctx());
    mint::mint(&mut cfg, pay, option::none(), &clk, sc.ctx());
    ts::return_shared(cfg);

    clock::destroy_for_testing(clk);
    sc.end();
}

// Mirror of mint::current_price_mist. Used to verify the formula at
// boundary points without running thousands of mints.
fun price_at(total_minted: u64): u64 {
    let step = total_minted / 25;
    let p = 20 * SUI_1 + step * 5 * SUI_1;
    if (p > 80 * SUI_1) 80 * SUI_1 else p
}

#[test]
fun test_price_curve_boundary_samples() {
    // #1 (total_minted=0) → 20 SUI
    assert!(price_at(0)      == 20 * SUI_1, 0);
    // #25 (total_minted=24) → still 20 SUI (last mint at base)
    assert!(price_at(24)     == 20 * SUI_1, 1);
    // #26 (total_minted=25) → 25 SUI (first step)
    assert!(price_at(25)     == 25 * SUI_1, 2);
    // #351 (total_minted=350) → cap of 80 SUI
    assert!(price_at(350)    == 80 * SUI_1, 3);
    // anything past the cap stays at the cap
    assert!(price_at(10_000) == 80 * SUI_1, 4);
}

// Drive the on-chain price curve by performing 26 successive mints and
// asserting the price-changes happen at the right tick.
#[test]
fun test_price_increments_on_chain() {
    let mut sc = bootstrap();

    sc.next_tx(ADMIN);
    let mut clk = clock::create_for_testing(sc.ctx());
    clk.set_for_testing(1_000_000);

    // Mints 1..25 should all cost 20 SUI; mint 26 should cost 25 SUI.
    let mut i = 0u64;
    while (i < 26) {
        sc.next_tx(ALICE);
        let mut cfg = sc.take_shared<MintConfig>();
        let expected = if (i < 25) 20 * SUI_1 else 25 * SUI_1;
        assert!(mint::current_price_mist(&cfg) == expected, 100 + i);
        let pay = coin::mint_for_testing<SUI>(expected, sc.ctx());
        mint::mint(&mut cfg, pay, option::none(), &clk, sc.ctx());
        ts::return_shared(cfg);
        i = i + 1;
    };

    sc.next_tx(ADMIN);
    let cfg = sc.take_shared<MintConfig>();
    assert!(mint::total_minted(&cfg) == 26, 200);
    // After mint 26, next mint (#27) should still be 25 SUI (next bump at 51).
    assert!(mint::current_price_mist(&cfg) == 25 * SUI_1, 201);
    ts::return_shared(cfg);

    clock::destroy_for_testing(clk);
    sc.end();
}
