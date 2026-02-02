//! Compare our crypto with boringtun's

use minnowvpn::crypto::blake2s as our_blake2s;

fn main() {
    println!("=== Comparing with boringtun ===\n");
    
    // Test HMAC
    let key = [0x42u8; 32];
    let data = b"test data";
    
    let our_hmac = our_blake2s::hmac(&key, data);
    println!("Our HMAC:      {}", hex::encode(&our_hmac));
    
    // Test KDF1
    let our_kdf1 = our_blake2s::kdf1(&key, data);
    println!("Our KDF1:      {}", hex::encode(&our_kdf1));
    
    // Test KDF2
    let (our_kdf2_1, our_kdf2_2) = our_blake2s::kdf2(&key, data);
    println!("Our KDF2[0]:   {}", hex::encode(&our_kdf2_1));
    println!("Our KDF2[1]:   {}", hex::encode(&our_kdf2_2));
    
    // Test MAC (16 bytes)
    let our_mac = our_blake2s::mac(&key, data);
    println!("Our MAC16:     {}", hex::encode(&our_mac));
    
    // Test hash
    let our_hash = our_blake2s::hash(data);
    println!("Our HASH:      {}", hex::encode(&our_hash));
    
    // Test hash_two
    let our_hash2 = our_blake2s::hash_two(&key, data);
    println!("Our HASH_TWO:  {}", hex::encode(&our_hash2));
    
    println!("\nThese values can be compared with boringtun's output");
    println!("or WireGuard test vectors to verify correctness.");
}
