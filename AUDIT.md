# SUITRUMP — Audit Handoff

**Contract:** `single_stake.move` (single-staking vault with 3 reward pools)
**Build:** v13 (final audit commission build)
**Branch:** `phase2/single-stake-vault`
**Testnet deployment:** `0x282c387f1e77129ead172b088e9e27c1acfbbe72c45f056ecb90c5c277edc955` (latest); type-anchor home `0xf8f981bb7bf1b6b649ee9744adbfd603e352b5886a1422c7073135fa8a4f23a2`

---

## TL;DR for the auditor

The Move package under audit is a **single-token staking vault** for the SUITRUMP token, distributing three concurrent reward streams to stakers:

- **Pool 1 (VICTORY):** native protocol reward, self-stabilising emission (`emission_rate = effective_balance / 90d`).
- **Pool 2 (SUITRUMP):** native protocol reward, same self-stabilising rule. Receives early-unstake principal forfeits (50%).
- **Pool 3 (Partner campaigns):** any third-party token, **linear** emission (`emission_rate = initial_amount / campaign_duration`). Up to 5 concurrent campaigns. Each campaign expires by its own clock.

Positions are **soulbound** (`StakePosition` has only `key`, no `store`). Stakers select a lock kind at stake time — flexible / 30d / 90d / 180d — which sets a weight multiplier (1.0× / 1.25× / 1.6× / 2.0×) used as the share denominator across all three pools. After lock end, positions auto-convert to flexible weight on the next claim/settle.

The bulk of the contract is straight-forward MasterChef accumulator math with `ACC_PRECISION = 1e12`. **No oracles, no admin price feed, no upgradable storage layouts after launch.** The single non-obvious piece is the per-campaign reward-debt initialisation (F15) and the residual-recovery flow (sweep + 30-day grace + admin reclaim), both detailed below.

The contract is ~1100 lines. **96 unit tests pass at canonical durations** (`sui move test`).

---

## Build & test

```bash
cd trumpagotchi-move
sui move build       # builds the package
sui move test        # runs all 96 tests, must report "Test result: OK"
```

Tests live in `tests/single_stake_tests.move` (96 staking tests) plus shop/mint/trumpagotchi suites that test adjacent modules. The single_stake module is the audit surface; the other modules (`shop`, `mint`, `trumpagotchi`) are NFT-side and outside scope.

Dependencies: Sui framework (testnet branch), kiosk apps (for the unrelated cosmetic module).

---

## Module map

| File | Surface | Audit scope |
|---|---|---|
| `sources/single_stake.move` | Vault, StakePosition, Campaign, all stake/claim/unstake/sweep paths | **YES — primary** |
| `sources/trumpagotchi.move` | Soulbound Trumpagotchi NFT, TierRegistry (`has_entry` gate referenced by stake) | Adjacent — `has_entry` is the only call into it from single_stake |
| `sources/mint.move` | Trumpagotchi mint pricing | Out of scope |
| `sources/shop.move` | Cosmetic NFT shop | Out of scope |

---

## Capability & authorisation model

| Capability | Holder | Powers |
|---|---|---|
| `AdminCap` | Deployer at publish, transferable | `seed_pool1`, `seed_pool2`, `set_vault_cap`, `set_vault_cap_active`, `create_campaign`, `sweep_expired_campaign`, `recover_stranded_residual` |
| Position owner (`position.owner` field, captured at stake time) | Address that called `stake`/`stake_non_entry` | `top_up`, `claim_rewards`, `claim_campaign`, `init_campaign_debt`, `unstake_at_maturity`, `unstake_flexible`, `unstake_early` — all gated by `assert!(position.owner == tx_context::sender(ctx))` |
| Anyone | — | `transfer_position_to_owner` (no auth — destination is always the stored `position.owner`, no redirection possible) |

`StakePosition` is `key`-only (soulbound). The only way the position can move addresses is via `transfer_position_to_owner`, which always routes to `position.owner`. There is no `key + store` shadow type, so neither Sui's PTB `TransferObjects` command nor `transfer::public_transfer` can ever consume a position.

---

## State machine — campaign lifecycle

```
   create_campaign           expiry_ms reached            sweep_expired_campaign           +30d grace
   ─────────►   ACTIVE   ──────────────────────►   EXPIRED   ──────────────────────►  FINALIZED  ──────────►  RECOVERABLE
                  │                                   │                                    │
                  │                                   │                                    └─► admin reclaim via
                  │                                   │                                        recover_stranded_residual
                  ▼                                   ▼
            stakers claim_campaign            stakers can still claim
            (legitimate emissions)            their residual share
                                              (F14 floor preserves it)
```

`active_campaign_count` decrements only at `sweep_expired_campaign`. After that, `campaign.finalized = true`; emissions are frozen (no more `update_campaign_pool` ticks); existing positions can still call `claim_campaign` to drain F14-preserved residual. After `expiry_ms + RECOVERY_GRACE_MS` (30 days), admin can call `recover_stranded_residual` to reclaim whatever balance hasn't been claimed.

---

## All audit findings & fixes (F1 → F15)

This section tracks every issue surfaced during pre-audit review and the version in which it shipped. The full source-level review notes that produced this list live in `AUDIT_READINESS.md`.

| ID | Severity | Status | Description |
|---|---|---|---|
| F1 | P0 (DRY) | ✅ v5 | Extracted `pay_pending` helper so `settle_rewards` and `finalize_unstake` share Pool 1 / Pool 2 payout math. |
| F2 | P1 | ✅ v5 | Removed dead entitlement variables in `auto_convert_if_due`. |
| F3 | P1 | ✅ v5 | Renamed `estimated_unclaimed` → `unclaimed_emitted_floor` with explicit invariant comment. |
| F4 | P1 | ✅ v5 | Inlined the trivial `update_campaign_pool` wrapper that existed in v4. (Note: v11 reintroduces a different `update_campaign_pool` with linear-release math — not the same function.) |
| F5 | P1 | ✅ v5 | `settle_rewards` now takes `now: u64` so all event timestamps in one tx are consistent. |
| F6 / F8 / F11 | P2 polish | DEFERRED | Cosmetic naming + comment polish, no behaviour change. Targeted post-launch. |
| F7 | P1 | ✅ v5 | Module-top documentation on visibility / capability / soulbound rationale. |
| F9 | P1 | ✅ v5 | `RewardPool` field invariants documented (monotonicity of `last_update_ms`, etc.). |
| F10 | P1 | ✅ v5 | Concrete overflow analysis on `ACC_PRECISION` (1e12) for worst-case Pool 2 cap × 2.0× weight. |
| F12 | P0 | ✅ v5 | `auto_convert_if_due` now pays OLD-weight pending via transfer-to-owner **before** resetting weight + debt. Pre-fix the lock-period accruals were forfeited on first claim post-lock-end. |
| F13 | P0 | ✅ v5 | `top_up` uses `MULT_FLEXIBLE_BPS` if `position.converted == true`. Pre-fix a converted position's top-up silently re-applied the original lock multiplier, breaking the accumulator invariant. |
| F14 | P0 | ✅ v6 | `unclaimed_emitted_floor` returns `bal` when `bal ≤ effective`. Pre-fix the dual `total_distributed >= bal` + `else 0` branches let `sweep_expired_campaign` drain legitimate residual under rounding drift. Tradeoff: zero-staker campaigns become stranded (closed by F-recover in v13, see below). |
| F15a | P0 | ✅ v8 | `claim_campaign` lazy-init now branches on `position.stake_ms vs campaign.start_ms`. Predates campaign → `prior_debt = 0` (entitled to full window). Joined after → `prior_debt = current entitlement` (no historical drain). Pre-fix a freshly-staked position could harvest an arbitrary pre-existing campaign's accumulated emissions. |
| F15b | P1 | ✅ v9 | `init_campaign_debt<P, V, T>` admin/owner entry to explicitly lock prior_debt at stake time. Idempotent. Closes the "between-stake-and-first-claim" forfeit window. |
| Composable stake | (architectural) | ✅ v10 | Split `stake` into `stake_non_entry` (returns `StakePosition` by value) + `transfer_position_to_owner` (in-module soulbound finaliser). Existing `stake` becomes a wrapper, signature unchanged. Enables single-PTB stake + `init_campaign_debt` × N + transfer. Pattern from Sui's own `request_add_stake_non_entry`. |
| Pool 3 linear release | (design correction) | ✅ v11 | Partner campaigns no longer share Pool 1/2's self-stabilising rule. New helper `update_campaign_pool` emits at `initial_amount / campaign_duration_ms` — partner contribution X over duration D drains ~X over D. The self-stabilising rule is correct for the protocol's deep core pools (asymptotic decay, never empties) but under-emits for bounded partner contributions. |
| **F-recover (stranded residual)** | P1 | ✅ v13 | New `recover_stranded_residual<P, V, T>` admin entry. After `expiry_ms + 30 days`, admin can reclaim any partner-token balance still in a finalised campaign. Closes the leakage hole created by F14 + unstake-without-bundle-include-campaign race. Requires `campaign.finalized == true` (sweep must run first). |
| F16 | (declined) | DECLINED | "First-staker forfeit" where the very first position into a campaign with `total_weight = 0 history` forfeits the empty-window emissions. Declined per product decision: at mainnet launch the vault will already have Pool 1/2 stakers locked in before any partner campaign is added, so the condition never fires. Don't reintroduce. |

---

## Threat model the auditor may want to focus on

### Reward-pool drain attacks
- **Historical-emission harvesting via fresh stake** (F15a). Now blocked by stake_ms vs campaign.start_ms branch.
- **Late-init forfeit recovery via new stake** (F15b). Closed via `init_campaign_debt` + composable stake PTB.
- **Stranded partner residual** (F-recover). Closed by 30-day-grace admin reclaim.

### Accumulator overflow / precision
- `ACC_PRECISION = 1e12`. Worst case: Pool 2 cap 100M × 2.0× weight = 2e14 raw × 1e12 = 2e26. Comfortably inside u128 (`max ≈ 3.4e38`). Documented in module-top comment.
- All entitlement multiplications go through u128; the final cast back to u64 is bounded by physical balance (`payout = min(claimable, pool_bal)`).

### Rounding & dust
- F14 floor preserves emissions-credited-to-acc that no position has yet claimed.
- After F-recover, dust remaining post-grace is also reclaimable.
- Worst case for a staker: a fraction of a unit of rounding loss per claim.

### Self-stabilising emission edge case
- With discrete updates, multiple full windows of inactivity can drain Pool 1/2 to dust (because `emit = min(effective × dt/W, effective)`). Mathematically asymptotic, but reaches numerical zero in practice. Acceptable: positions are still rewarded with whatever's left; the protocol can re-seed via `seed_pool1` / `seed_pool2`.

### Admin powers
- All admin entries are gated by `&AdminCap`. AdminCap is address-owned (transferable). Recommended post-launch: rotate to a multisig.
- Admin can `set_vault_cap` (raise or lower), but lowering is **grandfathered** — existing positions are not unwound. `test_set_vault_cap_lowers_cap_grandfathers_existing_stakers` covers this.
- Admin cannot mutate user-owned `StakePosition` objects (Sui ownership). The only admin paths that touch a position are pool emission updates against `vault.total_weight`, which are aggregate not per-position.

### Soulbound invariant
- `StakePosition` is `key`-only. The only function that calls `transfer::transfer` on it is `transfer_position_to_owner`, which always routes to `position.owner`. There is no path by which a position can land at a non-owner address.

---

## Test coverage (96 tests, all passing)

Run with `sui move test` from the package root. Final tally:

| Module | Tests |
|---|---|
| `single_stake_tests` | 54 |
| `trumpagotchi_tests` | 20 |
| `shop_tests` | 13 |
| `mint_tests` | 9 |
| **Total** | **96** |

`single_stake_tests` is the primary audit-relevant suite. Tests grouped by surface:

### Vault setup & access control
- `test_setup_creates_shared_vault_with_initial_state`
- `test_stake_fails_for_non_gotchi_holder` (abort)
- `test_stake_fails_below_min_stake` (abort)
- `test_stake_fails_invalid_lock_kind` (abort)
- `test_stake_fails_when_paused` (abort)
- `test_stake_fails_when_cap_exceeded` (abort)
- `test_set_vault_cap_lowers_cap_grandfathers_existing_stakers`
- `test_stake_exactly_at_cap_succeeds`
- `test_raising_cap_unblocks_new_stakes`
- `test_stake_blocked_at_cap_succeeds_after_raise`

### Stake state & weight math
- `test_stake_creates_position_with_correct_weight_and_state`
- `test_stake_flexible_has_zero_unlock_ms_and_1x_weight`
- `test_lock_multiplier_share_is_2x_180d_vs_flexible`
- `test_top_up_adds_principal_and_recomputes_weight`
- `test_top_up_below_min_aborts` (abort)

### Pool seeding
- `test_seed_pool1_increases_balance_and_effective`
- `test_seed_pool2_increases_balance_and_effective`
- `test_seed_pool_zero_amount_aborts` (abort)
- `test_seed_pool_succeeds_when_vault_paused`

### Emission & claim math
- `test_single_staker_emission_matches_balance_over_90d`
- `test_emission_rate_decreases_as_pool_drains` (self-stabilising rule)
- `test_multi_staker_pool2_emission_scales_with_weight`
- `test_pending_rewards_simulation_matches_subsequent_claim`
- `test_empty_pool_emission_is_zero_no_abort`
- `test_overflow_smoke_max_stake_max_pool` (100M × 2.0× weight, u128 acc bounds)

### Unstake paths
- `test_unstake_at_maturity_returns_full_principal_plus_rewards`
- `test_unstake_at_maturity_before_lock_end_aborts` (abort)
- `test_unstake_flexible_returns_full_principal_no_penalty`
- `test_unstake_flexible_on_locked_position_aborts` (abort)
- `test_unstake_early_returns_50pct_principal_and_full_rewards`
- `test_unstake_early_on_flexible_aborts` (abort)
- `test_unstake_early_after_lock_end_aborts` (abort)
- `test_total_weight_decreases_correctly_after_early_unstake`

### Auto-convert at lock end (F12)
- `test_auto_convert_drops_weight_to_1x_at_lock_end_on_claim`
- `test_f12_auto_convert_pays_out_pre_conversion_pending`
- `test_f12_auto_convert_pays_pending_for_30d_lock`
- `test_f12_auto_convert_pays_pending_for_90d_lock`
- `test_f13_top_up_after_auto_convert_uses_flexible_multiplier`

### Pool 3 partner campaigns
- `test_campaign_create_claim_sweep_full_lifecycle`
- `test_sweep_before_expiry_aborts` (abort)
- `test_create_campaign_aborts_at_max_active` (abort)
- `test_finalized_campaign_still_claimable_for_residual`
- `test_v11_campaign_linear_release_fully_emits` (linear rule)
- `test_v11_sweep_after_linear_release_drains_pool`

### F14 floor (sweep preserves residual)
- `test_f14_sweep_preserves_residual_when_balance_below_effective`

### F15 historical-drain protection
- `test_f15_late_joiner_cannot_drain_historical_emissions`
- `test_f15_position_predating_campaign_claims_full_share`
- `test_f15_init_campaign_debt_locks_entry_point`
- `test_f15_init_campaign_debt_is_idempotent`

### Composable stake (v10) + soulbound transfer
- `test_composable_stake_with_init_chain` (single-PTB stake + init + transfer)
- `test_transfer_position_to_owner_routes_correctly`

### Stranded-residual recovery (v13)
- `test_recover_stranded_residual_after_grace` (happy path, recovers preserved residual)
- `test_recover_stranded_aborts_before_grace` (abort)
- `test_recover_stranded_aborts_when_not_finalized` (abort)

### Adjacent suites
- `trumpagotchi_tests`: 20 tests over the soulbound NFT module — minting, tier registry, decay grace, equip flows.
- `shop_tests`: 13 tests over cosmetic shop — purchase, restock, kind validation.
- `mint_tests`: 9 tests over mint pricing curve.

The latter three are adjacent and out of primary audit scope.

---

## What's deliberately out of scope

- `mint.move`, `shop.move`, `trumpagotchi.move` — adjacent NFT modules. `single_stake` only depends on `trumpagotchi::has_entry` (a read against `TierRegistry`).
- Frontend (Next.js / TypeScript) — same logic mirrored client-side for UI display, but the on-chain contract is authoritative. Frontend bugs cannot affect contract security.
- Walrus storage / Display URLs — purely metadata, no on-chain economic effect.

---

## Reference deployment addresses (testnet)

| Object | ID |
|---|---|
| Package home (types anchor) | `0xf8f981bb7bf1b6b649ee9744adbfd603e352b5886a1422c7073135fa8a4f23a2` |
| Package latest (v13) | `0x282c387f1e77129ead172b088e9e27c1acfbbe72c45f056ecb90c5c277edc955` |
| Vault shared object | `0x3bd6fbcaba2067ea497da062fa50e5112ee8539b4ac149c0fffb6121a476236a` |
| AdminCap | `0xcadf5675eb658894a115c074a66d5dbce1088a61c9a22fed843521e7f1d6b6e2` |
| UpgradeCap | `0xfb8ac6193adff6a0c90cf6f9b4660151a0415ec7b3c6b72e1af8dcf540593948` |
| TierRegistry | `0x7a0b70cb0eea7cef7b658f88e3c75d20e01d115610baec86879537ad5fa88020` |
| Testnet SUITRUMP coin | `0x81a80ccd9b9de260d43521e8c8ea0e4f907a3d7a6eb223621c1dcad7e4fec6a9::suitrump::SUITRUMP` |
| Testnet VICTORY coin | `0x96057ed4a0ab215e71740c68d1e5fe34add6448d7a5595c229cf400b09e180e4::victory::VICTORY` |

Full deployment manifest: `deployments/testnet.json` (includes per-version upgrade notes from v1 → v13).

---

## Contact

GitHub: [@CryptoMischief](https://github.com/CryptoMischief)
Project: SUITRUMP / Mischief Finance
