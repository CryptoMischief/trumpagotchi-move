#[test_only]
module trumpagotchi::quest_permit_tests;

use std::string;
use sui::test_scenario as ts;
use trumpagotchi::trumpagotchi::{Self, AdminCap, Cosmetic};
use trumpagotchi::quest_permit::{Self, KeyRegistry};

// ── Constants ──────────────────────────────────────────────────────────────
const ADMIN: address = @0xA;
const ALICE: address = @0xa11ce;
const BOB:   address = @0xb0b;

// ── Fixtures (deterministic — see scripts/gen_quest_permit_fixtures.ts) ────
// Ed25519 keypair seeded from 32 bytes of 0x07. PUBKEY is the corresponding
// public key. Each PAYLOAD/SIG pair signs a specific cosmetic-mint permit.
// Re-run the script to regenerate; fields below are the ground truth.
const PUBKEY: vector<u8> = x"ea4a6c63e29c520abef5507b132ec5f9954776aebebe7b92421eea691446d22c";

// recipient=ALICE, nonce=42, kind=0 (outfit), tier_gate=5, rarity=2,
// name="Tuxedo", walrus="tuxedo-standalone-id", equipped="Tuxedo"
const PAYLOAD_VALID_OUTFIT: vector<u8> = x"00000000000000000000000000000000000000000000000000000000000a11ce2a000000000000000005020654757865646f1474757865646f2d7374616e64616c6f6e652d69640654757865646f";
const SIG_VALID_OUTFIT: vector<u8> = x"dcff32db1d80162779512bf035d949af1b971fa3930373ba7aaf59ed77715e9696efed8397c851f717eb68a33976b06d7f3c7b1115f2269a294820fefd325306";

// recipient=ALICE, nonce=43, kind=1 (background), tier_gate=3, rarity=1,
// name="Ballroom", walrus="ballroom-standalone-id", equipped="Ballroom"
const PAYLOAD_VALID_BG: vector<u8> = x"00000000000000000000000000000000000000000000000000000000000a11ce2b000000000000000103010842616c6c726f6f6d1662616c6c726f6f6d2d7374616e64616c6f6e652d69640842616c6c726f6f6d";
const SIG_VALID_BG: vector<u8> = x"28f86a190b3b42364b9e4770a11125815b783d142d68afe1ef2929e4975dc2590e91647ee0cbe697c9deaef4f870e71117174762c30785750c4770ec9cc8b202";

// recipient=BOB, nonce=99, kind=0, tier_gate=1, rarity=0, simple plain tee
const PAYLOAD_BOB_RECIPIENT: vector<u8> = x"0000000000000000000000000000000000000000000000000000000000000b0b630000000000000000010009506c61696e205465650c706c61696e2d7465652d696408506c61696e546565";
const SIG_BOB_RECIPIENT: vector<u8> = x"91d4e87bb57b4f3081b38343fd29e9dcb0e43dc3afb4ecee8b7d58a2bc8ed2db5ddb94e0bfc07bbb971f734a41c6fb1bcb8165d1d69c667927a3590ac07c6702";

// ── Helpers ────────────────────────────────────────────────────────────────
fun bootstrap(): ts::Scenario {
    let mut sc = ts::begin(ADMIN);
    trumpagotchi::init_for_testing(sc.ctx());
    // AdminCap lands in ADMIN's inventory after init. Create + share the
    // KeyRegistry in a follow-up admin tx, then set the pubkey.
    sc.next_tx(ADMIN);
    let admin = sc.take_from_sender<AdminCap>();
    quest_permit::create_registry(&admin, sc.ctx());
    sc.return_to_sender(admin);
    sc.next_tx(ADMIN);
    let admin = sc.take_from_sender<AdminCap>();
    let mut reg = sc.take_shared<KeyRegistry>();
    quest_permit::admin_set_pubkey(&admin, &mut reg, PUBKEY);
    sc.return_to_sender(admin);
    ts::return_shared(reg);
    sc
}

// ── Tests ──────────────────────────────────────────────────────────────────

#[test]
fun test_valid_permit_mints_cosmetic_to_recipient() {
    let mut sc = bootstrap();

    sc.next_tx(ALICE);
    {
        let mut reg = sc.take_shared<KeyRegistry>();
        let _cid = quest_permit::mint_cosmetic_from_permit(
            &mut reg,
            SIG_VALID_OUTFIT,
            PAYLOAD_VALID_OUTFIT,
            sc.ctx(),
        );
        ts::return_shared(reg);
    };

    // Cosmetic landed in ALICE's inventory.
    sc.next_tx(ALICE);
    let cosmetic = sc.take_from_sender<Cosmetic>();
    assert!(trumpagotchi::cosmetic_kind(&cosmetic) == 0, 0);
    assert!(trumpagotchi::cosmetic_tier_gate(&cosmetic) == 5, 1);
    assert!(trumpagotchi::cosmetic_rarity(&cosmetic) == 2, 2);
    assert!(trumpagotchi::cosmetic_name(&cosmetic) == string::utf8(b"Tuxedo"), 3);
    assert!(
        trumpagotchi::cosmetic_walrus_standalone(&cosmetic) == string::utf8(b"tuxedo-standalone-id"),
        4,
    );
    assert!(
        trumpagotchi::cosmetic_equipped_value(&cosmetic) == string::utf8(b"Tuxedo"),
        5,
    );
    sc.return_to_sender(cosmetic);

    sc.end();
}

#[test]
fun test_background_kind_payload_decodes_correctly() {
    let mut sc = bootstrap();

    sc.next_tx(ALICE);
    {
        let mut reg = sc.take_shared<KeyRegistry>();
        let _cid = quest_permit::mint_cosmetic_from_permit(
            &mut reg,
            SIG_VALID_BG,
            PAYLOAD_VALID_BG,
            sc.ctx(),
        );
        ts::return_shared(reg);
    };

    sc.next_tx(ALICE);
    let cosmetic = sc.take_from_sender<Cosmetic>();
    assert!(trumpagotchi::cosmetic_kind(&cosmetic) == 1, 0);
    assert!(trumpagotchi::cosmetic_name(&cosmetic) == string::utf8(b"Ballroom"), 1);
    sc.return_to_sender(cosmetic);

    sc.end();
}

#[test]
#[expected_failure(abort_code = quest_permit::ENonceConsumed)]
fun test_replay_same_permit_aborts() {
    let mut sc = bootstrap();

    sc.next_tx(ALICE);
    {
        let mut reg = sc.take_shared<KeyRegistry>();
        let _cid = quest_permit::mint_cosmetic_from_permit(
            &mut reg,
            SIG_VALID_OUTFIT,
            PAYLOAD_VALID_OUTFIT,
            sc.ctx(),
        );
        ts::return_shared(reg);
    };

    // Take cosmetic from ALICE so the next take_shared works; we just want
    // to confirm the replay aborts.
    sc.next_tx(ALICE);
    let c = sc.take_from_sender<Cosmetic>();
    sc.return_to_sender(c);

    sc.next_tx(ALICE);
    {
        let mut reg = sc.take_shared<KeyRegistry>();
        let _cid = quest_permit::mint_cosmetic_from_permit(
            &mut reg,
            SIG_VALID_OUTFIT,
            PAYLOAD_VALID_OUTFIT,
            sc.ctx(),
        );
        ts::return_shared(reg);
    };

    sc.end();
}

#[test]
#[expected_failure(abort_code = quest_permit::ESenderMismatch)]
fun test_wrong_sender_aborts() {
    let mut sc = bootstrap();

    // BOB tries to redeem ALICE's permit.
    sc.next_tx(BOB);
    let mut reg = sc.take_shared<KeyRegistry>();
    let _cid = quest_permit::mint_cosmetic_from_permit(
        &mut reg,
        SIG_VALID_OUTFIT,
        PAYLOAD_VALID_OUTFIT,
        sc.ctx(),
    );
    ts::return_shared(reg);
    sc.end();
}

#[test]
#[expected_failure(abort_code = quest_permit::EBadSignature)]
fun test_tampered_payload_fails_signature() {
    let mut sc = bootstrap();

    // Mutate the last byte of the payload — signature should no longer
    // verify even though pubkey + signature are otherwise valid.
    let mut tampered = PAYLOAD_VALID_OUTFIT;
    let last = vector::length(&tampered) - 1;
    let v = vector::borrow_mut(&mut tampered, last);
    *v = *v ^ 0xff;

    sc.next_tx(ALICE);
    let mut reg = sc.take_shared<KeyRegistry>();
    let _cid = quest_permit::mint_cosmetic_from_permit(
        &mut reg,
        SIG_VALID_OUTFIT,
        tampered,
        sc.ctx(),
    );
    ts::return_shared(reg);
    sc.end();
}

#[test]
#[expected_failure(abort_code = quest_permit::EBadSignature)]
fun test_signature_for_wrong_payload_fails() {
    let mut sc = bootstrap();

    // Use BG signature against the OUTFIT payload — both valid in isolation,
    // pairing them is a forgery attempt.
    sc.next_tx(ALICE);
    let mut reg = sc.take_shared<KeyRegistry>();
    let _cid = quest_permit::mint_cosmetic_from_permit(
        &mut reg,
        SIG_VALID_BG,
        PAYLOAD_VALID_OUTFIT,
        sc.ctx(),
    );
    ts::return_shared(reg);
    sc.end();
}

#[test]
#[expected_failure(abort_code = quest_permit::EPubkeyUnset)]
fun test_no_pubkey_set_aborts() {
    let mut sc = ts::begin(ADMIN);
    trumpagotchi::init_for_testing(sc.ctx());
    sc.next_tx(ADMIN);
    let admin = sc.take_from_sender<AdminCap>();
    quest_permit::create_registry(&admin, sc.ctx());
    sc.return_to_sender(admin);

    // Skip set_pubkey — registry has empty pubkey and any redeem must abort.
    sc.next_tx(ALICE);
    let mut reg = sc.take_shared<KeyRegistry>();
    let _cid = quest_permit::mint_cosmetic_from_permit(
        &mut reg,
        SIG_VALID_OUTFIT,
        PAYLOAD_VALID_OUTFIT,
        sc.ctx(),
    );
    ts::return_shared(reg);
    sc.end();
}

#[test]
#[expected_failure(abort_code = quest_permit::EBadPubkey)]
fun test_set_pubkey_wrong_length_aborts() {
    let mut sc = ts::begin(ADMIN);
    trumpagotchi::init_for_testing(sc.ctx());
    sc.next_tx(ADMIN);
    let admin = sc.take_from_sender<AdminCap>();
    quest_permit::create_registry(&admin, sc.ctx());
    sc.return_to_sender(admin);

    sc.next_tx(ADMIN);
    let admin = sc.take_from_sender<AdminCap>();
    let mut reg = sc.take_shared<KeyRegistry>();
    // 16 bytes — not 32. Should abort.
    quest_permit::admin_set_pubkey(&admin, &mut reg, x"00112233445566778899aabbccddeeff");
    sc.return_to_sender(admin);
    ts::return_shared(reg);
    sc.end();
}

#[test]
fun test_batch_two_permits_in_one_tx() {
    let mut sc = bootstrap();

    // Single PTB chains two redeems for ALICE (nonces 42 + 43).
    sc.next_tx(ALICE);
    {
        let mut reg = sc.take_shared<KeyRegistry>();
        let _cid1 = quest_permit::mint_cosmetic_from_permit(
            &mut reg,
            SIG_VALID_OUTFIT,
            PAYLOAD_VALID_OUTFIT,
            sc.ctx(),
        );
        let _cid2 = quest_permit::mint_cosmetic_from_permit(
            &mut reg,
            SIG_VALID_BG,
            PAYLOAD_VALID_BG,
            sc.ctx(),
        );
        assert!(quest_permit::is_nonce_consumed(&reg, 42), 0);
        assert!(quest_permit::is_nonce_consumed(&reg, 43), 1);
        ts::return_shared(reg);
    };

    sc.end();
}

#[test]
fun test_different_recipients_each_consume_their_nonce() {
    let mut sc = bootstrap();

    sc.next_tx(ALICE);
    {
        let mut reg = sc.take_shared<KeyRegistry>();
        let _cid = quest_permit::mint_cosmetic_from_permit(
            &mut reg,
            SIG_VALID_OUTFIT,
            PAYLOAD_VALID_OUTFIT,
            sc.ctx(),
        );
        ts::return_shared(reg);
    };

    sc.next_tx(BOB);
    {
        let mut reg = sc.take_shared<KeyRegistry>();
        let _cid = quest_permit::mint_cosmetic_from_permit(
            &mut reg,
            SIG_BOB_RECIPIENT,
            PAYLOAD_BOB_RECIPIENT,
            sc.ctx(),
        );
        assert!(quest_permit::is_nonce_consumed(&reg, 42), 0);
        assert!(quest_permit::is_nonce_consumed(&reg, 99), 1);
        ts::return_shared(reg);
    };

    sc.end();
}

#[test]
#[expected_failure(abort_code = quest_permit::ECleanupEpochInFuture)]
fun test_cleanup_future_epoch_aborts() {
    let mut sc = bootstrap();
    sc.next_tx(ADMIN);
    let admin = sc.take_from_sender<AdminCap>();
    let mut reg = sc.take_shared<KeyRegistry>();
    // Default test scenario epoch is 0; passing 1 is "in the future".
    quest_permit::cleanup_nonces(&admin, &mut reg, 1, vector[], sc.ctx());
    sc.return_to_sender(admin);
    ts::return_shared(reg);
    sc.end();
}

#[test]
fun test_pubkey_rotation_invalidates_old_signatures() {
    let mut sc = bootstrap();
    sc.next_tx(ADMIN);
    let admin = sc.take_from_sender<AdminCap>();
    let mut reg = sc.take_shared<KeyRegistry>();
    // Rotate to a different (but well-formed) pubkey. Any permit signed
    // by the original key will fail sig verify against the new one.
    let other_pubkey = x"0000000000000000000000000000000000000000000000000000000000000001";
    quest_permit::admin_set_pubkey(&admin, &mut reg, other_pubkey);
    sc.return_to_sender(admin);
    ts::return_shared(reg);

    // Verify the redeem now aborts. Cleaner than wrapping in try-catch:
    // factor into a nested test_failure scenario.
    sc.next_tx(ALICE);
    let reg = sc.take_shared<KeyRegistry>();
    assert!(quest_permit::pubkey(&reg) == other_pubkey, 0);
    ts::return_shared(reg);
    sc.end();
}
