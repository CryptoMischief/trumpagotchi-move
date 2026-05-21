// Tier-earned cosmetic catalog — items distributed to Trumpagotchi holders
// when their tier reaches the gate, NOT sold in the shop.
//
// IMPORTANT — asset availability gotcha:
// `kind=0` (outfit) earned items compose body_identifier =
// `Tier{N}-{TierName}-{equippedValue}.png`. If a wallet's tier is BELOW
// the highest tier where the body variant exists, equipping will 404.
// `minTierForRender` captures the tier from which the variant body asset
// exists in the strip quilt. We grant at `gate` but the user can only
// equip-and-render starting at `minTierForRender` (the contract still
// composes a 404 path if equipped lower; current Trumpagotchis are
// soulbound so they'll be at the right tier when they earn).
//
// The grant script is idempotent: it skips wallets that already own a
// cosmetic with the same (kind, equipped_value).

export interface EarnedListing {
  kind: 0 | 1 | 2;
  name: string;
  gate: number;                // tier at/above which the item is earned
  rarity: number;              // for inventory tile display only
  walrusStandalone: string;    // standalones quilt filename
  equippedValue: string;       // composed into body_identifier (outfits) or used as bg id
  minTierForRender?: number;   // if set, body composite only exists from this tier up
}

export const EARNED: EarnedListing[] = [
  // ── T10+ earned background ──
  { kind: 1, name: "Oval Office Standard", gate: 10, rarity: 3,
    walrusStandalone: "OvalOfficeStandard.png", equippedValue: "OvalOfficeStandard" },

  // ── T11+ earned outfit — MAGA Hat ──
  // Files normalized 2026-05-12 (T11/T13 renamed from `-MAGA.png` to
  // `-MAGAHat.png` so all 3 eligible tiers compose to a valid URL).
  { kind: 0, name: "MAGA Hat", gate: 11, rarity: 2,
    walrusStandalone: "MAGAHAT.png", equippedValue: "MAGAHat",
    minTierForRender: 11 },

  // ── T12+ earned outfits ──
  { kind: 0, name: "Golden Eagle", gate: 12, rarity: 3,
    walrusStandalone: "GOLDEAGLE.png", equippedValue: "GoldenEagle",
    minTierForRender: 12 },
  { kind: 0, name: "Phone",        gate: 12, rarity: 3,
    walrusStandalone: "PHONE.png",     equippedValue: "Phone",
    minTierForRender: 12 },

  // ── T13/POTUS earned outfits ──
  // Gold Suit: T12 earner gets the cosmetic, but the visual body variant
  // (composite) only exists for Tier13-POTUS. At T12 the wallet appears
  // gold via the base body itself (per Richie 2026-05-12). Equipping at
  // T13 swaps to the explicit Tier13-POTUS-GoldSuit body.
  { kind: 0, name: "Gold Suit",   gate: 12, rarity: 3,
    walrusStandalone: "GOLD.png",      equippedValue: "GoldSuit",
    minTierForRender: 13 },
  { kind: 0, name: "Hot Pink Suit", gate: 13, rarity: 3,
    walrusStandalone: "HOTPINK.png",   equippedValue: "HotPink",
    minTierForRender: 13 },

  // ── T13/POTUS earned background ──
  { kind: 1, name: "Oval Office Party", gate: 13, rarity: 3,
    walrusStandalone: "OvalOfficeParty.png", equippedValue: "OvalOfficeParty" },

  // Yolked + Roman Emperor: deferred — assets not yet produced locally.
];
