#[test_only]
module trumpagotchi::trumpagotchi_tests;

use std::string;
use sui::clock;
use sui::package::Publisher;
use sui::test_scenario as ts;
use sui::transfer_policy::{TransferPolicy, TransferPolicyCap};
use trumpagotchi::trumpagotchi::{Self, Trumpagotchi, Cosmetic, AdminCap, MintedRegistry};

const ADMIN: address = @0xA;
const ALICE: address = @0xA11CE;
const BOB: address = @0xB0B;

const PRE_EXEMPT_CRYPTOMISCHIEF: address =
    @0x39ee291682e829771ad0c3ed46ebc69a962b7c2f9e6477409b22616bcf21ac34;

// ── Helpers — keep tests focused on behaviour, not boilerplate ─────────────

fun bootstrap(): ts::Scenario {
    let mut sc = ts::begin(ADMIN);
    trumpagotchi::init_for_testing(sc.ctx());
    sc
}

// Mint a default Tier-1 NFT to `to`, threading the shared registry through.
fun mint_default(sc: &mut ts::Scenario, clk: &clock::Clock, to: address) {
    let mut reg = sc.take_shared<MintedRegistry>();
    trumpagotchi::mint_to(
        &mut reg, to, option::none(),
        string::utf8(b"Tier1-FakeNews"),
        string::utf8(b"BlackStars"),
        clk, sc.ctx(),
    );
    ts::return_shared(reg);
}

fun admin_issue_outfit(
    sc: &mut ts::Scenario,
    name: vector<u8>,
    tier_gate: u8,
    standalone: vector<u8>,
    equipped: vector<u8>,
    to: address,
) {
    let admin = sc.take_from_sender<AdminCap>();
    trumpagotchi::admin_issue_cosmetic(
        &admin,
        trumpagotchi::kind_outfit(),
        string::utf8(name),
        tier_gate,
        0,                              // rarity (tests don't gate on rarity)
        string::utf8(standalone),
        string::utf8(equipped),
        to,
        sc.ctx(),
    );
    sc.return_to_sender(admin);
}

// ── Tests ──────────────────────────────────────────────────────────────────

#[test]
fun test_mint_initialises_v8_state() {
    let mut sc = bootstrap();

    sc.next_tx(ADMIN);
    let mut clk = clock::create_for_testing(sc.ctx());
    clk.set_for_testing(1_000_000);

    sc.next_tx(ADMIN);
    mint_default(&mut sc, &clk, ALICE);

    sc.next_tx(ALICE);
    let nft = sc.take_from_sender<Trumpagotchi>();

    assert!(trumpagotchi::owner(&nft) == ALICE, 0);
    assert!(trumpagotchi::current_tier(&nft) == 1, 1);
    assert!(trumpagotchi::base_body_identifier(&nft) == string::utf8(b"Tier1-FakeNews"), 2);
    assert!(trumpagotchi::body_identifier(&nft) == string::utf8(b"Tier1-FakeNews"), 3);
    assert!(trumpagotchi::base_background_identifier(&nft) == string::utf8(b"BlackStars"), 4);
    assert!(trumpagotchi::background_identifier(&nft) == string::utf8(b"BlackStars"), 5);
    assert!(option::is_none(&trumpagotchi::equipped_outfit(&nft)), 6);
    assert!(option::is_none(&trumpagotchi::equipped_background(&nft)), 7);
    assert!(option::is_none(&trumpagotchi::equipped_shell(&nft)), 8);
    sc.return_to_sender(nft);

    clock::destroy_for_testing(clk);
    sc.end();
}

#[test]
fun test_equip_outfit_mutates_body_identifier() {
    let mut sc = bootstrap();

    sc.next_tx(ADMIN);
    let mut clk = clock::create_for_testing(sc.ctx());
    clk.set_for_testing(1_000_000);

    sc.next_tx(ADMIN);
    mint_default(&mut sc, &clk, ALICE);

    sc.next_tx(ADMIN);
    admin_issue_outfit(
        &mut sc, b"Tuxedo", 4,
        b"TUXEDO.png",
        b"Tier4-Tremendous-Tuxedo",
        ALICE,
    );

    sc.next_tx(ALICE);
    let mut nft = sc.take_from_sender<Trumpagotchi>();
    let cosmetic = sc.take_from_sender<Cosmetic>();
    assert!(trumpagotchi::cosmetic_walrus_standalone(&cosmetic) == string::utf8(b"TUXEDO.png"), 0);

    trumpagotchi::equip_outfit(&mut nft, cosmetic, 4, &clk, sc.ctx());

    // body_identifier mutated; base_body_identifier unchanged.
    assert!(trumpagotchi::body_identifier(&nft) == string::utf8(b"Tier4-Tremendous-Tuxedo"), 1);
    assert!(trumpagotchi::base_body_identifier(&nft) == string::utf8(b"Tier1-FakeNews"), 2);
    assert!(option::is_some(&trumpagotchi::equipped_outfit(&nft)), 3);

    // Unequip — reverts body_identifier to base.
    trumpagotchi::unequip_outfit(&mut nft, &clk, sc.ctx());
    assert!(trumpagotchi::body_identifier(&nft) == string::utf8(b"Tier1-FakeNews"), 4);
    assert!(option::is_none(&trumpagotchi::equipped_outfit(&nft)), 5);
    sc.return_to_sender(nft);

    sc.next_tx(ALICE);
    let returned = sc.take_from_sender<Cosmetic>();
    assert!(trumpagotchi::cosmetic_kind(&returned) == trumpagotchi::kind_outfit(), 6);
    sc.return_to_sender(returned);

    clock::destroy_for_testing(clk);
    sc.end();
}

#[test]
fun test_equip_background_mutates_background_identifier() {
    let mut sc = bootstrap();

    sc.next_tx(ADMIN);
    let mut clk = clock::create_for_testing(sc.ctx());
    clk.set_for_testing(1_000_000);

    sc.next_tx(ADMIN);
    mint_default(&mut sc, &clk, ALICE);

    sc.next_tx(ADMIN);
    {
        let admin = sc.take_from_sender<AdminCap>();
        trumpagotchi::admin_issue_cosmetic(
            &admin,
            trumpagotchi::kind_background(),
            string::utf8(b"Ballroom"),
            2, 0,
            string::utf8(b"Ballroom.png"),
            string::utf8(b"Ballroom"),
            ALICE,
            sc.ctx(),
        );
        sc.return_to_sender(admin);
    };

    sc.next_tx(ALICE);
    let mut nft = sc.take_from_sender<Trumpagotchi>();
    let cosmetic = sc.take_from_sender<Cosmetic>();
    trumpagotchi::equip_background(&mut nft, cosmetic, 5, &clk, sc.ctx());
    assert!(trumpagotchi::background_identifier(&nft) == string::utf8(b"Ballroom"), 0);
    assert!(trumpagotchi::base_background_identifier(&nft) == string::utf8(b"BlackStars"), 1);

    trumpagotchi::unequip_background(&mut nft, &clk, sc.ctx());
    assert!(trumpagotchi::background_identifier(&nft) == string::utf8(b"BlackStars"), 2);
    sc.return_to_sender(nft);

    clock::destroy_for_testing(clk);
    sc.end();
}

#[test, expected_failure(abort_code = trumpagotchi::EBelowTierGate)]
fun test_equip_aborts_below_tier_gate() {
    let mut sc = bootstrap();

    sc.next_tx(ADMIN);
    let mut clk = clock::create_for_testing(sc.ctx());
    clk.set_for_testing(1_000_000);

    sc.next_tx(ADMIN);
    mint_default(&mut sc, &clk, ALICE);

    sc.next_tx(ADMIN);
    admin_issue_outfit(
        &mut sc, b"GoldSuit", 12,
        b"GOLD.png", b"Tier12-VeryVeryRich-GoldSuit",
        ALICE,
    );

    sc.next_tx(ALICE);
    let mut nft = sc.take_from_sender<Trumpagotchi>();
    let cosmetic = sc.take_from_sender<Cosmetic>();
    trumpagotchi::equip_outfit(&mut nft, cosmetic, 1, &clk, sc.ctx());

    sc.return_to_sender(nft);
    clock::destroy_for_testing(clk);
    sc.end();
}

#[test, expected_failure(abort_code = trumpagotchi::EWrongCosmeticKind)]
fun test_equip_outfit_aborts_when_kind_is_background() {
    let mut sc = bootstrap();

    sc.next_tx(ADMIN);
    let mut clk = clock::create_for_testing(sc.ctx());
    clk.set_for_testing(1_000_000);

    sc.next_tx(ADMIN);
    mint_default(&mut sc, &clk, ALICE);

    sc.next_tx(ADMIN);
    {
        let admin = sc.take_from_sender<AdminCap>();
        trumpagotchi::admin_issue_cosmetic(
            &admin, trumpagotchi::kind_background(),
            string::utf8(b"Ballroom"),
            2, 0,
            string::utf8(b"Ballroom.png"),
            string::utf8(b"Ballroom"),
            ALICE,
            sc.ctx(),
        );
        sc.return_to_sender(admin);
    };

    sc.next_tx(ALICE);
    let mut nft = sc.take_from_sender<Trumpagotchi>();
    let cosmetic = sc.take_from_sender<Cosmetic>();
    trumpagotchi::equip_outfit(&mut nft, cosmetic, 5, &clk, sc.ctx());

    sc.return_to_sender(nft);
    clock::destroy_for_testing(clk);
    sc.end();
}

#[test, expected_failure(abort_code = trumpagotchi::EWrongOwner)]
fun test_equip_aborts_when_caller_not_owner() {
    let mut sc = bootstrap();

    sc.next_tx(ADMIN);
    let mut clk = clock::create_for_testing(sc.ctx());
    clk.set_for_testing(1_000_000);

    sc.next_tx(ADMIN);
    mint_default(&mut sc, &clk, ALICE);

    sc.next_tx(ADMIN);
    admin_issue_outfit(
        &mut sc, b"Tuxedo", 1,
        b"TUXEDO.png", b"Tier4-Tremendous-Tuxedo",
        BOB,
    );

    sc.next_tx(ALICE);
    let mut nft = sc.take_from_sender<Trumpagotchi>();

    sc.next_tx(BOB);
    let cosmetic = sc.take_from_sender<Cosmetic>();
    trumpagotchi::equip_outfit(&mut nft, cosmetic, 5, &clk, sc.ctx());

    trumpagotchi::destroy_nft_for_testing(nft);
    clock::destroy_for_testing(clk);
    sc.end();
}

#[test]
fun test_create_cosmetic_transfer_policy() {
    let mut sc = bootstrap();
    sc.next_tx(ADMIN);
    let admin = sc.take_from_sender<AdminCap>();
    let publisher = sc.take_from_sender<Publisher>();
    trumpagotchi::create_cosmetic_transfer_policy(&admin, &publisher, sc.ctx());
    sc.return_to_sender(admin);
    sc.return_to_sender(publisher);

    sc.next_tx(ADMIN);
    let policy = sc.take_shared<TransferPolicy<Cosmetic>>();
    let cap = sc.take_from_sender<TransferPolicyCap<Cosmetic>>();
    ts::return_shared(policy);
    sc.return_to_sender(cap);
    sc.end();
}

#[test, expected_failure(abort_code = trumpagotchi::EAlreadyMinted)]
fun test_second_mint_to_same_wallet_aborts() {
    let mut sc = bootstrap();
    sc.next_tx(ADMIN);
    let mut clk = clock::create_for_testing(sc.ctx());
    clk.set_for_testing(1_000_000);

    sc.next_tx(ADMIN);
    let mut reg = sc.take_shared<MintedRegistry>();
    trumpagotchi::mint_to(
        &mut reg, ALICE, option::none(),
        string::utf8(b"Tier1-FakeNews"), string::utf8(b"BlackStars"),
        &clk, sc.ctx(),
    );
    trumpagotchi::mint_to(
        &mut reg, ALICE, option::none(),
        string::utf8(b"Tier1-FakeNews"), string::utf8(b"BlackStars"),
        &clk, sc.ctx(),
    );
    ts::return_shared(reg);

    clock::destroy_for_testing(clk);
    sc.end();
}

#[test]
fun test_pre_exempt_address_can_mint_multiple() {
    let mut sc = bootstrap();
    sc.next_tx(ADMIN);
    let mut clk = clock::create_for_testing(sc.ctx());
    clk.set_for_testing(1_000_000);

    sc.next_tx(ADMIN);
    let mut reg = sc.take_shared<MintedRegistry>();
    assert!(trumpagotchi::is_exempt(&reg, PRE_EXEMPT_CRYPTOMISCHIEF), 0);
    trumpagotchi::mint_to(
        &mut reg, PRE_EXEMPT_CRYPTOMISCHIEF, option::none(),
        string::utf8(b"Tier1-FakeNews"), string::utf8(b"BlackStars"),
        &clk, sc.ctx(),
    );
    trumpagotchi::mint_to(
        &mut reg, PRE_EXEMPT_CRYPTOMISCHIEF, option::none(),
        string::utf8(b"Tier1-FakeNews"), string::utf8(b"BlackStars"),
        &clk, sc.ctx(),
    );
    trumpagotchi::mint_to(
        &mut reg, PRE_EXEMPT_CRYPTOMISCHIEF, option::none(),
        string::utf8(b"Tier1-FakeNews"), string::utf8(b"BlackStars"),
        &clk, sc.ctx(),
    );
    assert!(!trumpagotchi::has_minted(&reg, PRE_EXEMPT_CRYPTOMISCHIEF), 1);
    ts::return_shared(reg);

    clock::destroy_for_testing(clk);
    sc.end();
}

#[test]
fun test_admin_can_add_and_remove_exempt() {
    let mut sc = bootstrap();
    sc.next_tx(ADMIN);
    let admin = sc.take_from_sender<AdminCap>();
    let mut reg = sc.take_shared<MintedRegistry>();

    assert!(!trumpagotchi::is_exempt(&reg, ALICE), 0);
    trumpagotchi::add_exempt(&admin, &mut reg, ALICE);
    assert!(trumpagotchi::is_exempt(&reg, ALICE), 1);
    trumpagotchi::remove_exempt(&admin, &mut reg, ALICE);
    assert!(!trumpagotchi::is_exempt(&reg, ALICE), 2);

    ts::return_shared(reg);
    sc.return_to_sender(admin);
    sc.end();
}

#[test]
fun test_admin_set_current_tier_and_base_identifiers() {
    let mut sc = bootstrap();
    sc.next_tx(ADMIN);
    let mut clk = clock::create_for_testing(sc.ctx());
    clk.set_for_testing(1_000_000);

    sc.next_tx(ADMIN);
    mint_default(&mut sc, &clk, ALICE);

    sc.next_tx(ADMIN);
    let admin = sc.take_from_sender<AdminCap>();
    let mut nft = ts::take_from_address<Trumpagotchi>(&sc, ALICE);
    trumpagotchi::set_current_tier(&admin, &mut nft, 4, &clk);
    trumpagotchi::set_base_identifiers(
        &admin, &mut nft,
        string::utf8(b"Tier4-Tremendous"),
        string::utf8(b"BlackStars"),
    );
    assert!(trumpagotchi::current_tier(&nft) == 4, 0);
    assert!(trumpagotchi::base_body_identifier(&nft) == string::utf8(b"Tier4-Tremendous"), 1);
    assert!(trumpagotchi::body_identifier(&nft) == string::utf8(b"Tier4-Tremendous"), 2);
    ts::return_to_address(ALICE, nft);
    sc.return_to_sender(admin);

    clock::destroy_for_testing(clk);
    sc.end();
}
