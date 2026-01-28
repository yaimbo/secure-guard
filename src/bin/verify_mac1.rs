//! Verify MAC1 key computation

use base64::{engine::general_purpose::STANDARD as BASE64, Engine};
use secureguard_poc::crypto::blake2s;

fn main() {
    println!("=== MAC1 Key Verification ===\n");

    // Peer's public key from config
    let peer_public_b64 = "YgkBjKXER5YarD8STsvMFURw/5nhCLIFOJ5uKWrrMW4=";
    let peer_public: [u8; 32] = BASE64.decode(peer_public_b64).unwrap().try_into().unwrap();

    println!("Peer public key: {}", hex::encode(&peer_public));

    // MAC1 label
    let label_mac1 = b"mac1----";
    println!("MAC1 label: {:?}", std::str::from_utf8(label_mac1).unwrap());

    // Compute MAC1 key = HASH(LABEL_MAC1 || peer_public)
    let mac1_key = blake2s::hash_two(label_mac1, &peer_public);
    println!("\nMAC1 key = HASH(label || peer_public):");
    println!("  Full:     {}", hex::encode(&mac1_key));
    println!("  First 8:  {:02x?}", &mac1_key[..8]);

    // This should match what we see in debug output:
    // MAC1 key: [f0, 73, 77, 63, 4c, 85, a2, dd]
    println!("\nExpected first 8 bytes from debug: [f0, 73, 77, 63, 4c, 85, a2, dd]");
    println!("Match: {}", &mac1_key[..8] == [0xf0, 0x73, 0x77, 0x63, 0x4c, 0x85, 0xa2, 0xdd]);
}
