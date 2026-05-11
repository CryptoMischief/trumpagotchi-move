# single_stake.move — Audit Readiness Review

Date: 2026-05-10
Reviewed against: Move 2024 Code Quality Checklist + Sui Move Best Practices + staking-contract risk surface (SUI staking 1 MIST exploit, time-merge CTF, public/entry visibility for randomness, OWASP-style review).

Source: `sources/single_stake.move` (985 lines, 68 tests passing across project).

---

## Summary

The contract is **well-structured and largely audit-ready**. Naming, error-code style, capability pattern, soulbound position, MasterChef accumulator math, integer-overflow guards, and clamp-to-physical-balance defense are all idiomatic. The MIN_STAKE_NEW threshold (10k SUITRUMP) sidesteps the rounding-error class of attacks that bit Mysten's own staking pool (1 MIST exploit fixed in PR #9961).

The findings below are **mostly P1 polish and one P0 DRY violation**. None are exploitability concerns; they're the kinds of things an auditor will flag as "fix before sign-off" rather than "redesign required."

---

## Status as of 2026-05-10

| ID | Status | Notes |
|---|---|---|
| F1 | ✅ FIXED | Extracted `pay_pending` helper. Both `settle_rewards` and `finalize_unstake` use it. |
| F2 | ✅ FIXED | Dead vars removed. Replaced with audit note pointing at F12. |
| F3 | ✅ FIXED | Renamed `estimated_unclaimed` → `unclaimed_emitted_floor`. Dropped unused `_total_weight`. Added invariant comment. |
| F4 | ✅ FIXED | Inlined `update_campaign_pool` at the two callers. |
| F5 | ✅ FIXED | `settle_rewards` now takes `now: u64`. All event timestamps consistent. |
| F7 | ✅ FIXED | Module-top visibility + capability + soulbound rationale added. |
| F9 | ✅ FIXED | RewardPool fields now have INVARIANT lines. |
| F10 | ✅ FIXED | Concrete overflow analysis on `ACC_PRECISION`. |
| F12 | ✅ FIXED | `auto_convert_if_due` now pays OLD-weight pending via `pay_pending` + transfer-to-owner before resetting weight + debt. Emits `RewardsClaimed` if payout > 0. |
| F13 | ✅ FIXED | `top_up` now uses `MULT_FLEXIBLE_BPS` if `position.converted` else `lock_multiplier_bps(lock_kind)`. |
| F6, F8, F11 | DEFERRED | Polish / post-launch v2. |

## P0 — Fix before audit

### F1. `finalize_unstake` duplicates `settle_rewards` logic — FIXED
**Lines:** 801-834 vs. 711-743.

`finalize_unstake` re-implements the entitlement→pending→clamp→split→event flow inline because it consumes the position by value and can't borrow it as `&mut`. The math is currently identical, but **any future change has to be made in two places** — exactly the kind of footgun auditors flag because divergence creates real bugs over time.

**Fix options:**
- (a) Extract `compute_and_settle_pending<P,V>(vault, weight, debt1, debt2, ctx) -> (Coin<V>, Coin<P>, u64, u64)` returning the two coins plus payouts for the event. Both call sites use it.
- (b) Refactor `settle_rewards` to take `(weight, &mut debt1, &mut debt2)` instead of `&mut StakePosition` so it can be reused after the position's been decomposed.

Option (a) is cleaner. Want me to implement it?

---

### F12. Auto-convert forfeits all pre-conversion pending on first claim/top_up post lock-end (NEW — P0)

**Discovered during F2 fix.** The dead `entitlement1/entitlement2` vars in `auto_convert_if_due` were a TODO marker for a missing payment step.

**Lines:** auto_convert_if_due is called by claim_rewards (557), top_up (509), claim_campaign (575) BEFORE settle_rewards (or before campaign settlement). At entry, position has `weight = principal × lock_mult` (e.g. 2.0x) and `debt = old_weight × old_acc / PREC`. After auto_convert: `weight = principal × 1.0x`, `debt = new_weight × current_acc / PREC`. Then settle_rewards computes `pending = position.weight × current_acc / PREC - position.debt = 0`.

**Result:** Every reward accrued at the locked weight from stake-time to lock-end is **forfeited** the moment the user first interacts with the position post lock-end via claim/top_up. `unstake_at_maturity` is NOT affected (finalize_unstake doesn't call auto_convert and uses old weight in pay_pending).

**Worked example:**
- Alice stakes 10k SUITRUMP at LOCK_180D → weight=20k, total_weight=20k.
- Pool 2 has 1M SUITRUMP. After 90 days emits ~1M (asymptotic to balance).
- Alice's accrued = ~1M (she's the only staker).
- Alice calls claim_rewards at day 181 (one day past lock end).
  - update_pools: acc grows.
  - auto_convert: weight 20k→10k, debt set to 10k × current_acc / PREC.
  - settle_rewards: pending = 10k × acc / PREC − 10k × acc / PREC = **0**.
- Alice gets 0 SUITRUMP. Should have got ~1M.

**Severity:** High. User-impacting, silently loses substantial rewards. Easy to encounter in normal usage (any user who claims instead of unstaking at maturity).

**Fix options:**
- (a) Pay out OLD-weight pending inside `auto_convert_if_due` via `transfer::public_transfer` to position.owner, before resetting weight + debt. Slight anti-pattern (transfer in non-entry function) but OK because the pending unambiguously belongs to position.owner.
- (b) Reorder all 3 callers to settle BEFORE auto_convert. Requires `claim_campaign` to also settle pool 1/2 → must return three coins instead of one (Coin<V>, Coin<P>, Coin<T>). Frontend update needed.

**Recommended:** (a). Smaller blast radius, no API changes.

---

### F13. Top-up after auto-convert uses lock multiplier instead of flexible (NEW — P1)

**Lines:** top_up at 518 — `let mult_bps = lock_multiplier_bps(position.lock_kind)`.

After auto_convert sets `weight = principal × 1.0x` and `converted = true`, top_up immediately recomputes `weight = (principal + added) × lock_multiplier_bps(LOCK_180D) = (principal + added) × 2.0x`. The auto-convert weight reset is silently undone for the entire position.

**Result:** A user past their lock end can top-up by 1k SUITRUMP and get 2.0x weight on the entire (principal + 1k) position **without actually re-locking**.

**Severity:** Medium. Exploitable for sustained over-weighting after lock end. User can chain micro-top-ups to maintain 2.0x weight forever.

**Fix:** Change line 518 to `let mult_bps = if (position.converted) MULT_FLEXIBLE_BPS else lock_multiplier_bps(position.lock_kind);`.

Independent of F12.

---

## P1 — Polish (do before audit, won't block it)

### F2. Dead `entitlement1` / `entitlement2` in `auto_convert_if_due`
**Lines:** 767-770 + 788-789.

```move
let entitlement1 = (vault.pool1_victory.acc_reward_per_share * (position.weight as u128)) / ACC_PRECISION;
let entitlement2 = ...;
// We don't pay out here — settle_rewards does. Instead recompute debts so [...]
let _ = entitlement1;
let _ = entitlement2;
```

The values are computed and discarded. The comment says "exist for documentation; future revisions may auto-pay here." An auditor will flag dead computation as either a missed implementation or a bug. **Either remove, or implement the auto-pay.** My recommendation: remove and add a one-line comment explaining the math is intentionally external (caller must invoke settle_rewards before this).

### F3. `estimated_unclaimed` has unused param + name overstates precision
**Lines:** 918-926.

```move
fun estimated_unclaimed<T>(pool: &RewardPool<T>, _total_weight: u64): u64 { ... }
```

The `_total_weight` argument is unused. The function name implies it computes the per-staker unclaimed total, but it actually returns `bal - effective_balance` (the cumulative-emitted-but-not-yet-claimed amount across the whole pool). Two fixes:
- Drop the `_total_weight` parameter.
- Rename to `unclaimed_emitted_floor` or similar. Add a one-line invariant comment: `// = total emitted minus total claimed, ≤ balance.`

### F4. `update_campaign_pool` is a single-line wrapper around `update_single_pool`
**Lines:** 705-707.

Either inline the call sites or document why this layer exists. Currently it's noise. Suggest removing and calling `update_single_pool` directly at the two callers (`sweep_expired_campaign` line 403, `claim_campaign` line 579).

### F5. `RewardsClaimed` event uses `tx_context::epoch_timestamp_ms` in `settle_rewards`
**Line:** 750.

Other events in the file use the explicitly-passed `now` (the Clock-derived ms). `settle_rewards` doesn't take `now` so it falls back to the epoch timestamp. **Inconsistent** — auditors notice. Fix: thread `now` into `settle_rewards` as a param so all events use the same time source.

### F6. View-functions return wide tuples
**Lines:** 929-944.

`get_vault_status` returns 8-tuple, `get_position` returns 7-tuple. Tuple field-order is brittle: any caller (frontend, audit reviewer) has to count positions or refer back to the source. Sui Move idiom: split into per-field accessors:

```move
public fun total_locked<P,V>(v: &Vault<P,V>): u64 { v.total_locked }
public fun cap<P,V>(v: &Vault<P,V>): u64 { v.cap }
// etc
```

Frontend already reads via `getObject` json directly so we wouldn't lose anything. Worth doing if audit feedback requests it; defer otherwise.

### F7. No `entry` qualifier on any public function
All entry points are `public fun ...` (composable in PTBs). This is correct for our use case — none consume `&Random` so the `entry`-only-for-randomness rule doesn't apply. **Document this explicitly in a top-of-module comment** so the auditor doesn't have to derive the rationale themselves:

```move
// Visibility note: every public entry is `public`, not `entry`. None of these
// functions consume `&Random`, so the entry-only-for-randomness rule from
// the Sui security best-practices doesn't apply. PTB composability is
// intentional (claim+top_up in one tx, etc).
```

### F8. Hardcoded `MAX_ACTIVE_CAMPAIGNS = 5`
**Line:** 77.

Document the rationale (gas predictability for `claim_rewards` walking dynamic fields). Note that bumping it requires a contract upgrade. Currently no admin lever to raise it — that's the safe choice but should be explicit.

### F9. No invariant docstrings on the core accounting fields
**Lines:** 86-97 (`RewardPool`).

The math is correct but auditors love invariants spelled out next to fields. Suggested additions:

```move
public struct RewardPool<phantom T> has store {
    // INVARIANT: balance ≥ effective_balance + total_unclaimed_pending.
    // Physical reserve: decreases only on claim, never on emission update.
    balance: Balance<T>,
    // INVARIANT: 0 ≤ effective_balance ≤ balance.
    // Available-for-emission balance. Decreases each update by emitted.
    effective_balance: u64,
    // INVARIANT: monotonically non-decreasing across update_single_pool calls.
    // Sum over time of (emitted × ACC_PRECISION) / total_weight at each update.
    acc_reward_per_share: u128,
    // INVARIANT: monotonically non-decreasing.
    last_update_ms: u64,
    // INVARIANT: ≤ initial_amount (campaigns) or ≤ cumulative seeded (pool 1/2).
    total_distributed: u64,
}
```

### F10. Document overflow analysis explicitly
**Around line 56-58 (existing ACC_PRECISION constant).**

Current comment: "Sufficient headroom against u128 overflow given total weight bounded by 30B SUITRUMP × 2.0x and pool balances bounded by total mint revenue + farm fees."

Make it concrete:

```move
// Worst-case product: pool_balance × ACC_PRECISION / total_weight stays in u128.
// Pool 2 max: 100M SUITRUMP × 1e6 = 1e14 raw. ACC_PRECISION = 1e12.
// 1e14 × 1e12 = 1e26. u128 max ≈ 3.4e38. ~12 orders of magnitude headroom.
// Acc grows monotonically over the contract's lifetime; at the configured
// distribution window of 90 days, full pool drain caps acc at:
//   max_acc = (pool_balance × ACC_PRECISION) / min_total_weight
// where min_total_weight is bounded by MIN_STAKE_NEW × 1.0x = 1e10.
// max_acc ≤ 1e14 × 1e12 / 1e10 = 1e16. Safe. Multiplying by max weight
// (60M × 2.0x × 1e6 = 1.2e14) gives 1.2e30. Safe.
```

### F11. Move 2024 `#[error]` const upgrade
Modern Move 2024 supports rich error messages via `#[error] const EFoo: vector<u8> = b"…"`. Currently we use plain `u64` consts. **Defer** — this is mass refactor and the existing codes work. Do as a v2 polish pass after launch.

---

## What's strong (do not regress)

- **Min stake = 10k SUITRUMP** (line 47). Defends against the 1-MIST staking-pool exploit class (Mysten's own bug, fixed in PR #9961). Anything below this opens rounding-error attacks on the pool token exchange rate.
- **Position is `key` only** (line 119), `owner == sender` checked on every mutation (502, 554, 570, 632, 648, 665). Belt + braces — even though soulbound prevents transfer, the explicit owner check would catch a future ability change.
- **Hardcoded multipliers** (line 66-69) — no admin attack vector. Changing rates requires upgrade + migration.
- **Clamp-to-physical-balance** in `settle_rewards` (727-731) and `finalize_unstake` (824-825) — defense against accumulator/balance drift causing overdraw.
- **`update_single_pool` clamps `emitted` to `effective_balance`** (line 692-693) before subtracting — prevents underflow when `dt_ms` exceeds the distribution window (e.g. long pause).
- **Pool drain math is asymptotic** by design (`emission_rate = effective_balance / 90d`) — pool can never empty, no first-mover-wins / griefing edge cases.
- **Sweep gated on `expiry_ms`** (line 400). No force-close path. Cannot rug stakers.
- **Soulbound `key`-only position** prevents the transfer-position-after-stake attack vector that bit other staking protocols.
- **All admin functions take `_admin: &AdminCap`** by reference (lines 252, 287, 297, 307, 328, 351, 390). Capability pattern, not address whitelist. Composable + safe.
- **Self-stabilising emission** is the right primitive — no admin emission-rate-setting attack surface.
- **68 tests passing** — broad coverage of stake / top-up / unstake (all variants) / pool seed / cap grandfathering / auto-convert / pending-vs-claim consistency / multi-day emission rates.

---

## Test gaps to add before audit

Looking at what's in `tests/single_stake_tests.move`:

| Currently covered | Yes |
|---|---|
| Stake basic + 5 edge cases (paused, cap, non-gotchi, bad lock, min) | ✓ |
| Seed pool 1/2 + zero amount | ✓ |
| Single-staker emission over 90d | ✓ |
| Lock-multiplier proportional share | ✓ |
| Emission rate decay as pool drains | ✓ |
| Top-up basic + below-min-aborts | ✓ |
| Unstake at maturity (success + before-lock-aborts) | ✓ |
| Unstake flexible (success + on-locked-aborts) | ✓ |
| Unstake early (success + on-flex-aborts + after-lock-aborts) | ✓ |
| Auto-convert at lock end | ✓ |
| Pending-rewards-sim matches actual claim | ✓ |
| Set vault cap grandfathers existing stakers | ✓ |

| Gap | Status | Test name |
|---|---|---|
| Multi-staker proportional share | ✅ ADDED | `test_multi_staker_pool2_emission_scales_with_weight` |
| Pool 3 happy path (create + claim + sweep) | ✅ ADDED | `test_campaign_create_claim_sweep_full_lifecycle` |
| Pool 3 sweep before expiry aborts | ✅ ADDED | `test_sweep_before_expiry_aborts` |
| Pool 3 MAX_ACTIVE_CAMPAIGNS limit | ✅ ADDED | `test_create_campaign_aborts_at_max_active` |
| Pool 3 finalized campaign claim residual | ✅ ADDED | `test_finalized_campaign_still_claimable_for_residual` |
| Top-up auto-convert post lock end | ✅ COVERED | F13 regression test asserts `converted=true` after top_up |
| total_weight invariant after early-unstake | ✅ ADDED | `test_total_weight_decreases_correctly_after_early_unstake` |
| Empty-pool emission no-op | ✅ ADDED | `test_empty_pool_emission_is_zero_no_abort` |
| Pool seed during paused vault | ✅ ADDED | `test_seed_pool_succeeds_when_vault_paused` |
| Overflow guard | ✅ ADDED | `test_overflow_smoke_max_stake_max_pool` (100M stake × 100M pool × 90d window) |

---

## Pre-audit checklist (in priority order)

1. **F1**: Refactor finalize_unstake/settle_rewards duplication (P0). ✅ DONE
2. **F2**: Remove dead entitlement vars in auto_convert_if_due (or implement). ✅ DONE
3. **F3-F5**: Polish — unused params, single-line wrappers, event timestamp consistency. ✅ DONE
4. **F7**: Add visibility-rationale comment at module top. ✅ DONE
5. **F9-F10**: Add invariant docstrings + concrete overflow analysis. ✅ DONE
6. **F12-F13**: NEW findings discovered during refactor — auto-convert reward forfeiture + top-up multiplier bug. ✅ DONE (with regression tests)
7. **Test gaps**: 10 missing test cases. ✅ DONE (9 added, 1 covered by F13 test)
8. **F6, F8, F11**: Defer — auditor may or may not flag.
9. **Internal review of diff** before commissioning audit.
10. Commission audit. Pick from: OtterSec, Zellic, Hacken, Movebit (the firms that have audited Sui-system / DeepBook / Walrus).

---

## What's *not* in scope for this review

- `mint.move` — separate audit-readiness review, smaller surface, likely cleaner. Recommend reviewing as a follow-up before mainnet but lower priority.
- `trumpagotchi.move` — already audited via 9th deployment cycle; not in single-stake audit scope.
- Frontend-side reward debt math (we already verified parity with on-chain in dev preview QA).

---

## When to start the audit clock

After F1-F5, F7, F9-F10 + the test gap fills land. ETA: 1-2 dev days.
After audit: address findings, redeploy single_stake module via package upgrade (no full redeploy needed since module is already in trumpagotchi v4 package). Transfer AdminCap to mainnet keeper wallet. Set `set_vault_cap_active(false)` until ready.
