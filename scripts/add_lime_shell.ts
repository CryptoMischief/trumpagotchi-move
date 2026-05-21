// scripts/add_lime_shell.ts — one-shot admin script to add the Lime Green
// shell to the on-chain shop catalog WITHOUT running the catalog-wide
// validate_shop pre-flight (which fails today on 37 pre-existing missing
// quilt assets unrelated to the shell).
//
// What it does:
//   - Reads deployments/testnet.json for shop + admin cap + package ids.
//   - Builds a single PTB calling shop::admin_add_listing with the lime
//     shell values (matching the entry in shop_catalog.ts).
//   - Executes with the admin keypair from IDENTITY_PRIVKEY env.
//
// Run:
//   IDENTITY_PRIVKEY='suiprivkey1...' npx tsx scripts/add_lime_shell.ts
//   IDENTITY_PRIVKEY='suiprivkey1...' npx tsx scripts/add_lime_shell.ts --dry-run

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

const DRY_RUN = process.argv.includes("--dry-run");

// LOCKED VALUES — must match shop_catalog.ts shell entry + the frontend
// shellRegistry slug. Changing `name` requires updating shellRegistry.ts
// in the suitrump-site repo too.
const SHELL = {
  kind: 2 as const, // KIND_SHELL
  name: "Lime Green",
  tierGate: 0,
  rarity: 0,
  walrusStandalone: "Lime Green.png",
  equippedValue: "",
  priceSui: 0.1,
  initialStock: 100,
};

const priceMist = BigInt(Math.round(SHELL.priceSui * 1_000_000_000));

function loadKeypair(): Ed25519Keypair {
  const raw = process.env.IDENTITY_PRIVKEY;
  if (!raw) throw new Error("IDENTITY_PRIVKEY not set");
  if (raw.startsWith("suiprivkey")) return Ed25519Keypair.fromSecretKey(raw);
  throw new Error("expected suiprivkey-encoded admin key");
}

async function main() {
  const kp = loadKeypair();
  const sender = kp.toSuiAddress();
  const client = new SuiGrpcClient({ baseUrl: RPC, network: "testnet" });

  console.log("Lime Green shell — one-shot admin listing");
  console.log(`  sender:       ${sender}`);
  console.log(`  shop:         ${SHOP_OBJ}`);
  console.log(`  package:      ${PACKAGE_LATEST}`);
  console.log(`  admin cap:    ${ADMIN_CAP}`);
  console.log(`  name:         ${SHELL.name}`);
  console.log(`  kind:         ${SHELL.kind} (shell)`);
  console.log(`  price:        ${SHELL.priceSui} SUI (${priceMist.toString()} mist)`);
  console.log(`  stock:        ${SHELL.initialStock}`);
  console.log(`  tier gate:    ${SHELL.tierGate}`);
  console.log(`  rarity:       ${SHELL.rarity}`);
  console.log(`  walrus stand: "${SHELL.walrusStandalone}"`);
  console.log(`  dry-run:      ${DRY_RUN}`);

  const tx = new Transaction();
  tx.moveCall({
    target: `${PACKAGE_LATEST}::shop::admin_add_listing`,
    arguments: [
      tx.object(ADMIN_CAP),
      tx.object(SHOP_OBJ),
      tx.pure.u8(SHELL.kind),
      tx.pure.string(SHELL.name),
      tx.pure.u8(SHELL.tierGate),
      tx.pure.u8(SHELL.rarity),
      tx.pure.string(SHELL.walrusStandalone),
      tx.pure.string(SHELL.equippedValue),
      tx.pure.u64(priceMist),
      tx.pure.u64(BigInt(SHELL.initialStock)),
      tx.object(CLOCK),
    ],
  });

  if (DRY_RUN) {
    console.log("\n--dry-run set, NOT submitting tx.");
    const sim = await client.simulateTransaction({
      transaction: tx,
      checksEnabled: false,
      sender,
      include: { commandResults: true, events: true },
    });
    console.log("simulation:", JSON.stringify(sim, null, 2).slice(0, 1500));
    return;
  }

  const result = await client.signAndExecuteTransaction({
    transaction: tx,
    signer: kp,
    include: { effects: true, events: true },
  });

  if (result.Transaction) {
    console.log(`\n✓ Lime Green shell added to shop.`);
    console.log(`  digest: ${result.Transaction.digest}`);
    console.log(`  suiscan: https://suiscan.xyz/testnet/tx/${result.Transaction.digest}`);
  } else if (result.FailedTransaction) {
    console.error("\n✗ tx failed:", result.FailedTransaction.status?.error);
    process.exit(1);
  } else {
    console.log("unexpected response:", JSON.stringify(result, null, 2).slice(0, 1500));
  }
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
