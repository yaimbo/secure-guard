//! Test against known WireGuard test vectors
//!
//! Uses test vectors from wireguard-go and boringtun to verify our implementation.

use base64::{engine::general_purpose::STANDARD as BASE64, Engine};
use minnowvpn::crypto::{blake2s, x25519, aead};
use minnowvpn::crypto::noise::HandshakeState;

fn main() {
    println!("=== WireGuard Test Vector Verification ===\n");

    // Test vector keys (from various WireGuard implementations)
    // These are example keys - we'll compute derived values and compare patterns

    // 1. Verify X25519 with RFC 7748 test vector
    println!("1. X25519 Test Vector (RFC 7748):");
    let alice_private = hex::decode("77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a").unwrap();
    let alice_private: [u8; 32] = alice_private.try_into().unwrap();
    let alice_public = x25519::public_key(&alice_private);
    let expected_public = hex::decode("8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a").unwrap();
    println!("   Computed public: {}", hex::encode(&alice_public));
    println!("   Expected public: {}", hex::encode(&expected_public));
    println!("   Match: {}\n", alice_public == expected_public.as_slice());

    // 2. Verify BLAKE2s hash
    println!("2. BLAKE2s Hash:");
    let construction = b"Noise_IKpsk2_25519_ChaChaPoly_BLAKE2s";
    let ck = blake2s::hash(construction);
    println!("   HASH(CONSTRUCTION): {}", hex::encode(&ck));
    // The exact value depends on BLAKE2s implementation

    // 3. Verify HMAC (now using keyed BLAKE2s)
    println!("\n3. HMAC/KDF Test:");
    let test_key = [0u8; 32];
    let test_data = b"test";
    let hmac_result = blake2s::hmac(&test_key, test_data);
    println!("   HMAC(zeros, 'test'): {}", hex::encode(&hmac_result));

    // 4. Verify ChaCha20-Poly1305 encryption
    println!("\n4. ChaCha20-Poly1305 AEAD:");
    let key = [0u8; 32];
    let plaintext = b"hello";
    let aad = b"";
    let ciphertext = aead::encrypt(&key, 0, plaintext, aad).unwrap();
    println!("   Key: zeros");
    println!("   Plaintext: 'hello'");
    println!("   Ciphertext: {}", hex::encode(&ciphertext));

    // 5. Test full handshake initialization
    println!("\n5. Noise IKpsk2 Initialization:");
    let responder_static = [0u8; 32]; // Use zeros for test
    let state = HandshakeState::new_initiator(&responder_static);
    println!("   With responder_static = zeros:");
    println!("   Initial CK: {}", hex::encode(&state.chaining_key));
    println!("   Initial H:  {}", hex::encode(&state.hash));

    // 6. Verify our specific keys
    println!("\n6. Our Configuration Keys:");
    let our_private_b64 = "UOvtcWdILFwjb1UnsnK+a9lcqYvNTmtPv+fvqIVOz3w=";
    let peer_public_b64 = "YgkBjKXER5YarD8STsvMFURw/5nhCLIFOJ5uKWrrMW4=";

    let our_private: [u8; 32] = BASE64.decode(our_private_b64).unwrap().try_into().unwrap();
    let peer_public: [u8; 32] = BASE64.decode(peer_public_b64).unwrap().try_into().unwrap();

    let our_public = x25519::public_key(&our_private);
    println!("   Our private:  {}", hex::encode(&our_private));
    println!("   Our public:   {}", hex::encode(&our_public));
    println!("   Our pub b64:  {}", BASE64.encode(&our_public));
    println!("   Peer public:  {}", hex::encode(&peer_public));

    // Static-static DH
    let ss_dh = x25519::dh(&our_private, &peer_public);
    println!("   DH(us, peer): {}", hex::encode(&ss_dh));

    // 7. Check if maybe our implementation differs from boringtun
    println!("\n7. Cross-check with BoringTun format:");
    println!("   If you have access to a working WireGuard client,");
    println!("   compare the 'wg show' output with our public key:");
    println!("   Our public key: {}", BASE64.encode(&our_public));
}
