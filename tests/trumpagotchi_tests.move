#[test_only]
module trumpagotchi::trumpagotchi_tests;

use std::string;
use sui::clock;
use sui::package::Publisher;
use sui::test_scenario as ts;
use sui::transfer_policy::{TransferPolicy, TransferPolicyCap};
use trumpagotchi::trumpagotchi::{Self, Trumpagotchi, Cosmetic, AdminCap, MintedRegistry, TierRegistry};

const ADMIN: address = @0xA;
const ALICE: address = @0xA11CE;
const BOB: address = @0xB0B;

const PRE_EXEMPT_CRYPTOMISCHIEF: address =
    @0x39ee291682e829771ad0c3ed46ebc69a962b7c2f9e6477409b22616bcf21ac34;

// ── Helpers ────────────────────────────────────────────────────────────────

fun bootstrap(): ts::Scenario {
    let mut sc = ts::begin(ADMIN);
    trumpagotchi::init_for_testing(sc.ctx());
    sc
}

fun mint_default(sc: &mut ts::Scenario, clk: &clock::Clock, to: address) {
    let mut minted = sc.take_shared<MintedRegistry>();
    let mut tier = sc.take_shared<TierRegistry>();
    trumpagotchi::mint_to(
        &mut minted, &mut tier, to, option::none(),
        string::utf8(b"Tier1-FakeNews"),
        string::utf8(b"BlackStars"),
        clk, sc.ctx(),
    );
    ts::return_shared(minted);
    ts::return_shared(tier);
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
        0,
        string::utf8(standalone),
        string::utf8(equipped),
        to,
        sc.ctx(),
    );
    sc.return_to_sender(admin);
}

// Bump ALICE to a target tier in the registry. Used in equip tests so we
// can set up the tier-gate state before exercising equip_*.
fun admin_set_tier(
    sc: &mut ts::Scenario,
    clk: &clock::Clock,
    addr: address,
    new_tier: u8,
    target_base_body: vector<u8>,
) {
    let admin = sc.take_from_sender<AdminCap>();
    let mut reg = sc.take_shared<TierRegistry>();
    trumpagotchi::set_tier(
        &admin, &mut reg, addr, new_tier, 0u128,
        string::utf8(target_base_body),
        string::utf8(b"BlackStars"),
        clk,
    );
    ts::return_shared(reg);
    sc.return_to_sender(admin);
}

// ── Mint / equip / unequip ─────────────────────────────────────────────────

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
    assert!(trumpagotchi::synced_tier(&nft) == 1, 1);
    assert!(trumpagotchi::base_body_identifier(&nft) == string::utf8(b"Tier1-FakeNews"), 2);
    assert!(trumpagotchi::body_identifier(&nft) == string::utf8(b"Tier1-FakeNews"), 3);
    assert!(trumpagotchi::base_background_identifier(&nft) == string::utf8(b"BlackStars"), 4);
    assert!(trumpagotchi::background_identifier(&nft) == string::utf8(b"BlackStars"), 5);
    assert!(option::is_none(&trumpagotchi::equipped_outfit(&nft)), 6);
    assert!(option::is_none(&trumpagotchi::equipped_background(&nft)), 7);
    assert!(option::is_none(&trumpagotchi::equipped_shell(&nft)), 8);

    // Tier registry should have a tier=1 baseline entry from mint.
    let reg = sc.take_shared<TierRegistry>();
    assert!(trumpagotchi::tier_of(&reg, ALICE) == 1, 9);
    ts::return_shared(reg);
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
        b"Tuxedo",                       // suffix; equip_outfit composes
        ALICE,
    );

    // ALICE needs tier 4 in the registry to clear the gate. Wait past the
    // rate limit first so the advance is allowed.
    clk.set_for_testing(1_000_000 + trumpagotchi::default_update_interval_ms() + 1);
    sc.next_tx(ADMIN);
    admin_set_tier(&mut sc, &clk, ALICE, 4, b"Tier4-Tremendous");

    sc.next_tx(ALICE);
    let mut nft = sc.take_from_sender<Trumpagotchi>();
    let cosmetic = sc.take_from_sender<Cosmetic>();
    let reg = sc.take_shared<TierRegistry>();

    trumpagotchi::equip_outfit(&mut nft, cosmetic, &reg, &clk, sc.ctx());

    assert!(trumpagotchi::body_identifier(&nft) == string::utf8(b"Tier4-Tremendous-Tuxedo"), 1);
    assert!(trumpagotchi::base_body_identifier(&nft) == string::utf8(b"Tier1-FakeNews"), 2);
    assert!(option::is_some(&trumpagotchi::equipped_outfit(&nft)), 3);

    trumpagotchi::unequip_outfit(&mut nft, &clk, sc.ctx());
    assert!(trumpagotchi::body_identifier(&nft) == string::utf8(b"Tier1-FakeNews"), 4);
    assert!(option::is_none(&trumpagotchi::equipped_outfit(&nft)), 5);
    ts::return_shared(reg);
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

    clk.set_for_testing(1_000_000 + trumpagotchi::default_update_interval_ms() + 1);
    sc.next_tx(ADMIN);
    admin_set_tier(&mut sc, &clk, ALICE, 5, b"Tier5-BigLeague");

    sc.next_tx(ALICE);
    let mut nft = sc.take_from_sender<Trumpagotchi>();
    let cosmetic = sc.take_from_sender<Cosmetic>();
    let reg = sc.take_shared<TierRegistry>();
    trumpagotchi::equip_background(&mut nft, cosmetic, &reg, &clk, sc.ctx());
    assert!(trumpagotchi::background_identifier(&nft) == string::utf8(b"Ballroom"), 0);
    assert!(trumpagotchi::base_background_identifier(&nft) == string::utf8(b"BlackStars"), 1);

    trumpagotchi::unequip_background(&mut nft, &clk, sc.ctx());
    assert!(trumpagotchi::background_identifier(&nft) == string::utf8(b"BlackStars"), 2);
    ts::return_shared(reg);
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
    // ALICE registry tier stays at 1.

    sc.next_tx(ADMIN);
    admin_issue_outfit(
        &mut sc, b"GoldSuit", 12,
        b"GOLD.png", b"Tier12-VeryVeryRich-GoldSuit",
        ALICE,
    );

    sc.next_tx(ALICE);
    let mut nft = sc.take_from_sender<Trumpagotchi>();
    let cosmetic = sc.take_from_sender<Cosmetic>();
    let reg = sc.take_shared<TierRegistry>();
    trumpagotchi::equip_outfit(&mut nft, cosmetic, &reg, &clk, sc.ctx());

    ts::return_shared(reg);
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

    clk.set_for_testing(1_000_000 + trumpagotchi::default_update_interval_ms() + 1);
    sc.next_tx(ADMIN);
    admin_set_tier(&mut sc, &clk, ALICE, 5, b"Tier5-BigLeague");

    sc.next_tx(ALICE);
    let mut nft = sc.take_from_sender<Trumpagotchi>();
    let cosmetic = sc.take_from_sender<Cosmetic>();
    let reg = sc.take_shared<TierRegistry>();
    trumpagotchi::equip_outfit(&mut nft, cosmetic, &reg, &clk, sc.ctx());

    ts::return_shared(reg);
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
        b"TUXEDO.png", b"Tuxedo",
        BOB,
    );

    sc.next_tx(ALICE);
    let mut nft = sc.take_from_sender<Trumpagotchi>();

    sc.next_tx(BOB);
    let cosmetic = sc.take_from_sender<Cosmetic>();
    let reg = sc.take_shared<TierRegistry>();
    trumpagotchi::equip_outfit(&mut nft, cosmetic, &reg, &clk, sc.ctx());

    ts::return_shared(reg);
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
    let mut minted = sc.take_shared<MintedRegistry>();
    let mut tier = sc.take_shared<TierRegistry>();
    trumpagotchi::mint_to(
        &mut minted, &mut tier, ALICE, option::none(),
        string::utf8(b"Tier1-FakeNews"), string::utf8(b"BlackStars"),
        &clk, sc.ctx(),
    );
    trumpagotchi::mint_to(
        &mut minted, &mut tier, ALICE, option::none(),
        string::utf8(b"Tier1-FakeNews"), string::utf8(b"BlackStars"),
        &clk, sc.ctx(),
    );
    ts::return_shared(minted);
    ts::return_shared(tier);

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
    let mut minted = sc.take_shared<MintedRegistry>();
    let mut tier = sc.take_shared<TierRegistry>();
    assert!(trumpagotchi::is_exempt(&minted, PRE_EXEMPT_CRYPTOMISCHIEF), 0);
    trumpagotchi::mint_to(
        &mut minted, &mut tier, PRE_EXEMPT_CRYPTOMISCHIEF, option::none(),
        string::utf8(b"Tier1-FakeNews"), string::utf8(b"BlackStars"),
        &clk, sc.ctx(),
    );
    trumpagotchi::mint_to(
        &mut minted, &mut tier, PRE_EXEMPT_CRYPTOMISCHIEF, option::none(),
        string::utf8(b"Tier1-FakeNews"), string::utf8(b"BlackStars"),
        &clk, sc.ctx(),
    );
    trumpagotchi::mint_to(
        &mut minted, &mut tier, PRE_EXEMPT_CRYPTOMISCHIEF, option::none(),
        string::utf8(b"Tier1-FakeNews"), string::utf8(b"BlackStars"),
        &clk, sc.ctx(),
    );
    assert!(!trumpagotchi::has_minted(&minted, PRE_EXEMPT_CRYPTOMISCHIEF), 1);
    ts::return_shared(minted);
    ts::return_shared(tier);

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

// ── TierRegistry ──────────────────────────────────────────────────────────

#[test]
fun test_admin_set_tier_creates_entry_for_unminted_holder() {
    // Identity engine should be able to score a wallet that hasn't minted
    // yet (so the tier is ready when they later mint).
    let mut sc = bootstrap();
    sc.next_tx(ADMIN);
    let mut clk = clock::create_for_testing(sc.ctx());
    clk.set_for_testing(1_000_000);

    sc.next_tx(ADMIN);
    let admin = sc.take_from_sender<AdminCap>();
    let mut reg = sc.take_shared<TierRegistry>();
    assert!(!trumpagotchi::has_entry(&reg, ALICE), 0);

    trumpagotchi::set_tier(
        &admin, &mut reg, ALICE, 7, 1234567u128,
        string::utf8(b"Tier7-MajorPlayer"),
        string::utf8(b"BlackStars"),
        &clk,
    );
    assert!(trumpagotchi::tier_of(&reg, ALICE) == 7, 1);
    let entry = trumpagotchi::tier_entry(&reg, ALICE);
    assert!(trumpagotchi::entry_score(&entry) == 1234567u128, 2);
    assert!(trumpagotchi::entry_target_base_body(&entry) == string::utf8(b"Tier7-MajorPlayer"), 3);

    ts::return_shared(reg);
    sc.return_to_sender(admin);
    clock::destroy_for_testing(clk);
    sc.end();
}

#[test, expected_failure(abort_code = trumpagotchi::ETierAdvanceTooSoon)]
fun test_set_tier_rate_limit_blocks_immediate_re_advance() {
    let mut sc = bootstrap();
    sc.next_tx(ADMIN);
    let mut clk = clock::create_for_testing(sc.ctx());
    clk.set_for_testing(1_000_000);

    sc.next_tx(ADMIN);
    mint_default(&mut sc, &clk, ALICE);

    // First advance succeeds (waits past initial mint timestamp).
    clk.set_for_testing(1_000_000 + trumpagotchi::default_update_interval_ms() + 1);
    sc.next_tx(ADMIN);
    admin_set_tier(&mut sc, &clk, ALICE, 4, b"Tier4-Tremendous");

    // Second advance immediately after — should abort with ETierAdvanceTooSoon.
    sc.next_tx(ADMIN);
    admin_set_tier(&mut sc, &clk, ALICE, 5, b"Tier5-BigLeague");

    clock::destroy_for_testing(clk);
    sc.end();
}

#[test]
fun test_set_tier_drop_respects_decay_grace_window() {
    let mut sc = bootstrap();
    sc.next_tx(ADMIN);
    let mut clk = clock::create_for_testing(sc.ctx());
    clk.set_for_testing(1_000_000);

    sc.next_tx(ADMIN);
    mint_default(&mut sc, &clk, ALICE);

    // Advance to T7
    clk.set_for_testing(1_000_000 + trumpagotchi::default_update_interval_ms() + 1);
    sc.next_tx(ADMIN);
    admin_set_tier(&mut sc, &clk, ALICE, 7, b"Tier7-MajorPlayer");

    // Set decay grace ending in the future
    sc.next_tx(ADMIN);
    let admin = sc.take_from_sender<AdminCap>();
    let mut reg = sc.take_shared<TierRegistry>();
    let now = clock::timestamp_ms(&clk);
    trumpagotchi::set_decay_grace(&admin, &mut reg, ALICE, now + 10_000_000);
    ts::return_shared(reg);
    sc.return_to_sender(admin);

    // Try to drop to T3 — registry should keep tier at 7 (grace active).
    sc.next_tx(ADMIN);
    admin_set_tier(&mut sc, &clk, ALICE, 3, b"Tier3-Tremendous");
    sc.next_tx(ADMIN);
    let reg = sc.take_shared<TierRegistry>();
    assert!(trumpagotchi::tier_of(&reg, ALICE) == 7, 0);
    ts::return_shared(reg);

    // Advance clock past grace, retry drop.
    clk.set_for_testing(now + 11_000_000);
    sc.next_tx(ADMIN);
    admin_set_tier(&mut sc, &clk, ALICE, 3, b"Tier3-Tremendous");
    sc.next_tx(ADMIN);
    let reg = sc.take_shared<TierRegistry>();
    assert!(trumpagotchi::tier_of(&reg, ALICE) == 3, 1);
    ts::return_shared(reg);

    clock::destroy_for_testing(clk);
    sc.end();
}

#[test]
fun test_batch_set_tiers_bulk_update() {
    let mut sc = bootstrap();
    sc.next_tx(ADMIN);
    let mut clk = clock::create_for_testing(sc.ctx());
    clk.set_for_testing(1_000_000);

    sc.next_tx(ADMIN);
    let admin = sc.take_from_sender<AdminCap>();
    let mut reg = sc.take_shared<TierRegistry>();

    let addrs = vector[ALICE, BOB];
    let tiers = vector[5u8, 9u8];
    let scores = vector[100u128, 5_000_000u128];
    let bodies = vector[
        string::utf8(b"Tier5-BigLeague"),
        string::utf8(b"Tier9-BigStrongBoy"),
    ];
    let bgs = vector[
        string::utf8(b"BlackStars"),
        string::utf8(b"BlackStars"),
    ];
    trumpagotchi::batch_set_tiers(
        &admin, &mut reg, addrs, tiers, scores, bodies, bgs, &clk,
    );

    assert!(trumpagotchi::tier_of(&reg, ALICE) == 5, 0);
    assert!(trumpagotchi::tier_of(&reg, BOB) == 9, 1);

    ts::return_shared(reg);
    sc.return_to_sender(admin);
    clock::destroy_for_testing(clk);
    sc.end();
}

#[test]
fun test_set_update_interval_can_be_changed() {
    let mut sc = bootstrap();
    sc.next_tx(ADMIN);
    let admin = sc.take_from_sender<AdminCap>();
    let mut reg = sc.take_shared<TierRegistry>();

    assert!(trumpagotchi::update_interval_ms(&reg) == trumpagotchi::default_update_interval_ms(), 0);
    trumpagotchi::set_update_interval(&admin, &mut reg, 999_000);
    assert!(trumpagotchi::update_interval_ms(&reg) == 999_000, 1);

    ts::return_shared(reg);
    sc.return_to_sender(admin);
    sc.end();
}

#[test]
fun test_claim_tier_advance_pulls_registry_state_into_nft() {
    let mut sc = bootstrap();
    sc.next_tx(ADMIN);
    let mut clk = clock::create_for_testing(sc.ctx());
    clk.set_for_testing(1_000_000);

    sc.next_tx(ADMIN);
    mint_default(&mut sc, &clk, ALICE);

    // Engine pushes ALICE to tier 7
    clk.set_for_testing(1_000_000 + trumpagotchi::default_update_interval_ms() + 1);
    sc.next_tx(ADMIN);
    admin_set_tier(&mut sc, &clk, ALICE, 7, b"Tier7-MajorPlayer");

    // ALICE claims the advance — base_body identifier + synced_tier update.
    sc.next_tx(ALICE);
    let mut nft = sc.take_from_sender<Trumpagotchi>();
    assert!(trumpagotchi::synced_tier(&nft) == 1, 0);
    let reg = sc.take_shared<TierRegistry>();
    let new_tier = trumpagotchi::claim_tier_advance(&mut nft, &reg, &clk, sc.ctx());
    assert!(new_tier == 7, 1);
    assert!(trumpagotchi::synced_tier(&nft) == 7, 2);
    assert!(trumpagotchi::base_body_identifier(&nft) == string::utf8(b"Tier7-MajorPlayer"), 3);
    // No outfit equipped, so body_identifier follows base.
    assert!(trumpagotchi::body_identifier(&nft) == string::utf8(b"Tier7-MajorPlayer"), 4);
    // base_body_identifier_at_mint preserves original.
    assert!(trumpagotchi::base_body_identifier_at_mint(&nft) == string::utf8(b"Tier1-FakeNews"), 5);

    ts::return_shared(reg);
    sc.return_to_sender(nft);
    clock::destroy_for_testing(clk);
    sc.end();
}

#[test]
fun test_claim_tier_advance_recomposes_body_when_outfit_equipped() {
    // 9th-deployment behaviour: claim_tier_advance must update the equipped
    // body strip to match the wearer's new tier, e.g. switch from
    // Tier4-Tremendous-Tuxedo to Tier7-MajorPlayer-Tuxedo on T4→T7 advance.
    let mut sc = bootstrap();
    sc.next_tx(ADMIN);
    let mut clk = clock::create_for_testing(sc.ctx());
    clk.set_for_testing(1_000_000);

    sc.next_tx(ADMIN);
    mint_default(&mut sc, &clk, ALICE);

    // ALICE → T4 + equip Tuxedo (suffix only — registry composes with base).
    clk.set_for_testing(1_000_000 + trumpagotchi::default_update_interval_ms() + 1);
    sc.next_tx(ADMIN);
    admin_set_tier(&mut sc, &clk, ALICE, 4, b"Tier4-Tremendous");
    sc.next_tx(ADMIN);
    admin_issue_outfit(
        &mut sc, b"Tuxedo", 4,
        b"TUXEDO.png", b"Tuxedo",
        ALICE,
    );

    sc.next_tx(ALICE);
    let mut nft = sc.take_from_sender<Trumpagotchi>();
    let cosmetic = sc.take_from_sender<Cosmetic>();
    let reg = sc.take_shared<TierRegistry>();
    trumpagotchi::equip_outfit(&mut nft, cosmetic, &reg, &clk, sc.ctx());
    ts::return_shared(reg);
    assert!(trumpagotchi::body_identifier(&nft) == string::utf8(b"Tier4-Tremendous-Tuxedo"), 0);

    // Engine advances ALICE to T7.
    let t = clock::timestamp_ms(&clk);
    clk.set_for_testing(t + trumpagotchi::default_update_interval_ms() + 1);
    sc.return_to_sender(nft);
    sc.next_tx(ADMIN);
    admin_set_tier(&mut sc, &clk, ALICE, 7, b"Tier7-MajorPlayer");

    // ALICE claims — body recomposes to Tier7-MajorPlayer-Tuxedo.
    sc.next_tx(ALICE);
    let mut nft = sc.take_from_sender<Trumpagotchi>();
    let reg = sc.take_shared<TierRegistry>();
    trumpagotchi::claim_tier_advance(&mut nft, &reg, &clk, sc.ctx());
    assert!(trumpagotchi::synced_tier(&nft) == 7, 1);
    assert!(trumpagotchi::base_body_identifier(&nft) == string::utf8(b"Tier7-MajorPlayer"), 2);
    assert!(trumpagotchi::body_identifier(&nft) == string::utf8(b"Tier7-MajorPlayer-Tuxedo"), 3);
    ts::return_shared(reg);
    sc.return_to_sender(nft);

    clock::destroy_for_testing(clk);
    sc.end();
}

#[test, expected_failure(abort_code = trumpagotchi::ENoTierEntry)]
fun test_set_decay_grace_aborts_for_unknown_address() {
    // set_decay_grace requires the address to already have an entry —
    // engine should call set_tier (which creates) before set_decay_grace.
    let mut sc = bootstrap();
    sc.next_tx(ADMIN);
    let admin = sc.take_from_sender<AdminCap>();
    let mut reg = sc.take_shared<TierRegistry>();
    trumpagotchi::set_decay_grace(&admin, &mut reg, @0xDEAD, 10_000);
    ts::return_shared(reg);
    sc.return_to_sender(admin);
    sc.end();
}

#[test, expected_failure(abort_code = trumpagotchi::ETierOutOfRange)]
fun test_set_tier_rejects_out_of_range_tier() {
    let mut sc = bootstrap();
    sc.next_tx(ADMIN);
    let mut clk = clock::create_for_testing(sc.ctx());
    clk.set_for_testing(1_000_000);

    sc.next_tx(ADMIN);
    let admin = sc.take_from_sender<AdminCap>();
    let mut reg = sc.take_shared<TierRegistry>();
    trumpagotchi::set_tier(
        &admin, &mut reg, ALICE, 14, 0u128,
        string::utf8(b"Tier14-Invalid"),
        string::utf8(b"BlackStars"),
        &clk,
    );

    ts::return_shared(reg);
    sc.return_to_sender(admin);
    clock::destroy_for_testing(clk);
    sc.end();
}

#[test, expected_failure(abort_code = trumpagotchi::EVecLengthMismatch)]
fun test_batch_set_tiers_aborts_on_length_mismatch() {
    let mut sc = bootstrap();
    sc.next_tx(ADMIN);
    let mut clk = clock::create_for_testing(sc.ctx());
    clk.set_for_testing(1_000_000);

    sc.next_tx(ADMIN);
    let admin = sc.take_from_sender<AdminCap>();
    let mut reg = sc.take_shared<TierRegistry>();

    let addrs = vector[ALICE, BOB];
    let tiers = vector[5u8];   // length mismatch
    let scores = vector[0u128];
    let bodies = vector[string::utf8(b"x")];
    let bgs = vector[string::utf8(b"BlackStars")];
    trumpagotchi::batch_set_tiers(
        &admin, &mut reg, addrs, tiers, scores, bodies, bgs, &clk,
    );

    ts::return_shared(reg);
    sc.return_to_sender(admin);
    clock::destroy_for_testing(clk);
    sc.end();
}
