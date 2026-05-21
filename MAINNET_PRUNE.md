# Mainnet Prune Checklist

Source-of-truth for which testnet Move iterations to KEEP vs DELETE before publishing the mainnet package.

The testnet `trumpagotchi-move` package has accumulated functions through v15 → v16 → v17 → ... that explored designs we ultimately changed our minds on. Mainnet starts at v1 with whatever code is in the source tree at publish time, so we can simply DELETE these from `sources/*.move` before the mainnet `sui client publish`.

## Last updated
2026-05-13 — after the DB-rally migration decision.

---

## xp_registry.move — DELETE before mainnet publish

These were added during testnet experimentation and are no longer used because rally moved to DB:

| Function / item | Why delete |
|---|---|
| `public fun buy_meal_box_and_rally<T>` | v17 atomic flow — replaced by v16 buy_meal_box + DB rally |
| `public fun record_rally` | Rally is DB-only now; admin-signed rally is never called |
| `XP_PER_RALLY` constant (`200`) | Used only by buy_meal_box_and_rally; gone with it |
| `RallyRecorded` event | Was emitted by record_rally; no chain rally events anymore |
| `StreakSet` event | Emitted only by set_streak — see below |
| `MealBoxConsumed` event | Was emitted by admin-path apply_meal_box — see below |
| `public fun set_streak` | Streak is DB-only; no admin streak override needed |
| `public fun set_xp` | XP is DB-only; admin override happens in Mongo |
| `public fun add_xp` | Used by record_rally + apply_meal_box paths; both gone. **Verify** nothing else calls it before deleting. |
| `public fun batch_add_xp` | Convenience for batch admin XP grants — not used in DB-rally architecture |
| `public fun apply_meal_box` (admin path) | The user-signed buy_meal_box is the only path now |
| `set_decay_grace` (if present) | Was for an XP decay mode we never built |

**XpEntry struct fields**: with everything except `meal_box_at_ms` becoming dead state, consider whether the entire XpEntry / XpRegistry should be replaced by a simpler `MealBoxRegistry` that just tracks `(wallet → last_meal_box_at_ms)`. If we do that, the dynamic field on XpRegistry for `meal_box_coin_type` migrates too.

---

## xp_registry.move — KEEP

| Function / item | Why keep |
|---|---|
| `public fun buy_meal_box<T>` | Core user-signed burn flow. Required for chain-side SUITRUMP burn. |
| `public fun admin_set_meal_box_coin<T>` | Admin sets coin type post-publish (mainnet SUITRUMP). |
| `public fun meal_box_coin_type` | Read-only view |
| `public fun meal_box_price` | Read-only view |
| `MEAL_BOX_PRICE` constant (`5_000_000_000`) | Required by buy_meal_box |
| `BURN_ADDRESS` constant (`@0x0`) | Required by buy_meal_box |
| `MealBoxPurchased` event | Useful for analytics + future indexer |
| `MealBoxCoinTypeSet` event | Admin audit trail |
| `MEAL_BOX_COIN_KEY` constant | Dynamic field key |
| `create_registry` | Bootstrap shared object |
| `create_registry_internal` | Internal init |
| `XpRegistryCreated` event | Bootstrap audit |

**Note**: if we adopt the simpler "MealBoxRegistry" approach above, several of these would be renamed/restructured anyway. Make that call before publishing.

---

## xp-keeper repo — Strip rally code paths

These are non-Move so trivially deletable, but track them here for completeness:

- `src/index.ts`: `case "rally":` in `buildPtbForAction` — now throws (delete entirely)
- `src/streak.ts`: `maybeAwardStreakBonus`, `newStreakFromEvent`, `isStreakMilestone`, `hasMilestoneFired` — all rally-event-driven, deletable
- `src/chain.ts`: `buildRecordRally` — delete
- `scripts/test_streak_parse.ts` — delete

Keep:
- `buildApplyMealBox` (still callable for admin meal-box grants if we ever need them)
- `buildAddXp` — kept for non-rally XP (quests, raids, admin grants)
- `buildSetStreak`, `buildSetXp` — useful for admin migrations / fixes

If we delete `record_rally` + `add_xp` from Move source for mainnet, then `buildRecordRally` and `buildAddXp` in xp-keeper must also be deleted (they'd compile against a function that doesn't exist).

---

## site (suitrumpsite/suitrump-site) — Strip dead frontend paths

- `lib/trumpagotchi/ptb.ts`: `buildBuyMealBoxAndRallyTx` (v17 atomic) — delete; only `buildBuyMealBoxTx` is used
- `MEAL_BOX_PRICE_RAW` constant — keep (still used by v16 buy_meal_box flow)

No active code paths reference the v17 atomic in the codebase after the migration — the deletion is purely hygiene.

---

## Final mainnet publish checklist

Before running `sui client publish` against mainnet:

1. [ ] Review every public function in `sources/xp_registry.move` against this doc
2. [ ] Delete the marked functions/events/constants from source
3. [ ] Run `sui move build` clean
4. [ ] Run `sui move test` — all tests pass (delete tests for deleted functions)
5. [ ] Audit the resulting bytecode size — should be materially smaller
6. [ ] Publish mainnet, capture the new packageId
7. [ ] Call `admin_set_meal_box_coin<MAINNET_SUITRUMP>` to initialize the dynamic field
8. [ ] Update site config TRUMPAGOTCHI_PACKAGE_LATEST + ecosystem CLAUDE.md
9. [ ] Run `scripts/seedXpState.ts` against mainnet Mongo only if any rally history needs preserving (testnet history → mainnet doesn't make sense, so probably skip)

Mainnet ships clean from day one.
