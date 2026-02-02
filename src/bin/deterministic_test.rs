//! Test with fixed keys to compare with other implementations

use minnowvpn::crypto::{blake2s, x25519, aead, noise};

fn main() {
    println!("=== Deterministic Handshake Test ===\n");
    
    // Use fixed keys that we can compare with other implementations
    // These are test vectors - DO NOT use in production
    
    // Initiator (us)
    let initiator_private: [u8; 32] = [
        0x98, 0x1e, 0xb8, 0x4c, 0x5a, 0x5c, 0x36, 0x17, 
        0x2f, 0xa2, 0x81, 0x84, 0x0f, 0x93, 0x15, 0xd5,
        0x65, 0x6e, 0x25, 0x4f, 0xb4, 0xd0, 0x11, 0x7c,
        0xf1, 0x41, 0x02, 0x45, 0x72, 0x76, 0xd4, 0x6a,
    ];
    let initiator_public = x25519::public_key(&initiator_private);
    
    // Responder (server)
    let responder_private: [u8; 32] = [
        0x48, 0xfb, 0xe5, 0x46, 0x66, 0xf4, 0xf5, 0x54,
        0xad, 0xc4, 0x2c, 0xd6, 0x58, 0x04, 0xe1, 0x6c,
        0x38, 0xdd, 0x03, 0x87, 0x14, 0x6e, 0x2b, 0x14,
        0x6a, 0xab, 0x76, 0xe5, 0xb6, 0x0e, 0xb7, 0x47,
    ];
    let responder_public = x25519::public_key(&responder_private);
    
    // Fixed ephemeral (for deterministic output)
    let ephemeral_private: [u8; 32] = [
        0xe0, 0x1e, 0x57, 0xf8, 0x74, 0xe8, 0x01, 0x48,
        0x82, 0xa0, 0x1d, 0x60, 0xf8, 0x77, 0x37, 0xe7,
        0x49, 0x47, 0x41, 0xa9, 0x5b, 0x1d, 0x50, 0x14,
        0xf9, 0x8d, 0x75, 0xea, 0xf6, 0x93, 0x8a, 0x5a,
    ];
    let ephemeral_public = x25519::public_key(&ephemeral_private);
    
    println!("Initiator static private: {}", hex::encode(&initiator_private));
    println!("Initiator static public:  {}", hex::encode(&initiator_public));
    println!("Responder static public:  {}", hex::encode(&responder_public));
    println!("Ephemeral private:        {}", hex::encode(&ephemeral_private));
    println!("Ephemeral public:         {}", hex::encode(&ephemeral_public));
    
    // Initialize noise state
    let mut ck = noise::HandshakeState::initial_chain_key();
    let mut hash = blake2s::hash_two(&ck, noise::IDENTIFIER);
    hash = blake2s::hash_two(&hash, &responder_public);
    
    println!("\n=== Initial State ===");
    println!("ck:   {}", hex::encode(&ck));
    println!("hash: {}", hex::encode(&hash));
    
    // e: mix_hash then KDF1
    hash = blake2s::hash_two(&hash, &ephemeral_public);
    ck = blake2s::kdf1(&ck, &ephemeral_public);
    
    println!("\n=== After ephemeral ===");
    println!("ck:   {}", hex::encode(&ck));
    println!("hash: {}", hex::encode(&hash));
    
    // es: DH and KDF2
    let shared_es = x25519::dh(&ephemeral_private, &responder_public);
    println!("DH(e, S_r): {}", hex::encode(&shared_es));
    
    let (new_ck, key_es) = blake2s::kdf2(&ck, &shared_es);
    ck = new_ck;
    
    println!("\n=== After es DH ===");
    println!("ck:  {}", hex::encode(&ck));
    println!("key: {}", hex::encode(&key_es));
    
    // Encrypt static
    let encrypted_static = aead::encrypt(&key_es, 0, &initiator_public, &hash).unwrap();
    println!("\n=== Encrypted static ===");
    println!("ciphertext: {}", hex::encode(&encrypted_static));
    
    // Mix hash
    hash = blake2s::hash_two(&hash, &encrypted_static);
    println!("hash: {}", hex::encode(&hash));
    
    // ss: DH and KDF2
    let shared_ss = x25519::dh(&initiator_private, &responder_public);
    println!("\nDH(S_i, S_r): {}", hex::encode(&shared_ss));
    
    let (new_ck, key_ss) = blake2s::kdf2(&ck, &shared_ss);
    ck = new_ck;
    
    println!("\n=== After ss DH ===");
    println!("ck:  {}", hex::encode(&ck));
    println!("key: {}", hex::encode(&key_ss));
    
    // Encrypt timestamp (use fixed timestamp for determinism)
    let timestamp: [u8; 12] = [0x40, 0x00, 0x00, 0x00, 0x65, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00];
    let encrypted_timestamp = aead::encrypt(&key_ss, 0, &timestamp, &hash).unwrap();
    println!("\n=== Encrypted timestamp ===");
    println!("ciphertext: {}", hex::encode(&encrypted_timestamp));
    
    // MAC1
    let mac1_key = noise::mac1_key(&responder_public);
    println!("\n=== MAC1 ===");
    println!("mac1_key: {}", hex::encode(&mac1_key));
    
    // Build message for MAC1
    let mut msg = [0u8; 116];
    msg[0] = 1; // type
    msg[4..8].copy_from_slice(&0x12345678u32.to_le_bytes());
    msg[8..40].copy_from_slice(&ephemeral_public);
    msg[40..88].copy_from_slice(&encrypted_static);
    msg[88..116].copy_from_slice(&encrypted_timestamp);
    
    let mac1 = blake2s::mac(&mac1_key, &msg);
    println!("mac1: {}", hex::encode(&mac1));
    
    println!("\n=== Final packet (first 116 bytes) ===");
    println!("{}", hex::encode(&msg));
}
