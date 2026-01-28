//! Detailed handshake trace with step-by-step comparison

use base64::{engine::general_purpose::STANDARD as BASE64, Engine};
use secureguard_poc::crypto::{blake2s, x25519, aead, noise};

fn main() {
    println!("=== Detailed Handshake Trace ===\n");
    
    // Config values
    let private_key_b64 = "0D3qFVX1k+IHHm3Qg7S9hX7LyrBhRdVVQgjMQ5CSh2E=";
    let peer_public_b64 = "YgkBjKXER5YarD8STsvMFURw/5nhCLIFOJ5uKWrrMW4=";
    
    let static_private: [u8; 32] = BASE64.decode(private_key_b64).unwrap().try_into().unwrap();
    let peer_static: [u8; 32] = BASE64.decode(peer_public_b64).unwrap().try_into().unwrap();
    let static_public = x25519::public_key(&static_private);
    
    println!("Static private: {}", hex::encode(&static_private));
    println!("Static public:  {}", hex::encode(&static_public));
    println!("Peer static:    {}", hex::encode(&peer_static));
    
    // Step 1: Initialize
    let mut ck = noise::HandshakeState::initial_chain_key();
    let mut hash = blake2s::hash_two(&ck, noise::IDENTIFIER);
    hash = blake2s::hash_two(&hash, &peer_static);
    
    println!("\n=== Initialization ===");
    println!("ck (HASH(CONSTRUCTION)):     {}", hex::encode(&ck));
    println!("hash after IDENTIFIER:        {}", hex::encode(&blake2s::hash_two(&noise::HandshakeState::initial_chain_key(), noise::IDENTIFIER)));
    println!("hash after peer_static:       {}", hex::encode(&hash));
    
    // Step 2: Generate ephemeral - use fixed for reproducibility
    let ephemeral_private: [u8; 32] = [
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
        0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f, 0x10,
        0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18,
        0x19, 0x1a, 0x1b, 0x1c, 0x1d, 0x1e, 0x1f, 0x20,
    ];
    let ephemeral_public = x25519::public_key(&ephemeral_private);
    
    println!("\n=== Ephemeral ===");
    println!("ephemeral_private: {}", hex::encode(&ephemeral_private));
    println!("ephemeral_public:  {}", hex::encode(&ephemeral_public));
    
    // Step 3: e - mix ephemeral into hash first
    hash = blake2s::hash_two(&hash, &ephemeral_public);
    println!("\n=== Step e: mix_hash(ephemeral) ===");
    println!("hash = HASH(hash || ephemeral): {}", hex::encode(&hash));
    
    // Step 4: e - KDF1 for chaining key
    ck = blake2s::kdf1(&ck, &ephemeral_public);
    println!("ck = KDF1(ck, ephemeral):       {}", hex::encode(&ck));
    
    // Step 5: es - DH(ephemeral, peer_static)
    let shared_es = x25519::dh(&ephemeral_private, &peer_static);
    println!("\n=== Step es: DH(ephemeral, peer_static) ===");
    println!("shared_es: {}", hex::encode(&shared_es));
    
    // Step 6: MixKey for es
    let (new_ck, key_es) = blake2s::kdf2(&ck, &shared_es);
    ck = new_ck;
    println!("After KDF2(ck, shared_es):");
    println!("  new ck: {}", hex::encode(&ck));
    println!("  key:    {}", hex::encode(&key_es));
    
    // Step 7: Encrypt static public key
    let encrypted_static = aead::encrypt(&key_es, 0, &static_public, &hash).unwrap();
    println!("\n=== Encrypt static ===");
    println!("plaintext (static_public): {}", hex::encode(&static_public));
    println!("AAD (current hash):        {}", hex::encode(&hash));
    println!("key:                       {}", hex::encode(&key_es));
    println!("encrypted_static:          {}", hex::encode(&encrypted_static));
    
    // Step 8: Mix hash with encrypted static
    hash = blake2s::hash_two(&hash, &encrypted_static);
    println!("hash after encrypted_static: {}", hex::encode(&hash));
    
    // Step 9: ss - DH(static, peer_static)
    let shared_ss = x25519::dh(&static_private, &peer_static);
    println!("\n=== Step ss: DH(static, peer_static) ===");
    println!("shared_ss: {}", hex::encode(&shared_ss));
    
    // Step 10: MixKey for ss
    let (new_ck, key_ss) = blake2s::kdf2(&ck, &shared_ss);
    ck = new_ck;
    println!("After KDF2(ck, shared_ss):");
    println!("  new ck: {}", hex::encode(&ck));
    println!("  key:    {}", hex::encode(&key_ss));
    
    // Step 11: Encrypt timestamp (use fixed for reproducibility)
    let timestamp: [u8; 12] = [0x40, 0x00, 0x00, 0x00, 0x65, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00];
    let encrypted_timestamp = aead::encrypt(&key_ss, 0, &timestamp, &hash).unwrap();
    println!("\n=== Encrypt timestamp ===");
    println!("plaintext (timestamp): {}", hex::encode(&timestamp));
    println!("AAD (current hash):    {}", hex::encode(&hash));
    println!("key:                   {}", hex::encode(&key_ss));
    println!("encrypted_timestamp:   {}", hex::encode(&encrypted_timestamp));
    
    // Step 12: Mix hash with encrypted timestamp
    hash = blake2s::hash_two(&hash, &encrypted_timestamp);
    println!("hash after encrypted_timestamp: {}", hex::encode(&hash));
    
    // Step 13: Compute MAC1
    let mac1_key = noise::mac1_key(&peer_static);
    println!("\n=== MAC1 ===");
    println!("mac1_key = HASH(\"mac1----\" || peer_static): {}", hex::encode(&mac1_key));
    
    // Build the message bytes for MAC1 (first 116 bytes)
    let mut msg = vec![0u8; 148];
    msg[0] = 1; // type
    msg[4..8].copy_from_slice(&0x12345678u32.to_le_bytes()); // sender_index
    msg[8..40].copy_from_slice(&ephemeral_public);
    msg[40..88].copy_from_slice(&encrypted_static);
    msg[88..116].copy_from_slice(&encrypted_timestamp);
    
    let mac1 = blake2s::mac(&mac1_key, &msg[..116]);
    println!("MAC1: {}", hex::encode(&mac1));
    
    // Copy MAC1 into message
    msg[116..132].copy_from_slice(&mac1);
    
    println!("\n=== Final Message ({} bytes) ===", msg.len());
    println!("Full: {}", hex::encode(&msg));
}
