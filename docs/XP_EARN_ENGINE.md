# XP Earn Engine — Backend Spec

Companion to `sources/xp_registry.move`. The Move module is intentionally dumb about how much XP each action awards — all earn rates, daily caps, and reason→action mapping live in the backend config. This doc captures that config and the keeper architecture that signs `add_xp` / `record_rally` PTBs.

Per Phase 2 v2 spec §3.1, §4: XP rates are admin-adjustable without a contract upgrade. Changing a rate is a config edit + keeper restart, never a Move upgrade.

## Earn sources (launch values)

Numbers from spec §3.1. Tier 1 holders earn at 0× — backend gates this *before* calling `add_xp`. Single-stake unlock is Trumpagotchi-holder only (separate from XP).

| Action | Reason code | XP per event | Cap / cadence |
|---|---|---|---|
| Daily rally | `REASON_RALLY` (1) | 200 | 1 per 24h per wallet (contract-enforced) |
| Weekly quest — individual | `REASON_QUEST_INDIVIDUAL` (2) | 1,000–3,000 | Per quest, completion-gated |
| Weekly quest — community | `REASON_QUEST_COMMUNITY` (3) | 500–2,000 | Per quest, completion-gated |
| Raid completion (X retweet) | `REASON_RAID` (4) | 500 | 1 per raid week |
| 7-day rally streak bonus | `REASON_STREAK_BONUS` (5) | 500 | One-shot at streak == 7 |
| 30-day rally streak bonus | `REASON_STREAK_BONUS` (5) | 5,000 | One-shot at streak == 30 |
| 100-day rally streak bonus | `REASON_STREAK_BONUS` (5) | 20,000 | One-shot at streak == 100 |
| 365-day rally streak bonus | `REASON_STREAK_BONUS` (5) | 100,000 | One-shot at streak == 365 |
| Admin grant / migration | `REASON_ADMIN_GRANT` (6) | varies | Use `set_xp` for absolute, `add_xp` for delta |
| Other / future | `REASON_OTHER` (7) | varies | Backstop |

Active-player baseline per spec: 4,000–7,000 XP per week steady state.

## Streak system (contract behavior)

| Scenario | Outcome |
|---|---|
| First rally ever | streak = 1, longest_streak = 1, total_rallies = 1 |
| Rally within `rally_window_ms` of previous | streak += 1, longest_streak = max(streak, longest_streak) |
| Second rally < `rally_window_ms` after previous | aborts `ERallyTooSoon` (backend should not retry) |
| Gap > `streak_break_ms` since last rally | streak resets to 1; longest_streak preserved |
| Gap > `streak_break_ms` BUT `apply_meal_box` was called within `rally_window_ms` of next rally | streak += 1 (forgiven) — `RallyRecorded.streak_preserved_by_meal_box == true` |

Defaults: `rally_window_ms = 24h`, `streak_break_ms = 48h`, `losing_steam_threshold_ms = 24h`, `gone_quiet_threshold_ms = 96h`. All admin-tunable via `set_config`.

## Streak-bonus award flow

Streak bonuses are NOT awarded automatically by `record_rally` — the contract just updates the streak counter. The keeper:

1. Calls `record_rally` (atomic with the rally tx).
2. Reads the `RallyRecorded` event for the new streak value.
3. If `new_streak ∈ {7, 30, 100, 365}` AND this is the FIRST time this wallet has hit that milestone (idempotency check in Mongo), calls `add_xp` with `REASON_STREAK_BONUS` for the milestone amount.
4. Records `wallet + milestone` in Mongo to prevent double-award if a wallet drops back below and climbs again.

This keeps bonus-awarding policy entirely in the keeper.

## Daily caps

Caps are backend-enforced (no contract surface). The keeper:
- Reads the wallet's XP-earn history from Mongo (last 24h / 7d, by reason_code).
- Compares against the cap for that reason_code.
- If at-cap, drops the `add_xp` call (logs a `xp_cap_hit` event for ops).

Initial caps:
| Reason | Daily cap | Weekly cap |
|---|---|---|
| `REASON_RALLY` | 200 (one rally) | 1,400 |
| `REASON_QUEST_INDIVIDUAL` | none — per-quest gated | none |
| `REASON_QUEST_COMMUNITY` | none — per-quest gated | none |
| `REASON_RAID` | none | 500 (one raid/wk) |
| `REASON_STREAK_BONUS` | none — milestone-gated | none |

Caps will be revised quarterly based on engagement data.

## Reason → action mapping

The Move contract stores only the reason code on `XpAwarded` events. The keeper resolves it back to human-readable actions for indexing:

| Reason code | Constant | Action examples |
|---|---|---|
| 1 | `REASON_RALLY` | Daily rally tap |
| 2 | `REASON_QUEST_INDIVIDUAL` | Reach 7-day streak, equip Epic outfit, etc. |
| 3 | `REASON_QUEST_COMMUNITY` | Build the Wall, Drain the Swamp, etc. |
| 4 | `REASON_RAID` | X retweet of raid target tweet |
| 5 | `REASON_STREAK_BONUS` | 7 / 30 / 100 / 365-day milestone |
| 6 | `REASON_ADMIN_GRANT` | Manual grant by admin, migration backfill, decay-adjust |
| 7 | `REASON_OTHER` | Future / undefined |

## Keeper architecture

### Process

- Repo (to create): `CryptoMischief/xp-keeper` (private)
- Deploy target: Contabo VPS at `/root/xp-keeper/`
- Process manager: PM2 (single process)
- Signer: dedicated admin wallet (separate from limit bot / fee collector wallets — easier to revoke if XP rates need a freeze)
- RPC: gRPC fullnode at `https://fullnode.mainnet.sui.io:443` (testnet pre-launch). Per global rules: JSON-RPC is forbidden for new code.
- Polling cadence: 30s for rally action queue; 5min for streak milestone scans; quest closeout fires on quest end-of-day cron.

### Data store

- MongoDB Atlas (same cluster as everything else): `suitrump` db, new collections:
  - `xp_actions` — log of every awarded XP grant. Indexed by `wallet`, `timestamp`, `reason_code`. Idempotency keys for dedup on retry.
  - `xp_rally_log` — every rally call. Indexed by `wallet`, `day_bucket`. Drives "rallied today?" check.
  - `xp_streak_milestones` — `{wallet, milestone, awarded_at_ms}` for idempotent bonus awards.
  - `xp_quest_completions` — `{wallet, quest_id, completed_at_ms, reward_xp}` for individual quests.
  - `xp_community_quest_progress` — community quest goal trackers (one doc per quest).

### Action ingest flow

1. **Rally button click** — Frontend hits `/api/rally` (Vercel). Vercel checks: wallet owns Trumpagotchi, not rallied in last 24h, tier ≥ 2 (gating per spec §3.1). Inserts into MongoDB `xp_actions_queue` with `kind=rally`.
2. **Keeper poll loop** — Picks up queued actions, builds PTB:
   ```
   record_rally(admin, registry, addr, clock)
   add_xp(admin, registry, addr, 200, REASON_RALLY, clock)
   ```
   Submits via gRPC `executeTransaction`. Stores tx digest + new_streak in `xp_actions`.
3. **Streak milestone scan** — Every 5 min, walks recent `RallyRecorded` events from the indexer; if `new_streak ∈ {7,30,100,365}` and not in `xp_streak_milestones`, fires the bonus PTB and inserts the milestone row.
4. **Quest completion** — Quest engine (separate module, Track B item 5) inserts to `xp_actions_queue` with `kind=quest_individual / quest_community`; keeper builds `add_xp` PTB with corresponding reason code.
5. **Raid completion** — Raid module (Track B item 6) inserts after X retweet verification; same path.

### Idempotency

Every queued action has a unique `action_id` (UUID). Keeper checks `xp_actions` for existing row with same `action_id` before submitting. After successful submission, inserts row with tx digest. On retry after partial failure, the unique-index on `action_id` prevents double-grant.

For streak bonuses, the `(wallet, milestone)` composite key in `xp_streak_milestones` provides the same guarantee.

### Failure modes

| Failure | Recovery |
|---|---|
| RPC timeout on `record_rally` | Keeper retries up to 3× with exponential backoff. After 3 fails, action moves to `xp_dlq` for manual review. |
| `ERallyTooSoon` abort | Action was already processed (wallet's clock-skew or front-running). Mark resolved, no retry. |
| `add_xp` succeeds but `record_rally` failed earlier in same PTB | Impossible — PTBs are atomic. Either both happen or neither. |
| Backend crash mid-flight | On restart, keeper re-reads queue. Idempotency keys prevent double-grant. |
| Indexer falls behind | Streak milestone scan reads from gRPC fullnode events directly, not the indexer — no dependency. |

### Decay (deferred — not in launch)

XP does not decay at launch. Spec §3.3 calls for decay capability built in. The contract supports this via `set_xp` (admin can lower a wallet's XP). When/if decay is turned on:
- Add `xp_decay_config` admin doc with `decay_per_day_per_xp` rate.
- Add a daily cron that walks all wallets in `xp_actions` (last activity > 30 days), computes decay, calls `set_xp` with the new lower value.
- Emit `XpAwarded` events with `REASON_ADMIN_GRANT` are NOT emitted on decay (downward set_xp emits no event by design). A separate `xp_decay_log` Mongo collection captures the audit trail.

## Admin operations

| Operation | Move call | When |
|---|---|---|
| Adjust earn rate | (config edit only — no Move call) | Anytime — keeper picks up next cycle |
| Adjust daily cap | (config edit only) | Anytime |
| Change rally window / streak break | `set_config` | Rare — testnet first |
| Manual XP grant | `add_xp` with `REASON_ADMIN_GRANT` | Spot fixes, community rewards |
| Manual streak fix | `set_streak` with `REASON_OTHER` | Paid streak recovery flow, support cases |
| Pause all XP | (config flag: `keeper_paused = true`) | Emergency — keeper drops queue without panicking |
| Migration backfill | `batch_add_xp` | Initial seed of pre-existing engagement (if any) |

## Pre-launch checklist

- [ ] Package upgrade lands `xp_registry.move` into the trumpagotchi v13 package
- [ ] **Run `create_registry(&AdminCap, ctx)` once** — Sui upgrade does not auto-run `init()` for newly-added modules. The XpRegistry shared object only exists after this admin call. Verify `XpRegistryCreated` event + `take_shared<XpRegistry>` works before wiring keeper.
- [ ] Initial config values approved (defaults match `xp_registry.move` constants — change via `set_config` if needed)
- [ ] Admin wallet provisioned, AdminCap reachable
- [ ] MongoDB indices created (`xp_actions.wallet`, `xp_actions.action_id` unique, `xp_streak_milestones.{wallet,milestone}` unique)
- [ ] Tier-2-gate enforced in `/api/rally` (Vercel) — Tier 1 holders should see rally button but POSTs should return 200 without queuing
- [ ] Keeper deployed to VPS under PM2 with restart policy
- [ ] First 30-day quest plan written (Richie — spec open item)
- [ ] First raid target tweet selection process locked in (Richie — spec open item)

## Out-of-scope (Track B items 2-7)

This doc covers XP earn engine wiring. The following are separate builds that *consume* this engine but ship later:

- Daily rally button UI + frontend `/api/rally` endpoint (Track B item 2)
- McDonalds Meal Box shop integration → `apply_meal_box` call (Track B item 2)
- Streak recovery burn flow (Track B item 3 — `set_streak` via burn-keeper)
- Quest engine + admin panel (Track B item 5)
- Raid mechanic + X retweet verification (Track B item 6)
- Profile pages displaying XP/streak (Track B item 4)
- Gallery v2 + chat tags (Track A items 4-5 — depend on this engine)
