// scripts/sync_shop.ts — idempotent shop catalog sync.
//
// Reads the on-chain shop, diffs against ./shop_catalog.ts, and applies
// the minimal set of admin txs to reconcile:
//   - Catalog entry not on-chain  → admin_add_listing
//   - On-chain SKU not in catalog → admin_set_active(false) (orphan
//                                   listings deactivated, never removed
//                                   so we don't break users holding
//                                   already-issued cosmetics)
//   - Field drift on a match-by-name SKU → admin_set_equipped_value /
//                                   admin_set_tier_gate / admin_set_name /
//                                   admin_set_walrus_standalone /
//                                   admin_set_price as needed
//   - Inactive listing that catalog wants active → admin_set_active(true)
//
// Pre-flight: ALWAYS runs validate_shop.ts. If any catalog entry's
// equipped_value × tier doesn't resolve in the strip quilt, the sync
// aborts before submitting any tx.
//
// Required env:
//   IDENTITY_PRIVKEY   suiprivkey1... — the deployer / admin wallet
//
// Flags:
//   --dry-run          Show what would change without submitting txs.
//   --remove-orphans   admin_remove_listing for on-chain SKUs not in
//                      catalog. Default is admin_set_active(false).
//
// Run:
//   IDENTITY_PRIVKEY='suiprivkey1...' npx tsx scripts/sync_shop.ts
//   IDENTITY_PRIVKEY='suiprivkey1...' npx tsx scripts/sync_shop.ts --dry-run

import { readFileSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";
import { SuiGrpcClient } from "@mysten/sui/grpc";
import { Transaction } from "@mysten/sui/transactions";
import { CATALOG, type CatalogListing } from "./shop_catalog.js";
import { validateCatalogAssets } from "./validate_shop.js";

const __dirname = dirname(fileURLToPath(import.meta.url));
const dep = JSON.parse(
  readFileSync(join(__dirname, "..", "deployments", "testnet.json"), "utf8"),
);

const RPC = "https://fullnode.testnet.sui.io";
const CLOCK = "0x6";
const PACKAGE_LATEST: string = dep.packageIdLatest;
const ADMIN_CAP: string = dep.adminCap;
const SHOP_OBJ: string = dep.shop.objectId;

const DRY_RUN = process.argv.includes("--dry-run");
const REMOVE_ORPHANS = process.argv.includes("--remove-orphans");

const priceMistFor = (suiAmount: number): bigint =>
  BigInt(Math.round(suiAmount * 1_000_000_000));
const suiFromMist = (mist: bigint | number | string): number =>
  Number(BigInt(mist)) / 1_000_000_000;

interface OnChainListing {
  sku: number;
  kind: number;
  name: string;
  tierGate: number;
  rarity: number;
  walrusStandalone: string;
  equippedValue: string;
  priceMist: bigint;
  stock: number;
  totalMinted: number;
  active: boolean;
}

function loadKeypair(): Ed25519Keypair {
  const raw = process.env.IDENTITY_PRIVKEY;
  if (!raw) throw new Error("IDENTITY_PRIVKEY not set");
  if (raw.startsWith("suiprivkey")) return Ed25519Keypair.fromSecretKey(raw);
  throw new Error("expected suiprivkey-encoded admin key");
}

// Enumerate the dynamic-field children of Shop.listings (Table<u64, Listing>),
// then getObjects them in one batched call to recover the Listing values.
async function fetchAllOnChainListings(
  client: SuiGrpcClient,
): Promise<OnChainListing[]> {
  // 1) Find the listings table's parent UID inside the Shop object.
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const shop: any = await client.getObject({
    objectId: SHOP_OBJ,
    include: { json: true },
  });
  const listingsField = shop?.object?.json?.listings;
  const tableUid: string =
    listingsField?.id?.id ?? listingsField?.id ?? listingsField?.fields?.id?.id;
  if (!tableUid) throw new Error("could not locate listings table UID on Shop");

  // 2) Walk dynamic fields. Catalog stays small (<100) but paginate
  //    defensively in case it grows.
  const childIds: string[] = [];
  let cursor: string | undefined;
  for (let page = 0; page < 50; page++) {
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const list: any = await client.listDynamicFields({
      parentId: tableUid,
      limit: 200,
      ...(cursor ? { cursor } : {}),
    });
    const items: unknown[] = Array.isArray(list?.dynamicFields)
      ? list.dynamicFields
      : [];
    for (const it of items) {
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      const item = it as any;
      if (item?.fieldId) childIds.push(String(item.fieldId));
    }
    cursor = list?.cursor ?? list?.nextPageToken ?? list?.nextCursor;
    if (!cursor) break;
  }
  if (childIds.length === 0) return [];

  // 3) One batched call.
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const batch: any = await client.getObjects({
    objectIds: childIds,
    include: { json: true },
  });
  const objects: unknown[] = Array.isArray(batch?.objects) ? batch.objects : [];
  const listings: OnChainListing[] = [];
  for (const o of objects) {
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const obj = o as any;
    if (!obj || obj instanceof Error) continue;
    const v = obj.json?.value;
    if (!v) continue;
    listings.push({
      sku: Number(v.sku ?? 0),
      kind: Number(v.kind ?? 0),
      name: String(v.name ?? ""),
      tierGate: Number(v.tier_gate ?? 0),
      rarity: Number(v.rarity ?? 0),
      walrusStandalone: String(v.walrus_identifier_standalone ?? ""),
      equippedValue: String(v.equipped_value ?? ""),
      priceMist: BigInt(v.price_mist ?? 0),
      stock: Number(v.stock ?? 0),
      totalMinted: Number(v.total_minted ?? 0),
      active: Boolean(v.active),
    });
  }
  return listings.sort((a, b) => a.sku - b.sku);
}

// Returns a Transaction with all the diff operations chained, or null if
// no changes are needed.
function buildDiffTx(
  catalog: CatalogListing[],
  onChain: OnChainListing[],
): { tx: Transaction | null; plan: string[] } {
  const tx = new Transaction();
  const plan: string[] = [];
  const byName = new Map(onChain.map((l) => [l.name, l]));

  // Pass 1 — add or reconcile each catalog entry.
  for (const c of catalog) {
    const existing = byName.get(c.name);
    const wantPriceMist = priceMistFor(c.priceSui);

    if (!existing) {
      plan.push(`ADD     "${c.name}" (kind=${c.kind}, gate=${c.tierGate}, eq=${c.equippedValue}, price=${c.priceSui} SUI, stock=${c.initialStock})`);
      tx.moveCall({
        target: `${PACKAGE_LATEST}::shop::admin_add_listing`,
        arguments: [
          tx.object(ADMIN_CAP),
          tx.object(SHOP_OBJ),
          tx.pure.u8(c.kind),
          tx.pure.string(c.name),
          tx.pure.u8(c.tierGate),
          tx.pure.u8(c.rarity),
          tx.pure.string(c.walrusStandalone),
          tx.pure.string(c.equippedValue),
          tx.pure.u64(wantPriceMist),
          tx.pure.u64(c.initialStock),
          tx.object(CLOCK),
        ],
      });
      continue;
    }

    // Field drift checks. Only emit a tx call when a field actually differs.
    if (existing.equippedValue !== c.equippedValue) {
      plan.push(`EDIT sku=${existing.sku} "${c.name}" equipped_value: "${existing.equippedValue}" → "${c.equippedValue}"`);
      tx.moveCall({
        target: `${PACKAGE_LATEST}::shop::admin_set_equipped_value`,
        arguments: [tx.object(ADMIN_CAP), tx.object(SHOP_OBJ), tx.pure.u64(existing.sku), tx.pure.string(c.equippedValue), tx.object(CLOCK)],
      });
    }
    if (existing.tierGate !== c.tierGate) {
      plan.push(`EDIT sku=${existing.sku} "${c.name}" tier_gate: ${existing.tierGate} → ${c.tierGate}`);
      tx.moveCall({
        target: `${PACKAGE_LATEST}::shop::admin_set_tier_gate`,
        arguments: [tx.object(ADMIN_CAP), tx.object(SHOP_OBJ), tx.pure.u64(existing.sku), tx.pure.u8(c.tierGate), tx.object(CLOCK)],
      });
    }
    if (existing.walrusStandalone !== c.walrusStandalone) {
      plan.push(`EDIT sku=${existing.sku} "${c.name}" walrus_standalone: "${existing.walrusStandalone}" → "${c.walrusStandalone}"`);
      tx.moveCall({
        target: `${PACKAGE_LATEST}::shop::admin_set_walrus_standalone`,
        arguments: [tx.object(ADMIN_CAP), tx.object(SHOP_OBJ), tx.pure.u64(existing.sku), tx.pure.string(c.walrusStandalone), tx.object(CLOCK)],
      });
    }
    if (existing.priceMist !== wantPriceMist) {
      plan.push(`EDIT sku=${existing.sku} "${c.name}" price: ${suiFromMist(existing.priceMist)} → ${c.priceSui} SUI`);
      tx.moveCall({
        target: `${PACKAGE_LATEST}::shop::admin_set_price`,
        arguments: [tx.object(ADMIN_CAP), tx.object(SHOP_OBJ), tx.pure.u64(existing.sku), tx.pure.u64(wantPriceMist), tx.object(CLOCK)],
      });
    }
    if (!existing.active) {
      plan.push(`EDIT sku=${existing.sku} "${c.name}" active: false → true`);
      tx.moveCall({
        target: `${PACKAGE_LATEST}::shop::admin_set_active`,
        arguments: [tx.object(ADMIN_CAP), tx.object(SHOP_OBJ), tx.pure.u64(existing.sku), tx.pure.bool(true), tx.object(CLOCK)],
      });
    }
  }

  // Pass 2 — orphans (on-chain SKUs the catalog no longer mentions).
  const catalogNames = new Set(catalog.map((c) => c.name));
  for (const existing of onChain) {
    if (catalogNames.has(existing.name)) continue;
    if (REMOVE_ORPHANS) {
      plan.push(`REMOVE  sku=${existing.sku} "${existing.name}" (orphan; --remove-orphans set)`);
      tx.moveCall({
        target: `${PACKAGE_LATEST}::shop::admin_remove_listing`,
        arguments: [tx.object(ADMIN_CAP), tx.object(SHOP_OBJ), tx.pure.u64(existing.sku), tx.object(CLOCK)],
      });
    } else if (existing.active) {
      plan.push(`DEACTIV sku=${existing.sku} "${existing.name}" (orphan; soft-disable)`);
      tx.moveCall({
        target: `${PACKAGE_LATEST}::shop::admin_set_active`,
        arguments: [tx.object(ADMIN_CAP), tx.object(SHOP_OBJ), tx.pure.u64(existing.sku), tx.pure.bool(false), tx.object(CLOCK)],
      });
    }
  }

  return { tx: plan.length === 0 ? null : tx, plan };
}

async function main() {
  console.log(`[sync_shop] target package: ${PACKAGE_LATEST}`);
  console.log(`[sync_shop] shop object:    ${SHOP_OBJ}`);
  console.log(`[sync_shop] strip quilt:    ${dep.walrus.stripQuilt.blobId}`);
  console.log(`[sync_shop] dry_run=${DRY_RUN} remove_orphans=${REMOVE_ORPHANS}`);

  // 1. Pre-flight asset validation.
  console.log("\n[sync_shop] validating catalog assets against quilt...");
  const v = await validateCatalogAssets();
  if (!v.ok) {
    console.error(`✗ asset validation FAILED — ${v.missing.length} missing of ${v.probed}:`);
    for (const m of v.missing.slice(0, 20)) console.error(`    ${m}`);
    if (v.missing.length > 20) console.error(`    ...and ${v.missing.length - 20} more`);
    console.error("\nAborting. Fix the asset pipeline or shop_catalog.ts before retrying.");
    process.exit(1);
  }
  console.log(`✓ ${v.probed} files all present.`);

  // 2. Read on-chain state.
  const client = new SuiGrpcClient({ baseUrl: RPC, network: "testnet" });
  console.log("\n[sync_shop] reading on-chain shop listings...");
  const onChain = await fetchAllOnChainListings(client);
  console.log(`  found ${onChain.length} listings on-chain (skus: ${onChain.map((l) => l.sku).join(", ")})`);

  // 3. Diff.
  const { tx, plan } = buildDiffTx(CATALOG, onChain);
  if (!tx) {
    console.log("\n✓ Shop is in sync with catalog. Nothing to do.");
    return;
  }

  console.log(`\n[sync_shop] plan (${plan.length} ops):`);
  for (const line of plan) console.log(`  ${line}`);

  if (DRY_RUN) {
    console.log("\n--dry-run — not submitting tx.");
    return;
  }

  // 4. Submit.
  const signer = loadKeypair();
  console.log(`\n[sync_shop] submitting as ${signer.toSuiAddress()}...`);
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const res: any = await client.signAndExecuteTransaction({
    transaction: tx,
    signer,
    include: { effects: true, events: true },
  });
  if (res?.FailedTransaction) {
    const reason = res.FailedTransaction?.status?.error ?? "unknown failure";
    throw new Error(`sync tx failed: ${reason}`);
  }
  const digest = res?.Transaction?.digest ?? res?.digest;
  console.log(`✓ sync complete — tx ${digest}`);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
