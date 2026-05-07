// Repointed test prices to 0.01 SUI for all live SKUs and fixes the two
// background SKUs whose walrus standalone names didn't match the actual
// quilt patches (`MarALago.png` → `Mar-A-Lago.png`, `McDonalds.png` →
// `Macdonalds.png`). Single PTB so the shop is consistent atomically.
//
// Run from `identity-engine/` (which has the SDK + dotenv):
//   IDENTITY_PRIVKEY='suiprivkey1...' npx tsx \
//     /Users/apple/Desktop/suitrump/trumpagotchi-move/scripts/fix_shop_test_prices.ts

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

// 0.01 SUI in mist for the test phase. Mainnet sets canonical pricing
// per v8 docs; do NOT use this script for mainnet.
const TEST_PRICE_MIST = 10_000_000n;

// SKUs currently in the shop with correct walrus names — only price changes.
const SKUS_TO_REPRICE: number[] = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 15];

// SKUs to remove + re-add with corrected walrus standalone identifiers.
// (Tier-gate / rarity / equipped_value preserved; price = 0.01 SUI test.)
interface ReissueListing {
  oldSku: number;
  kind: 0 | 1 | 2;
  name: string;
  tierGate: number;
  rarity: number;
  walrusStandalone: string;
  equippedValue: string;
  initialStock: number;
}
const REISSUE: ReissueListing[] = [
  {
    oldSku: 13,
    kind: 1,
    name: "Mar-A-Lago",
    tierGate: 4,
    rarity: 1,
    walrusStandalone: "Mar-A-Lago.png",
    equippedValue: "Mar-A-Lago",
    initialStock: 25,
  },
  {
    oldSku: 14,
    kind: 1,
    name: "Macdonalds",
    tierGate: 6,
    rarity: 1,
    walrusStandalone: "Macdonalds.png",
    equippedValue: "Macdonalds",
    initialStock: 15,
  },
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

  for (const sku of SKUS_TO_REPRICE) {
    tx.moveCall({
      target: `${PACKAGE_LATEST}::shop::admin_set_price`,
      arguments: [
        tx.object(ADMIN_CAP),
        tx.object(SHOP_OBJ),
        tx.pure.u64(sku),
        tx.pure.u64(TEST_PRICE_MIST),
        tx.object(CLOCK),
      ],
    });
  }

  for (const r of REISSUE) {
    tx.moveCall({
      target: `${PACKAGE_LATEST}::shop::admin_remove_listing`,
      arguments: [
        tx.object(ADMIN_CAP),
        tx.object(SHOP_OBJ),
        tx.pure.u64(r.oldSku),
        tx.object(CLOCK),
      ],
    });
    tx.moveCall({
      target: `${PACKAGE_LATEST}::shop::admin_add_listing`,
      arguments: [
        tx.object(ADMIN_CAP),
        tx.object(SHOP_OBJ),
        tx.pure.u8(r.kind),
        tx.pure.string(r.name),
        tx.pure.u8(r.tierGate),
        tx.pure.u8(r.rarity),
        tx.pure.string(r.walrusStandalone),
        tx.pure.string(r.equippedValue),
        tx.pure.u64(TEST_PRICE_MIST),
        tx.pure.u64(r.initialStock),
        tx.object(CLOCK),
      ],
    });
  }

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const res: any = await client.signAndExecuteTransaction({
    transaction: tx,
    signer,
    include: { effects: true },
  });
  if (res?.FailedTransaction) {
    const reason = res.FailedTransaction?.status?.error ?? "unknown failure";
    throw new Error(`fix tx failed: ${reason}`);
  }
  const digest = res?.Transaction?.digest ?? res?.digest;
  console.log(
    `repriced ${SKUS_TO_REPRICE.length} SKUs to 0.01 SUI; ` +
      `re-issued ${REISSUE.length} bg listings with correct walrus names — ` +
      `tx ${digest}`,
  );
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
