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
// Per v8 + 2026-05-06 refactor: tier no longer lives on the NFT (admin can't
// update user-owned objects). The shared TierRegistry is the single source of
// truth for current tier; the NFT only caches the last value the user pulled
// in via claim_tier_advance.
public struct Trumpagotchi has key {
    id: UID,
    owner: address,
    // Immutable identity — set at mint, never changes (used for events).
    base_body_identifier_at_mint: String,        // e.g. "Tier1-FakeNews"
    base_background_identifier_at_mint: String,  // e.g. "BlackStars"
    // Mutable per-tier base — updated by user via claim_tier_advance.
    base_body_identifier: String,
    base_background_identifier: String,
    // Mutable per-equip — updates on equip_outfit / equip_background.
    body_identifier: String,
    background_identifier: String,
    // Equip slots. None = SUITRUMP_SUIT default for outfits / Black Stars
    // default for background.
    equipped_outfit: Option<ID>,
    equipped_background: Option<ID>,
    equipped_shell: Option<ID>,
    // Cached tier — last value pulled in via claim_tier_advance. Frontend
    // compares against TierRegistry.get(owner).tier to show "Sync available".
    synced_tier: u8,
    // Optional displayed name (Tier 10+ only — set via set_name, costs 1 SUI).
    name: Option<String>,
    referrer: Option<address>,
    creation_timestamp: u64,
}

// ── Tradeable Cosmetic NFT ─────────────────────────────────────────────────
// Has `store` — placed in Kiosk / listed on Tradeport. While equipped,
// physically locked inside parent NFT via dynamic field — can't list until
// unequipped.
public struct Cosmetic has key, store {
    id: UID,
    // 0 = outfit, 1 = background, 2 = shell  (v8 §3.5)
    kind: u8,
    name: String,
    // Minimum tier required to equip; secondary-market trades have NO gate.
    tier_gate: u8,
    // 0 = common, 1 = rare, 2 = epic, 3 = legendary
    rarity: u8,
    // Paper-doll image used by Display.image_url for the cosmetic itself
    // (shop card / marketplace preview). Same for all kinds.
    walrus_identifier_standalone: String,
    // Kind-dependent semantics for body / background composition:
    //   kind=0 (outfit):     SUFFIX appended after the wearer's tier base body.
    //                        e.g. "Tuxedo" → body_identifier = "Tier5-BigLeague-Tuxedo"
    //                        when wearer is at T5. The equipped body strip
    //                        thus advances automatically as the wearer's tier
    //                        advances (after a claim_tier_advance call).
    //   kind=1 (background): FULL identifier used as-is. e.g. "Ballroom".
    //                        Backgrounds don't vary by tier.
    //   kind=2 (shell):      Unused — shells don't mutate body/bg.
    equipped_value: String,
}

// Dynamic-field key types — one per slot.
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
const ETierAdvanceTooSoon: u64 = 7;  // < update_interval_ms since last advance
const ETierOutOfRange: u64 = 8;
const EVecLengthMismatch: u64 = 9;
const ENoTierEntry: u64 = 10;        // claim_tier_advance with no registry entry

const KIND_OUTFIT: u8 = 0;
const KIND_BACKGROUND: u8 = 1;
const KIND_SHELL: u8 = 2;
const NAME_MAX_LEN: u64 = 32;
const NAME_MIN_TIER: u8 = 10;

const MIN_TIER: u8 = 1;
const MAX_TIER: u8 = 13;

// Default rate-limit between tier advances. Testnet uses a small value so the
// identity engine can iterate quickly. Production should bump to 604_800_000
// (7 days) via set_update_interval before mainnet handover.
const DEFAULT_UPDATE_INTERVAL_MS: u64 = 60_000;

// 2.5% (250 bps) royalty on cosmetic secondary sales — accumulates in the
// TransferPolicy, swept manually to the prize-pool address.
const COSMETIC_ROYALTY_BPS: u16 = 250;
const COSMETIC_ROYALTY_MIN_MIST: u64 = 0;

// ── MintedRegistry ─────────────────────────────────────────────────────────
// Enforces one-Trumpagotchi-per-wallet; exempt list bypasses for testing /
// admin-issued promo NFTs.
public struct MintedRegistry has key {
    id: UID,
    minted: Table<address, ID>,
    exempt: VecSet<address>,
}

// ── TierRegistry ───────────────────────────────────────────────────────────
// Single source of truth for tier per address. Shared object — admin writes
// from off-chain identity engine without needing user signatures (the Sui
// ownership rule that blocked admin-update of user-owned NFTs doesn't apply
// to shared objects). NFT.synced_tier is the cached lag indicator.
public struct TierRegistry has key {
    id: UID,
    tiers: Table<address, TierEntry>,
    // Min ms between successive tier ADVANCES per address (drops aren't
    // rate-limited; decay_grace_ends_ms gates those instead).
    update_interval_ms: u64,
}

public struct TierEntry has store, copy, drop {
    tier: u8,
    score: u128,
    // What body / background the tier maps to. Off-chain engine computes
    // these per address; on claim_tier_advance the user copies them into
    // their NFT. Storing them in the registry keeps the contract from
    // needing a hardcoded tier→body lookup.
    target_base_body: String,
    target_base_background: String,
    last_update_ms: u64,
    decay_grace_ends_ms: Option<u64>,
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
    new_body_identifier: String,
    new_background_identifier: String,
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
    equipped_value: String,
    recipient: address,
}

public struct CosmeticPolicyCreated has copy, drop {
    policy_id: ID,
    royalty_bps: u16,
}

public struct TierUpdated has copy, drop {
    addr: address,
    old_tier: u8,
    new_tier: u8,
    score: u128,
    target_base_body: String,
    target_base_background: String,
    timestamp_ms: u64,
}

public struct TierSynced has copy, drop {
    nft_id: ID,
    owner: address,
    new_synced_tier: u8,
    new_base_body: String,
    new_base_background: String,
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

    // TierRegistry — shared, admin-writable. Default interval 60s for testnet.
    let tier_registry = TierRegistry {
        id: object::new(ctx),
        tiers: table::new<address, TierEntry>(ctx),
        update_interval_ms: DEFAULT_UPDATE_INTERVAL_MS,
    };
    transfer::share_object(tier_registry);

    // Display: NFT image_url is the animated GIF (always animated per v8 §3.1).
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
        b"https://aggregator.walrus-testnet.walrus.space/v1/blobs/by-quilt-id/mRWwGYSSeTpmJSzsmcAxUMp8jh1ZCT_0FiX8Xc5-QxM/{walrus_identifier_standalone}".to_string(),
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
// outfit) and Black Stars background. base_* identifiers initialised to match.
// Also seeds a tier=1 entry in the TierRegistry for the recipient if missing.
public(package) fun mint_to(
    minted_registry: &mut MintedRegistry,
    tier_registry: &mut TierRegistry,
    recipient: address,
    referrer: Option<address>,
    base_body_identifier: String,
    base_background_identifier: String,
    clock: &Clock,
    ctx: &mut TxContext,
): ID {
    let is_exempt = vec_set::contains(&minted_registry.exempt, &recipient);
    if (!is_exempt) {
        assert!(!table::contains(&minted_registry.minted, recipient), EAlreadyMinted);
    };

    let now = clock::timestamp_ms(clock);
    let nft = Trumpagotchi {
        id: object::new(ctx),
        owner: recipient,
        base_body_identifier_at_mint: base_body_identifier,
        base_background_identifier_at_mint: base_background_identifier,
        base_body_identifier,
        base_background_identifier,
        body_identifier: base_body_identifier,
        background_identifier: base_background_identifier,
        equipped_outfit: option::none(),
        equipped_background: option::none(),
        equipped_shell: option::none(),
        synced_tier: 1,
        name: option::none(),
        referrer,
        creation_timestamp: now,
    };
    let nft_id = object::id(&nft);

    if (!is_exempt) {
        table::add(&mut minted_registry.minted, recipient, nft_id);
    };

    // Seed tier=1 baseline so admin / claim_tier_advance always see an entry.
    if (!table::contains(&tier_registry.tiers, recipient)) {
        let entry = TierEntry {
            tier: 1,
            score: 0,
            target_base_body: base_body_identifier,
            target_base_background: base_background_identifier,
            last_update_ms: now,
            decay_grace_ends_ms: option::none(),
        };
        table::add(&mut tier_registry.tiers, recipient, entry);
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

// ── TierRegistry admin ────────────────────────────────────────────────────
// set_tier — single-address upsert. Identity engine calls this from a VPS
// cron with admin-signed PTBs. Rate-limit applies only to ADVANCES; drops
// are gated by decay_grace_ends_ms (set separately via set_decay_grace).
public fun set_tier(
    _admin: &AdminCap,
    registry: &mut TierRegistry,
    addr: address,
    new_tier: u8,
    new_score: u128,
    target_base_body: String,
    target_base_background: String,
    clock: &Clock,
) {
    assert!(new_tier >= MIN_TIER && new_tier <= MAX_TIER, ETierOutOfRange);
    let now = clock::timestamp_ms(clock);

    if (table::contains(&registry.tiers, addr)) {
        let existing = *table::borrow(&registry.tiers, addr);
        let old_tier = existing.tier;
        // Advance gating
        if (new_tier > old_tier) {
            assert!(
                now >= existing.last_update_ms + registry.update_interval_ms,
                ETierAdvanceTooSoon,
            );
        };
        // Drop gating: if grace period set and not yet expired, refuse drop.
        if (new_tier < old_tier) {
            if (option::is_some(&existing.decay_grace_ends_ms)) {
                let grace_end = *option::borrow(&existing.decay_grace_ends_ms);
                if (now < grace_end) {
                    // Still inside grace — don't drop, just update score/timestamp.
                    let updated = TierEntry {
                        tier: old_tier,
                        score: new_score,
                        target_base_body: existing.target_base_body,
                        target_base_background: existing.target_base_background,
                        last_update_ms: now,
                        decay_grace_ends_ms: existing.decay_grace_ends_ms,
                    };
                    let entry_ref = table::borrow_mut(&mut registry.tiers, addr);
                    *entry_ref = updated;
                    return
                };
            };
        };

        let entry = TierEntry {
            tier: new_tier,
            score: new_score,
            target_base_body,
            target_base_background,
            last_update_ms: now,
            // Drop clears any stale grace window; advance preserves none.
            decay_grace_ends_ms: option::none(),
        };
        let entry_ref = table::borrow_mut(&mut registry.tiers, addr);
        *entry_ref = entry;

        if (old_tier != new_tier) {
            event::emit(TierUpdated {
                addr,
                old_tier,
                new_tier,
                score: new_score,
                target_base_body,
                target_base_background,
                timestamp_ms: now,
            });
        };
    } else {
        // Brand-new entry — no rate limit on initial set.
        let entry = TierEntry {
            tier: new_tier,
            score: new_score,
            target_base_body,
            target_base_background,
            last_update_ms: now,
            decay_grace_ends_ms: option::none(),
        };
        table::add(&mut registry.tiers, addr, entry);
        event::emit(TierUpdated {
            addr,
            old_tier: 0,
            new_tier,
            score: new_score,
            target_base_body,
            target_base_background,
            timestamp_ms: now,
        });
    };
}

// Bulk variant — fewer txs from the cron. Vector lengths must match.
public fun batch_set_tiers(
    admin: &AdminCap,
    registry: &mut TierRegistry,
    addrs: vector<address>,
    tiers: vector<u8>,
    scores: vector<u128>,
    target_base_bodies: vector<String>,
    target_base_backgrounds: vector<String>,
    clock: &Clock,
) {
    let n = vector::length(&addrs);
    assert!(vector::length(&tiers) == n, EVecLengthMismatch);
    assert!(vector::length(&scores) == n, EVecLengthMismatch);
    assert!(vector::length(&target_base_bodies) == n, EVecLengthMismatch);
    assert!(vector::length(&target_base_backgrounds) == n, EVecLengthMismatch);
    let mut i = 0;
    while (i < n) {
        set_tier(
            admin,
            registry,
            *vector::borrow(&addrs, i),
            *vector::borrow(&tiers, i),
            *vector::borrow(&scores, i),
            *vector::borrow(&target_base_bodies, i),
            *vector::borrow(&target_base_backgrounds, i),
            clock,
        );
        i = i + 1;
    };
}

public fun set_update_interval(
    _admin: &AdminCap,
    registry: &mut TierRegistry,
    new_interval_ms: u64,
) {
    registry.update_interval_ms = new_interval_ms;
}

// Sets a decay grace window so a sell-spike doesn't immediately drop the
// holder a tier. Identity engine fires this when it detects a sell event
// (per v8 §7 — 72-hour grace). admin can also clear by passing 0.
public fun set_decay_grace(
    _admin: &AdminCap,
    registry: &mut TierRegistry,
    addr: address,
    grace_ends_ms: u64,
) {
    assert!(table::contains(&registry.tiers, addr), ENoTierEntry);
    let entry_ref = table::borrow_mut(&mut registry.tiers, addr);
    entry_ref.decay_grace_ends_ms = if (grace_ends_ms == 0)
        option::none()
    else
        option::some(grace_ends_ms);
}

// ── TierRegistry reads (public) ───────────────────────────────────────────
public fun tier_of(registry: &TierRegistry, addr: address): u8 {
    if (!table::contains(&registry.tiers, addr)) {
        return MIN_TIER
    };
    table::borrow(&registry.tiers, addr).tier
}

public fun has_entry(registry: &TierRegistry, addr: address): bool {
    table::contains(&registry.tiers, addr)
}

public fun tier_entry(registry: &TierRegistry, addr: address): TierEntry {
    *table::borrow(&registry.tiers, addr)
}

public fun update_interval_ms(registry: &TierRegistry): u64 {
    registry.update_interval_ms
}

public fun entry_tier(e: &TierEntry): u8 { e.tier }
public fun entry_score(e: &TierEntry): u128 { e.score }
public fun entry_target_base_body(e: &TierEntry): String { e.target_base_body }
public fun entry_target_base_background(e: &TierEntry): String { e.target_base_background }
public fun entry_last_update_ms(e: &TierEntry): u64 { e.last_update_ms }
public fun entry_decay_grace_ends_ms(e: &TierEntry): Option<u64> { e.decay_grace_ends_ms }

// ── Cosmetic issuance ──────────────────────────────────────────────────────
public(package) fun issue_cosmetic(
    kind: u8,
    name: String,
    tier_gate: u8,
    rarity: u8,
    walrus_identifier_standalone: String,
    equipped_value: String,
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
        equipped_value,
    };
    let cid = object::id(&cosmetic);
    event::emit(CosmeticIssued {
        cosmetic_id: cid,
        kind,
        name: cosmetic.name,
        tier_gate,
        rarity,
        walrus_identifier_standalone: cosmetic.walrus_identifier_standalone,
        equipped_value: cosmetic.equipped_value,
        recipient,
    });
    transfer::public_transfer(cosmetic, recipient);
    cid
}

public fun admin_mint(
    _admin: &AdminCap,
    minted_registry: &mut MintedRegistry,
    tier_registry: &mut TierRegistry,
    recipient: address,
    base_body_identifier: String,
    base_background_identifier: String,
    clock: &Clock,
    ctx: &mut TxContext,
): ID {
    mint_to(
        minted_registry,
        tier_registry,
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
    equipped_value: String,
    recipient: address,
    ctx: &mut TxContext,
): ID {
    issue_cosmetic(
        kind, name, tier_gate, rarity,
        walrus_identifier_standalone, equipped_value,
        recipient, ctx,
    )
}

// ── Equip ──────────────────────────────────────────────────────────────────
// Outfit: mutates body_identifier to cosmetic.walrus_identifier_equipped.
// Background: mutates background_identifier to cosmetic.walrus_identifier_equipped.
// Shell: only sets equipped_shell — no body/bg identifier change.
//
// Tier gate: read from TierRegistry.tier_of(ctx.sender()) — single source of
// truth across the dapp / shop / equip surfaces.
public fun equip_outfit(
    nft: &mut Trumpagotchi,
    cosmetic: Cosmetic,
    registry: &TierRegistry,
    clock: &Clock,
    ctx: &TxContext,
) {
    assert!(nft.owner == ctx.sender(), EWrongOwner);
    assert!(cosmetic.kind == KIND_OUTFIT, EWrongCosmeticKind);
    assert!(option::is_none(&nft.equipped_outfit), ESlotOccupied);

    // Read tier + tier-base body from the registry so the equipped body
    // strip matches the wearer's CURRENT tier (not the tier at the time
    // the cosmetic was issued).
    let entry = if (table::contains(&registry.tiers, ctx.sender())) {
        *table::borrow(&registry.tiers, ctx.sender())
    } else {
        // Fall back to NFT's cached state. tier_of returns 1 here.
        TierEntry {
            tier: MIN_TIER,
            score: 0,
            target_base_body: nft.base_body_identifier,
            target_base_background: nft.base_background_identifier,
            last_update_ms: 0,
            decay_grace_ends_ms: option::none(),
        }
    };
    assert!(entry.tier >= cosmetic.tier_gate, EBelowTierGate);

    let cid = object::id(&cosmetic);
    let new_body = compose_outfit_body(&entry.target_base_body, &cosmetic.equipped_value);
    nft.equipped_outfit = option::some(cid);
    nft.body_identifier = new_body;
    df::add(&mut nft.id, OutfitSlot {}, cosmetic);

    event::emit(Equipped {
        nft_id: object::id(nft),
        cosmetic_id: cid,
        kind: KIND_OUTFIT,
        new_body_identifier: new_body,
        new_background_identifier: nft.background_identifier,
        timestamp_ms: clock::timestamp_ms(clock),
    });
}

// Internal: glue base-body + outfit suffix into the body strip identifier.
// Asset-naming convention: "Tier{N}-{TierName}-{OutfitName}"
//   target_base_body = "Tier5-BigLeague"
//   suffix           = "Tuxedo"
//   result           = "Tier5-BigLeague-Tuxedo"
fun compose_outfit_body(target_base_body: &String, suffix: &String): String {
    let mut s = *target_base_body;
    s.append_utf8(b"-");
    s.append(*suffix);
    s
}

public fun equip_background(
    nft: &mut Trumpagotchi,
    cosmetic: Cosmetic,
    registry: &TierRegistry,
    clock: &Clock,
    ctx: &TxContext,
) {
    assert!(nft.owner == ctx.sender(), EWrongOwner);
    assert!(cosmetic.kind == KIND_BACKGROUND, EWrongCosmeticKind);
    let tier = tier_of(registry, ctx.sender());
    assert!(tier >= cosmetic.tier_gate, EBelowTierGate);
    assert!(option::is_none(&nft.equipped_background), ESlotOccupied);

    let cid = object::id(&cosmetic);
    let new_bg = cosmetic.equipped_value;  // bg uses the full id directly
    nft.equipped_background = option::some(cid);
    nft.background_identifier = new_bg;
    df::add(&mut nft.id, BackgroundSlot {}, cosmetic);

    event::emit(Equipped {
        nft_id: object::id(nft),
        cosmetic_id: cid,
        kind: KIND_BACKGROUND,
        new_body_identifier: nft.body_identifier,
        new_background_identifier: new_bg,
        timestamp_ms: clock::timestamp_ms(clock),
    });
}

public fun equip_shell(
    nft: &mut Trumpagotchi,
    cosmetic: Cosmetic,
    registry: &TierRegistry,
    clock: &Clock,
    ctx: &TxContext,
) {
    assert!(nft.owner == ctx.sender(), EWrongOwner);
    assert!(cosmetic.kind == KIND_SHELL, EWrongCosmeticKind);
    let tier = tier_of(registry, ctx.sender());
    assert!(tier >= cosmetic.tier_gate, EBelowTierGate);
    assert!(option::is_none(&nft.equipped_shell), ESlotOccupied);

    let cid = object::id(&cosmetic);
    nft.equipped_shell = option::some(cid);
    df::add(&mut nft.id, ShellSlot {}, cosmetic);

    event::emit(Equipped {
        nft_id: object::id(nft),
        cosmetic_id: cid,
        kind: KIND_SHELL,
        new_body_identifier: nft.body_identifier,
        new_background_identifier: nft.background_identifier,
        timestamp_ms: clock::timestamp_ms(clock),
    });
}

// ── Unequip ────────────────────────────────────────────────────────────────
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

// ── Tier sync (user-initiated) ─────────────────────────────────────────────
// Pulls the current tier + base identifiers from the shared TierRegistry
// into the NFT. User signs because they own the NFT. Updates body_identifier
// + background_identifier as well IFF the corresponding slot is empty (so we
// don't clobber a deliberately-equipped cosmetic).
//
// Pattern: identity engine pushes tier to registry continuously; user pulls
// to NFT when they want their visuals to advance. Marketplaces show whatever
// is currently on-chain (NFT.body_identifier).
public fun claim_tier_advance(
    nft: &mut Trumpagotchi,
    registry: &TierRegistry,
    clock: &Clock,
    ctx: &TxContext,
): u8 {
    assert!(nft.owner == ctx.sender(), EWrongOwner);
    assert!(table::contains(&registry.tiers, ctx.sender()), ENoTierEntry);
    let entry = *table::borrow(&registry.tiers, ctx.sender());

    nft.synced_tier = entry.tier;
    nft.base_body_identifier = entry.target_base_body;
    nft.base_background_identifier = entry.target_base_background;

    // Recompute body identifier — even if an outfit is equipped, the body
    // strip should advance to the wearer's new tier (e.g. switch from
    // Tier4-Tremendous-Tuxedo to Tier5-BigLeague-Tuxedo when advancing T4→T5).
    if (option::is_some(&nft.equipped_outfit)) {
        let cosmetic: &Cosmetic = df::borrow(&nft.id, OutfitSlot {});
        nft.body_identifier = compose_outfit_body(
            &entry.target_base_body,
            &cosmetic.equipped_value,
        );
    } else {
        nft.body_identifier = entry.target_base_body;
    };
    // Backgrounds don't vary by tier — only update the slot if no bg equipped.
    if (option::is_none(&nft.equipped_background)) {
        nft.background_identifier = entry.target_base_background;
    };

    event::emit(TierSynced {
        nft_id: object::id(nft),
        owner: nft.owner,
        new_synced_tier: entry.tier,
        new_base_body: entry.target_base_body,
        new_base_background: entry.target_base_background,
        timestamp_ms: clock::timestamp_ms(clock),
    });
    entry.tier
}

// ── Naming ─────────────────────────────────────────────────────────────────
// Tier 10+ only — gate read from TierRegistry. Frontend layer collects the
// 1 SUI fee on top.
public fun set_name(
    nft: &mut Trumpagotchi,
    new_name: String,
    registry: &TierRegistry,
    _clock: &Clock,
    ctx: &TxContext,
) {
    assert!(nft.owner == ctx.sender(), EWrongOwner);
    let tier = tier_of(registry, ctx.sender());
    assert!(tier >= NAME_MIN_TIER, EBelowTierGate);
    assert!(new_name.length() <= NAME_MAX_LEN, ENameTooLong);
    nft.name = option::some(new_name);
}

// ── Read-only accessors ────────────────────────────────────────────────────
public fun owner(nft: &Trumpagotchi): address { nft.owner }
public fun synced_tier(nft: &Trumpagotchi): u8 { nft.synced_tier }
public fun base_body_identifier(nft: &Trumpagotchi): String { nft.base_body_identifier }
public fun body_identifier(nft: &Trumpagotchi): String { nft.body_identifier }
public fun base_background_identifier(nft: &Trumpagotchi): String { nft.base_background_identifier }
public fun background_identifier(nft: &Trumpagotchi): String { nft.background_identifier }
public fun base_body_identifier_at_mint(nft: &Trumpagotchi): String { nft.base_body_identifier_at_mint }
public fun base_background_identifier_at_mint(nft: &Trumpagotchi): String { nft.base_background_identifier_at_mint }
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
public fun cosmetic_equipped_value(c: &Cosmetic): String { c.equipped_value }

// ── Test-only helpers ──────────────────────────────────────────────────────
#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(TRUMPAGOTCHI {}, ctx);
}

#[test_only]
public fun destroy_nft_for_testing(nft: Trumpagotchi) {
    let Trumpagotchi {
        id, owner: _,
        base_body_identifier_at_mint: _, base_background_identifier_at_mint: _,
        base_body_identifier: _, base_background_identifier: _,
        body_identifier: _, background_identifier: _,
        equipped_outfit: _, equipped_background: _, equipped_shell: _,
        synced_tier: _, name: _, referrer: _, creation_timestamp: _,
    } = nft;
    object::delete(id);
}

#[test_only] public fun kind_outfit(): u8 { KIND_OUTFIT }
#[test_only] public fun kind_background(): u8 { KIND_BACKGROUND }
#[test_only] public fun kind_shell(): u8 { KIND_SHELL }
#[test_only] public fun cosmetic_royalty_bps(): u16 { COSMETIC_ROYALTY_BPS }
#[test_only] public fun default_update_interval_ms(): u64 { DEFAULT_UPDATE_INTERVAL_MS }
