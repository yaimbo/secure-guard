//! Debug initialization sequence

use minnowvpn::crypto::{blake2s, noise};

fn main() {
    println!("=== Debugging Noise Initialization ===\n");
    
    // Step by step following boringtun
    let construction = b"Noise_IKpsk2_25519_ChaChaPoly_BLAKE2s";
    let identifier = b"WireGuard v1 zx2c4 Jason@zx2c4.com";
    
    // CONSTRUCTION string
    println!("CONSTRUCTION: {:?}", std::str::from_utf8(construction).unwrap());
    println!("CONSTRUCTION bytes: {} bytes", construction.len());
    
    // IDENTIFIER string  
    println!("IDENTIFIER: {:?}", std::str::from_utf8(identifier).unwrap());
    println!("IDENTIFIER bytes: {} bytes", identifier.len());
    
    // Step 1: HASH(CONSTRUCTION) -> chaining_key
    let ck = blake2s::hash(construction);
    println!("\nStep 1: ck = HASH(CONSTRUCTION)");
    println!("  ck: {}", hex::encode(&ck));
    
    // Step 2: HASH(ck || IDENTIFIER) -> initial hash before peer static
    let h = blake2s::hash_two(&ck, identifier);
    println!("\nStep 2: h = HASH(ck || IDENTIFIER)");
    println!("  h: {}", hex::encode(&h));
    
    // Verify our noise module produces same values
    println!("\n=== Verification ===");
    let our_ck = noise::HandshakeState::initial_chain_key();
    println!("Our initial_chain_key(): {}", hex::encode(&our_ck));
    println!("Match ck: {}", our_ck == ck);
    
    // Check IDENTIFIER constant
    println!("\nOur IDENTIFIER constant: {:?}", std::str::from_utf8(noise::IDENTIFIER).unwrap());
    println!("Match IDENTIFIER: {}", noise::IDENTIFIER == identifier);
    
    // Now with peer static
    let peer_static = hex::decode("6209018ca5c447961aac3f124ecbcc154470ff99e108b205389e6e296aeb316e").unwrap();
    let peer_static: [u8; 32] = peer_static.try_into().unwrap();
    
    let h_with_peer = blake2s::hash_two(&h, &peer_static);
    println!("\nStep 3: h = HASH(h || peer_static)");
    println!("  h: {}", hex::encode(&h_with_peer));
    
    // Verify our initial_hash
    let our_h = noise::HandshakeState::initial_hash(&peer_static);
    println!("Our initial_hash(): {}", hex::encode(&our_h));
    println!("Match h_with_peer: {}", our_h == h_with_peer);
}
