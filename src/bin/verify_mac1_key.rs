//! Verify MAC1 key computation against peer's public key

use base64::{engine::general_purpose::STANDARD as BASE64, Engine};
use secureguard_poc::crypto::{blake2s, noise};

fn main() {
    // Peer's public key from config
    let peer_public_b64 = "YgkBjKXER5YarD8STsvMFURw/5nhCLIFOJ5uKWrrMW4=";
    let peer_public: [u8; 32] = BASE64.decode(peer_public_b64).unwrap().try_into().unwrap();

    println!("=== MAC1 Key Verification ===\n");
    println!("Peer public key (base64): {}", peer_public_b64);
    println!("Peer public key (hex): {}", hex::encode(&peer_public));

    // MAC1 label
    let label = b"mac1----";
    println!("\nMAC1 label: {:?} ({} bytes)", std::str::from_utf8(label).unwrap(), label.len());
    println!("Label hex: {}", hex::encode(label));

    // Manual computation: HASH(label || peer_public)
    let manual_key = blake2s::hash_two(label, &peer_public);
    println!("\nManual: HASH(label || peer_public)");
    println!("  Result: {}", hex::encode(&manual_key));

    // Using noise module
    let noise_key = noise::mac1_key(&peer_public);
    println!("\nUsing noise::mac1_key():");
    println!("  Result: {}", hex::encode(&noise_key));

    println!("\nMatch: {}", manual_key == noise_key);

    // Now let's compute what the MAC should be for a known message
    // We'll use a simple test: just the type byte
    let test_msg = [0x01u8; 116];
    let mac = blake2s::mac(&noise_key, &test_msg);
    println!("\nTest MAC of 116 0x01 bytes: {}", hex::encode(&mac));
}
