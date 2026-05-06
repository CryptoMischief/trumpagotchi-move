module trumpagotchi::trumpagotchi;

use std::string::String;
use sui::clock::{Self, Clock};
use sui::display;
use sui::dynamic_field as df;
use sui::event;
use sui::package::{Self, Publisher};
use sui::table::{Self, Table};
use sui::transfer_policy;
use sui::vec_set::{Self, VecSet};
use kiosk::royalty_rule;

// Pre-seeded exempt address — cryptomischief.sui — exempt from the
// one-Trumpagotchi-per-wallet rule for testing. Admin can add/remove
// additional exempt addresses via add_exempt / remove_exempt.
const PRE_EXEMPT_CRYPTOMISCHIEF: address =
    @0x39ee291682e829771ad0c3ed46ebc69a962b7c2f9e6477409b22616bcf21ac34;

// ── Soulbound Trumpagotchi NFT ─────────────────────────────────────────────
// `key` only (no `store`). Without `store` the object cannot be wrapped,
// placed in dynamic fields, or transferred via `sui::transfer::public_transfer`.
// This is the canonical Sui soulbound pattern (Sui Foundation example).
// v8 §5.1 sketches `key, store` but that's incompatible with the soulbound
// requirement in v8 §3 — we keep the canonical pattern.
public struct Trumpagotchi has key {
    id: UID,
    owner: address,
    // Immutable identity — set at mint, never changes (used to revert on unequip).
    base_body_identifier: String,        // e.g. "Tier1-FakeNews"
    base_background_identifier: String,  // e.g. "BlackStars"
    // Mutable identity — updates on equip/unequip. Display.image_url
    // interpolates `body_identifier` into "{body_identifier}-animated.gif".
    body_identifier: String,
    background_identifier: String,
    // Equip slots. None = SUITRUMP_SUIT default for outfits / Black Stars
    // default for background. Cosmetic moves into a typed dynamic field
    // child of this NFT while equipped — physically untransferable.
    equipped_outfit: Option<ID>,
    equipped_background: Option<ID>,
    equipped_shell: Option<ID>,
    // Tier — updated by the off-chain identity engine via admin call.
    // Frontend reads this to drive the outfit selector + tier gates.
    current_tier: u8,
    // Optional displayed name (Tier 10+ only — set via set_name, costs 1 SUI).
    name: Option<String>,
    referrer: Option<address>,
    creation_timestamp: u64,
}

// ── Tradeable Cosmetic NFT ─────────────────────────────────────────────────
// Has `store` — can be placed in a Kiosk and listed on Tradeport et al.
// While equipped, the cosmetic is physically locked inside the parent NFT
// via dynamic field — can't be listed until unequipped.
public struct Cosmetic has key, store {
    id: UID,
    // 0 = outfit, 1 = background, 2 = shell  (v8 §3.5)
    kind: u8,
    // Display name — e.g. "Golf", "Ballroom", "Classic Red".
    name: String,
    // Minimum tier required to equip; secondary-market trades have NO gate.
    tier_gate: u8,
    // 0 = common, 1 = rare, 2 = epic, 3 = legendary
    rarity: u8,
    // Walrus quilt patch identifier for the static paper-doll PNG (shop +
    // marketplace card). e.g. "TUXEDO.png", "Ballroom.png".
    walrus_identifier_standalone: String,
    // Walrus quilt patch identifier for the animated body strip (the
    // dapp browser compositor uses this; also stamped into the parent
    // NFT's `body_identifier` on equip). e.g. "Tier4-Tremendous-Tuxedo".
    walrus_identifier_equipped: String,
}

// Dynamic-field key types — one per slot. Distinct types avoid collision.
public struct OutfitSlot has copy, drop, store {}
public struct BackgroundSlot has copy, drop, store {}
public struct ShellSlot has copy, drop, store {}

// ── Capabilities + OTW ─────────────────────────────────────────────────────
public struct AdminCap has key, store { id: UID }
public struct TRUMPAGOTCHI has drop {}

// ── Errors ─────────────────────────────────────────────────────────────────
const EWrongOwner: u64 = 0;
const EWrongCosmeticKind: u64 = 1;
const ESlotOccupied: u64 = 2;
const ESlotEmpty: u64 = 3;
const EBelowTierGate: u64 = 4;
const ENameTooLong: u64 = 5;
const EAlreadyMinted: u64 = 6;

const KIND_OUTFIT: u8 = 0;
const KIND_BACKGROUND: u8 = 1;
const KIND_SHELL: u8 = 2;
const NAME_MAX_LEN: u64 = 32;
const NAME_MIN_TIER: u8 = 10;

// 2.5% (250 bps) royalty on cosmetic secondary sales — accumulates in the
// TransferPolicy, swept manually to the prize-pool address.
const COSMETIC_ROYALTY_BPS: u16 = 250;
const COSMETIC_ROYALTY_MIN_MIST: u64 = 0;

// ── MintedRegistry ─────────────────────────────────────────────────────────
public struct MintedRegistry has key {
    id: UID,
    minted: Table<address, ID>,
    exempt: VecSet<address>,
}

// ── Events ─────────────────────────────────────────────────────────────────
public struct Minted has copy, drop {
    nft_id: ID,
    owner: address,
    referrer: Option<address>,
    base_body_identifier: String,
    timestamp_ms: u64,
}

public struct Equipped has copy, drop {
    nft_id: ID,
    cosmetic_id: ID,
    kind: u8,
    new_body_identifier: String,        // ignored when kind != 0 (outfit)
    new_background_identifier: String,  // ignored when kind != 1 (background)
    timestamp_ms: u64,
}

public struct Unequipped has copy, drop {
    nft_id: ID,
    cosmetic_id: ID,
    kind: u8,
    timestamp_ms: u64,
}

public struct CosmeticIssued has copy, drop {
    cosmetic_id: ID,
    kind: u8,
    name: String,
    tier_gate: u8,
    rarity: u8,
    walrus_identifier_standalone: String,
    walrus_identifier_equipped: String,
    recipient: address,
}

public struct CosmeticPolicyCreated has copy, drop {
    policy_id: ID,
    royalty_bps: u16,
}

public struct TierUpdated has copy, drop {
    nft_id: ID,
    old_tier: u8,
    new_tier: u8,
    timestamp_ms: u64,
}

// ── Init ───────────────────────────────────────────────────────────────────
fun init(otw: TRUMPAGOTCHI, ctx: &mut TxContext) {
    let publisher = package::claim(otw, ctx);

    // MintedRegistry — pre-seed exempt list.
    let mut exempt = vec_set::empty<address>();
    vec_set::insert(&mut exempt, PRE_EXEMPT_CRYPTOMISCHIEF);
    let registry = MintedRegistry {
        id: object::new(ctx),
        minted: table::new<address, ID>(ctx),
        exempt,
    };
    transfer::share_object(registry);

    // Display: NFT image_url is the animated GIF (always animated per v8 §3.1).
    // Background equip/unequip does NOT affect image_url — only body_identifier
    // interpolates. Background is dapp-only per v8 §5.3 amendment 2026-05-05.
    let mut display = display::new<Trumpagotchi>(&publisher, ctx);
    display.add(b"name".to_string(), b"Trumpagotchi #{owner}".to_string());
    display.add(
        b"description".to_string(),
        b"Soulbound Trumpagotchi NFT for SUITRUMP holders.".to_string(),
    );
    display.add(
        b"image_url".to_string(),
        b"https://aggregator.walrus-testnet.walrus.space/v1/blobs/by-quilt-id/fUP4-zZix8juJvewM27ZllW3QG5RfYUQgN20oAJeBJY/{body_identifier}-animated.gif".to_string(),
    );
    display.add(b"project_url".to_string(), b"https://suitrump.com".to_string());
    display.update_version();

    // Display: Cosmetic image_url is the standalone paper-doll PNG.
    let mut cosmetic_display = display::new<Cosmetic>(&publisher, ctx);
    cosmetic_display.add(b"name".to_string(), b"{name}".to_string());
    cosmetic_display.add(
        b"image_url".to_string(),
        b"https://aggregator.walrus-testnet.walrus.space/v1/blobs/by-quilt-id/qTpv-JbQi39xsODi6b5ZUbJFgw6MG1VCZ7Iq6QhzF4s/{walrus_identifier_standalone}".to_string(),
    );
    cosmetic_display.update_version();

    let admin = AdminCap { id: object::new(ctx) };

    transfer::public_transfer(publisher, ctx.sender());
    transfer::public_transfer(display, ctx.sender());
    transfer::public_transfer(cosmetic_display, ctx.sender());
    transfer::public_transfer(admin, ctx.sender());
}

// ── Cosmetic TransferPolicy + 2.5% royalty rule ────────────────────────────
public entry fun create_cosmetic_transfer_policy(
    _admin: &AdminCap,
    publisher: &Publisher,
    ctx: &mut TxContext,
) {
    let (mut policy, cap) = transfer_policy::new<Cosmetic>(publisher, ctx);
    royalty_rule::add(&mut policy, &cap, COSMETIC_ROYALTY_BPS, COSMETIC_ROYALTY_MIN_MIST);
    let policy_id = object::id(&policy);
    transfer::public_share_object(policy);
    transfer::public_transfer(cap, ctx.sender());
    event::emit(CosmeticPolicyCreated { policy_id, royalty_bps: COSMETIC_ROYALTY_BPS });
}

// ── Mint ───────────────────────────────────────────────────────────────────
// Per v8: every fresh mint starts at Tier 1 with SUITRUMP_SUIT (no equipped
// outfit) and Black Stars background. base_* identifiers immutable; mutable
// identifiers initialised to match.
public(package) fun mint_to(
    registry: &mut MintedRegistry,
    recipient: address,
    referrer: Option<address>,
    base_body_identifier: String,
    base_background_identifier: String,
    clock: &Clock,
    ctx: &mut TxContext,
): ID {
    let is_exempt = vec_set::contains(&registry.exempt, &recipient);
    if (!is_exempt) {
        assert!(!table::contains(&registry.minted, recipient), EAlreadyMinted);
    };

    let now = clock::timestamp_ms(clock);
    let nft = Trumpagotchi {
        id: object::new(ctx),
        owner: recipient,
        base_body_identifier,
        base_background_identifier,
        body_identifier: base_body_identifier,
        background_identifier: base_background_identifier,
        equipped_outfit: option::none(),
        equipped_background: option::none(),
        equipped_shell: option::none(),
        current_tier: 1,
        name: option::none(),
        referrer,
        creation_timestamp: now,
    };
    let nft_id = object::id(&nft);

    if (!is_exempt) {
        table::add(&mut registry.minted, recipient, nft_id);
    };

    event::emit(Minted {
        nft_id,
        owner: recipient,
        referrer,
        base_body_identifier: nft.base_body_identifier,
        timestamp_ms: now,
    });
    transfer::transfer(nft, recipient);
    nft_id
}

// ── MintedRegistry admin ──────────────────────────────────────────────────
public fun add_exempt(_admin: &AdminCap, registry: &mut MintedRegistry, who: address) {
    if (!vec_set::contains(&registry.exempt, &who)) {
        vec_set::insert(&mut registry.exempt, who);
    };
}

public fun remove_exempt(_admin: &AdminCap, registry: &mut MintedRegistry, who: address) {
    if (vec_set::contains(&registry.exempt, &who)) {
        vec_set::remove(&mut registry.exempt, &who);
    };
}

public fun has_minted(registry: &MintedRegistry, who: address): bool {
    table::contains(&registry.minted, who)
}

public fun is_exempt(registry: &MintedRegistry, who: address): bool {
    vec_set::contains(&registry.exempt, &who)
}

// ── Cosmetic issuance ──────────────────────────────────────────────────────
public(package) fun issue_cosmetic(
    kind: u8,
    name: String,
    tier_gate: u8,
    rarity: u8,
    walrus_identifier_standalone: String,
    walrus_identifier_equipped: String,
    recipient: address,
    ctx: &mut TxContext,
): ID {
    assert!(
        kind == KIND_OUTFIT || kind == KIND_BACKGROUND || kind == KIND_SHELL,
        EWrongCosmeticKind,
    );
    let cosmetic = Cosmetic {
        id: object::new(ctx),
        kind,
        name,
        tier_gate,
        rarity,
        walrus_identifier_standalone,
        walrus_identifier_equipped,
    };
    let cid = object::id(&cosmetic);
    event::emit(CosmeticIssued {
        cosmetic_id: cid,
        kind,
        name: cosmetic.name,
        tier_gate,
        rarity,
        walrus_identifier_standalone: cosmetic.walrus_identifier_standalone,
        walrus_identifier_equipped: cosmetic.walrus_identifier_equipped,
        recipient,
    });
    transfer::public_transfer(cosmetic, recipient);
    cid
}

// Admin direct mint (used for promo/airdrops/smoke). Same 1-per-wallet rule.
public fun admin_mint(
    _admin: &AdminCap,
    registry: &mut MintedRegistry,
    recipient: address,
    base_body_identifier: String,
    base_background_identifier: String,
    clock: &Clock,
    ctx: &mut TxContext,
): ID {
    mint_to(
        registry,
        recipient,
        option::none(),
        base_body_identifier,
        base_background_identifier,
        clock,
        ctx,
    )
}

public fun admin_issue_cosmetic(
    _admin: &AdminCap,
    kind: u8,
    name: String,
    tier_gate: u8,
    rarity: u8,
    walrus_identifier_standalone: String,
    walrus_identifier_equipped: String,
    recipient: address,
    ctx: &mut TxContext,
): ID {
    issue_cosmetic(
        kind, name, tier_gate, rarity,
        walrus_identifier_standalone, walrus_identifier_equipped,
        recipient, ctx,
    )
}

// ── Equip ──────────────────────────────────────────────────────────────────
// Outfit: mutates body_identifier to cosmetic.walrus_identifier_equipped.
// Background: mutates background_identifier to cosmetic.walrus_identifier_equipped.
// Shell: only sets equipped_shell — no body/bg identifier change.
//
// Tier gate: caller-supplied current_tier checked against cosmetic.tier_gate.
// (Frontend reads NFT.current_tier; we trust the caller-passed value as
// defence-in-depth — off-chain identity engine refuses mismatched renders.)
public fun equip_outfit(
    nft: &mut Trumpagotchi,
    cosmetic: Cosmetic,
    current_tier: u8,
    clock: &Clock,
    ctx: &TxContext,
) {
    assert!(nft.owner == ctx.sender(), EWrongOwner);
    assert!(cosmetic.kind == KIND_OUTFIT, EWrongCosmeticKind);
    assert!(current_tier >= cosmetic.tier_gate, EBelowTierGate);
    assert!(option::is_none(&nft.equipped_outfit), ESlotOccupied);

    let cid = object::id(&cosmetic);
    let new_body = cosmetic.walrus_identifier_equipped;
    nft.equipped_outfit = option::some(cid);
    nft.body_identifier = new_body;
    df::add(&mut nft.id, OutfitSlot {}, cosmetic);

    let now = clock::timestamp_ms(clock);
    event::emit(Equipped {
        nft_id: object::id(nft),
        cosmetic_id: cid,
        kind: KIND_OUTFIT,
        new_body_identifier: new_body,
        new_background_identifier: nft.background_identifier,
        timestamp_ms: now,
    });
}

public fun equip_background(
    nft: &mut Trumpagotchi,
    cosmetic: Cosmetic,
    current_tier: u8,
    clock: &Clock,
    ctx: &TxContext,
) {
    assert!(nft.owner == ctx.sender(), EWrongOwner);
    assert!(cosmetic.kind == KIND_BACKGROUND, EWrongCosmeticKind);
    assert!(current_tier >= cosmetic.tier_gate, EBelowTierGate);
    assert!(option::is_none(&nft.equipped_background), ESlotOccupied);

    let cid = object::id(&cosmetic);
    let new_bg = cosmetic.walrus_identifier_equipped;
    nft.equipped_background = option::some(cid);
    nft.background_identifier = new_bg;
    df::add(&mut nft.id, BackgroundSlot {}, cosmetic);

    let now = clock::timestamp_ms(clock);
    event::emit(Equipped {
        nft_id: object::id(nft),
        cosmetic_id: cid,
        kind: KIND_BACKGROUND,
        new_body_identifier: nft.body_identifier,
        new_background_identifier: new_bg,
        timestamp_ms: now,
    });
}

public fun equip_shell(
    nft: &mut Trumpagotchi,
    cosmetic: Cosmetic,
    current_tier: u8,
    clock: &Clock,
    ctx: &TxContext,
) {
    assert!(nft.owner == ctx.sender(), EWrongOwner);
    assert!(cosmetic.kind == KIND_SHELL, EWrongCosmeticKind);
    assert!(current_tier >= cosmetic.tier_gate, EBelowTierGate);
    assert!(option::is_none(&nft.equipped_shell), ESlotOccupied);

    let cid = object::id(&cosmetic);
    nft.equipped_shell = option::some(cid);
    df::add(&mut nft.id, ShellSlot {}, cosmetic);

    let now = clock::timestamp_ms(clock);
    event::emit(Equipped {
        nft_id: object::id(nft),
        cosmetic_id: cid,
        kind: KIND_SHELL,
        new_body_identifier: nft.body_identifier,
        new_background_identifier: nft.background_identifier,
        timestamp_ms: now,
    });
}

// ── Unequip ────────────────────────────────────────────────────────────────
// Outfit unequip = "select SUITRUMP_SUIT" per v8 §3.2 — reverts body to
// base_body_identifier. Background unequip = revert to base (Black Stars).
#[allow(lint(self_transfer))]
public fun unequip_outfit(nft: &mut Trumpagotchi, clock: &Clock, ctx: &mut TxContext) {
    assert!(nft.owner == ctx.sender(), EWrongOwner);
    assert!(option::is_some(&nft.equipped_outfit), ESlotEmpty);
    let cosmetic: Cosmetic = df::remove(&mut nft.id, OutfitSlot {});
    let cid = object::id(&cosmetic);
    nft.equipped_outfit = option::none();
    nft.body_identifier = nft.base_body_identifier;
    let now = clock::timestamp_ms(clock);
    transfer::public_transfer(cosmetic, ctx.sender());
    event::emit(Unequipped { nft_id: object::id(nft), cosmetic_id: cid, kind: KIND_OUTFIT, timestamp_ms: now });
}

#[allow(lint(self_transfer))]
public fun unequip_background(nft: &mut Trumpagotchi, clock: &Clock, ctx: &mut TxContext) {
    assert!(nft.owner == ctx.sender(), EWrongOwner);
    assert!(option::is_some(&nft.equipped_background), ESlotEmpty);
    let cosmetic: Cosmetic = df::remove(&mut nft.id, BackgroundSlot {});
    let cid = object::id(&cosmetic);
    nft.equipped_background = option::none();
    nft.background_identifier = nft.base_background_identifier;
    let now = clock::timestamp_ms(clock);
    transfer::public_transfer(cosmetic, ctx.sender());
    event::emit(Unequipped { nft_id: object::id(nft), cosmetic_id: cid, kind: KIND_BACKGROUND, timestamp_ms: now });
}

#[allow(lint(self_transfer))]
public fun unequip_shell(nft: &mut Trumpagotchi, clock: &Clock, ctx: &mut TxContext) {
    assert!(nft.owner == ctx.sender(), EWrongOwner);
    assert!(option::is_some(&nft.equipped_shell), ESlotEmpty);
    let cosmetic: Cosmetic = df::remove(&mut nft.id, ShellSlot {});
    let cid = object::id(&cosmetic);
    nft.equipped_shell = option::none();
    let now = clock::timestamp_ms(clock);
    transfer::public_transfer(cosmetic, ctx.sender());
    event::emit(Unequipped { nft_id: object::id(nft), cosmetic_id: cid, kind: KIND_SHELL, timestamp_ms: now });
}

// ── Naming ─────────────────────────────────────────────────────────────────
// Tier 10+ only — Sprint 4 will gate the 1 SUI fee at the frontend layer.
public fun set_name(
    nft: &mut Trumpagotchi,
    new_name: String,
    current_tier: u8,
    _clock: &Clock,
    ctx: &TxContext,
) {
    assert!(nft.owner == ctx.sender(), EWrongOwner);
    assert!(current_tier >= NAME_MIN_TIER, EBelowTierGate);
    assert!(new_name.length() <= NAME_MAX_LEN, ENameTooLong);
    nft.name = option::some(new_name);
}

// Admin-managed tier — set by the off-chain identity engine each Monday.
public fun set_current_tier(
    _admin: &AdminCap,
    nft: &mut Trumpagotchi,
    new_tier: u8,
    clock: &Clock,
) {
    let old_tier = nft.current_tier;
    if (old_tier == new_tier) return;
    nft.current_tier = new_tier;
    event::emit(TierUpdated {
        nft_id: object::id(nft),
        old_tier,
        new_tier,
        timestamp_ms: clock::timestamp_ms(clock),
    });
}

// Admin can update body_identifier directly when the identity engine
// advances tier — base_body_identifier is mutable here too because the
// "base body" for a wallet changes per tier (Tier 4 base = Tier4-Tremendous,
// Tier 5 base = Tier5-BigLeague, etc).
public fun set_base_identifiers(
    _admin: &AdminCap,
    nft: &mut Trumpagotchi,
    new_base_body: String,
    new_base_background: String,
) {
    nft.base_body_identifier = new_base_body;
    nft.base_background_identifier = new_base_background;
    // If currently no outfit equipped, body_identifier follows the base.
    if (option::is_none(&nft.equipped_outfit)) {
        nft.body_identifier = new_base_body;
    };
    if (option::is_none(&nft.equipped_background)) {
        nft.background_identifier = new_base_background;
    };
}

// ── Read-only accessors ────────────────────────────────────────────────────
public fun owner(nft: &Trumpagotchi): address { nft.owner }
public fun current_tier(nft: &Trumpagotchi): u8 { nft.current_tier }
public fun base_body_identifier(nft: &Trumpagotchi): String { nft.base_body_identifier }
public fun body_identifier(nft: &Trumpagotchi): String { nft.body_identifier }
public fun base_background_identifier(nft: &Trumpagotchi): String { nft.base_background_identifier }
public fun background_identifier(nft: &Trumpagotchi): String { nft.background_identifier }
public fun equipped_outfit(nft: &Trumpagotchi): Option<ID> { nft.equipped_outfit }
public fun equipped_background(nft: &Trumpagotchi): Option<ID> { nft.equipped_background }
public fun equipped_shell(nft: &Trumpagotchi): Option<ID> { nft.equipped_shell }
public fun referrer(nft: &Trumpagotchi): Option<address> { nft.referrer }
public fun creation_timestamp(nft: &Trumpagotchi): u64 { nft.creation_timestamp }
public fun nft_name(nft: &Trumpagotchi): Option<String> { nft.name }

public fun cosmetic_kind(c: &Cosmetic): u8 { c.kind }
public fun cosmetic_name(c: &Cosmetic): String { c.name }
public fun cosmetic_tier_gate(c: &Cosmetic): u8 { c.tier_gate }
public fun cosmetic_rarity(c: &Cosmetic): u8 { c.rarity }
public fun cosmetic_walrus_standalone(c: &Cosmetic): String { c.walrus_identifier_standalone }
public fun cosmetic_walrus_equipped(c: &Cosmetic): String { c.walrus_identifier_equipped }

// ── Test-only helpers ──────────────────────────────────────────────────────
#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(TRUMPAGOTCHI {}, ctx);
}

#[test_only]
public fun destroy_nft_for_testing(nft: Trumpagotchi) {
    let Trumpagotchi {
        id, owner: _, base_body_identifier: _, base_background_identifier: _,
        body_identifier: _, background_identifier: _,
        equipped_outfit: _, equipped_background: _, equipped_shell: _,
        current_tier: _, name: _, referrer: _, creation_timestamp: _,
    } = nft;
    object::delete(id);
}

#[test_only] public fun kind_outfit(): u8 { KIND_OUTFIT }
#[test_only] public fun kind_background(): u8 { KIND_BACKGROUND }
#[test_only] public fun kind_shell(): u8 { KIND_SHELL }
#[test_only] public fun cosmetic_royalty_bps(): u16 { COSMETIC_ROYALTY_BPS }
