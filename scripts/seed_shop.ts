// scripts/seed_shop.ts — admin seeds the testnet Shop with the v8 cosmetic
// catalog (subset). One PTB, many admin_add_listing calls.
//
// Required env:
//   IDENTITY_PRIVKEY   suiprivkey1... — the deployer / admin wallet
//
// Run:
//   IDENTITY_PRIVKEY='suiprivkey1...' npx tsx scripts/seed_shop.ts
//
// Idempotent? No — re-running adds another set of listings with new SKUs.
// Use admin_remove_listing or admin_set_active=false to retire duplicates.

import { readFileSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";
import { SuiGrpcClient } from "@mysten/sui/grpc";
import { Transaction } from "@mysten/sui/transactions";

const __dirname = dirname(fileURLToPath(import.meta.url));
const dep = JSON.parse(
  readFileSync(join(__dirname, "..", "deployments", "testnet.json"), "utf8"),
);

const RPC = "https://fullnode.testnet.sui.io";
const CLOCK = "0x6";
const PACKAGE_LATEST: string = dep.packageIdLatest;
const ADMIN_CAP: string = dep.adminCap;
const SHOP_OBJ: string = dep.shop.objectId;

interface ListingSeed {
  kind: 0 | 1 | 2;
  name: string;
  tierGate: number;
  rarity: number; // 0 common, 1 rare, 2 epic, 3 legendary
  walrusStandalone: string;
  equippedValue: string;
  priceSui: number;
  initialStock: number;
}

// Pricing tier — arbitrary testnet figures, easy to retune.
const SUI_1 = 1_000_000_000n;
const priceMistFor = (suiAmount: number): bigint =>
  BigInt(Math.round(suiAmount * 1_000_000_000));

// Initial catalog — representative across kinds + rarity. Walrus standalone
// IDs match `cosmeticStandalonesQuilt.outfitIdentifiers` in deployments
// where we already have paper-doll PNGs pinned. Backgrounds reuse the body
// strip names (their standalone is a separate per-bg PNG; reusing here
// because the cosmetics standalones quilt covers backgrounds too).
const SEED: ListingSeed[] = [
  // ── Outfits ────────────────────────────────────────────────────────────
  { kind: 0, name: "Golf",         tierGate: 2, rarity: 0, walrusStandalone: "GOLF.png",       equippedValue: "Golf",       priceSui: 1,   initialStock: 50 },
  { kind: 0, name: "Tracksuit",    tierGate: 2, rarity: 0, walrusStandalone: "TRACKSUIT.png",  equippedValue: "Tracksuit",  priceSui: 1,   initialStock: 50 },
  { kind: 0, name: "Vacation",     tierGate: 2, rarity: 0, walrusStandalone: "VACATION.png",   equippedValue: "Vacation",   priceSui: 1,   initialStock: 50 },
  { kind: 0, name: "Tuxedo",       tierGate: 4, rarity: 1, walrusStandalone: "TUXEDO.png",     equippedValue: "Tuxedo",     priceSui: 5,   initialStock: 25 },
  { kind: 0, name: "Cowboy",       tierGate: 4, rarity: 1, walrusStandalone: "COWBOY.png",     equippedValue: "Cowboy",     priceSui: 5,   initialStock: 25 },
  { kind: 0, name: "Blue Collar",  tierGate: 4, rarity: 1, walrusStandalone: "BLUECOLLAR.png", equippedValue: "BlueCollar", priceSui: 5,   initialStock: 25 },
  { kind: 0, name: "Boxer Shorts", tierGate: 8, rarity: 2, walrusStandalone: "BOXERSHORTS.png",equippedValue: "BoxerShorts",priceSui: 25,  initialStock: 10 },
  { kind: 0, name: "Astronaut",    tierGate: 8, rarity: 2, walrusStandalone: "ASTRONAUT.png",  equippedValue: "Astronaut",  priceSui: 25,  initialStock: 10 },
  { kind: 0, name: "General",      tierGate: 8, rarity: 2, walrusStandalone: "GENERAL.png",    equippedValue: "General",    priceSui: 25,  initialStock: 10 },
  { kind: 0, name: "Gold Suit",    tierGate: 12,rarity: 3, walrusStandalone: "GOLD.png",       equippedValue: "GoldSuit",   priceSui: 100, initialStock: 3 },
  // ── Backgrounds ────────────────────────────────────────────────────────
  // Backgrounds use `equipped_value` = full identifier (kind=1 semantics).
  // Standalone png matches the bg name on the cosmetic-standalones quilt.
  { kind: 1, name: "Ballroom",     tierGate: 2, rarity: 0, walrusStandalone: "Ballroom.png",   equippedValue: "Ballroom",   priceSui: 1,   initialStock: 50 },
  { kind: 1, name: "Casino",       tierGate: 2, rarity: 0, walrusStandalone: "Casino.png",     equippedValue: "Casino",     priceSui: 1,   initialStock: 50 },
  { kind: 1, name: "Mar-A-Lago",   tierGate: 4, rarity: 1, walrusStandalone: "MarALago.png",   equippedValue: "MarALago",   priceSui: 5,   initialStock: 25 },
  { kind: 1, name: "McDonald's",   tierGate: 6, rarity: 1, walrusStandalone: "McDonalds.png",  equippedValue: "McDonalds",  priceSui: 10,  initialStock: 15 },
  { kind: 1, name: "Gold Clouds",  tierGate: 10,rarity: 3, walrusStandalone: "GoldClouds.png", equippedValue: "GoldClouds", priceSui: 75,  initialStock: 5 },
];

function loadKeypair(): Ed25519Keypair {
  const raw = process.env.IDENTITY_PRIVKEY;
  if (!raw) throw new Error("IDENTITY_PRIVKEY not set");
  if (raw.startsWith("suiprivkey")) return Ed25519Keypair.fromSecretKey(raw);
  throw new Error("expected suiprivkey-encoded admin key");
}

async function main() {
  const signer = loadKeypair();
  const client = new SuiGrpcClient({ baseUrl: RPC, network: "testnet" });

  const tx = new Transaction();

  // One Move call per listing; all batched into a single PTB so the seed is
  // either fully applied or rolled back together.
  for (const s of SEED) {
    tx.moveCall({
      target: `${PACKAGE_LATEST}::shop::admin_add_listing`,
      arguments: [
        tx.object(ADMIN_CAP),
        tx.object(SHOP_OBJ),
        tx.pure.u8(s.kind),
        tx.pure.string(s.name),
        tx.pure.u8(s.tierGate),
        tx.pure.u8(s.rarity),
        tx.pure.string(s.walrusStandalone),
        tx.pure.string(s.equippedValue),
        tx.pure.u64(priceMistFor(s.priceSui)),
        tx.pure.u64(s.initialStock),
        tx.object(CLOCK),
      ],
    });
  }

  const res: any = await client.signAndExecuteTransaction({
    transaction: tx,
    signer,
    include: { effects: true, events: true },
  });
  if (res?.FailedTransaction) {
    const reason = res.FailedTransaction?.status?.error ?? "unknown failure";
    throw new Error(`seed tx failed: ${reason}`);
  }
  const digest = res?.Transaction?.digest ?? res?.digest;
  console.log(`seeded ${SEED.length} listings — tx ${digest}`);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
