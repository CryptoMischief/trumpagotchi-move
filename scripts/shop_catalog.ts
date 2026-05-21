// Single source of truth for the shop catalog. Imported by validate_shop.ts
// and sync_shop.ts. Edit this file to add / rename / retire SKUs.
//
// IMPORTANT: `equippedValue` MUST match the canonical asset filename
// suffix in the Walrus strip quilt. For outfits the file is
// `Tier{N}-{TierName}-{equippedValue}.png`. For backgrounds it's just
// `{equippedValue}.png`. The validate_shop.ts pre-flight refuses to seed
// anything that doesn't resolve in the live quilt.

export interface CatalogListing {
  kind: 0 | 1 | 2; // 0 outfit, 1 bg, 2 shell (shell unused at launch)
  name: string;
  tierGate: number;
  rarity: number; // 0 common, 1 rare, 2 epic, 3 legendary
  walrusStandalone: string;
  equippedValue: string;
  priceSui: number;
  initialStock: number;
}

// Canonical tier label list — must match the on-chain TierRegistry
// `target_base_body` values. Excludes Tier 1 (no outfits equippable).
export const TIER_LABELS: Record<number, string> = {
  1: "Tier1-FakeNews",
  2: "Tier2-LowEnergy",
  3: "Tier3-Patriot",
  4: "Tier4-Tremendous",
  5: "Tier5-BigLeague",
  6: "Tier6-ArtoftheDeal",
  7: "Tier7-MajorPlayer",
  8: "Tier8-EpicFury",
  9: "Tier9-CommanderinChief",
  10: "Tier10-MAGA",
  11: "Tier11-BigStrongBoy",
  12: "Tier12-VeryVeryRich",
  13: "Tier13-POTUS",
};

export const MAX_TIER = 13;

// Uniform pricing per Phase 2 spec.
//   Outfits: Common 1, Rare 5, Epic 25 (legendary all earned, not bought)
//   Backgrounds: flat 2 SUI per spec § Backgrounds
const BG_PRICE = 2;

export const CATALOG: CatalogListing[] = [
  // ── Outfits — Common (T2+) ──────────────────────────────────────────
  { kind: 0, name: "Golf",             tierGate: 2, rarity: 0, walrusStandalone: "GOLF.png",        equippedValue: "Golf",         priceSui: 1, initialStock: 50 },
  { kind: 0, name: "Tracksuit",        tierGate: 2, rarity: 0, walrusStandalone: "TRACKSUIT.png",   equippedValue: "Tracksuit",    priceSui: 1, initialStock: 50 },
  { kind: 0, name: "Vacation",         tierGate: 2, rarity: 0, walrusStandalone: "VACATION.png",    equippedValue: "VacationMode", priceSui: 1, initialStock: 50 },
  { kind: 0, name: "Billionaire",      tierGate: 2, rarity: 0, walrusStandalone: "BILLIONAIRE.png", equippedValue: "Billionaire",  priceSui: 1, initialStock: 50 },
  { kind: 0, name: "Rally Bomber",     tierGate: 2, rarity: 0, walrusStandalone: "RALLY.png",       equippedValue: "Rally",        priceSui: 1, initialStock: 50 },

  // ── Outfits — Rare (T4+) ────────────────────────────────────────────
  { kind: 0, name: "Tuxedo",           tierGate: 4, rarity: 1, walrusStandalone: "TUXEDO.png",      equippedValue: "Tuxedo",      priceSui: 5, initialStock: 25 },
  { kind: 0, name: "Cowboy",           tierGate: 4, rarity: 1, walrusStandalone: "COWBOY.png",      equippedValue: "Cowboy",      priceSui: 5, initialStock: 25 },
  { kind: 0, name: "Blue Collar",      tierGate: 4, rarity: 1, walrusStandalone: "BLUECOLLAR.png",  equippedValue: "BlueCollar",  priceSui: 5, initialStock: 25 },
  { kind: 0, name: "Garbage Man",      tierGate: 4, rarity: 1, walrusStandalone: "GARBAGEMAN.png",  equippedValue: "GarbageMan",  priceSui: 5, initialStock: 25 },

  // ── Outfits — Epic (T8+) ────────────────────────────────────────────
  { kind: 0, name: "Boxer Shorts",     tierGate: 8, rarity: 2, walrusStandalone: "BOXERSHORTS.png", equippedValue: "BoxerShorts", priceSui: 25, initialStock: 10 },
  { kind: 0, name: "Astronaut",        tierGate: 8, rarity: 2, walrusStandalone: "ASTRONAUT.png",   equippedValue: "Astronaut",   priceSui: 25, initialStock: 10 },
  { kind: 0, name: "General",          tierGate: 8, rarity: 2, walrusStandalone: "GENERAL.png",     equippedValue: "General",     priceSui: 25, initialStock: 10 },
  { kind: 0, name: "Eagle",            tierGate: 8, rarity: 2, walrusStandalone: "EAGLE.png",       equippedValue: "Eagle",       priceSui: 25, initialStock: 10 },

  // ── Outfits — EARNED (not in shop) ──────────────────────────────────
  // MAGAHat (T11+), GoldSuit (T12+), GoldenEagle (T12+), Phone (T12+),
  // HotPink + Yolked + RomanEmperor (T13/POTUS) — distributed via the
  // grant_earned.ts script (Trumpagotchi-holder tier-gated grant), not
  // sold here.

  // ── Backgrounds — T2+ (2 SUI each, 18 SKUs) ─────────────────────────
  { kind: 1, name: "Ballroom",         tierGate: 2, rarity: 0, walrusStandalone: "Ballroom.png",      equippedValue: "Ballroom",      priceSui: BG_PRICE, initialStock: 100 },
  { kind: 1, name: "Boardroom",        tierGate: 2, rarity: 0, walrusStandalone: "Boardroom.png",     equippedValue: "Boardroom",     priceSui: BG_PRICE, initialStock: 100 },
  { kind: 1, name: "Campaign Rally",   tierGate: 2, rarity: 0, walrusStandalone: "CampaignRally.png", equippedValue: "CampaignRally", priceSui: BG_PRICE, initialStock: 100 },
  { kind: 1, name: "Casino",           tierGate: 2, rarity: 0, walrusStandalone: "Casino.png",        equippedValue: "Casino",        priceSui: BG_PRICE, initialStock: 100 },
  { kind: 1, name: "Classic Stars",    tierGate: 2, rarity: 0, walrusStandalone: "ClassicStars.png",  equippedValue: "ClassicStars",  priceSui: BG_PRICE, initialStock: 100 },
  { kind: 1, name: "Debate",           tierGate: 2, rarity: 0, walrusStandalone: "Debate.png",        equippedValue: "Debate",        priceSui: BG_PRICE, initialStock: 100 },
  { kind: 1, name: "Fireside",         tierGate: 2, rarity: 0, walrusStandalone: "Fireside.png",      equippedValue: "Fireside",      priceSui: BG_PRICE, initialStock: 100 },
  { kind: 1, name: "Golf Green",       tierGate: 2, rarity: 0, walrusStandalone: "GolfGreen.png",     equippedValue: "GolfGreen",     priceSui: BG_PRICE, initialStock: 100 },
  { kind: 1, name: "Golf Tee",         tierGate: 2, rarity: 0, walrusStandalone: "GolfTee.png",       equippedValue: "GolfTee",       priceSui: BG_PRICE, initialStock: 100 },
  { kind: 1, name: "Gym",              tierGate: 2, rarity: 0, walrusStandalone: "Gym.png",           equippedValue: "Gym",           priceSui: BG_PRICE, initialStock: 100 },
  { kind: 1, name: "Helipad",          tierGate: 2, rarity: 0, walrusStandalone: "Helipad.png",       equippedValue: "Helipad",       priceSui: BG_PRICE, initialStock: 100 },
  { kind: 1, name: "Poolside",         tierGate: 2, rarity: 0, walrusStandalone: "Poolside.png",      equippedValue: "Poolside",      priceSui: BG_PRICE, initialStock: 100 },
  { kind: 1, name: "Rainbow Stars",    tierGate: 2, rarity: 0, walrusStandalone: "RainbowStars.png",  equippedValue: "RainbowStars",  priceSui: BG_PRICE, initialStock: 100 },
  { kind: 1, name: "Starry Night",     tierGate: 2, rarity: 0, walrusStandalone: "StarryNight.png",   equippedValue: "StarryNight",   priceSui: BG_PRICE, initialStock: 100 },
  { kind: 1, name: "Tanning Booth",    tierGate: 2, rarity: 0, walrusStandalone: "TanningBooth.png",  equippedValue: "TanningBooth",  priceSui: BG_PRICE, initialStock: 100 },
  { kind: 1, name: "Twitter",          tierGate: 2, rarity: 0, walrusStandalone: "Twitter.png",       equippedValue: "Twitter",       priceSui: BG_PRICE, initialStock: 100 },
  { kind: 1, name: "Vegas Strip",      tierGate: 2, rarity: 0, walrusStandalone: "VegasStrip.png",    equippedValue: "VegasStrip",    priceSui: BG_PRICE, initialStock: 100 },
  { kind: 1, name: "Wrestling",        tierGate: 2, rarity: 0, walrusStandalone: "Wrestling.png",     equippedValue: "Wrestling",     priceSui: BG_PRICE, initialStock: 100 },

  // ── Backgrounds — T4+ (9 SKUs) ──────────────────────────────────────
  { kind: 1, name: "Gold Tower",       tierGate: 4, rarity: 1, walrusStandalone: "GoldTower.png",       equippedValue: "GoldTower",       priceSui: BG_PRICE, initialStock: 50 },
  { kind: 1, name: "Mar-A-Lago",       tierGate: 4, rarity: 1, walrusStandalone: "Mar-A-Lago.png",      equippedValue: "Mar-A-Lago",      priceSui: BG_PRICE, initialStock: 50 },
  { kind: 1, name: "Moon",             tierGate: 4, rarity: 1, walrusStandalone: "Moon.png",            equippedValue: "Moon",            priceSui: BG_PRICE, initialStock: 50 },
  { kind: 1, name: "Moonbase",         tierGate: 4, rarity: 1, walrusStandalone: "Moonbase.png",        equippedValue: "Moonbase",        priceSui: BG_PRICE, initialStock: 50 },
  { kind: 1, name: "Penthouse Inside", tierGate: 4, rarity: 1, walrusStandalone: "PenthouseInside.png", equippedValue: "PenthouseInside", priceSui: BG_PRICE, initialStock: 50 },
  { kind: 1, name: "Penthouse Outside",tierGate: 4, rarity: 1, walrusStandalone: "PenthouseOutside.png",equippedValue: "PenthouseOutside",priceSui: BG_PRICE, initialStock: 50 },
  { kind: 1, name: "Press Room",       tierGate: 4, rarity: 1, walrusStandalone: "PressRoom.png",       equippedValue: "PressRoom",       priceSui: BG_PRICE, initialStock: 50 },
  { kind: 1, name: "Purple Night",     tierGate: 4, rarity: 1, walrusStandalone: "PurpleNight.png",     equippedValue: "PurpleNight",     priceSui: BG_PRICE, initialStock: 50 },
  { kind: 1, name: "Trophy Room",      tierGate: 4, rarity: 1, walrusStandalone: "TrophyRoom.png",      equippedValue: "TrophyRoom",      priceSui: BG_PRICE, initialStock: 50 },

  // ── Backgrounds — T6+ (16 SKUs) ─────────────────────────────────────
  { kind: 1, name: "Air Force 1",      tierGate: 6, rarity: 1, walrusStandalone: "AirForce1.png",      equippedValue: "AirForce1",      priceSui: BG_PRICE, initialStock: 30 },
  { kind: 1, name: "Alps",             tierGate: 6, rarity: 1, walrusStandalone: "Alps.png",           equippedValue: "Alps",           priceSui: BG_PRICE, initialStock: 30 },
  { kind: 1, name: "Church",           tierGate: 6, rarity: 1, walrusStandalone: "Church.png",         equippedValue: "Church",         priceSui: BG_PRICE, initialStock: 30 },
  { kind: 1, name: "Kitchen",          tierGate: 6, rarity: 1, walrusStandalone: "Kitchen.png",        equippedValue: "Kitchen",        priceSui: BG_PRICE, initialStock: 30 },
  { kind: 1, name: "McDonald's",       tierGate: 6, rarity: 1, walrusStandalone: "McDonalds.png",      equippedValue: "McDonalds",      priceSui: BG_PRICE, initialStock: 30 },
  { kind: 1, name: "Mt Rushmore",      tierGate: 6, rarity: 1, walrusStandalone: "MtRushmore.png",     equippedValue: "MtRushmore",     priceSui: BG_PRICE, initialStock: 30 },
  { kind: 1, name: "Narnia",           tierGate: 6, rarity: 1, walrusStandalone: "Narnia.png",         equippedValue: "Narnia",         priceSui: BG_PRICE, initialStock: 30 },
  { kind: 1, name: "Newspaper Stand",  tierGate: 6, rarity: 1, walrusStandalone: "NewspaperStand.png", equippedValue: "NewspaperStand", priceSui: BG_PRICE, initialStock: 30 },
  { kind: 1, name: "Pink Clouds",      tierGate: 6, rarity: 1, walrusStandalone: "PinkClouds.png",     equippedValue: "PinkClouds",     priceSui: BG_PRICE, initialStock: 30 },
  { kind: 1, name: "Purple Clouds",    tierGate: 6, rarity: 1, walrusStandalone: "PurpleClouds.png",   equippedValue: "PurpleClouds",   priceSui: BG_PRICE, initialStock: 30 },
  { kind: 1, name: "Skid Row",         tierGate: 6, rarity: 1, walrusStandalone: "SkidRow.png",        equippedValue: "SkidRow",        priceSui: BG_PRICE, initialStock: 30 },
  { kind: 1, name: "Storm",            tierGate: 6, rarity: 1, walrusStandalone: "Storm.png",          equippedValue: "Storm",          priceSui: BG_PRICE, initialStock: 30 },
  { kind: 1, name: "Trump Tower",      tierGate: 6, rarity: 1, walrusStandalone: "TrumpTower.png",     equippedValue: "TrumpTower",     priceSui: BG_PRICE, initialStock: 30 },
  { kind: 1, name: "Under The Sea",    tierGate: 6, rarity: 1, walrusStandalone: "UnderTheSea.png",    equippedValue: "UnderTheSea",    priceSui: BG_PRICE, initialStock: 30 },
  { kind: 1, name: "Venice",           tierGate: 6, rarity: 1, walrusStandalone: "Venice.png",         equippedValue: "Venice",         priceSui: BG_PRICE, initialStock: 30 },
  { kind: 1, name: "Whitehouse Gate",  tierGate: 6, rarity: 1, walrusStandalone: "WhitehouseGate.png", equippedValue: "WhitehouseGate", priceSui: BG_PRICE, initialStock: 30 },

  // ── Backgrounds — T8+ (9 SKUs) ──────────────────────────────────────
  { kind: 1, name: "Alien",            tierGate: 8, rarity: 2, walrusStandalone: "Alien.png",            equippedValue: "Alien",            priceSui: BG_PRICE, initialStock: 20 },
  { kind: 1, name: "Gold Toilet",      tierGate: 8, rarity: 2, walrusStandalone: "GoldToilet.png",       equippedValue: "GoldToilet",       priceSui: BG_PRICE, initialStock: 20 },
  { kind: 1, name: "Heaven",           tierGate: 8, rarity: 2, walrusStandalone: "Heaven.png",           equippedValue: "Heaven",           priceSui: BG_PRICE, initialStock: 20 },
  { kind: 1, name: "Hell",             tierGate: 8, rarity: 2, walrusStandalone: "Hell.png",             equippedValue: "Hell",             priceSui: BG_PRICE, initialStock: 20 },
  { kind: 1, name: "Morning Clouds",   tierGate: 8, rarity: 2, walrusStandalone: "MorningClouds.png",    equippedValue: "MorningClouds",    priceSui: BG_PRICE, initialStock: 20 },
  { kind: 1, name: "Purple Smoke",     tierGate: 8, rarity: 2, walrusStandalone: "PurpleSmoke.png",      equippedValue: "PurpleSmoke",      priceSui: BG_PRICE, initialStock: 20 },
  { kind: 1, name: "Strip Club",       tierGate: 8, rarity: 2, walrusStandalone: "StripClub.png",        equippedValue: "StripClub",        priceSui: BG_PRICE, initialStock: 20 },
  { kind: 1, name: "White House Garden", tierGate: 8, rarity: 2, walrusStandalone: "WhiteHouseGarden.png", equippedValue: "WhiteHouseGarden", priceSui: BG_PRICE, initialStock: 20 },
  { kind: 1, name: "Wild West",        tierGate: 8, rarity: 2, walrusStandalone: "WildWest.png",         equippedValue: "WildWest",         priceSui: BG_PRICE, initialStock: 20 },

  // ── Backgrounds — T10+ purchasable (2 SKUs) ─────────────────────────
  // OvalOfficeStandard is EARNED (T10+) — granted via grant_earned.ts.
  { kind: 1, name: "Blackhole",        tierGate: 10, rarity: 3, walrusStandalone: "BlackHole.png",  equippedValue: "BlackHole",  priceSui: BG_PRICE, initialStock: 10 },
  { kind: 1, name: "Gold Clouds",      tierGate: 10, rarity: 3, walrusStandalone: "GoldClouds.png", equippedValue: "GoldClouds", priceSui: BG_PRICE, initialStock: 10 },

  // ── Backgrounds — POTUS purchasable (2 SKUs) ────────────────────────
  // OvalOfficeParty is EARNED (T13/POTUS) — granted via grant_earned.ts.
  { kind: 1, name: "Oval Office Gold",       tierGate: 13, rarity: 3, walrusStandalone: "OvalOfficeGold.png",       equippedValue: "OvalOfficeGold",       priceSui: BG_PRICE, initialStock: 5 },
  { kind: 1, name: "Oval Office Underwater", tierGate: 13, rarity: 3, walrusStandalone: "OvalOfficeUnderwater.png", equippedValue: "OvalOfficeUnderwater", priceSui: BG_PRICE, initialStock: 5 },

  // ── Shells — buyable TV-shell variants (kind=2) ─────────────────────
  // The frontend slugifies the `name` and looks it up in shellRegistry.ts
  // to pick the React component variant. `walrusStandalone` is served
  // from /public/cosmetics/shells/ for now (smoke-test path); production
  // should pin a dedicated shellsQuilt on Walrus.
  // `equippedValue` is unused for shells.
  { kind: 2, name: "Lime Green", tierGate: 0, rarity: 0, walrusStandalone: "Lime Green.png", equippedValue: "", priceSui: 0.1, initialStock: 100 },
];
