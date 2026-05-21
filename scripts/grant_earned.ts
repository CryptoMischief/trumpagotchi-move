// scripts/grant_earned.ts — idempotent tier-earned cosmetic grant.
//
// For each Trumpagotchi holder, reads their current tier from
// TierRegistry, then for each entry in EARNED (from earned_catalog.ts)
// whose `gate` <= holder.tier, grants the cosmetic IFF the holder
// doesn't already own one with the same (kind, equipped_value).
//
// All grants bundle into a single PTB per run (Sui PTB cap 1024). Safe
// to re-run — second run is a no-op.
//
// Required env:
//   IDENTITY_PRIVKEY   suiprivkey1... — the AdminCap-holding wallet
//
// Flags:
//   --dry-run     Show grants without submitting tx.
//   --wallet=0x… Restrict to a single wallet (debug / target a fix).

import { readFileSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";
import { SuiGrpcClient } from "@mysten/sui/grpc";
import { Transaction } from "@mysten/sui/transactions";
import { bcs } from "@mysten/sui/bcs";
import { EARNED, type EarnedListing } from "./earned_catalog.js";

const __dirname = dirname(fileURLToPath(import.meta.url));
const dep = JSON.parse(
  readFileSync(join(__dirname, "..", "deployments", "testnet.json"), "utf8"),
);

const RPC = "https://fullnode.testnet.sui.io";
const PACKAGE_ID: string = dep.packageId;            // canonical original-id for Cosmetic type
const PACKAGE_LATEST: string = dep.packageIdLatest;  // call latest published-at for the entry function
const ADMIN_CAP: string = dep.adminCap;
const TIER_REGISTRY: string = dep.tierRegistry;
const MINTED_REGISTRY: string = dep.mintedRegistry;
const COSMETIC_TYPE = `${PACKAGE_ID}::trumpagotchi::Cosmetic`;

const DRY_RUN = process.argv.includes("--dry-run");
const WALLET_FLAG = process.argv.find((a) => a.startsWith("--wallet="));
const SINGLE_WALLET = WALLET_FLAG ? WALLET_FLAG.split("=")[1] : null;

function loadKeypair(): Ed25519Keypair {
  const raw = process.env.IDENTITY_PRIVKEY;
  if (!raw) throw new Error("IDENTITY_PRIVKEY not set");
  if (raw.startsWith("suiprivkey")) return Ed25519Keypair.fromSecretKey(raw);
  throw new Error("expected suiprivkey-encoded admin key");
}

function bcsBytesToAddressHex(
  bytes: Record<string, number> | Uint8Array | undefined,
): string {
  if (!bytes) return "";
  const out: string[] = [];
  for (let i = 0; i < 32; i++) {
    const b =
      bytes instanceof Uint8Array
        ? bytes[i]
        : (bytes as Record<string, number>)[String(i)] ?? 0;
    out.push(b.toString(16).padStart(2, "0"));
  }
  return "0x" + out.join("");
}

// Enumerate every address with a Trumpagotchi NFT — walk TierRegistry.tiers
// instead of MintedRegistry.minted. Exempt wallets (cryptomischief.sui)
// bypass MintedRegistry but mint_to ALWAYS seeds a TierRegistry entry, so
// tiers is the authoritative holder list.
async function fetchHolders(client: SuiGrpcClient): Promise<string[]> {
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const reg: any = await client.getObject({
    objectId: TIER_REGISTRY,
    include: { json: true },
  });
  const tiersField = reg?.object?.json?.tiers;
  const tableUid: string | undefined =
    tiersField?.id?.id ?? tiersField?.id ?? tiersField?.fields?.id?.id;
  if (!tableUid) return [];

  const holders = new Set<string>();
  let cursor: string | undefined;
  for (let page = 0; page < 100; page++) {
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
      const decoded = bcsBytesToAddressHex((it as any)?.name?.bcs);
      if (decoded) holders.add(decoded.toLowerCase());
    }
    cursor = list?.cursor ?? list?.nextPageToken ?? list?.nextCursor;
    if (!cursor) break;
  }
  return Array.from(holders);
}

// Read the tier of a single address via the TierRegistry tiers Table.
async function fetchTier(client: SuiGrpcClient, addr: string): Promise<number> {
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const reg: any = await client.getObject({
    objectId: TIER_REGISTRY,
    include: { json: true },
  });
  const tiersField = reg?.object?.json?.tiers;
  const tableUid: string | undefined =
    tiersField?.id?.id ?? tiersField?.id ?? tiersField?.fields?.id?.id;
  if (!tableUid) return 1;

  try {
    const addrBytes = bcs.Address.serialize(addr).toBytes();
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const df: any = await client.getDynamicField({
      parentId: tableUid,
      name: { type: "address", bcs: addrBytes },
    });
    const fieldId: string | undefined = df?.dynamicField?.fieldId;
    if (!fieldId) return 1;
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const child: any = await client.getObject({
      objectId: fieldId,
      include: { json: true },
    });
    return Number(child?.object?.json?.value?.tier ?? 1);
  } catch {
    return 1;
  }
}

// Enumerate the wallet's owned Cosmetics + the equipped (DF-child)
// cosmetics on its NFT. Returns the set of "kind:equipped_value" keys
// already owned so we can skip duplicate grants.
async function fetchOwnedCosmeticSig(
  client: SuiGrpcClient,
  addr: string,
): Promise<Set<string>> {
  const out = new Set<string>();

  // Owned (top-level) cosmetics.
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const res: any = await client.listOwnedObjects({
    owner: addr,
    type: COSMETIC_TYPE,
    include: { json: true },
    limit: 200,
  });
  for (const o of res?.objects ?? []) {
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const obj = o as any;
    const kind = obj?.json?.kind;
    const eq = obj?.json?.equipped_value;
    if (kind !== undefined && eq) out.add(`${kind}:${eq}`);
  }

  // Equipped cosmetics live as dynamic fields on the NFT. Walk
  // owned Trumpagotchi NFTs and enumerate the DF children too.
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const nftRes: any = await client.listOwnedObjects({
    owner: addr,
    type: `${PACKAGE_ID}::trumpagotchi::Trumpagotchi`,
    include: { json: true },
    limit: 50,
  });
  for (const o of nftRes?.objects ?? []) {
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const nftId: string | undefined = (o as any)?.objectId;
    if (!nftId) continue;
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const list: any = await client.listDynamicFields({
      parentId: nftId,
      limit: 50,
    });
    const items: unknown[] = Array.isArray(list?.dynamicFields)
      ? list.dynamicFields
      : [];
    if (items.length === 0) continue;
    const fieldIds = (items as Array<Record<string, unknown>>)
      .map((i) => (i as { fieldId?: string }).fieldId)
      .filter((x): x is string => Boolean(x));
    if (fieldIds.length === 0) continue;
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const batch: any = await client.getObjects({
      objectIds: fieldIds,
      include: { json: true },
    });
    for (const ob of batch?.objects ?? []) {
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      const inner = (ob as any)?.json?.value;
      if (!inner) continue;
      const kind = inner.kind;
      const eq = inner.equipped_value;
      if (kind !== undefined && eq) out.add(`${kind}:${eq}`);
    }
  }

  return out;
}

interface GrantPlan {
  wallet: string;
  tier: number;
  toGrant: EarnedListing[];
}

async function buildPlan(client: SuiGrpcClient): Promise<GrantPlan[]> {
  const wallets = SINGLE_WALLET ? [SINGLE_WALLET.toLowerCase()] : await fetchHolders(client);
  console.log(`[grant_earned] candidates: ${wallets.length} holder${wallets.length === 1 ? "" : "s"}`);

  const plan: GrantPlan[] = [];
  for (const w of wallets) {
    const tier = await fetchTier(client, w);
    const owned = await fetchOwnedCosmeticSig(client, w);
    const toGrant = EARNED.filter((e) => {
      if (tier < e.gate) return false;
      const sig = `${e.kind}:${e.equippedValue}`;
      return !owned.has(sig);
    });
    if (toGrant.length > 0) {
      plan.push({ wallet: w, tier, toGrant });
    }
  }
  return plan;
}

function buildTx(plan: GrantPlan[]): Transaction {
  const tx = new Transaction();
  for (const p of plan) {
    for (const e of p.toGrant) {
      tx.moveCall({
        target: `${PACKAGE_LATEST}::trumpagotchi::admin_issue_cosmetic`,
        arguments: [
          tx.object(ADMIN_CAP),
          tx.pure.u8(e.kind),
          tx.pure.string(e.name),
          tx.pure.u8(e.gate),
          tx.pure.u8(e.rarity),
          tx.pure.string(e.walrusStandalone),
          tx.pure.string(e.equippedValue),
          tx.pure.address(p.wallet),
        ],
      });
    }
  }
  return tx;
}

async function main() {
  console.log(`[grant_earned] target package: ${PACKAGE_LATEST}`);
  console.log(`[grant_earned] earned catalog: ${EARNED.length} items`);
  console.log(`[grant_earned] dry_run=${DRY_RUN} single_wallet=${SINGLE_WALLET ?? "all minters"}`);

  const client = new SuiGrpcClient({ baseUrl: RPC, network: "testnet" });
  const plan = await buildPlan(client);

  if (plan.length === 0) {
    console.log("\n✓ All eligible wallets already have all earned items. Nothing to do.");
    return;
  }

  console.log(`\n[grant_earned] plan (${plan.length} wallet${plan.length === 1 ? "" : "s"}):`);
  let totalGrants = 0;
  for (const p of plan) {
    console.log(`  ${p.wallet.slice(0, 12)}… (tier=${p.tier}) — ${p.toGrant.length} item${p.toGrant.length === 1 ? "" : "s"}:`);
    for (const e of p.toGrant) {
      console.log(`    + ${e.name} (kind=${e.kind}, gate=${e.gate}, eq=${e.equippedValue})`);
    }
    totalGrants += p.toGrant.length;
  }
  console.log(`\n[grant_earned] total grants: ${totalGrants}`);

  if (DRY_RUN) {
    console.log("\n--dry-run — not submitting tx.");
    return;
  }

  const signer = loadKeypair();
  console.log(`\n[grant_earned] submitting as ${signer.toSuiAddress()}...`);
  const tx = buildTx(plan);

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const res: any = await client.signAndExecuteTransaction({
    transaction: tx,
    signer,
    include: { effects: true, events: true },
  });
  if (res?.FailedTransaction) {
    throw new Error(`grant tx failed: ${res.FailedTransaction?.status?.error ?? "unknown"}`);
  }
  const digest = res?.Transaction?.digest ?? res?.digest;
  console.log(`✓ grant_earned complete — tx ${digest}`);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
