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
// one-Trumpagotchi-per-wallet rule for testing purposes. Admin can add/
// remove additional exempt addresses at runtime via add_exempt / remove_exempt.
const PRE_EXEMPT_CRYPTOMISCHIEF: address =
    @0x39ee291682e829771ad0c3ed46ebc69a962b7c2f9e6477409b22616bcf21ac34;

// ── Soulbound NFT ──────────────────────────────────────────────────────────
// `Trumpagotchi` deliberately has `key` but NOT `store`. Without `store` the
// object cannot be wrapped, placed in dynamic fields, or transferred by the
// generic `sui::transfer::public_transfer`. This makes it permanently bound
// to its owner — only this module can move it, and this module never exposes
// a transfer function. Equivalent to a Kiosk + locked transfer policy with
// less overhead. (Cosmetics, by contrast, are tradeable — they have `store`
// and an associated TransferPolicy, so unequipped cosmetics can list on
// Tradeport et al.)
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
    // Walrus quilt identifier for the body sprite (e.g. "Tier1-FakeNews.png").
    // Used by the Display image_url template; frontend compositor reads the
    // matching JSON sidecar (same identifier with .json suffix) for frame
    // count + fps. Defaults to the tier-1 base body at mint.
    body_identifier: String,
}

// ── Cosmetic NFT ───────────────────────────────────────────────────────────
// Cosmetics are tradeable (`key, store`) until they get equipped. On equip,
// the cosmetic moves into a dynamic field of the Trumpagotchi NFT — physically
// preventing transfer (dynamic-field children are owned by the parent UID).
// On unequip the cosmetic is removed from the dynamic field and returned to
// the owner, who can then place it in their personal Kiosk and list it.
public struct Cosmetic has key, store {
    id: UID,
    kind: u8,        // 1 = outfit, 2 = background, 3 = shell
    variant: String, // e.g. "classic_red", "ballroom", "tier04_tremendous"
    tier_gate: u8,   // min tier required to equip (1 = Fake News, 13 = POTUS)
    // Walrus quilt identifier for the cosmetic's sprite (e.g. "Ballroom.png",
    // "Tier4-Tremendous-Tuxedo.png"). Set at issuance from the asset manifest.
    walrus_identifier: String,
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
const EAlreadyMinted: u64 = 6;

// ── MintedRegistry ─────────────────────────────────────────────────────────
// Shared object enforcing one-Trumpagotchi-per-wallet, with an exempt list
// for test wallets. cryptomischief.sui is pre-seeded into `exempt` at init.
public struct MintedRegistry has key {
    id: UID,
    minted: Table<address, ID>, // recipient → their NFT id (used for the lookup)
    exempt: VecSet<address>,    // addresses bypassing the check
}

const KIND_OUTFIT: u8 = 1;
const KIND_BACKGROUND: u8 = 2;
const KIND_SHELL: u8 = 3;
const NAME_MAX_LEN: u64 = 32;

// 2.5% royalty (250 bps) on cosmetic secondary sales. Royalty accumulates in
// the TransferPolicy; admin sweeps via transfer_policy::withdraw and forwards
// to the prize-pool address (per project_cosmetic_royalty memory).
const COSMETIC_ROYALTY_BPS: u16 = 250;
const COSMETIC_ROYALTY_MIN_MIST: u64 = 0;

// ── Events ─────────────────────────────────────────────────────────────────
public struct Minted has copy, drop {
    nft_id: ID,
    owner: address,
    referrer: Option<address>,
    body_identifier: String,
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
    walrus_identifier: String,
    recipient: address,
}

public struct CosmeticPolicyCreated has copy, drop {
    policy_id: ID,
    royalty_bps: u16,
}

// ── Init ───────────────────────────────────────────────────────────────────
// Display image_url templates point at the testnet Walrus quilt aggregator.
// The quilt id is baked into the URL; only `{body_identifier}` /
// `{walrus_identifier}` interpolate per object. For mainnet, admin updates
// these via the Display + DisplayCap held by the deployer.
fun init(otw: TRUMPAGOTCHI, ctx: &mut TxContext) {
    let publisher = package::claim(otw, ctx);

    // Shared registry — one entry per minter except for exempt addresses.
    let mut exempt = vec_set::empty<address>();
    vec_set::insert(&mut exempt, PRE_EXEMPT_CRYPTOMISCHIEF);
    let registry = MintedRegistry {
        id: object::new(ctx),
        minted: table::new<address, ID>(ctx),
        exempt,
    };
    transfer::share_object(registry);

    // Display.image_url points at the *preview* quilt (single-frame portraits)
    // so wallets and marketplaces show a clean image. The dapp's compositor
    // separately fetches the full animated strip from the strip quilt.
    //
    // Trumpagotchi NFT: body_identifier is the base name (no extension);
    // template appends "-preview.png".
    // Cosmetic: walrus_identifier is the FULL filename in the preview quilt
    // — body-style cosmetics use "<name>-preview.png", static backgrounds
    // use their own "<name>.png" (which is also pinned in the preview quilt).
    let mut display = display::new<Trumpagotchi>(&publisher, ctx);
    display.add(b"name".to_string(), b"Trumpagotchi #{owner}".to_string());
    display.add(
        b"description".to_string(),
        b"Soulbound Trumpagotchi NFT for SUITRUMP holders.".to_string(),
    );
    display.add(
        b"image_url".to_string(),
        b"https://aggregator.walrus-testnet.walrus.space/v1/blobs/by-quilt-id/8lnSwb5lmXo3kqATuKNGWvIMSImtrZ2Qf7a-iGRrK3A/{body_identifier}-preview.png".to_string(),
    );
    display.add(b"project_url".to_string(), b"https://suitrump.com".to_string());
    display.update_version();

    let mut cosmetic_display = display::new<Cosmetic>(&publisher, ctx);
    cosmetic_display.add(
        b"name".to_string(),
        b"Trumpagotchi Cosmetic — {variant}".to_string(),
    );
    cosmetic_display.add(
        b"image_url".to_string(),
        b"https://aggregator.walrus-testnet.walrus.space/v1/blobs/by-quilt-id/8lnSwb5lmXo3kqATuKNGWvIMSImtrZ2Qf7a-iGRrK3A/{walrus_identifier}".to_string(),
    );
    cosmetic_display.update_version();

    let admin = AdminCap { id: object::new(ctx) };

    transfer::public_transfer(publisher, ctx.sender());
    transfer::public_transfer(display, ctx.sender());
    transfer::public_transfer(cosmetic_display, ctx.sender());
    transfer::public_transfer(admin, ctx.sender());
}

// ── Cosmetic TransferPolicy (post-publish, called once by deployer) ────────
// Creates a shared TransferPolicy<Cosmetic> with the standard kiosk royalty
// rule attached. Must be called once after publish so cosmetics can be listed
// on Kiosk-aware marketplaces (Tradeport etc).
//
// Royalty mechanics: the kiosk royalty_rule deposits COSMETIC_ROYALTY_BPS%
// of every secondary sale into the TransferPolicy itself. The admin (holder
// of the returned TransferPolicyCap) periodically calls
// transfer_policy::withdraw to drain accumulated royalties and forwards them
// to the prize-pool address. AdminCap is required as a redundant gate so a
// stolen Publisher alone can't create rogue policies.
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
// Public mint entry. Payment + revenue split are handled by a separate `mint`
// module that calls into this one with the payer + referrer. New mints always
// start at Tier 1 (Fake News) regardless of wallet score, per spec — the
// mint module passes the matching Tier 1 body identifier.
//
// Enforces 1-per-wallet via the MintedRegistry. Recipients in registry.exempt
// (e.g. cryptomischief.sui for testing) bypass the check and are not added
// to the minted table — they can mint repeatedly.
public(package) fun mint_to(
    registry: &mut MintedRegistry,
    recipient: address,
    referrer: Option<address>,
    body_identifier: String,
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
        created_at_ms: now,
        referrer,
        tier_at_mint: 1,
        equipped_outfit: option::none(),
        equipped_background: option::none(),
        equipped_shell: option::none(),
        name: option::none(),
        last_updated_ms: now,
        body_identifier,
    };
    let nft_id = object::id(&nft);

    if (!is_exempt) {
        table::add(&mut registry.minted, recipient, nft_id);
    };

    event::emit(Minted {
        nft_id,
        owner: recipient,
        referrer,
        body_identifier: nft.body_identifier,
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

// ── Cosmetic issuance (admin or mint-flow gated) ───────────────────────────
public(package) fun issue_cosmetic(
    kind: u8,
    variant: String,
    tier_gate: u8,
    walrus_identifier: String,
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
        walrus_identifier,
    };
    let cid = object::id(&cosmetic);
    event::emit(CosmeticIssued {
        cosmetic_id: cid,
        kind,
        variant: cosmetic.variant,
        tier_gate,
        walrus_identifier: cosmetic.walrus_identifier,
        recipient,
    });
    transfer::public_transfer(cosmetic, recipient);
    cid
}

// Admin-gated direct mint (used for promo, airdrops, smoke tests). Same
// 1-per-wallet enforcement applies; admin can pre-add the recipient to
// exempt if they need multiple.
public fun admin_mint(
    _admin: &AdminCap,
    registry: &mut MintedRegistry,
    recipient: address,
    body_identifier: String,
    clock: &Clock,
    ctx: &mut TxContext,
): ID {
    mint_to(registry, recipient, option::none(), body_identifier, clock, ctx)
}

// Admin-gated direct issuance (used for top-5 POTUS shells, airdrops, etc).
public fun admin_issue_cosmetic(
    _admin: &AdminCap,
    kind: u8,
    variant: String,
    tier_gate: u8,
    walrus_identifier: String,
    recipient: address,
    ctx: &mut TxContext,
): ID {
    issue_cosmetic(kind, variant, tier_gate, walrus_identifier, recipient, ctx)
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

// Admin can change a wallet's body_identifier when its tier advances or
// drops, since the on-chain NFT doesn't auto-update from the off-chain tier
// engine. Frontend reads tier separately; this just keeps the marketplace
// preview image fresh.
public fun set_body_identifier(
    _admin: &AdminCap,
    nft: &mut Trumpagotchi,
    new_body_identifier: String,
    clock: &Clock,
) {
    nft.body_identifier = new_body_identifier;
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
public fun body_identifier(nft: &Trumpagotchi): String { nft.body_identifier }

public fun cosmetic_kind(c: &Cosmetic): u8 { c.kind }
public fun cosmetic_variant(c: &Cosmetic): String { c.variant }
public fun cosmetic_tier_gate(c: &Cosmetic): u8 { c.tier_gate }
public fun cosmetic_walrus_identifier(c: &Cosmetic): String { c.walrus_identifier }

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
        body_identifier: _,
    } = nft;
    object::delete(id);
}

#[test_only]
public fun kind_outfit(): u8 { KIND_OUTFIT }
#[test_only]
public fun kind_background(): u8 { KIND_BACKGROUND }
#[test_only]
public fun kind_shell(): u8 { KIND_SHELL }
#[test_only]
public fun cosmetic_royalty_bps(): u16 { COSMETIC_ROYALTY_BPS }
