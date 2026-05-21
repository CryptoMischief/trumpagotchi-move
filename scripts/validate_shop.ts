// scripts/validate_shop.ts — pre-flight validation for the shop catalog.
//
// For every listing in CATALOG, verifies that EVERY filename the contract
// could compose actually resolves in the live Walrus strip quilt. This
// prevents future "broken Vacation" style bugs where a typo in the seed
// silently issues cosmetics that 404 when equipped.
//
// For outfits (kind=0): probes `Tier{N}-{TierName}-{equippedValue}.png`
//   for every tier N where N >= tierGate.
// For backgrounds (kind=1): probes `{equippedValue}.png` (single file).
// For shells (kind=2): unused at launch — skipped.
//
// Run standalone:
//   npx tsx scripts/validate_shop.ts
//
// Or import from another script:
//   import { validateCatalogAssets } from "./validate_shop.js";
//   const result = await validateCatalogAssets();
//   if (!result.ok) throw new Error(...);

import { readFileSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { CATALOG, TIER_LABELS, MAX_TIER, type CatalogListing } from "./shop_catalog.js";

const __dirname = dirname(fileURLToPath(import.meta.url));
const dep = JSON.parse(
  readFileSync(join(__dirname, "..", "deployments", "testnet.json"), "utf8"),
);

const AGGREGATOR = "https://aggregator.walrus-testnet.walrus.space";
const STRIP_QUILT: string = dep.walrus.stripQuilt.blobId;

export interface ValidationResult {
  ok: boolean;
  probed: number;
  missing: string[];
}

// GET probe with retries — the Walrus aggregator sometimes returns
// connection errors under burst load, especially right after a fresh
// pin. Three tries with backoff; 30s total budget per file.
async function probe(filename: string): Promise<number> {
  const encoded = encodeURI(filename);
  const url = `${AGGREGATOR}/v1/blobs/by-quilt-id/${STRIP_QUILT}/${encoded}`;
  for (let attempt = 0; attempt < 3; attempt++) {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), 12_000);
    try {
      const r = await fetch(url, { signal: controller.signal });
      clearTimeout(timer);
      // 404 is a real signal — return immediately.
      if (r.status === 404) return 404;
      if (r.status === 200) return 200;
      // 5xx / 429 — back off + retry.
    } catch {
      clearTimeout(timer);
      // Network / abort — retry.
    }
    if (attempt < 2) {
      await new Promise((r) => setTimeout(r, 1_500 * (attempt + 1)));
    }
  }
  return 0; // treat exhausted retries as failure
}

function filenamesFor(entry: CatalogListing): string[] {
  if (entry.kind === 0) {
    // Outfit — probe every eligible tier composite.
    const files: string[] = [];
    for (let n = entry.tierGate; n <= MAX_TIER; n++) {
      const tierLabel = TIER_LABELS[n];
      files.push(`${tierLabel}-${entry.equippedValue}.png`);
    }
    return files;
  }
  if (entry.kind === 1) {
    // Background — single file.
    return [`${entry.equippedValue}.png`];
  }
  // Shell — skip.
  return [];
}

export async function validateCatalogAssets(
  catalog: CatalogListing[] = CATALOG,
  opts: { verbose?: boolean; concurrency?: number } = {},
): Promise<ValidationResult> {
  const verbose = opts.verbose ?? false;
  // Aggregator rate-limits hard above ~4 concurrent connections per IP.
  const concurrency = opts.concurrency ?? 4;

  const allFiles: { entry: CatalogListing; filename: string }[] = [];
  for (const entry of catalog) {
    for (const f of filenamesFor(entry)) {
      allFiles.push({ entry, filename: f });
    }
  }

  if (verbose) {
    console.log(
      `Probing ${allFiles.length} (listing × tier) combos against quilt ${STRIP_QUILT}...`,
    );
  }

  const missing: string[] = [];
  // Simple worker pool — bounded concurrency to avoid hammering the aggregator.
  let idx = 0;
  async function worker() {
    while (idx < allFiles.length) {
      const i = idx++;
      const { entry, filename } = allFiles[i];
      const code = await probe(filename);
      if (code !== 200) {
        missing.push(`${filename} (${code}) — for SKU "${entry.name}"`);
      }
    }
  }
  await Promise.all(Array.from({ length: concurrency }, worker));

  const ok = missing.length === 0;
  if (verbose) {
    if (ok) console.log(`✓ All ${allFiles.length} files present in quilt.`);
    else {
      console.error(`✗ ${missing.length} of ${allFiles.length} files MISSING:`);
      for (const m of missing) console.error(`  - ${m}`);
    }
  }

  return { ok, probed: allFiles.length, missing };
}

// CLI mode — run validation, exit 0 on success, 1 on failure.
const isMain = import.meta.url === `file://${process.argv[1]}`;
if (isMain) {
  validateCatalogAssets(undefined, { verbose: true })
    .then((r) => process.exit(r.ok ? 0 : 1))
    .catch((err) => {
      console.error(err);
      process.exit(2);
    });
}
