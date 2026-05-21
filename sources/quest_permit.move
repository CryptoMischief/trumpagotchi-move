module trumpagotchi::quest_permit;

// Off-chain signed permit pattern for user-redeemed cosmetic claims (Track B
// — Quest Box). The admin keeper signs a BCS-encoded `CosmeticMintPermit`
// off-chain with an Ed25519 keypair whose public key is registered in the
// shared `KeyRegistry`. The user submits a single PTB that calls
// `mint_cosmetic_from_permit`: the call verifies the signature, consumes
// the permit's nonce (single-use), parses the payload, and mints the
// Cosmetic NFT to the caller. The user pays the gas; the keeper never pays
// per-claim mint gas after this is wired in.
//
// Wire format (Move peel order matches the JS BCS encode order):
//   address            recipient                       (32 bytes)
//   u64                nonce                           (8 bytes LE)
//   u8                 kind                            (0 outfit / 1 bg / 2 shell)
//   u8                 tier_gate
//   u8                 rarity                          (0..3)
//   vector<u8>         name UTF-8                      (ULEB128 length + bytes)
//   vector<u8>         walrus_identifier_standalone    (ULEB128 length + bytes)
//   vector<u8>         equipped_value                  (ULEB128 length + bytes)
//
// Security properties:
//   - Signature scheme is plain Ed25519 over raw payload bytes (no intent
//     prefix, no Blake2b hashing) — same shape as the Enoki ticketing POC.
//     The keeper must sign the EXACT bytes the Move side peels.
//   - Nonce is consumed on first redeem; a second attempt aborts with
//     `ENonceConsumed`. Nonces are random u64s issued by engagement-api.
//   - Sender must equal `recipient` in the payload — prevents a stolen
//     permit from being redeemed to a different wallet.
//   - `admin_set_pubkey` lets the admin rotate keys if the keeper key
//     leaks. Old nonces stay in the table so replays of pre-rotation
//     permits keep being rejected.

use std::string;
use sui::bcs;
use sui::ed25519;
use sui::event;
use sui::table::{Self, Table};
use trumpagotchi::trumpagotchi::{AdminCap, issue_cosmetic};

// ── Errors ─────────────────────────────────────────────────────────────────
const EBadSignature: u64 = 1;
const ENonceConsumed: u64 = 2;
const EBadPubkey: u64 = 3;
const ESenderMismatch: u64 = 4;
const EPubkeyUnset: u64 = 5;
const ECleanupEpochInFuture: u64 = 6;

// ── Constants ──────────────────────────────────────────────────────────────
const ED25519_PUBKEY_LEN: u64 = 32;

// ── Structs ────────────────────────────────────────────────────────────────
// Shared object. `pubkey` is the 32-byte Ed25519 public key the keeper uses
// to sign permits. `used_nonces` is the single-use bookkeeping table —
// each entry maps nonce → epoch consumed (epoch retained so admin can run
// `cleanup_nonces` later without losing replay protection for active ones).
public struct KeyRegistry has key {
    id: UID,
    pubkey: vector<u8>,
    used_nonces: Table<u64, u64>,
}

// ── Events ─────────────────────────────────────────────────────────────────
public struct RegistryCreated has copy, drop {
    registry_id: ID,
}

public struct PubkeyRotated has copy, drop {
    old: vector<u8>,
    new: vector<u8>,
}

public struct PermitRedeemed has copy, drop {
    recipient: address,
    nonce: u64,
    cosmetic_id: ID,
    epoch: u64,
}

public struct NoncesCleaned has copy, drop {
    before_epoch: u64,
    removed_count: u64,
}

// ── Admin: bootstrap + rotate ──────────────────────────────────────────────
// Create and share the registry. Called once post-upgrade. Starts with an
// empty pubkey — admin must call `admin_set_pubkey` before any redemption
// can succeed.
public fun create_registry(_admin: &AdminCap, ctx: &mut TxContext) {
    let registry = KeyRegistry {
        id: object::new(ctx),
        pubkey: vector[],
        used_nonces: table::new(ctx),
    };
    event::emit(RegistryCreated { registry_id: object::id(&registry) });
    transfer::share_object(registry);
}

public fun admin_set_pubkey(
    _admin: &AdminCap,
    registry: &mut KeyRegistry,
    new_pubkey: vector<u8>,
) {
    assert!(vector::length(&new_pubkey) == ED25519_PUBKEY_LEN, EBadPubkey);
    let old = registry.pubkey;
    registry.pubkey = new_pubkey;
    event::emit(PubkeyRotated { old, new: new_pubkey });
}

// Admin housekeeping. Caller supplies the candidate nonce list (built
// off-chain by scanning prior `PermitRedeemed` events). Each entry is
// removed iff present AND consumed before `before_epoch`. `before_epoch`
// must not be in the future so the admin can't accidentally wipe the
// entire table.
public fun cleanup_nonces(
    _admin: &AdminCap,
    registry: &mut KeyRegistry,
    before_epoch: u64,
    nonces_to_remove: vector<u64>,
    ctx: &TxContext,
) {
    assert!(before_epoch <= tx_context::epoch(ctx), ECleanupEpochInFuture);
    let mut i = 0;
    let n = vector::length(&nonces_to_remove);
    let mut removed: u64 = 0;
    while (i < n) {
        let nonce = *vector::borrow(&nonces_to_remove, i);
        if (table::contains(&registry.used_nonces, nonce)) {
            let consumed_epoch = *table::borrow(&registry.used_nonces, nonce);
            if (consumed_epoch < before_epoch) {
                table::remove(&mut registry.used_nonces, nonce);
                removed = removed + 1;
            };
        };
        i = i + 1;
    };
    event::emit(NoncesCleaned { before_epoch, removed_count: removed });
}

// ── User-callable: redeem a signed permit ──────────────────────────────────
// Called by the holder in their own PTB. The keeper has already signed
// `bcs_payload` off-chain and stored (signature, payload, nonce) in
// engagement-api. The frontend fetches these and submits this call.
public fun mint_cosmetic_from_permit(
    registry: &mut KeyRegistry,
    signature: vector<u8>,
    bcs_payload: vector<u8>,
    ctx: &mut TxContext,
): ID {
    assert!(
        vector::length(&registry.pubkey) == ED25519_PUBKEY_LEN,
        EPubkeyUnset,
    );

    // 1. Ed25519 verification over the raw payload bytes.
    assert!(
        ed25519::ed25519_verify(&signature, &registry.pubkey, &bcs_payload),
        EBadSignature,
    );

    // 2. Peel payload — order MUST match the JS encoder's field order.
    let mut peeler = bcs::new(bcs_payload);
    let recipient = bcs::peel_address(&mut peeler);
    let nonce = bcs::peel_u64(&mut peeler);
    let kind = bcs::peel_u8(&mut peeler);
    let tier_gate = bcs::peel_u8(&mut peeler);
    let rarity = bcs::peel_u8(&mut peeler);
    let name_bytes = bcs::peel_vec_u8(&mut peeler);
    let walrus_bytes = bcs::peel_vec_u8(&mut peeler);
    let equipped_bytes = bcs::peel_vec_u8(&mut peeler);

    // 3. Sender must equal the recipient encoded in the signed payload.
    assert!(tx_context::sender(ctx) == recipient, ESenderMismatch);

    // 4. Single-use nonce consumption (replay protection).
    assert!(!table::contains(&registry.used_nonces, nonce), ENonceConsumed);
    let epoch = tx_context::epoch(ctx);
    table::add(&mut registry.used_nonces, nonce, epoch);

    // 5. Mint via the existing package-internal cosmetic issuance path.
    //    issue_cosmetic emits CosmeticIssued + public_transfers to recipient,
    //    so the cosmetic lands in the user's wallet by the end of this PTB.
    let cid = issue_cosmetic(
        kind,
        string::utf8(name_bytes),
        tier_gate,
        rarity,
        string::utf8(walrus_bytes),
        string::utf8(equipped_bytes),
        recipient,
        ctx,
    );

    event::emit(PermitRedeemed {
        recipient,
        nonce,
        cosmetic_id: cid,
        epoch,
    });
    cid
}

// ── Views ──────────────────────────────────────────────────────────────────
public fun pubkey(registry: &KeyRegistry): vector<u8> { registry.pubkey }

public fun is_nonce_consumed(registry: &KeyRegistry, nonce: u64): bool {
    table::contains(&registry.used_nonces, nonce)
}

// ── Test helpers ───────────────────────────────────────────────────────────
#[test_only]
public fun create_registry_for_testing(ctx: &mut TxContext): KeyRegistry {
    KeyRegistry {
        id: object::new(ctx),
        pubkey: vector[],
        used_nonces: table::new(ctx),
    }
}

#[test_only]
public fun set_pubkey_for_testing(registry: &mut KeyRegistry, pubkey: vector<u8>) {
    registry.pubkey = pubkey;
}

#[test_only]
public fun destroy_for_testing(registry: KeyRegistry) {
    let KeyRegistry { id, pubkey: _, used_nonces } = registry;
    table::drop(used_nonces);
    object::delete(id);
}
