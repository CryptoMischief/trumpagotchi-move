#!/usr/bin/env bash
# End-to-end testnet smoke test for the trumpagotchi package.
#
# Uses the deployer (trumpagotchi-testnet) as both admin and end-user. Mints a
# Trumpagotchi via admin_mint, issues a cosmetic of each kind, equips and
# unequips each, then verifies state via gRPC reads.

set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
DEP="$REPO/deployments/testnet.json"

PKG=$(jq -r .packageId "$DEP")
ADMIN_CAP=$(jq -r .adminCap "$DEP")
DEPLOYER=$(jq -r .deployer "$DEP")
MINT_CFG=$(jq -r .mintConfig "$DEP")
BUY_BURN=$(jq -r .mintAddresses.buyBurn "$DEP")
LP_ADDR=$(jq -r .mintAddresses.lp "$DEP")
VICTORY_ADDR=$(jq -r .mintAddresses.victoryVault "$DEP")
PRIZE_ADDR=$(jq -r .mintAddresses.prizePool "$DEP")
DEV_ADDR=$(jq -r .mintAddresses.dev "$DEP")
CLOCK=0x6
GAS=100000000

# Sanity: env + active address. Restored at exit regardless of outcome.
ORIG_ENV=$(sui client active-env)
ORIG_ADDR=$(sui client active-address)
restore() {
  sui client switch --env "$ORIG_ENV" >/dev/null 2>&1 || true
  sui client switch --address "$ORIG_ADDR" >/dev/null 2>&1 || true
}
trap restore EXIT

sui client switch --env testnet >/dev/null
sui client switch --address trumpagotchi-testnet >/dev/null

echo "package:  $PKG"
echo "admin:    $ADMIN_CAP"
echo "deployer: $DEPLOYER"
echo

# Helper: call function, return the object id of the first newly-created
# object whose type contains the given substring.
call_and_grab() {
  local fn=$1; shift
  local match=$1; shift
  local out
  out=$(sui client call --package "$PKG" --module trumpagotchi --function "$fn" \
    --args "$@" --gas-budget "$GAS" --json 2>&1)
  echo "$out" | jq -r --arg m "$match" '
    .objectChanges[] | select(.type=="created" and (.objectType | contains($m))) | .objectId
  ' | head -1
}

call_only() {
  local fn=$1; shift
  local out
  out=$(sui client call --package "$PKG" --module trumpagotchi --function "$fn" \
    --args "$@" --gas-budget "$GAS" --json 2>&1)
  local status
  status=$(echo "$out" | jq -r '.effects.status.status // "unknown"' 2>/dev/null || echo "parse_fail")
  if [[ "$status" != "success" ]]; then
    echo "CALL FAILED: $fn" >&2
    echo "$out" | tail -40 >&2
    exit 1
  fi
}

# Read parsed object content via JSON-RPC (the new CLI's `--json` returns BCS
# bytes for object contents, which is harder to parse than RPC's parsed shape).
read_object_json() {
  local id=$1
  curl -s -X POST https://fullnode.testnet.sui.io:443 \
    -H 'Content-Type: application/json' \
    -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"sui_getObject\",\"params\":[\"$id\",{\"showContent\":true,\"showOwner\":true}]}"
}

# ── Step 1: mint a Trumpagotchi to self ───────────────────────────────────
echo "[1/8] admin_mint -> trumpagotchi-testnet"
NFT_ID=$(call_and_grab admin_mint "::trumpagotchi::Trumpagotchi" \
  "$ADMIN_CAP" "$DEPLOYER" "$CLOCK")
echo "      nft: $NFT_ID"

# ── Step 2-4: issue one cosmetic of each kind ─────────────────────────────
echo "[2/8] admin_issue_cosmetic outfit (kind=1, tier_gate=1)"
OUTFIT_ID=$(call_and_grab admin_issue_cosmetic "::trumpagotchi::Cosmetic" \
  "$ADMIN_CAP" 1 "tier04_tremendous" 1 "$DEPLOYER")
echo "      outfit: $OUTFIT_ID"

echo "[3/8] admin_issue_cosmetic background (kind=2, tier_gate=1)"
BG_ID=$(call_and_grab admin_issue_cosmetic "::trumpagotchi::Cosmetic" \
  "$ADMIN_CAP" 2 "ballroom" 1 "$DEPLOYER")
echo "      background: $BG_ID"

echo "[4/8] admin_issue_cosmetic shell (kind=3, tier_gate=1)"
SHELL_ID=$(call_and_grab admin_issue_cosmetic "::trumpagotchi::Cosmetic" \
  "$ADMIN_CAP" 3 "classic_red" 1 "$DEPLOYER")
echo "      shell: $SHELL_ID"

# ── Step 5: equip all three ───────────────────────────────────────────────
echo "[5/8] equip_outfit + equip_background + equip_shell (current_tier=5)"
call_only equip_outfit     "$NFT_ID" "$OUTFIT_ID" 5 "$CLOCK"
call_only equip_background "$NFT_ID" "$BG_ID"     5 "$CLOCK"
call_only equip_shell      "$NFT_ID" "$SHELL_ID"  5 "$CLOCK"

# ── Step 6: read NFT state, assert all three slots filled ─────────────────
echo "[6/8] verify equipped state via JSON-RPC sui_getObject"
STATE=$(read_object_json "$NFT_ID")
EQ_O=$(echo "$STATE" | jq -r '.result.data.content.fields.equipped_outfit // empty')
EQ_B=$(echo "$STATE" | jq -r '.result.data.content.fields.equipped_background // empty')
EQ_S=$(echo "$STATE" | jq -r '.result.data.content.fields.equipped_shell // empty')
echo "      equipped_outfit:     $EQ_O"
echo "      equipped_background: $EQ_B"
echo "      equipped_shell:      $EQ_S"

assert_eq() {
  if [[ "$1" != "$2" ]]; then
    echo "ASSERT FAILED: expected $2, got $1" >&2
    exit 1
  fi
}
assert_eq "$EQ_O" "$OUTFIT_ID"
assert_eq "$EQ_B" "$BG_ID"
assert_eq "$EQ_S" "$SHELL_ID"
echo "      ✓ all three slots match expected ids"

# ── Step 7: unequip all three ─────────────────────────────────────────────
echo "[7/8] unequip_outfit + unequip_background + unequip_shell"
call_only unequip_outfit     "$NFT_ID" "$CLOCK"
call_only unequip_background "$NFT_ID" "$CLOCK"
call_only unequip_shell      "$NFT_ID" "$CLOCK"

# ── Step 8: re-read, assert all slots empty + cosmetics back in wallet ────
echo "[8/8] verify post-unequip state"
STATE=$(read_object_json "$NFT_ID")
EQ_O=$(echo "$STATE" | jq -r '.result.data.content.fields.equipped_outfit // "none" | if . == null then "none" else . end')
EQ_B=$(echo "$STATE" | jq -r '.result.data.content.fields.equipped_background // "none" | if . == null then "none" else . end')
EQ_S=$(echo "$STATE" | jq -r '.result.data.content.fields.equipped_shell // "none" | if . == null then "none" else . end')
assert_eq "$EQ_O" "none"
assert_eq "$EQ_B" "none"
assert_eq "$EQ_S" "none"
echo "      ✓ all slots cleared"

OUTFIT_OWNER=$(read_object_json "$OUTFIT_ID" | jq -r '.result.data.owner.AddressOwner // "shared/missing"')
BG_OWNER=$(read_object_json "$BG_ID"         | jq -r '.result.data.owner.AddressOwner // "shared/missing"')
SHELL_OWNER=$(read_object_json "$SHELL_ID"   | jq -r '.result.data.owner.AddressOwner // "shared/missing"')
assert_eq "$OUTFIT_OWNER" "$DEPLOYER"
assert_eq "$BG_OWNER"     "$DEPLOYER"
assert_eq "$SHELL_OWNER"  "$DEPLOYER"
echo "      ✓ all three cosmetics returned to deployer wallet"

echo
echo "[Mint flow] public mint with referrer + revenue split verification"

# Snapshot SUI balance at each destination, then mint, then diff. We compare
# deltas not absolutes because the deployer address is itself the receiver
# of multiple buckets if any setup sent SUI there.
read_sui_balance() {
  local addr=$1
  curl -s -X POST https://fullnode.testnet.sui.io:443 \
    -H 'Content-Type: application/json' \
    -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"suix_getBalance\",\"params\":[\"$addr\",\"0x2::sui::SUI\"]}" \
    | jq -r '.result.totalBalance // "0"'
}

# Read live config rather than hardcoding so smoke tolerates any
# admin set_pricing override (e.g. lowered to fit faucet budget).
CFG_STATE=$(curl -s -X POST https://fullnode.testnet.sui.io:443 \
  -H 'Content-Type: application/json' \
  -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"sui_getObject\",\"params\":[\"$MINT_CFG\",{\"showContent\":true}]}")
BASE_PRICE=$(echo "$CFG_STATE" | jq -r '.result.data.content.fields.base_price_mist')
TOTAL_MINTED=$(echo "$CFG_STATE" | jq -r '.result.data.content.fields.total_minted')
PRICE_STEP=$(echo "$CFG_STATE" | jq -r '.result.data.content.fields.price_step_mist')
STEP_COUNT=$(echo "$CFG_STATE" | jq -r '.result.data.content.fields.price_step_count')
PRICE_CAP=$(echo "$CFG_STATE" | jq -r '.result.data.content.fields.price_cap_mist')
STEP_NUM=$(( TOTAL_MINTED / STEP_COUNT ))
PRICE_MIST=$(( BASE_PRICE + STEP_NUM * PRICE_STEP ))
if (( PRICE_MIST > PRICE_CAP )); then PRICE_MIST=$PRICE_CAP; fi
echo "      live price: $PRICE_MIST mist (mint #$((TOTAL_MINTED + 1)))"
REFERRER=0x000000000000000000000000000000000000000000000000000000000000beef

BB_BEFORE=$(read_sui_balance "$BUY_BURN")
LP_BEFORE=$(read_sui_balance "$LP_ADDR")
VT_BEFORE=$(read_sui_balance "$VICTORY_ADDR")
PZ_BEFORE=$(read_sui_balance "$PRIZE_ADDR")
RF_BEFORE=$(read_sui_balance "$REFERRER")
DV_BEFORE=$(read_sui_balance "$DEV_ADDR")

# Need a Coin<SUI> of exactly the price. Split from gas first.
echo "      splitting payment coin of $PRICE_MIST mist..."
SPLIT_OUT=$(sui client split-coin --coin-id "$(sui client gas --json | jq -r '.[0].gasCoinId')" \
  --amounts "$PRICE_MIST" --gas-budget "$GAS" --json 2>&1)
PAY_COIN=$(echo "$SPLIT_OUT" | jq -r '.objectChanges[] | select(.type=="created" and (.objectType | contains("0x2::coin::Coin"))) | .objectId' | head -1)
echo "      pay coin: $PAY_COIN"

echo "      calling mint::mint with referrer..."
MINT_OUT=$(sui client call --package "$PKG" --module mint --function mint \
  --args "$MINT_CFG" "$PAY_COIN" "[$REFERRER]" "$CLOCK" \
  --gas-budget "$GAS" --json 2>&1)
MINT_STATUS=$(echo "$MINT_OUT" | jq -r '.effects.status.status // "unknown"')
if [[ "$MINT_STATUS" != "success" ]]; then
  echo "MINT CALL FAILED" >&2
  echo "$MINT_OUT" | tail -40 >&2
  exit 1
fi
NEW_NFT=$(echo "$MINT_OUT" | jq -r '.objectChanges[] | select(.type=="created" and (.objectType | contains("::trumpagotchi::Trumpagotchi"))) | .objectId' | head -1)
echo "      ✓ minted nft: $NEW_NFT"

# Verify splits via balance deltas. Expected at 20 SUI price:
#   25%   buy_burn = 5_000_000_000
#   20%   lp       = 4_000_000_000
#   30%   victory  = 6_000_000_000
#   10%   prize    = 2_000_000_000
#   2.5%  ref      = 500_000_000
#   12.5% dev      = 2_500_000_000

BB_AFTER=$(read_sui_balance "$BUY_BURN")
LP_AFTER=$(read_sui_balance "$LP_ADDR")
VT_AFTER=$(read_sui_balance "$VICTORY_ADDR")
PZ_AFTER=$(read_sui_balance "$PRIZE_ADDR")
RF_AFTER=$(read_sui_balance "$REFERRER")
DV_AFTER=$(read_sui_balance "$DEV_ADDR")

assert_delta() {
  local name=$1 before=$2 after=$3 expected=$4
  local delta=$(( after - before ))
  if [[ "$delta" != "$expected" ]]; then
    echo "ASSERT FAILED ($name): expected delta $expected, got $delta (before=$before after=$after)" >&2
    exit 1
  fi
  echo "      ✓ $name +$delta mist"
}

# Derive expected splits from live price (BPS in mint.move).
EXP_BB=$(( PRICE_MIST * 2500 / 10000 ))
EXP_LP=$(( PRICE_MIST * 2000 / 10000 ))
EXP_VT=$(( PRICE_MIST * 3000 / 10000 ))
EXP_PZ=$(( PRICE_MIST * 1000 / 10000 ))
EXP_RF=$(( PRICE_MIST * 250  / 10000 ))
EXP_DV=$(( PRICE_MIST * 1250 / 10000 ))

assert_delta buy_burn "$BB_BEFORE" "$BB_AFTER" "$EXP_BB"
assert_delta lp       "$LP_BEFORE" "$LP_AFTER" "$EXP_LP"
assert_delta victory  "$VT_BEFORE" "$VT_AFTER" "$EXP_VT"
assert_delta prize    "$PZ_BEFORE" "$PZ_AFTER" "$EXP_PZ"
assert_delta referrer "$RF_BEFORE" "$RF_AFTER" "$EXP_RF"
assert_delta dev      "$DV_BEFORE" "$DV_AFTER" "$EXP_DV"

echo
echo "SMOKE TEST PASSED"
echo "  admin-mint nft:     $NFT_ID"
echo "  outfit:             $OUTFIT_ID"
echo "  background:         $BG_ID"
echo "  shell:              $SHELL_ID"
echo "  public-mint nft:    $NEW_NFT"
echo "  payment digest:     $(echo "$MINT_OUT" | jq -r .digest)"
