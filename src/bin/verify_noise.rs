//! Verify Noise protocol initialization against known values

use minnowvpn::crypto::blake2s;
use minnowvpn::protocol::handshake::InitiatorHandshake;
use base64::{engine::general_purpose::STANDARD as BASE64, Engine};

fn main() {
    println!("=== Noise Protocol Verification ===\n");

    // WireGuard constants
    let construction = b"Noise_IKpsk2_25519_ChaChaPoly_BLAKE2s";
    let identifier = b"WireGuard v1 zx2c4 Jason@zx2c4.com";
    let label_mac1 = b"mac1----";

    // Compute initial chaining key
    let ck = blake2s::hash(construction);
    println!("Initial chaining key (C = HASH(CONSTRUCTION)):");
    println!("  {}", hex::encode(&ck));

    // Compute H = HASH(C || IDENTIFIER)
    let h1 = blake2s::hash_two(&ck, identifier);
    println!("\nH = HASH(C || IDENTIFIER):");
    println!("  {}", hex::encode(&h1));

    // Use peer public key from config
    let peer_public_b64 = "YgkBjKXER5YarD8STsvMFURw/5nhCLIFOJ5uKWrrMW4=";
    let peer_public: [u8; 32] = BASE64
        .decode(peer_public_b64)
        .unwrap()
        .try_into()
        .unwrap();

    // Compute H = HASH(H || peer_public)
    let h2 = blake2s::hash_two(&h1, &peer_public);
    println!("\nH = HASH(H || peer_public):");
    println!("  {}", hex::encode(&h2));

    // Compute MAC1 key = HASH(LABEL_MAC1 || peer_public)
    let mac1_key = blake2s::hash_two(label_mac1, &peer_public);
    println!("\nMAC1 key = HASH(LABEL_MAC1 || peer_public):");
    println!("  {}", hex::encode(&mac1_key));

    // Now let's verify our InitiatorHandshake uses the same values
    println!("\n=== Verifying InitiatorHandshake ===");

    let private_key_b64 = "UOvtcWdILFwjb1UnsnK+a9lcqYvNTmtPv+fvqIVOz3w=";
    let private_key: [u8; 32] = BASE64
        .decode(private_key_b64)
        .unwrap()
        .try_into()
        .unwrap();

    let handshake = InitiatorHandshake::new(private_key, peer_public, None, 12345);

    println!("\nHandshake initial hash: {}", hex::encode(&handshake.noise_state.hash));
    println!("Expected (h2):          {}", hex::encode(&h2));
    println!("Match: {}", handshake.noise_state.hash == h2);

    println!("\nHandshake initial ck:   {}", hex::encode(&handshake.noise_state.chaining_key));
    println!("Expected (ck):          {}", hex::encode(&ck));
    println!("Match: {}", handshake.noise_state.chaining_key == ck);

    // Verify HMAC implementation
    println!("\n=== Verifying HMAC ===");

    // HMAC test vector from RFC 4231
    // HMAC-SHA-256 with key = 0x0b (20 bytes) and data = "Hi There"
    // We're using BLAKE2s, so we need different test vectors

    // Let's test the KDF functions
    let test_key = [0u8; 32];
    let test_input = b"test input";

    let (t1, t2) = blake2s::kdf2(&test_key, test_input);
    println!("\nKDF2 test with zero key:");
    println!("  T1: {}", hex::encode(&t1));
    println!("  T2: {}", hex::encode(&t2));

    // Verify T1 != T2
    println!("  T1 != T2: {}", t1 != t2);
}
