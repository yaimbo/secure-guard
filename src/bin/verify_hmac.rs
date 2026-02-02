//! Verify HMAC vs BLAKE2s keyed mode
//!
//! WireGuard's HMAC is defined as:
//!   HMAC(key, input) := BLAKE2s(input, 32, key) if len(key) <= 32
//!
//! This uses BLAKE2s's native keyed mode, not the standard HMAC construction.

use blake2::{Blake2sMac256, digest::Mac};
use minnowvpn::crypto::blake2s;

fn main() {
    println!("=== HMAC vs BLAKE2s Keyed Mode ===\n");

    let key = b"test key for hmac";
    let data = b"test data";

    // Our HMAC implementation (should now be using keyed mode)
    let our_hmac_result = blake2s::hmac(key, data);
    println!("Our HMAC implementation: {}", hex::encode(&our_hmac_result));

    // BLAKE2s keyed mode (what WireGuard uses)
    let keyed_result = blake2s_keyed(key, data);
    println!("BLAKE2s keyed mode:      {}", hex::encode(&keyed_result));

    println!("\nThey match: {}", our_hmac_result == keyed_result);

    // Test with a 32-byte key
    let key32 = [0x42u8; 32];
    let our_hmac_result32 = blake2s::hmac(&key32, data);
    let keyed_result32 = blake2s_keyed(&key32, data);
    println!("\nWith 32-byte key:");
    println!("Our HMAC implementation: {}", hex::encode(&our_hmac_result32));
    println!("BLAKE2s keyed mode:      {}", hex::encode(&keyed_result32));
    println!("They match: {}", our_hmac_result32 == keyed_result32);
}

fn blake2s_keyed(key: &[u8], data: &[u8]) -> [u8; 32] {
    // Use BLAKE2s with key parameter
    let mut mac = Blake2sMac256::new_from_slice(key).expect("valid key length");
    Mac::update(&mut mac, data);
    mac.finalize().into_bytes().into()
}
