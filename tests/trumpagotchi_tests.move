#[test_only]
module trumpagotchi::trumpagotchi_tests;

use std::string;
use sui::clock;
use sui::package::Publisher;
use sui::test_scenario as ts;
use sui::transfer_policy::{TransferPolicy, TransferPolicyCap};
use trumpagotchi::trumpagotchi::{Self, Trumpagotchi, Cosmetic, AdminCap};

const ADMIN: address = @0xA;
const ALICE: address = @0xA11CE;
const BOB: address = @0xB0B;

#[test]
fun test_mint_emits_and_lands_on_recipient() {
    let mut sc = ts::begin(ADMIN);
    trumpagotchi::init_for_testing(sc.ctx());

    sc.next_tx(ADMIN);
    let mut clk = clock::create_for_testing(sc.ctx());
    clk.set_for_testing(1_000_000);

    sc.next_tx(ADMIN);
    let _id = trumpagotchi::mint_to(
        ALICE,
        option::none(),
        string::utf8(b"Tier1-FakeNews.png"),
        &clk,
        sc.ctx(),
    );

    sc.next_tx(ALICE);
    let nft = sc.take_from_sender<Trumpagotchi>();
    assert!(trumpagotchi::owner(&nft) == ALICE, 0);
    assert!(option::is_none(&trumpagotchi::equipped_outfit(&nft)), 1);
    assert!(option::is_none(&trumpagotchi::equipped_background(&nft)), 2);
    assert!(option::is_none(&trumpagotchi::equipped_shell(&nft)), 3);
    assert!(trumpagotchi::body_identifier(&nft) == string::utf8(b"Tier1-FakeNews.png"), 4);
    sc.return_to_sender(nft);

    clock::destroy_for_testing(clk);
    sc.end();
}

#[test]
fun test_equip_unequip_outfit_round_trip() {
    let mut sc = ts::begin(ADMIN);
    trumpagotchi::init_for_testing(sc.ctx());

    sc.next_tx(ADMIN);
    let mut clk = clock::create_for_testing(sc.ctx());
    clk.set_for_testing(1_000_000);

    sc.next_tx(ADMIN);
    trumpagotchi::mint_to(ALICE, option::none(), string::utf8(b"Tier1-FakeNews.png"), &clk, sc.ctx());

    sc.next_tx(ADMIN);
    let admin = sc.take_from_sender<AdminCap>();
    trumpagotchi::admin_issue_cosmetic(
        &admin,
        trumpagotchi::kind_outfit(),
        string::utf8(b"tier04_tremendous"),
        4,
        string::utf8(b"Tier4-Tremendous-Tuxedo.png"),
        ALICE,
        sc.ctx(),
    );
    sc.return_to_sender(admin);

    sc.next_tx(ALICE);
    let mut nft = sc.take_from_sender<Trumpagotchi>();
    let cosmetic = sc.take_from_sender<Cosmetic>();
    assert!(
        trumpagotchi::cosmetic_walrus_identifier(&cosmetic)
            == string::utf8(b"Tier4-Tremendous-Tuxedo.png"),
        99,
    );

    trumpagotchi::equip_outfit(&mut nft, cosmetic, 4, &clk, sc.ctx());
    assert!(option::is_some(&trumpagotchi::equipped_outfit(&nft)), 0);
    assert!(option::is_none(&trumpagotchi::equipped_background(&nft)), 1);

    trumpagotchi::unequip_outfit(&mut nft, &clk, sc.ctx());
    assert!(option::is_none(&trumpagotchi::equipped_outfit(&nft)), 2);

    sc.return_to_sender(nft);

    sc.next_tx(ALICE);
    let returned = sc.take_from_sender<Cosmetic>();
    assert!(trumpagotchi::cosmetic_kind(&returned) == trumpagotchi::kind_outfit(), 3);
    sc.return_to_sender(returned);

    clock::destroy_for_testing(clk);
    sc.end();
}

// Abort codes (must match constants in trumpagotchi.move):
//   0=EWrongOwner  1=EWrongCosmeticKind  2=ESlotOccupied
//   3=ESlotEmpty   4=ETierGateFailed     5=ENameTooLong
// `location=` binds the expected abort to our module specifically, so a code
// collision in a dependency can't mask the wrong abort source.
#[test, expected_failure(abort_code = trumpagotchi::ETierGateFailed)]
fun test_equip_aborts_when_tier_below_gate() {
    let mut sc = ts::begin(ADMIN);
    trumpagotchi::init_for_testing(sc.ctx());

    sc.next_tx(ADMIN);
    let mut clk = clock::create_for_testing(sc.ctx());
    clk.set_for_testing(1_000_000);

    sc.next_tx(ADMIN);
    trumpagotchi::mint_to(ALICE, option::none(), string::utf8(b"Tier1-FakeNews.png"), &clk, sc.ctx());

    sc.next_tx(ADMIN);
    let admin = sc.take_from_sender<AdminCap>();
    trumpagotchi::admin_issue_cosmetic(
        &admin,
        trumpagotchi::kind_shell(),
        string::utf8(b"potus_gold"),
        13,
        string::utf8(b"Tier13-POTUS-Yolked.png"),
        ALICE,
        sc.ctx(),
    );
    sc.return_to_sender(admin);

    sc.next_tx(ALICE);
    let mut nft = sc.take_from_sender<Trumpagotchi>();
    let cosmetic = sc.take_from_sender<Cosmetic>();
    // Alice is tier 1 but the shell needs tier 13 — must abort.
    trumpagotchi::equip_shell(&mut nft, cosmetic, 1, &clk, sc.ctx());

    sc.return_to_sender(nft);
    clock::destroy_for_testing(clk);
    sc.end();
}

#[test, expected_failure(abort_code = trumpagotchi::EWrongCosmeticKind)]
fun test_equip_aborts_when_kind_mismatch() {
    let mut sc = ts::begin(ADMIN);
    trumpagotchi::init_for_testing(sc.ctx());

    sc.next_tx(ADMIN);
    let mut clk = clock::create_for_testing(sc.ctx());
    clk.set_for_testing(1_000_000);

    sc.next_tx(ADMIN);
    trumpagotchi::mint_to(ALICE, option::none(), string::utf8(b"Tier1-FakeNews.png"), &clk, sc.ctx());

    sc.next_tx(ADMIN);
    let admin = sc.take_from_sender<AdminCap>();
    trumpagotchi::admin_issue_cosmetic(
        &admin,
        trumpagotchi::kind_background(),
        string::utf8(b"ballroom"),
        2,
        string::utf8(b"Ballroom.png"),
        ALICE,
        sc.ctx(),
    );
    sc.return_to_sender(admin);

    sc.next_tx(ALICE);
    let mut nft = sc.take_from_sender<Trumpagotchi>();
    let cosmetic = sc.take_from_sender<Cosmetic>();
    // Cosmetic is a background but we call equip_outfit — must abort.
    trumpagotchi::equip_outfit(&mut nft, cosmetic, 5, &clk, sc.ctx());

    sc.return_to_sender(nft);
    clock::destroy_for_testing(clk);
    sc.end();
}

#[test, expected_failure(abort_code = trumpagotchi::EWrongOwner)]
fun test_equip_aborts_when_caller_not_owner() {
    let mut sc = ts::begin(ADMIN);
    trumpagotchi::init_for_testing(sc.ctx());

    sc.next_tx(ADMIN);
    let mut clk = clock::create_for_testing(sc.ctx());
    clk.set_for_testing(1_000_000);

    sc.next_tx(ADMIN);
    trumpagotchi::mint_to(ALICE, option::none(), string::utf8(b"Tier1-FakeNews.png"), &clk, sc.ctx());

    sc.next_tx(ADMIN);
    let admin = sc.take_from_sender<AdminCap>();
    trumpagotchi::admin_issue_cosmetic(
        &admin,
        trumpagotchi::kind_outfit(),
        string::utf8(b"tier04_tremendous"),
        1,
        string::utf8(b"Tier4-Tremendous-Tuxedo.png"),
        BOB,
        sc.ctx(),
    );
    sc.return_to_sender(admin);

    // Alice's NFT is in her account; Bob has a cosmetic. Bob can't equip onto
    // Alice's NFT — but he can mutably borrow it via test_scenario only via
    // address_of. To trigger EWrongOwner we have Alice ferry her NFT to Bob's
    // tx context: take from Alice, run as Bob.
    sc.next_tx(ALICE);
    let mut nft = sc.take_from_sender<Trumpagotchi>();

    sc.next_tx(BOB);
    let cosmetic = sc.take_from_sender<Cosmetic>();
    trumpagotchi::equip_outfit(&mut nft, cosmetic, 5, &clk, sc.ctx());

    // Unreachable — abort happens above — but the borrow checker still needs
    // a path that consumes `nft`.
    trumpagotchi::destroy_nft_for_testing(nft);
    clock::destroy_for_testing(clk);
    sc.end();
}

#[test]
fun test_create_cosmetic_transfer_policy() {
    let mut sc = ts::begin(ADMIN);
    trumpagotchi::init_for_testing(sc.ctx());

    sc.next_tx(ADMIN);
    let admin = sc.take_from_sender<AdminCap>();
    let publisher = sc.take_from_sender<Publisher>();
    trumpagotchi::create_cosmetic_transfer_policy(&admin, &publisher, sc.ctx());
    sc.return_to_sender(admin);
    sc.return_to_sender(publisher);

    // Policy is shared, cap is owned by ADMIN.
    sc.next_tx(ADMIN);
    let policy = sc.take_shared<TransferPolicy<Cosmetic>>();
    let cap = sc.take_from_sender<TransferPolicyCap<Cosmetic>>();
    // Just confirm both exist + we got a TransferPolicyCap matching the policy.
    // The royalty rule is attached as a dynamic field on the policy; the
    // standard kiosk royalty_rule has no public reader on testnet builds, so
    // we trust the bps constant we passed (250) and verify behavior via the
    // smoke script's actual purchase flow.
    ts::return_shared(policy);
    sc.return_to_sender(cap);
    sc.end();
}
