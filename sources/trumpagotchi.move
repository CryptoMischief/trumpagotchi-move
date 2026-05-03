module trumpagotchi::trumpagotchi;

use std::string::String;
use sui::clock::{Self, Clock};
use sui::dynamic_field as df;
use sui::event;
use sui::package;
use sui::display;

// ── Soulbound NFT ──────────────────────────────────────────────────────────
// `Trumpagotchi` deliberately has `key` but NOT `store`. Without `store` the
// object cannot be wrapped, placed in dynamic fields, or transferred by the
// generic `sui::transfer::public_transfer`. This makes it permanently bound
// to its owner — only this module can move it, and this module never exposes
// a transfer function. Equivalent to a Kiosk + locked transfer policy with
// less overhead.
public struct Trumpagotchi has key {
    id: UID,
    owner: address,
    created_at_ms: u64,
    referrer: Option<address>,
    tier_at_mint: u8,
    equipped_outfit: Option<ID>,
    equipped_background: Option<ID>,
    equipped_shell: Option<ID>,
    name: Option<String>,
    last_updated_ms: u64,
}

// ── Cosmetic NFT ───────────────────────────────────────────────────────────
// Cosmetics ARE transferable (`store` ability) until they get equipped.
// On equip, the cosmetic moves into a dynamic field of the Trumpagotchi NFT,
// which physically prevents transfer (dynamic-field children are owned by
// the parent UID). On unequip the cosmetic is removed from the dynamic field
// and returned to the owner.
public struct Cosmetic has key, store {
    id: UID,
    kind: u8,        // 1 = outfit, 2 = background, 3 = shell
    variant: String, // e.g. "classic_red", "ballroom", "tier04_tremendous"
    tier_gate: u8,   // min tier required to equip (1 = Fake News, 13 = POTUS)
}

// Dynamic-field key types — one per slot. Using distinct types means a
// dynamic-field collision is impossible across slots.
public struct OutfitSlot has copy, drop, store {}
public struct BackgroundSlot has copy, drop, store {}
public struct ShellSlot has copy, drop, store {}

// ── Capabilities ───────────────────────────────────────────────────────────
public struct AdminCap has key, store { id: UID }

// One-time witness for the package — required for `display::new`.
public struct TRUMPAGOTCHI has drop {}

// ── Errors ─────────────────────────────────────────────────────────────────
const EWrongOwner: u64 = 0;
const EWrongCosmeticKind: u64 = 1;
const ESlotOccupied: u64 = 2;
const ESlotEmpty: u64 = 3;
const ETierGateFailed: u64 = 4;
const ENameTooLong: u64 = 5;

const KIND_OUTFIT: u8 = 1;
const KIND_BACKGROUND: u8 = 2;
const KIND_SHELL: u8 = 3;
const NAME_MAX_LEN: u64 = 32;

// ── Events ─────────────────────────────────────────────────────────────────
public struct Minted has copy, drop {
    nft_id: ID,
    owner: address,
    referrer: Option<address>,
    timestamp_ms: u64,
}

public struct Equipped has copy, drop {
    nft_id: ID,
    cosmetic_id: ID,
    kind: u8,
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
    variant: String,
    tier_gate: u8,
    recipient: address,
}

// ── Init ───────────────────────────────────────────────────────────────────
fun init(otw: TRUMPAGOTCHI, ctx: &mut TxContext) {
    let publisher = package::claim(otw, ctx);

    let mut display = display::new<Trumpagotchi>(&publisher, ctx);
    display.add(b"name".to_string(), b"Trumpagotchi #{owner}".to_string());
    display.add(
        b"description".to_string(),
        b"Soulbound Trumpagotchi NFT for SUITRUMP holders.".to_string(),
    );
    display.add(
        b"image_url".to_string(),
        b"https://sui-trump.com/api/trumpagotchi/{owner}.png".to_string(),
    );
    display.add(b"project_url".to_string(), b"https://sui-trump.com".to_string());
    display.update_version();

    let mut cosmetic_display = display::new<Cosmetic>(&publisher, ctx);
    cosmetic_display.add(b"name".to_string(), b"Trumpagotchi Cosmetic — {variant}".to_string());
    cosmetic_display.add(
        b"image_url".to_string(),
        b"https://sui-trump.com/api/cosmetic/{kind}/{variant}.png".to_string(),
    );
    cosmetic_display.update_version();

    let admin = AdminCap { id: object::new(ctx) };

    transfer::public_transfer(publisher, ctx.sender());
    transfer::public_transfer(display, ctx.sender());
    transfer::public_transfer(cosmetic_display, ctx.sender());
    transfer::public_transfer(admin, ctx.sender());
}

// ── Mint ───────────────────────────────────────────────────────────────────
// Public mint entry. Payment + revenue split are handled by a separate `mint`
// module that calls into this one with the payer + referrer. New mints always
// start at Tier 1 (Fake News) regardless of wallet score, per spec.
public(package) fun mint_to(
    recipient: address,
    referrer: Option<address>,
    clock: &Clock,
    ctx: &mut TxContext,
): ID {
    let now = clock::timestamp_ms(clock);
    let nft = Trumpagotchi {
        id: object::new(ctx),
        owner: recipient,
        created_at_ms: now,
        referrer,
        tier_at_mint: 1,
        equipped_outfit: option::none(),
        equipped_background: option::none(),
        equipped_shell: option::none(),
        name: option::none(),
        last_updated_ms: now,
    };
    let nft_id = object::id(&nft);

    event::emit(Minted { nft_id, owner: recipient, referrer, timestamp_ms: now });
    transfer::transfer(nft, recipient);
    nft_id
}

// ── Cosmetic issuance (admin or mint-flow gated) ───────────────────────────
public(package) fun issue_cosmetic(
    kind: u8,
    variant: String,
    tier_gate: u8,
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
        variant,
        tier_gate,
    };
    let cid = object::id(&cosmetic);
    event::emit(CosmeticIssued {
        cosmetic_id: cid,
        kind,
        variant: cosmetic.variant,
        tier_gate,
        recipient,
    });
    transfer::public_transfer(cosmetic, recipient);
    cid
}

// Admin-gated direct mint (used for promo, airdrops, smoke tests). The
// public payment-mint flow lives in a separate `mint` module which calls
// `mint_to` directly.
public fun admin_mint(
    _admin: &AdminCap,
    recipient: address,
    clock: &Clock,
    ctx: &mut TxContext,
): ID {
    mint_to(recipient, option::none(), clock, ctx)
}

// Admin-gated direct issuance (used for top-5 POTUS shells, airdrops, etc).
public fun admin_issue_cosmetic(
    _admin: &AdminCap,
    kind: u8,
    variant: String,
    tier_gate: u8,
    recipient: address,
    ctx: &mut TxContext,
): ID {
    issue_cosmetic(kind, variant, tier_gate, recipient, ctx)
}

// ── Equip ──────────────────────────────────────────────────────────────────
// Caller must own both the Trumpagotchi NFT and the cosmetic. The current
// wallet tier is passed in by the frontend (read off-chain from the leader-
// board) and verified against the cosmetic's tier_gate. Stricter on-chain
// gating would require an oracle; we trust the caller-supplied tier and let
// the off-chain identity engine refuse to render mismatches as a defence in
// depth.
public fun equip_outfit(
    nft: &mut Trumpagotchi,
    cosmetic: Cosmetic,
    current_tier: u8,
    clock: &Clock,
    ctx: &TxContext,
) {
    equip_internal(nft, cosmetic, current_tier, KIND_OUTFIT, clock, ctx);
}

public fun equip_background(
    nft: &mut Trumpagotchi,
    cosmetic: Cosmetic,
    current_tier: u8,
    clock: &Clock,
    ctx: &TxContext,
) {
    equip_internal(nft, cosmetic, current_tier, KIND_BACKGROUND, clock, ctx);
}

public fun equip_shell(
    nft: &mut Trumpagotchi,
    cosmetic: Cosmetic,
    current_tier: u8,
    clock: &Clock,
    ctx: &TxContext,
) {
    equip_internal(nft, cosmetic, current_tier, KIND_SHELL, clock, ctx);
}

fun equip_internal(
    nft: &mut Trumpagotchi,
    cosmetic: Cosmetic,
    current_tier: u8,
    expected_kind: u8,
    clock: &Clock,
    ctx: &TxContext,
) {
    assert!(nft.owner == ctx.sender(), EWrongOwner);
    assert!(cosmetic.kind == expected_kind, EWrongCosmeticKind);
    assert!(current_tier >= cosmetic.tier_gate, ETierGateFailed);

    let cid = object::id(&cosmetic);
    let now = clock::timestamp_ms(clock);

    if (expected_kind == KIND_OUTFIT) {
        assert!(option::is_none(&nft.equipped_outfit), ESlotOccupied);
        nft.equipped_outfit = option::some(cid);
        df::add(&mut nft.id, OutfitSlot {}, cosmetic);
    } else if (expected_kind == KIND_BACKGROUND) {
        assert!(option::is_none(&nft.equipped_background), ESlotOccupied);
        nft.equipped_background = option::some(cid);
        df::add(&mut nft.id, BackgroundSlot {}, cosmetic);
    } else {
        assert!(option::is_none(&nft.equipped_shell), ESlotOccupied);
        nft.equipped_shell = option::some(cid);
        df::add(&mut nft.id, ShellSlot {}, cosmetic);
    };

    nft.last_updated_ms = now;
    event::emit(Equipped { nft_id: object::id(nft), cosmetic_id: cid, kind: expected_kind, timestamp_ms: now });
}

// ── Unequip ────────────────────────────────────────────────────────────────
// Each unequip transfers the cosmetic back to the caller — the dominant use
// case. PTBs needing to swap cosmetics in a single tx can call equip directly
// after take_from_address; we don't need a returning variant for v1.
#[allow(lint(self_transfer))]
public fun unequip_outfit(nft: &mut Trumpagotchi, clock: &Clock, ctx: &mut TxContext) {
    assert!(nft.owner == ctx.sender(), EWrongOwner);
    assert!(option::is_some(&nft.equipped_outfit), ESlotEmpty);
    let cosmetic: Cosmetic = df::remove(&mut nft.id, OutfitSlot {});
    let cid = object::id(&cosmetic);
    nft.equipped_outfit = option::none();
    let now = clock::timestamp_ms(clock);
    nft.last_updated_ms = now;
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
    let now = clock::timestamp_ms(clock);
    nft.last_updated_ms = now;
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
    nft.last_updated_ms = now;
    transfer::public_transfer(cosmetic, ctx.sender());
    event::emit(Unequipped { nft_id: object::id(nft), cosmetic_id: cid, kind: KIND_SHELL, timestamp_ms: now });
}

// ── Naming ─────────────────────────────────────────────────────────────────
// Spec gates naming at MAGA+ (Tier 10+). Tier check uses caller-supplied
// current_tier — same trust model as equip.
public fun set_name(
    nft: &mut Trumpagotchi,
    new_name: String,
    current_tier: u8,
    clock: &Clock,
    ctx: &TxContext,
) {
    assert!(nft.owner == ctx.sender(), EWrongOwner);
    assert!(current_tier >= 10, ETierGateFailed);
    assert!(new_name.length() <= NAME_MAX_LEN, ENameTooLong);
    nft.name = option::some(new_name);
    nft.last_updated_ms = clock::timestamp_ms(clock);
}

// ── Read-only accessors (for indexer + frontend) ───────────────────────────
public fun owner(nft: &Trumpagotchi): address { nft.owner }
public fun created_at_ms(nft: &Trumpagotchi): u64 { nft.created_at_ms }
public fun referrer(nft: &Trumpagotchi): Option<address> { nft.referrer }
public fun equipped_outfit(nft: &Trumpagotchi): Option<ID> { nft.equipped_outfit }
public fun equipped_background(nft: &Trumpagotchi): Option<ID> { nft.equipped_background }
public fun equipped_shell(nft: &Trumpagotchi): Option<ID> { nft.equipped_shell }
public fun nft_name(nft: &Trumpagotchi): Option<String> { nft.name }

public fun cosmetic_kind(c: &Cosmetic): u8 { c.kind }
public fun cosmetic_variant(c: &Cosmetic): String { c.variant }
public fun cosmetic_tier_gate(c: &Cosmetic): u8 { c.tier_gate }

// ── Test-only init ─────────────────────────────────────────────────────────
#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(TRUMPAGOTCHI {}, ctx);
}

#[test_only]
public fun destroy_nft_for_testing(nft: Trumpagotchi) {
    let Trumpagotchi {
        id,
        owner: _,
        created_at_ms: _,
        referrer: _,
        tier_at_mint: _,
        equipped_outfit: _,
        equipped_background: _,
        equipped_shell: _,
        name: _,
        last_updated_ms: _,
    } = nft;
    object::delete(id);
}

#[test_only]
public fun kind_outfit(): u8 { KIND_OUTFIT }
#[test_only]
public fun kind_background(): u8 { KIND_BACKGROUND }
#[test_only]
public fun kind_shell(): u8 { KIND_SHELL }
