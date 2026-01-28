//! Self-test: verify we can decrypt our own handshake
//! This simulates what the server does when it receives our handshake

use base64::{engine::general_purpose::STANDARD as BASE64, Engine};
use secureguard_poc::crypto::{blake2s, x25519, aead, noise};
use secureguard_poc::protocol::handshake::InitiatorHandshake;

fn main() {
    println!("=== Self-Test: Decrypt Our Own Handshake ===\n");
    
    // Our keys (client/initiator)
    let initiator_private_b64 = "0D3qFVX1k+IHHm3Qg7S9hX7LyrBhRdVVQgjMQ5CSh2E=";
    let initiator_private: [u8; 32] = BASE64.decode(initiator_private_b64).unwrap().try_into().unwrap();
    let initiator_public = x25519::public_key(&initiator_private);
    
    // Server keys (responder) - we'll generate a test pair
    let (responder_private, responder_public) = x25519::generate_keypair();
    
    println!("Initiator public: {}", BASE64.encode(&initiator_public));
    println!("Responder public: {}", BASE64.encode(&responder_public));
    
    // Create handshake initiation (as client)
    let mut handshake = InitiatorHandshake::new(
        initiator_private,
        responder_public,  // We're talking to our test server
        None,
        0x12345678,
    );
    
    let init = handshake.create_initiation(None).expect("create initiation");
    let msg_bytes = init.to_bytes();
    
    println!("\n--- Handshake created, now simulating server processing ---\n");
    
    // === SERVER SIDE: Process the handshake initiation ===
    
    // Step 1: Verify MAC1
    let mac1_key = noise::mac1_key(&responder_public);
    let expected_mac1 = blake2s::mac(&mac1_key, &msg_bytes[..116]);
    let actual_mac1 = &msg_bytes[116..132];
    
    println!("MAC1 verification:");
    println!("  Expected: {}", hex::encode(&expected_mac1));
    println!("  Actual:   {}", hex::encode(actual_mac1));
    println!("  Match: {}", expected_mac1 == actual_mac1);
    
    if expected_mac1 != actual_mac1 {
        println!("\n*** MAC1 VERIFICATION FAILED! ***");
        return;
    }
    
    // Step 2: Initialize noise state (as responder)
    let mut ck = noise::HandshakeState::initial_chain_key();
    let mut hash = blake2s::hash_two(&ck, noise::IDENTIFIER);
    hash = blake2s::hash_two(&hash, &responder_public);  // Responder's own public key
    
    println!("\nServer initial state:");
    println!("  ck: {:02x?}", &ck[..8]);
    println!("  hash: {:02x?}", &hash[..8]);
    
    // Step 3: Extract ephemeral from message
    let ephemeral_public: [u8; 32] = msg_bytes[8..40].try_into().unwrap();
    println!("\nEphemeral from message: {:02x?}", &ephemeral_public[..8]);
    
    // Step 4: mix_hash(ephemeral)
    hash = blake2s::hash_two(&hash, &ephemeral_public);
    println!("After mix_hash(e): {:02x?}", &hash[..8]);
    
    // Step 5: KDF1(ck, ephemeral)
    ck = blake2s::kdf1(&ck, &ephemeral_public);
    println!("After KDF1(ck, e): {:02x?}", &ck[..8]);
    
    // Step 6: DH(responder_private, ephemeral) and KDF2
    let shared_se = x25519::dh(&responder_private, &ephemeral_public);
    println!("DH(s, e): {:02x?}", &shared_se[..8]);
    
    let (new_ck, key) = blake2s::kdf2(&ck, &shared_se);
    ck = new_ck;
    println!("After KDF2: ck={:02x?}, key={:02x?}", &ck[..8], &key[..8]);
    
    // Step 7: Decrypt initiator's static public key
    let encrypted_static = &msg_bytes[40..88];
    println!("\nDecrypting initiator's static public key...");
    println!("  Ciphertext: {}", hex::encode(&encrypted_static[..16]));
    println!("  AAD (hash): {:02x?}", &hash[..8]);
    
    match aead::decrypt(&key, 0, encrypted_static, &hash) {
        Ok(decrypted_static) => {
            let decrypted_static: [u8; 32] = decrypted_static.try_into().expect("32 bytes");
            println!("  Decrypted: {}", hex::encode(&decrypted_static));
            println!("  Expected:  {}", hex::encode(&initiator_public));
            println!("  Match: {}", decrypted_static == initiator_public);
            
            if decrypted_static != initiator_public {
                println!("\n*** STATIC KEY MISMATCH! ***");
                return;
            }
            
            // Continue with ss DH
            hash = blake2s::hash_two(&hash, encrypted_static);
            
            let shared_ss = x25519::dh(&responder_private, &decrypted_static);
            println!("\nDH(s, S_i): {:02x?}", &shared_ss[..8]);
            
            let (new_ck, key) = blake2s::kdf2(&ck, &shared_ss);
            ck = new_ck;
            println!("After KDF2(ss): ck={:02x?}, key={:02x?}", &ck[..8], &key[..8]);
            
            // Decrypt timestamp
            let encrypted_timestamp = &msg_bytes[88..116];
            match aead::decrypt(&key, 0, encrypted_timestamp, &hash) {
                Ok(timestamp) => {
                    println!("\nTimestamp decrypted successfully!");
                    println!("  Timestamp: {}", hex::encode(&timestamp));
                    println!("\n*** SELF-TEST PASSED! ***");
                    println!("Our handshake can be decrypted correctly.");
                }
                Err(e) => {
                    println!("\n*** TIMESTAMP DECRYPTION FAILED: {:?} ***", e);
                }
            }
        }
        Err(e) => {
            println!("\n*** STATIC DECRYPTION FAILED: {:?} ***", e);
        }
    }
}
